# Story 9.1: Gate Command Mode records out of Re-paste

Status: done

<!-- Remediation story. Source: adversarial acceptance audit, 2026-08-22.
Violates Epic 6 AC ("the instruction text is never injected into the
document" — epics.md:944, Story 6.3). -->

## Story

As a user who uses Command Mode to rewrite selected text,
I want Re-paste to refuse Command Mode history records,
So that my spoken instruction ("make this shorter") can never be typed into a document as if it were dictated content.

## Context / Defect

A Command Mode history record stores the spoken **instruction** in both
`rawTranscript` and `finalText` (`AppState.recordCommandHistory`,
`Sources/VocaMac/Models/AppState.swift:1644-1665`) — deliberately, per the
doc comment there: the selection and the rewrite are document content and
AD-5 forbids persisting them, so the instruction is the only thing left to
show as the record's preview/detail text.

That is fine for *display*. It is not fine for *Re-paste*: `rePaste(_:)`
(`AppState.swift:1728-1749`) reads `record.finalText` and injects it
unfiltered via `textInjector.inject(...)`, with no check on `record.mode`.
`rePasteMostRecent()` (`AppState.swift:1770-1776`) forwards straight to
`historyStore.records.first`, again with no mode check. The result: hitting
Re-paste on a Command Mode record types the user's spoken instruction into
whatever app has focus — exactly the failure Epic 6's AC says must never
happen ("the instruction text is never injected into the document",
epics.md:944).

`HistoryView.swift:202-203` already labels the field honestly ("Instruction
(spoken)") for a command record, but the Re-paste button right below it
(`HistoryView.swift:211-216`) is not gated on `record.mode`, and neither is
the context-menu "Re-paste" item on the list row (`HistoryView.swift:29-32`).

`HistoryRecord.Mode` is `dictation` / `command`
(`Sources/VocaMac/Models/HistoryRecord.swift:18-21`).

## Acceptance Criteria

1. `AppState.rePaste(_:)` refuses a record whose `mode == .command`: no call
   to `textInjector.inject(...)` happens, and `appStatus`/`lastInjection`
   are left unchanged. (No new History Record either way — re-paste never
   writes one.)
2. `AppState.rePasteMostRecent()` skips command-mode records when picking
   what to re-paste: it re-pastes the most recent **dictation** record, or
   does nothing if `historyStore.records` contains no dictation record at
   all (including when it is empty).
3. `HistoryView` hides or disables the Re-paste control for a command-mode
   record — both the context-menu item on the list row (`HistoryView.swift:
   29-32`) and the button in `HistoryDetailView` (`HistoryView.swift:
   211-216`).
4. Unit tests pin (1) and (2) using the existing `TextInjector` mock
   (`mocks.textInjector`) and the existing `AppStateRePasteTests` class in
   `Tests/VocaMacTests/HistoryStoreTests.swift`.
5. Full suite green (`swift test`).

## Tasks / Subtasks

- [x] Task 1 — Guard `rePaste` (AC: 1)
  - [x] In `AppState.rePaste(_:)` (`AppState.swift:1728`), add an early
        return when `record.mode == .command`, before the idle-status guard
        or right after it — either order is fine as long as no injection
        occurs and the existing idle/generation logic for dictation records
        is untouched. Log via `VocaLogger.info(.appState, ...)` matching the
        existing style in that function (e.g. the "ignoring" log at
        `AppState.swift:1730`).
- [x] Task 2 — Guard `rePasteMostRecent` (AC: 2)
  - [x] In `AppState.rePasteMostRecent()` (`AppState.swift:1770`), change
        `historyStore.records.first` to `historyStore.records.first(where:
        { $0.mode != .command })` (records are newest-first, per the
        existing doc comment on that function and on
        `testRePasteMostRecentInjectsTheNewestRecord`). Keep the existing
        "nothing to do" log/no-op path when there is no match.
- [x] Task 3 — Gate the UI (AC: 3)
  - [x] `HistoryView.swift:29-32` (list row context menu): only show the
        "Re-paste" `Button` when `record.mode != .command` (or disable it —
        match whichever the codebase already does elsewhere for a
        conditionally-unavailable action; a plain `if` around the `Button`
        is simplest and matches this file's existing conditional rendering
        style, e.g. `HistoryView.swift:191, 204-209`).
  - [x] `HistoryView.swift:211-216` (`HistoryDetailView`'s Re-paste
        button): same treatment, keyed on `record.mode == .command` (the
        check already used at `HistoryView.swift:202`).
- [x] Task 4 — Tests (AC: 4)
  - [x] Add to `AppStateRePasteTests` in
        `Tests/VocaMacTests/HistoryStoreTests.swift` (style precedent:
        `testRePasteInjectsTheGivenRecordsFinalText`, line 485):
        - `testRePasteRefusesACommandModeRecord`: build a
          `HistoryRecord(rawTranscript: "make this shorter", finalText:
          "make this shorter", modelName: "Tiny", mode: .command)`, call
          `appState.rePaste(record)`, assert
          `mocks.textInjector.injectCallCount == 0`.
        - `testRePasteMostRecentSkipsCommandModeRecords`: seed
          `mocks.historyStore.records` with a newest command-mode record
          and an older dictation record (mirror the two-record setup in
          `testRePasteMostRecentInjectsTheNewestRecord`, line 518), call
          `appState.rePasteMostRecent()`, assert
          `mocks.textInjector.lastInjectedText` equals the older
          dictation record's `finalText`.
        - `testRePasteMostRecentDoesNothingWhenOnlyCommandRecordsExist`:
          seed only command-mode records, call `rePasteMostRecent()`,
          assert `injectCallCount == 0`.
- [x] Task 5 — Full suite (AC: 5)
  - [x] `swift test` green.

## Dev Notes

- Repo is Swift/SwiftPM (Xcode 26.6 installed); `swift test` works from the
  repo root. Baseline: 784 tests green before this story.
- Minimal, surgical diffs only — do not touch unrelated logic in `rePaste`,
  `rePasteMostRecent`, or `HistoryView`. Match existing style (log wording,
  guard-clause shape, SwiftUI conditional-view idiom already used in the
  same file).
- `HistoryRecord.Mode` (`HistoryRecord.swift:18-21`) is the only field
  needed to distinguish the two record kinds — no new model field required.
- `AppState.makeTestState()` (`Tests/VocaMacTests/Mocks/MockServices.swift:
  871`) returns `(appState, mocks)`; `mocks.textInjector` is a
  `MockTextInjector` with `injectCallCount` / `lastInjectedText` /
  `lastPreserveClipboard`, already used throughout
  `AppStateRePasteTests`.
- Do not add tests for the idle/generation gating already covered by
  `testRePasteIsIgnoredWhileRecording` etc. — this story only adds the
  mode gate.
- No commits by the dev agent.

### Project Structure Notes

- Changes confined to `Sources/VocaMac/Models/AppState.swift`,
  `Sources/VocaMac/Views/HistoryView.swift`, and
  `Tests/VocaMacTests/HistoryStoreTests.swift`. No new files needed.

### References

- [Source: Sources/VocaMac/Models/AppState.swift:1644-1665, 1728-1776]
- [Source: Sources/VocaMac/Views/HistoryView.swift:20-67, 174-226]
- [Source: Sources/VocaMac/Models/HistoryRecord.swift:14-106]
- [Source: Tests/VocaMacTests/HistoryStoreTests.swift:483-582]
- [Source: _bmad-output/planning-artifacts/epics.md:940-960 (Epic 6, Story 6.3 AC)]

## Dev Agent Record

### Agent Model Used

claude-opus-5[1m] (bmad-build, dev agent)

### Debug Log References

- `swift test` — 789 tests, 1 skipped, 0 failures (2026-08-22).
- `swift test --filter AppStateRePasteTests` — 12 tests, 0 failures; the three
  new tests are confirmed to have run, not merely compiled.

### Completion Notes List

- The `mode == .command` guard in `rePaste(_:)` sits **before** the idle
  guard, so a command record is refused regardless of `appStatus`. It returns
  before `dictationGeneration` is read and before `withTargetAppActivated`,
  so no injection, no `appStatus` write, no `lastInjection` write, and no
  target-app re-activation happens (AC 1).
- `rePasteMostRecent()` now picks `records.first(where: { $0.mode != .command })`.
  The existing "no history — nothing to do" log/no-op path now also covers
  "history holds only command records" (AC 2); the wording was left as-is
  rather than broadened, per the surgical-diff instruction.
- Both Re-paste controls are **hidden** rather than disabled for a command
  record — a plain `if` matches this file's existing conditional-view style
  (`HistoryView.swift:191, 204-209`) and the story's stated preference (AC 3).
- Baseline was 784 tests; the suite now reports 789 because concurrent Epic 9
  stories landed tests in the same run. All green.
- No commits made.

### File List

- `Sources/VocaMac/Models/HistoryRecord.swift` — modified (added
  `isRePastable` computed property — allowlist on `.dictation`)
- `Sources/VocaMac/Models/AppState.swift` — modified (`rePaste(_:)` and
  `rePasteMostRecent()` gates now use `isRePastable`; "no history" log
  message distinguishes empty history from command-only history)
- `Sources/VocaMac/Views/HistoryView.swift` — modified (both Re-paste gates
  now use `isRePastable`; added a secondary caption in the detail pane
  explaining why Re-paste is hidden for a command record)
- `Sources/VocaMac/Views/MenuBarView.swift` — modified ("Re-paste Last" row
  now disabled via `isRePastable`, not `records.isEmpty`)
- `Tests/VocaMacTests/HistoryStoreTests.swift` — modified (added
  `testIsRePastableIsTrueOnlyForDictationMode`; strengthened
  `testRePasteMostRecentSkipsCommandModeRecords` with an `injectCallCount`
  assertion)

### Change Log

| Date | Change |
| --- | --- |
| 2026-08-22 | Implemented ACs 1-5: mode gate on `rePaste`/`rePasteMostRecent`, both UI Re-paste controls gated, 3 tests added, full suite green. Status → review. |
| 2026-08-22 | Closed all four code-review MINORs: introduced `HistoryRecord.isRePastable` (allowlist on `.dictation`, fails closed on a future mode) and used it at all four existing gates plus `MenuBarView.swift:488`'s "Re-paste Last" row (previously ungated, MINOR 1/3); reworded the `rePasteMostRecent` no-op log to distinguish "no history" from "only Command Mode records" (MINOR 2); added an explanatory caption in the detail pane when Re-paste is hidden (MINOR 4); added `testIsRePastableIsTrueOnlyForDictationMode` and an `injectCallCount` assertion to `testRePasteMostRecentSkipsCommandModeRecords`. Full suite green (795 tests, 1 skipped, 0 failures). Status left at review.|

---

**Validation: PASSED 2026-08-22** — ACs are concrete and independently
testable (mode-gated behavior on two named functions plus two named UI call
sites); context is self-contained (exact file/line anchors for both the
defect and every touch point, existing test class and mock APIs identified,
no external doc lookups required); Dev Notes name every file the diff should
touch and nothing else. No fixes needed.

---

## Code Review

**Verdict: APPROVED-WITH-NOTES** — 2026-08-22, fresh adversarial review
(`bmad-code-review`; blind-hunter, edge-case, verification-gap and
acceptance-audit lenses, plus independent reviewer verification). The
security-relevant contract holds: **there is no reachable path that injects a
Command Mode record's instruction text.** All findings are MINOR polish; none
blocks. Nothing was fixed by the reviewer — source is untouched.

### Verification performed (not taken on trust)

| Check | Result |
| --- | --- |
| `swift test --filter AppStateRePasteTests` | 12 tests, 0 failures. All three new tests confirmed *executed*, not merely compiled. |
| `swift test` (full suite) | 794 tests, 1 skipped, **0 failures**, exit 0. (Story claimed 789 — the delta is sibling Epic 9 stories landing tests in the same tree, consistent with the dev note.) |
| Diff scope | `git diff HEAD` on the three File List paths touches only `rePaste`-related code. No sibling story (9-2/9-3/9-4) code is entangled in the reviewed hunks. |
| Bypass audit | `rePaste` has exactly **three** call sites: `MenuBarView.swift:470` (via `rePasteMostRecent`), `HistoryView.swift:35`, `HistoryView.swift:65`. `HotKeyManager`/`HotKeyBinding` expose **no** re-paste action (hotkeys drive push-to-talk and Command Mode recording only) — no keyboard-shortcut bypass. No other code reads a record's text and injects it; the only other consumer is display (`HistoryView.swift:210`). |
| Defense in depth | The guard lives in the model (`AppState.swift:1733`), so the two hidden UI controls are a second layer, not the only barrier. Even `HistoryView.swift:65`'s unconditional `onRePaste` closure is safe. |
| Concurrency | `AppState` is `@MainActor` (`AppState.swift:55`); `historyStore.records` is read on the main actor with no `await` between `first(where:)` and `rePaste`, so no interleaving. `HistoryRecord` is a value-type `struct` captured **before** the `focusSettleDelay` hop, so the mode check cannot go stale mid-flight. |

### AC-by-AC

- **AC 1 — MET.** The `mode != .command` guard sits *before* the idle guard, so a command record is refused regardless of `appStatus`. It returns before `dictationGeneration` is read and before `withTargetAppActivated`, so no injection, no target-app re-activation. The AC's "`appStatus`/`lastInjection` unchanged" clause is satisfied trivially — `rePaste` never writes either for *any* record (`lastInjection` lives in `TextInjector`).
- **AC 2 — MET.** `records.first(where: { $0.mode != .command })` on a newest-first array; all-command and empty both fall to the existing no-op path.
- **AC 3 — MET.** Both controls are **hidden** (`HistoryView.swift:33`, `:220`). The AC permits hide *or* disable.
- **AC 4 — MET, and the tests are NOT tautological.** Injection is genuinely reachable in this harness: `makeTestState` leaves `appStatus == .idle`, and `lastNonSelfFrontmostApp` stays `nil` under `skipSystemIntegration`, so `withTargetAppActivated` runs `work()` **synchronously**. Proof by pre-existing sibling: `testRePasteInjectsTheGivenRecordsFinalText` asserts `injectCallCount == 1` in the same harness and passes. Mutation analysis: reverting the `rePaste` guard alone fails `testRePasteRefusesACommandModeRecord`; reverting the `first(where:)` filter alone fails `testRePasteMostRecentSkipsCommandModeRecords` (it asserts a *positive* value, `"older final"`, which would become `"make this shorter"`). Both production guards are independently pinned.
- **AC 5 — MET.** Full suite green, reproduced by the reviewer.

### Findings

**MINOR 1 — "Re-paste Last" menu row is a dead control when history is all-command.**
`MenuBarView.swift:488` still gates on `.disabled(appState.historyStore.records.isEmpty)`. After this change "history is non-empty" is no longer the same predicate as "there is something to re-paste": with only Command Mode records the row renders **enabled**, and clicking it silently no-ops. This is the one Re-paste affordance that did not adopt the new rule while its two siblings did. Strictly outside AC 3 (which names only `HistoryView`), but a direct consequence of AC 2 and the exact state this story introduces. Suggested fix, matching this repo's habit of asserting on the `AppState` seam rather than the SwiftUI body: hoist a computed property `var canRePaste: Bool { historyStore.records.contains { $0.mode != .command } }`, bind `.disabled(!appState.canRePaste)`, and assert it in `AppStateRePasteTests`.

**MINOR 2 — Log line is now inaccurate.**
`AppState.swift:1781` still says `"Re-paste requested with no history — nothing to do"`, which now also fires when history is full but holds only command records. The dev consciously left the wording per the surgical-diff instruction; that call is defensible, but the line will mislead during log triage. One-word fix ("no re-pastable history").

**MINOR 3 — Denylist rather than allowlist (fail-open on a future mode).**
All four gates test `mode != .command` (`AppState.swift:1733`, `:1780`, `HistoryView.swift:33`, `:220`). `HistoryRecord.Mode` has exactly two cases today, so this is currently equivalent to `== .dictation` and there is no live gap. But the polarity fails **open**: a third mode added later (e.g. an agent/tool mode whose text is also not document content) becomes injectable by default, silently re-opening precisely the Epic 6 AC violation this story exists to close. An allowlist (`== .dictation`) fails closed. Related: the rule is now duplicated verbatim across four sites, which makes drift cheap — a single `HistoryRecord.isRePastable` would collapse MINOR 1 and 3 together.

**MINOR 4 (cosmetic) — Unexplained disappearance in the detail pane.**
For a command record the `HStack` at `HistoryView.swift:216-232` renders only the destructive **Delete This Record** button, which slides into the leading position the prominent Re-paste button used to hold. No layout break, and context is partly supplied by the `Mode: Command` row (`:190`) and the `Instruction (spoken)` heading (`:208`). A one-line caption explaining why Re-paste is unavailable would close the loop. Non-blocking.

**NOTE — AC 3 is manual-only coverage.**
No automated verification exists for the two SwiftUI gates: `Tests/` contains no `HistoryView` references, and `Package.swift` declares no ViewInspector/snapshot dependency and no UI-test target. Deleting either `if` wrapper leaves the whole suite green. This is *not* an AC 4 violation — AC 4 scoped tests to (1) and (2) only — and the blast radius is honestly small because the model guard is the real defense: a regression there ships a button that appears and does nothing, not an injected instruction. Recording it so AC 3 is not later assumed to be test-covered.

**NOTE — one new test is redundant rather than load-bearing.**
`testRePasteMostRecentDoesNothingWhenOnlyCommandRecordsExist` passes even with the `first(where:)` filter reverted, because `rePaste`'s own guard absorbs the command record. It fails under a full revert, and the filter is properly pinned by `testRePasteMostRecentSkipsCommandModeRecords`, so coverage is intact. Worth knowing only if the `rePaste` guard is ever loosened.

**PRE-EXISTING — not this story: stale-snapshot injection across `focusSettleDelay`.**
A record deleted (or retention-pruned) during `withTargetAppActivated`'s delay is still injected, because `text` is captured before the hop; the `generation`/`appStatus` recheck at `AppState.swift:1752` covers the new-dictation race but not deletion. This predates the diff and is unrelated to the mode gate (mode travels with the captured value, so the gate itself cannot go stale). Flagged for the backlog — **do not fix inside this story**.

### Recommendation

Ship as-is. MINOR 1 is the only finding a user could actually notice, and it degrades to a no-op click, not a data leak. Folding MINOR 1 + 3 into a single `isRePastable` predicate is the highest-value follow-up; it is a clean candidate for a small remediation story rather than a scope expansion here.

### MINORs closed — 2026-08-22

All four MINORs addressed in one small pass, following the reviewer's suggested shape:

- **MINOR 1 + 3** — added `HistoryRecord.isRePastable` (allowlist on `.dictation`, fails closed on a future mode) and switched all four existing gates plus `MenuBarView.swift`'s previously-ungated "Re-paste Last" row onto it.
- **MINOR 2** — the `rePasteMostRecent` no-op log now distinguishes "no history" from "only Command Mode records".
- **MINOR 4** — added a secondary caption in the detail pane ("Command Mode records can't be re-pasted.") when Re-paste is hidden.
- Also strengthened `testRePasteMostRecentSkipsCommandModeRecords` with `injectCallCount == 1` (acceptance-auditor gap) and added `testIsRePastableIsTrueOnlyForDictationMode`.

`swift test`: 795 tests, 1 skipped, 0 failures. No commits made. Status left at `review`.

<!-- checkpoint: epic-9 closed 2026-08-22 — story done, code-review approved, suite 796 green, committed with re-verification round -->
