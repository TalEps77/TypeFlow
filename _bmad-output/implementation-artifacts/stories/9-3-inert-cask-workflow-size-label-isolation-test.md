# Story 9.3: Inert cask workflow, correct size label, isolation-safe test

Status: done

<!-- Remediation story. Source: adversarial acceptance audit, 2026-08-22.
Three independent mechanical defects bundled because each is small; do not
let them bleed into one shared diff — three separate, narrow changes. -->

## Story

As a maintainer of this fork,
I want the Homebrew-cask workflow to be genuinely inert, the shipped model's
size label to be correct, and the model-size-default test to be trustworthy,
So that a re-enabled workflow can't silently publish garbage, the UI never
lies about which model is loaded, and `swift test --filter` results can be
trusted in isolation.

## Context / Defects

**(a) `.github/workflows/update-homebrew-cask.yml` is not actually inert.**
This fork has no release repo of its own (per the Epic 8 retrospective note
in `sprint-status.yaml`, both Homebrew casks already point at upstream's
`jatinkrmalik/vocamac` assets and are "flagged in-file as unpublishable").
The workflow file itself, however, has no disable guard at all — it
triggers `on: release: types: [published]` and, if a release is ever
published on this fork (e.g. by accident, or by someone unaware of the
cask situation), it will: `curl -sL` a DMG URL that 404s (no such release
exists upstream under this fork's tag), `shasum -a 256` the resulting
**404 HTML body** as if it were a real checksum, and push that fabricated
checksum straight to the public `jatinkrmalik/homebrew-vocamac` tap repo
(`update-homebrew-cask.yml:24-36, 59-67`) — silently corrupting a tap other
people may have installed from. `curl -sL` does not fail on a 404; it just
downloads the error page.

**(b) `modelSizeFromName` misclassifies the shipped default model.**
`WhisperService.modelSizeFromName(_:)` (`Sources/VocaMac/Services/
WhisperService.swift:323-338`) maps a loaded model's folder name back to a
`ModelSize`. The shipped default is `ModelSize.largeV3LatestCompact`
(`AppState.swift:120`), whose on-disk folder name is
`openai_whisper-large-v3-v20240930_626MB` (`ModelManager.swift:272-273`).
Passed through `modelSizeFromName`, the check order is: not "ivrit"; not
("v20240930" **and** "turbo") — no "turbo" substring, so this branch is
skipped; then the very next check is plain `lowered.contains("v20240930")`,
which **is** true — so it returns `.largeV3Latest` before ever looking at
the `"626mb"` size suffix that distinguishes the compact build from the
non-compact one. Result: the app logs/displays "Large v3 Latest (Best)"
(`WhisperModel.swift:69`) for what is actually the "(Compact)" build
(`WhisperModel.swift:68`) — the size suffix loses to the bare date token.
The turbo-compact case (`largeV3LatestTurboCompact`, folder suffix
`_turbo_632MB`) has the same latent bug shape but happens to still resolve
correctly today only because its "turbo"+"v20240930" branch is checked
before the plain "v20240930" branch — it is not being asked to fix a real
symptom, but the compact/non-turbo case is.

**(c) `testSelectedModelSizeDefault` is order-dependent and currently
wrong.** `Tests/VocaMacTests/AppStateRecordingTests.swift:128-133` asserts
`appState.selectedModelSize == ModelSize.tiny.rawValue`. The real default,
declared right at the `@AppStorage` site, is `ModelSize.largeV3LatestCompact
.rawValue` (`AppState.swift:120`) — the assertion is checking the wrong
value. It only passes today because `VocaDefaults.store` is one
process-wide `UserDefaults` scratch suite shared by every test in the run
(`Sources/VocaMac/Models/VocaDefaults.swift:23-51`, wiped once at process
start, **not** between tests), and
`testPerformStartupInstallsBundledTinyModelBeforeDownload`
(`Tests/VocaMacTests/AppStateTests.swift:246-260`) writes
`appState.selectedModelSize = ModelSize.tiny.rawValue` into that shared
store with no `tearDown` cleanup — so by the time
`testSelectedModelSizeDefault` runs in a full-suite pass, the key is
already polluted to `tiny`, and the (wrong) assertion happens to hold. Run
in isolation (`swift test --filter testSelectedModelSizeDefault`), nothing
has polluted the key, the real default (`largeV3LatestCompact`) comes back,
and the test fails.

## Acceptance Criteria

1. `.github/workflows/update-homebrew-cask.yml` has an explicit disable
   guard — e.g. a job- or step-level `if: false` with a comment such as
   `# fork has no release repo; re-enable when casks re-pointed` — **and**
   the download/checksum step is hardened so that if someone ever flips the
   guard back on prematurely, it fails loudly instead of shasumming a 404
   body: use `curl -f` (or `-fsSL`) so a non-2xx response aborts the step,
   and/or a sanity check on the downloaded file (e.g. verify it's plausibly
   a DMG, not an HTML error page) before computing/pushing the checksum.
2. `modelSizeFromName` is fixed so a size-suffix match (e.g. `"626mb"`,
   `"632mb"`) is checked before the bare `"v20240930"` date-token branches,
   so the shipped default's folder name
   (`openai_whisper-large-v3-v20240930_626MB`) resolves to
   `.largeV3LatestCompact`, not `.largeV3Latest`. A unit test pins this
   specific previously-misclassified name.
3. `testSelectedModelSizeDefault` passes both under `swift test --filter
   testSelectedModelSizeDefault` (run alone, no prior test has touched the
   key) and as part of the full suite — made order-independent, and
   asserting the actual documented default (`ModelSize.largeV3LatestCompact
   .rawValue`), not `tiny`.
4. Full suite green (`swift test`).

## Tasks / Subtasks

- [x] Task 1 — Inert workflow (AC: 1)
  - [x] Add `if: false` (with the explanatory comment above) to the
        `update-cask` job in `.github/workflows/update-homebrew-cask.yml`
        (job starts at line 10), or to each step — job-level is simpler and
        sufficient since the whole job is unpublishable right now.
  - [x] In the "Download DMG artifact" step (`update-homebrew-cask.yml:
        24-29`), change `curl -sL -o vocamac.dmg "$DMG_URL"` to fail on a
        non-2xx response — add `-f` (fail on HTTP errors) — so a 404 aborts
        the workflow instead of proceeding to shasum the error body. This
        must hold even with the `if: false` guard removed later, so treat
        it as a real fix to the step, not just a comment.
- [x] Task 2 — Fix `modelSizeFromName` ordering (AC: 2)
  - [x] In `Sources/VocaMac/Services/WhisperService.swift:323-338`, reorder
        (or add) checks so a compact/size-suffix match wins over the plain
        date-token match. Concretely: check for `"626mb"` (→
        `.largeV3LatestCompact`) and `"632mb"` combined with `"turbo"` (→
        `.largeV3LatestTurboCompact`) **before** the existing
        `lowered.contains("v20240930") && lowered.contains("turbo")` and
        `lowered.contains("v20240930")` branches. Keep the existing "ivrit"
        check first (it must still win, per the existing comment at line
        325-326 about "large"/"turbo" substrings colliding with the ivrit
        folder name).
  - [x] Add a unit test (likely in `Tests/VocaMacTests/WhisperServiceTests
        .swift` if it exists, else colocate with existing
        `modelSizeFromName`/`ModelSize` tests — check for a
        `WhisperServiceTests.swift` or similar first) asserting
        `modelSizeFromName("openai_whisper-large-v3-v20240930_626MB") ==
        .largeV3LatestCompact`. Also assert the plain
        `"openai_whisper-large-v3-v20240930"` (no size suffix) still
        resolves to `.largeV3Latest`, so the fix doesn't over-correct.
- [x] Task 3 — Fix the order-dependent test (AC: 3)
  - [x] In `Tests/VocaMacTests/AppStateRecordingTests.swift:128-133`,
        change the expected value from `ModelSize.tiny.rawValue` to
        `ModelSize.largeV3LatestCompact.rawValue`.
  - [x] Make it order-independent by clearing any prior pollution before
        asserting — e.g. `VocaDefaults.store.removeObject(forKey:
        "vocamac.selectedModelSize")` before creating/reading `appState`,
        mirroring the pattern already used in `AppStateModelLoadingTests
        .setUp()`/`tearDown()` (`AppStateTests.swift:267-275`). Do **not**
        assume `AppState.makeTestState()` resets this key on its own — it
        doesn't for this key.
  - [x] Do not touch `testPerformStartupInstallsBundledTinyModelBeforeDownload`
        (`AppStateTests.swift:246-260`) — the root pollution source — unless
        the isolation fix above is insufficient to make
        `testSelectedModelSizeDefault` pass in both modes; prefer the
        smaller, self-contained fix.
  - [x] Verify: `swift test --filter testSelectedModelSizeDefault` passes
        alone, and the full suite still passes with this test included.
- [x] Task 4 — Full suite (AC: 4)
  - [x] `swift test` green.

## Dev Notes

- Repo is Swift/SwiftPM (Xcode 26.6 installed); baseline 784 tests green.
- These are three independent, narrow diffs — one workflow YAML edit, one
  reordering inside a single function, one test-file edit. Do not let any
  of the three grow beyond what its AC asks for.
- `VocaDefaults.store` (`Sources/VocaMac/Models/VocaDefaults.swift`) is a
  documented process-wide UserDefaults scratch suite that is **not** reset
  between individual tests — its own doc comment explains why (MAJOR 8
  historically) and that tests are expected to clean up their own keys.
  This is why (c) needs an explicit `removeObject` rather than relying on
  test isolation that doesn't exist.
- No commits by the dev agent.

### Project Structure Notes

- Touches: `.github/workflows/update-homebrew-cask.yml`,
  `Sources/VocaMac/Services/WhisperService.swift`,
  `Tests/VocaMacTests/AppStateRecordingTests.swift`, plus one new/extended
  test file or test case for `modelSizeFromName`.

### References

- [Source: .github/workflows/update-homebrew-cask.yml:1-68]
- [Source: Sources/VocaMac/Services/WhisperService.swift:322-338]
- [Source: Sources/VocaMac/Models/WhisperModel.swift:11-76]
- [Source: Sources/VocaMac/Services/ModelManager.swift:267-277]
- [Source: Sources/VocaMac/Models/AppState.swift:120]
- [Source: Tests/VocaMacTests/AppStateRecordingTests.swift:128-133]
- [Source: Tests/VocaMacTests/AppStateTests.swift:245-275]
- [Source: Sources/VocaMac/Models/VocaDefaults.swift:1-51]
- [Source: _bmad-output/implementation-artifacts/sprint-status.yaml — Epic 8 retrospective note on unpublishable casks; action item `epic-8-retro-item-7` on this exact test]

## Dev Agent Record

### Agent Model Used

Claude Sonnet 5 (claude-sonnet-5)

### Debug Log References

- `swift test --filter testSelectedModelSizeDefault` (isolation): 1 test, 0 failures.
- `swift test` (full suite): 790 tests, 1 skipped, 0 failures.

### Completion Notes List

- (a) Added `if: false` job-level guard (with explanatory comment) to
  `update-cask` in `.github/workflows/update-homebrew-cask.yml`, and
  hardened the download step: `curl -sL` → `curl -fsSL` (fails loudly on
  non-2xx) plus a `file`-based sanity check that rejects a non-DMG payload
  (e.g. an HTML error page) before checksumming.
- (b) Reordered `modelSizeFromName` in `WhisperService.swift` so
  `"626mb"` and `"632mb"+"turbo"` size-suffix checks are evaluated before
  the bare `"v20240930"` date-token branches, so the shipped default's
  folder name now resolves to `.largeV3LatestCompact` instead of
  `.largeV3Latest`. Added `testCompactSizeSuffixWinsOverBareDateToken` in
  `WhisperServiceTests.swift`, pinning both the fixed case and the
  no-size-suffix case (still `.largeV3Latest`).
- (c) Fixed `testSelectedModelSizeDefault` in
  `AppStateRecordingTests.swift`: now clears
  `vocamac.selectedModelSize` from `VocaDefaults.store` before creating
  `appState` (mirroring `AppStateModelLoadingTests`'s pattern) and asserts
  the real default, `ModelSize.largeV3LatestCompact.rawValue`. Verified
  green both filtered alone and inside the full suite.
- Did not touch `testPerformStartupInstallsBundledTinyModelBeforeDownload`
  — the isolation fix in the target test was sufficient.

### File List

- `.github/workflows/update-homebrew-cask.yml`
- `Sources/VocaMac/Services/WhisperService.swift`
- `Tests/VocaMacTests/WhisperServiceTests.swift`
- `Tests/VocaMacTests/AppStateRecordingTests.swift`

### Change Log

| Date | Change |
| --- | --- |
| 2026-08-22 | Implemented ACs 1-4: `if: false` guard + `curl -fsSL` and DMG sanity check on the cask workflow, `modelSizeFromName` size-suffix-before-date-token fix with a pinning test, `testSelectedModelSizeDefault` made order-independent and corrected to assert `largeV3LatestCompact`. Full suite green (790, 1 skipped). Status → review. |

---

**Validation: PASSED 2026-08-22** — each of the three ACs is independently
testable and cites the exact broken lines plus the exact fix shape; (c) in
particular names both the wrong-assertion bug and the isolation-leak
mechanism so the dev agent isn't guessing why the test is flaky. No fixes
needed.

## Code Review

**Verdict: PASS.** No functional defects found. All three fixes verified
independently (fresh reviewer, adversarial pass, read-only).

**(a) Workflow inertness — confirmed.** `if: false` at job level
(`update-homebrew-cask.yml:13`) is a bare YAML boolean, not a string —
GitHub Actions auto-evaluates a non-expression `if` value as
`${{ <value> }}`, so the literal boolean `false` skips the job exactly like
`${{ false }}` would; this is the same pattern GitHub's own docs and common
repos use to hard-disable a job. `curl -sL` → `curl -fsSL` (line 30) now
aborts on non-2xx before the `file`-based DMG sanity check (lines 31-35),
which itself runs before the sha256/push steps — a 404 HTML body can no
longer reach the checksum or the tap push. Searched all six other workflow
files (`ci.yml`, `deploy-website.yml`, `labeler.yml`, `nightly.yml`,
`pr-build.yml`, `release.yml`) for `homebrew|tap|cask`; `nightly.yml:357` is
an unrelated comment ("stable-named copies for Homebrew cask"), not a push
path. No other workflow shares this hazard.

**(b) `modelSizeFromName` ordering — confirmed correct, no new
misclassification.** Enumerated the full real inventory (13 folder names)
from `ModelManager.whisperKitModelName(for:)` and traced each through the
new branch order in `WhisperService.swift:323-343`: all 13 resolve to their
correct `ModelSize`, including the two previously-suspect cases —
`openai_whisper-large-v3-v20240930_626MB` → `.largeV3LatestCompact` (fixed,
per AC2) and `..._turbo_632MB` → `.largeV3LatestTurboCompact` (already
correct, confirmed still correct via its own dedicated branch checked
before the plain-turbo/plain-date branches). No other name flips the other
way. `swift test --filter WhisperService` (the exact class name filter
`WhisperServiceTests` in the task brief matches nothing — no class is
literally named that; classes are `WhisperServiceModelSizeFromNameTests`
etc.) → 19 tests, 0 failures, including the new
`testCompactSizeSuffixWinsOverBareDateToken`.

**(c) Isolation fix — confirmed.** `swift test --filter
testSelectedModelSizeDefault` run alone: 1 test, 0 failures — the real
default (`largeV3LatestCompact`) now comes back correctly instead of the
stale `tiny` assertion. The fix only calls `removeObject` and then reads
`appState.selectedModelSize` — it never writes to `VocaDefaults.store`, so
it cannot leak state to tests that run after it (verified no `tearDown` is
needed here, unlike `AppStateModelLoadingTests`, which both reads and
writes the key and correctly pairs `setUp`/`tearDown`). Grepped all
`selectedModelSize` references in `Tests/VocaMacTests/`: the only
unguarded polluter remains
`testPerformStartupInstallsBundledTinyModelBeforeDownload`
(`AppStateTests.swift:249`, no tearDown) — left untouched per the story's
explicit instruction, and neutralized by this test's own upfront
`removeObject` regardless of run order.

**Full suite:** `swift test` → 794 tests, 1 skipped, 0 failures, exit 0.
Note: the story's Dev Agent Record cites 790 tests; the 4-test difference
is consistent with other uncommitted sibling-story changes present in the
working tree (per the review brief, out of scope for this diff) and is not
a regression introduced by this story's changes — confirmed by running the
narrower filters above against only this diff's files.

No blocking, major, or minor findings. Nothing to fix.

<!-- checkpoint: epic-9 closed 2026-08-22 — story done, code-review approved, suite 796 green, committed with re-verification round -->
