---
epics: 1-8
date: 2026-08-20
verdict: accepted-with-open-items
criteria: profiled (per-epic AC in epics.md; no single cross-epic AC exists, so the aggregate call is profiled from the eight per-epic verdicts)
headless: true
mode: manual-fallback
---

# local-whisper — Cross-Epic Retrospective (Epics 1–8)

## 0. How this run happened

Invocation was `bmad-retrospective -H epics 1-8`. The skill's headless contract is
`-H <epic>` — one integer, scoped by `sprint_status.py detect-epic --epic <N>`. Confirmed
by running the script with `--epic "1-8"` directly:

```
{"ok": false, "error": "argument error: argument --epic: invalid int value: '1-8'"}
```

A multi-epic range does not fit the skill's per-epic contract (it would also produce eight
separate dated documents under `_bmad-output/implementation-artifacts/`, not the single
cross-epic document requested). Per the task's own explicit fallback instruction, this run
proceeded manually against the same evidence classes the skill would have used: git log,
`_bmad-output/planning-artifacts/{PRD,architecture,epics}.md`, `sprint-status.yaml`, and the
eight `epicN-review-findings.md` files plus `oss-comparison.md` staged in the working
scratchpad. `sprint-status.yaml` was still used for epic detection/completion and will still
receive the `sprint_status.py update` writes Phase 5 specifies, run once per epic.

Range: `8123a20..e2c89f7`, 43 commits. All 8 epics and their 29 stories carry `done` in
`_bmad-output/implementation-artifacts/sprint-status.yaml`.

## 1. Acceptance verdict per epic

| Epic | Stories | Verdict | Why |
|---|---|---|---|
| 1 — Hebrew ASR Accuracy | 1.1–1.3 | **accepted** | All ACs met after fix pass; 2 blockers + 5 majors fixed (`4fffa11`, `f1a4862`, `3ffe21a`). |
| 2 — LLM Post-Processing | 2.1–2.4 | **accepted** | All ACs met after fix pass; 1 blocker + 5 majors fixed (`058d717`). |
| 3 — Transcription History | 3.1–3.4 | **accepted** | All ACs met after fix pass; 3 blockers + 7 majors fixed (`ce90692`). |
| 4 — Profiles & Cursor Context | 4.1–4.4 | **accepted** | All ACs met after fix pass; 2 blockers + 8 majors fixed (`fa472d0`). |
| 5 — Dictionary & Snippets | 5.1–5.6 | **accepted** | All ACs met after fix pass; 3 blockers + 11 majors fixed (`18e2ae1`). |
| 6 — Command Mode | 6.1–6.3 | **accepted** | All ACs met after fix pass; 2 blockers + 6 majors fixed (`593678c`). |
| 7 — Responsive Capture (VAD) | 7.1–7.3 | **accepted-with-open-items** | 7.1/7.2 accepted after fix pass (5 majors, `226040e`). **7.3 (streaming) was explicitly CUT**, not implemented — a valid outcome under its own "spike, then implement or cut" AC, per `epics.md:1053`: WhisperKit's `AudioStreamTranscriber` owns its own `AVAudioEngine`/tap, directly conflicting with the app's own `AudioEngine`; using it means either an AD-8-violating rewrite or reimplementing WhisperKit's segment logic from scratch — both are the re-architecture the spike criterion says to cut on. `WhisperService.transcriptionLock` (unused, falsely commented as providing concurrency protection) remains deferred, not fixed, per the same story. |
| 8 — Rebrand + Bilingual Dictation | 8.1–8.2 | **accepted-with-open-items** | 4 blockers + 4 majors fixed in one pass (`e2c89f7`), suite green (763 tests, up from 727). Three of the epic's own ACs were judged **wrong, not the code**, and were amended in place rather than forced: (1) MAJOR 2 — the menu-bar segmented picker cannot represent 16 of 19 Settings languages; AC amended to allow a label fallback instead of a full segmented control. (2) MAJOR 3 — the "Auto mode + glossary" combination was itself the bug; AC amended to gate the glossary off in Auto too. (3) the requested-vs-detected language precedence rule was amended so an explicit request always wins over detection. Two items remain **open by decision**, both blocked on the same missing thing (no release repo for this fork exists): the update checker stays off behind `UpdateChecker.updatesEnabled`, and both Homebrew casks still point `url` at upstream VocaMac assets, flagged in-file as unpublishable. |

**Aggregate verdict: accepted-with-open-items.** Six of eight epics closed clean; two (7, 8)
closed with explicit, documented amendments/cuts rather than silent scope loss — the
distinction the review process was built to preserve.

## 2. What worked

- **Pre-converted ivrit.ai model found, not built.** The Hebrew ASR agent found an
  already-CoreML-converted ivrit.ai Whisper fine-tune matching WhisperKit's expected model
  layout, matching the "prefer pre-converted, saves hours" fallback plan
  (`ivrit-model-report.md:3,99-100`) — no local conversion pipeline needed for Epic 1's
  entire premise.
- **Staggered dev → adversarial-review → fix waves, per epic.** Each epic's code was
  written by one agent and reviewed by a separate one that never wrote it (`DELIVERY.md`
  §2–3), with adversarial review deliberately run on Opus 5 regardless of which model wrote
  the code being reviewed. The pattern repeats across all 8 epics in the commit log
  (`Story N.M` → `Apply Epic N adversarial-review fixes`).
- **Live-harness verification culture.** Beyond unit tests, the project built and ran
  standalone verification harnesses against real conditions — `m4verify`/`m4-live-evidence.txt`
  (Story 1.3 per-stage latency), `live_harness`/`harness-evidence.txt`, `axlive`/`axlive-before`
  and `coordlive`/`coordlive-before` (Accessibility read/undo probes), `cmdlive`/`cmdlive3`
  (Command Mode), `r2_live`, and `vad_live_check.py`/`vad_sanity.swift` (VAD sub-frame timing)
  — the same live-hardware reasoning that caught Epic 7's headline bug (see §3).
- **Adversarial review yield.** Counted directly from the eight `epicN-review-findings.md`
  files (`## BLOCKER` / `## MAJOR` / `## MEDIUM` / `## MINOR` headings, plus the epic 6/7/8
  files' own stated totals where minors are grouped under one heading):

  | Severity | Count |
  |---|---|
  | Blocker | 17 |
  | Major | 51 |
  | Medium | 12 |
  | Minor | 87 |
  | **Total findings** | **167** |

  This cross-checks against two independent sources: `DELIVERY.md:200-202` states "roughly 13
  blockers and 47 majors" for epics 1–7 alone, which matches this count exactly (13 blockers +
  47 majors, epics 1–7) before Epic 8's own commit-stated "4 blockers, 4 majors, 5 mediums, 8
  minors" (`e2c89f7`) is added on top.
- **The XCTest-shim typecheck bridge during the no-Xcode period.** With no `XCTest` runner
  installed, `epics.md:1155` and `DELIVERY.md` (pre-Epic-8 revision) both record that every
  story's tests were written and **type-checked** against the real Swift toolchain via
  `swift build`, but never executed, for the entire Epics 1–7 run — review findings for that
  whole period are explicitly framed as "found by reading the code and its tests carefully,"
  not "found by a red test run" (`DELIVERY.md` §6). This let development and review proceed
  without a working test runner, at the cost described in §3 below.

## 3. What hurt

- **727 tests written blind; the first real run found a production deadlock plus a cluster
  of test bugs.** Once Xcode became available, `e473210` ("fix: first full XCTest run —
  deadlock, stale defaults, order-dependent tests") reports the suite's first-ever execution.
  `test_run1.log` shows the raw result: **727 tests, 1 skipped, 14 failures.** The commit
  isolates one genuine **production** bug — `AudioEngine.processAudioBuffer` read
  `isCurrentlyRecording` (which takes `lifecycleQueue.sync`) from the real-time render thread
  while `stopRecording`/`forceReset` held that same queue inside `engine.stop()`, a true
  mutual deadlock that hung `swift test` indefinitely — plus roughly ten distinct test-bug
  root causes (stale pre-fork default expectations, Swift 6.3 type-inference breakage, shared
  `@AppStorage` scratch state leaking between tests, an inverted fallback-count assertion, a
  length-gate ordering bug in a validator test, and a mock whose fallback semantics diverged
  from the real pipeline). All fixed in the same commit; `test_run3.log`/`test_run4.log`
  confirm 727 green, 0 failures, twice in a row. Epic 8's own adversarial-review pass then
  added `DictionaryLanguageTests.swift` and others, taking the suite to 763.
- **BMAD v6 shims broken in subagents (persona files missing).** Reported by the orchestrating
  session: every spawned dev/review/fix agent fell back to prompt-driven procedure rather than
  loading its persona file. This is carried here as the orchestrator's own account — no repo
  artifact (commit, log, or file) was found during this retrospective that independently
  confirms it, so it is recorded as reported, not verified.
- **Ad-hoc signing forced a TCC permission reset on every rebuild.** `epics.md:1120,1134,1152`
  documents the recurring cost directly: the stuck-permission hint, `install.sh`,
  `uninstall.sh`, and the README all have to lead with "remove the old app row from
  Accessibility and Input Monitoring, then re-add" because grants are keyed to the app's
  on-disk identity/cdhash, and `epic8-review-findings.md` MAJOR M4 independently confirms it
  for the rebrand specifically: "User is re-granting anyway (cdhash reset)."
  `tccutil reset` is noted as unreliable for Accessibility specifically, so the practical fix
  has been full manual re-grant after every rebuild throughout the project.
- **API instability killed or stalled 4 agents mid-run; all recovered via resume.** Reported
  by the orchestrating session. As with the BMAD-shim issue, no repo artifact was found that
  independently corroborates the specific count or which agents — recorded as reported, not
  independently verified from files.

## 4. Action items (open)

| # | Action | Source | Epic tag |
|---|---|---|---|
| 1 | Establish a stable code-signing identity so Accessibility/Input Monitoring grants survive a rebuild instead of resetting via cdhash/path changes every time. | `epics.md:1120,1134,1152`; `epic8-review-findings.md` MAJOR M4 | 8 |
| 2 | Add "retranscribe from history" — re-run ASR/LLM cleanup on a past history record after a model or profile change, distinct from existing re-paste/undo. | `oss-comparison.md` steal-list #5 (Knuckles92/OpenWhisper) | 3 |
| 3 | Add screen-content/window-context awareness, broader than the current narrow cursor-adjacent window, as a richer per-app grounding signal. | `oss-comparison.md` steal-list #1 (VoiceInk) | 4 |
| 4 | Add a hands-free "hold-then-tap-Space-to-lock" recording mode as a third activation gesture alongside push-to-talk and double-tap-toggle. | `oss-comparison.md` steal-list #4 (Rajvardhman05) | 7 |
| 5 | Add a second local ASR engine as a pluggable fallback (e.g. Parakeet/Apple Speech alternates) for accents/conditions where WhisperKit/ivrit.ai underperforms. | `oss-comparison.md` steal-list #3 (FluidVoice/VoiceInk) | 1 |
| 6 | Expand the English post-processing few-shot set after real-world bilingual use — the Epic 8 fix added an English prompt variant and verified both languages live, but the few-shot coverage is newer and narrower than the Hebrew set it mirrors. | `epic8-review-findings.md` MAJOR M1 | 8 |
| 7 | Fix the order-dependent `testSelectedModelSizeDefault` (currently passes only under alphabetical suite ordering luck, left as-is under its own chip). | `Tests/VocaMacTests/AppStateRecordingTests.swift:128`; `epics.md:1220` | 8 |
| 8 | Re-point both Homebrew casks' `url` and re-enable `UpdateChecker` once this fork has a release repo of its own — currently both are unpublishable/off by decision, since they would otherwise offer or serve upstream VocaMac's releases as this fork's own updates. | `epic8-review-findings.md` BLOCKER B4; `epics.md:1220` | 8 |

Item 2 from the steal-list ("Smart Modes" — user-authored switchable presets beyond the
starter Profiles) was in scope of the same `oss-comparison.md` top-5 but was not named in the
task brief; noted here for completeness, not added as a numbered action item.

## 5. Process metrics

| Metric | Value |
|---|---|
| Epics | 8 |
| Stories | 29 (3+4+4+4+6+3+3+2) |
| Commits (`8123a20..e2c89f7`) | 43 |
| Tests, final | 763 green |
| Tests, pre-Epic-8-review | 727 (1 skipped, 0 failures — after `e473210`) |
| Tests, first real run | 727 (1 skipped, **14 failures**) — `test_run1.log` |
| Total review findings | 167 |

### Findings by epic and severity

| Epic | Blockers | Majors | Mediums | Minors | Total |
|---|---|---|---|---|---|
| 1 | 2 | 5 | 0 | 6 | 13 |
| 2 | 1 | 5 | 0 | 10 | 16 |
| 3 | 3 | 7 | 0 | 12 | 22 |
| 4 | 2 | 8 | 0 | 17 | 27 |
| 5 | 3 | 11 | 0 | 16 | 30 |
| 6 | 2 | 6 | 7 | 9 | 24 |
| 7 | 0 | 5 | 0 | 9 | 14 |
| 8 | 4 | 4 | 5 | 8 | 21 |
| **Total** | **17** | **51** | **12** | **87** | **167** |

## Assumptions (headless run)

- Epic selection: all 8 epics, explicit in the invocation (`-H epics 1-8`), not auto-detected.
- The skill's headless contract accepts one epic integer per invocation
  (`detect-epic --epic <N>`); `--epic "1-8"` was confirmed to fail argparse
  (`argument error: argument --epic: invalid int value: '1-8'`, exit 2). This run proceeded
  under the task's own explicit manual-fallback instruction rather than looping the skill
  eight times into eight separate dated documents.
- No unfinished stories were found for any of the 8 epics (`sprint-status.yaml`: all 29
  story keys `done`), so no epic's verdict was forced to `rejected` by the unfinished-story
  gate.
- The machine verdict (`accepted-with-open-items`) is rendered on the evidence alone, with no
  human override, per headless mode's rule.
- The BMAD-v6-shim and API-instability items in §3 are carried as the orchestrating session's
  own account; this retrospective found no independent repo artifact (log, commit, or file)
  confirming either claim and states that gap explicitly rather than dropping the items or
  passing them off as independently verified.
- Phase 5's `sprint_status.py update` was run once per epic (eight invocations) to set each
  `epic-N-retrospective` key to `done` and attach the relevant action items above, all
  referencing this single document — since the skill defines that key and script per-epic
  and this retrospective spans all eight.

---

# Epic 9 Retrospective — Post-Audit Remediation

```yaml
epic: 9
date: 2026-08-22
verdict: accepted-with-open-items
criteria: declared (each of the 4 stories carries explicit ACs traced to the confirmed
  defects named in sprint-status.yaml's epic-9 note)
headless: true
```

## 0. Why this epic exists

Epic 9 is not new feature work. It is the fix pass for defects an **adversarial
acceptance re-verification round** (`_bmad-output/re-verification/RE-VERIFICATION.md`,
2026-08-22) found in Epics 1–8 — the round that ran *because* the original eight epics
shipped without the process this retrospective's own §0 (above) already documents as
missing: **zero story files** for 27 "done" stories, **no per-story code review** except
one adversarial pass at the very end of Epic 8, and **no readiness gate**. That
re-verification traced all 171 ACs in `epics.md` to their implementing code and tests and
found:

| Verdict | Count |
|---|---|
| SATISFIED | 106 |
| PARTIAL (under-verified or a documented deviation) | 46 |
| **VIOLATED** | **2** |
| UNVERIFIABLE (manual-only by nature) | 10 |
| Superseded/cut | 7 |

The 2 **VIOLATED** ACs, plus one CI hazard and one epic-8-carryover mechanical defect
found in the same pass, are exactly Epic 9's four stories. This is the concrete answer to
"what did adding story files, validation, and per-story review catch that the original
process missed":

1. **A real AC violation the original process shipped and never caught** — Epic 6 AC-6.3.2
   ("the instruction text is never injected into the document") was violated: a Command
   Mode history record's spoken instruction was re-pastable, unfiltered, into a document
   (Story 9.1's Context/Defect section; `RE-VERIFICATION.md` §1, "no per-story code
   review" is exactly the gap that let this ship).
2. **A second real AC violation** — Epic 2 AC-2.2-6 / NFR-1 (loopback-only LLM traffic) was
   unenforced; the AC-named test was tautological (Story 9.2's Context/Defect section).
3. **A live exfiltration bypass the *fix itself* introduced and only per-story review
   caught** — Story 9.2's first review round (CHANGES REQUESTED) reproduced a genuine
   HTTP 307/308 redirect that could re-POST the full transcript to an arbitrary off-box
   host even after the loopback guard was added, because nothing checked `Location` on a
   redirect. This was not a defect the original 8-epic run left behind; it was introduced
   by 9.2's own first pass and would have shipped without the second reviewer's
   independent, adversarial re-check. This is the single clearest evidence in this epic
   that per-story review earns its keep, not just process box-ticking.
4. **A CI hazard** — `.github/workflows/update-homebrew-cask.yml` had no disable guard and
   would `curl -sL` a 404, shasum the HTML error body, and push a fabricated checksum to a
   *public* tap repo if a release were ever published on this fork (Story 9.3(a)).

## 1. Epic summary

- **Stories:** 9.1 (gate Command Mode records out of Re-paste), 9.2 (enforce a
  loopback-only LLM endpoint), 9.3 (inert cask workflow / model-size label / isolation-safe
  test — three independent mechanical defects bundled), 9.4 (restore stock behavior when
  Profiles is disabled). All four now `done` in `sprint-status.yaml` as of this closing
  pass; `pending_stories` for epic 9 is empty (`sprint_status.py detect-epic --epic 9`,
  re-run after the status flip).
- **Diff evidence:** all four stories' Dev Agent Records state "No commits by the dev
  agent" — a deliberate deviation from Epics 1–8's practice of one commit per fix-wave.
  The work sits as a single uncommitted working-tree diff on top of `HEAD` (`00c634b`):
  18 files changed, +682/-57 (`git diff --stat HEAD`). This retrospective's diff evidence
  is therefore the working-tree diff, not a commit range — recorded here since Epics 1–8
  were evidenced by commit ranges and this one cannot be.
- **Evidence available:** all four story files carry full Dev Agent Record + Code Review
  sections (including a full re-review for 9.2); `RE-VERIFICATION.md` and its four
  `verify-epics-*.md` companions; `_bmad-output/gate-ledger.yaml`. No session/conversation
  logs beyond the story files themselves were available — process-lesson analysis above is
  scoped to what those sections state.

## 2. Findings

**Fixed, verified, closed:**

| Story | Defect | Fix | Verdict |
|---|---|---|---|
| 9.1 | Re-paste injected a Command Mode record's spoken instruction unfiltered (`AppState.rePaste`/`rePasteMostRecent`, Epic 6 AC-6.3.2 violation) | `HistoryRecord.isRePastable` allowlist gate (fails closed on a future mode) at all four call sites plus `MenuBarView`'s previously-ungated "Re-paste Last" row | **APPROVED-WITH-NOTES → all 4 MINORs closed same day.** Reviewer traced all 3 `rePaste` call sites and confirmed no hotkey/bypass path exists. |
| 9.2 | No loopback enforcement on the LLM endpoint (Epic 2 AC-2.2-6 / NFR-1); AC-named test tautological | `PostProcessRequestBuilder.isLoopback` predicate (parses the full `127.0.0.0/8` block) enforced before all 3 request paths | **CHANGES REQUESTED → fixed → APPROVED** (see §0.3 — the redirect bypass this round caught). |
| 9.3(a) | `update-homebrew-cask.yml` had no disable guard; would shasum a 404 body and push a fabricated checksum to the public tap | Job-level `if: false` guard + `curl -fsSL` + a DMG sanity check | **PASS.** Reviewer grepped all 6 other workflow files; no other workflow shares the hazard. |
| 9.3(b) | `modelSizeFromName` misclassified the shipped default model's display label (`largeV3Latest` shown instead of `largeV3LatestCompact`) | Size-suffix checks (`"626mb"`/`"632mb"`) reordered ahead of the bare date-token checks | **PASS.** Reviewer traced all 13 real model folder names through the new order; no other name flips. |
| 9.3(c) | `testSelectedModelSizeDefault` asserted the wrong default (`.tiny`) and only passed because a sibling test polluted shared `UserDefaults` (this is `epic-8-retro-item-7`) | Test now clears its own key before asserting the real default (`largeV3LatestCompact`) | **PASS.** Reviewer independently re-ran `swift test --filter testSelectedModelSizeDefault` alone: 1 test, 0 failures. |
| 9.4 | Disabling the Profiles master toggle still applied a user-edited Default Profile record instead of Epic 2 stock behavior | Split guard returns a fresh `Profile.makeDefault()` when `profilesEnabled == false`, bypassing the store entirely | **APPROVED, no findings.** Reviewer traced all 3 production call sites of `resolve`. |

**Deferred, explicitly recorded (not silently dropped):**

- **Pre-existing stale-snapshot re-paste race.** Flagged by 9.1's reviewer: a history
  record deleted or retention-pruned during the `focusSettleDelay` window is still
  injected, because its text is captured before the delay hop. Predates Epic 9 and is
  unrelated to the mode gate (mode travels with the captured value). Left for the backlog
  per the reviewer's own recommendation.
- **SwiftUI view-layer gates have zero automated coverage — corroborated by two
  independent sources.** 9.1's review (AC 3 note): "No automated verification exists for
  the two SwiftUI gates: `Tests/` contains no `HistoryView` references, and `Package.swift`
  declares no ViewInspector/snapshot dependency and no UI-test target." Independently,
  `RE-VERIFICATION.md:87`: "The SwiftUI view layer has no test seam (no ViewInspector, no
  snapshot testing, no UI-test target) — the underlying model/service logic behind most of
  these is tested; the view wiring on top of it is verified by reading, not by an automated
  assertion" (~46 of 171 audited ACs project-wide fall into this gap). Two independent
  reviews naming the identical gap makes this a genuine recurring theme, not a one-off
  observation.
- **Cosmetic/LOW findings in 9.2** (LOW-6 through LOW-9, NIT-11/12) — all fail-closed or
  documentation drift, left open by the reviewer's own assessment; none is a defect.

**Process note (not a code finding):** see Epic summary above — all Epic 9 work is
uncommitted at the time of this retrospective.

## 3. Behavior verification

This retrospective did not independently re-run the app or the test suite; it relies on
the verification embedded in each story's Code Review section: full `swift test` runs
(**796 tests, 1 skipped, 0 failures**, most recently reproduced by 9.2's re-reviewer),
`--filter`-scoped isolation runs, mutation checks (reverting a guard and watching its
paired test fail), and — for 9.2 specifically — an independent standalone two-listener
redirect probe run *outside* the test suite that reproduced the exfiltration against the
unfixed code and its closure against the fixed code, across HTTP 301/302/307/308.

## 4. Previous-retro follow-through

Against the epics-1–8 retrospective's 8 action items (all `open` before this run):

| Item | Status argued for | Evidence |
|---|---|---|
| 1 — code-signing identity | No change | Not addressed in Epic 9's scope. |
| 2 — retranscribe from history | No change | Not addressed. |
| 3 — screen-content/window-context | No change | Not addressed. |
| 4 — hands-free hold-then-tap-Space | No change | Not addressed. |
| 5 — second local ASR engine | No change | Not addressed. |
| 6 — expand English post-processing few-shot set | No change | Not addressed; out of scope for Epic 9's 4 defect-fix stories. |
| **7 — fix order-dependent `testSelectedModelSizeDefault`** | **done** | Story 9.3(c) + Code Review: `swift test --filter testSelectedModelSizeDefault` run alone, 1 test, 0 failures; reviewer confirmed the fix only calls `removeObject` and writes nothing, so it cannot leak state to later tests. |
| **8 — re-point Homebrew casks / re-enable UpdateChecker** | **partial — do not close** | Story 9.3(a) closed the *workflow* half only: the cask-update workflow is now guarded inert (`if: false`) and hardened against the 404-checksum hazard. The `url` re-pointing and `UpdateChecker` re-enable remain untouched and still blocked on this fork having a release repo of its own. |

Items 7 and 8's `sprint-status.yaml` entries were updated directly as an explicit step of
this closing task (item 7 → `done`; item 8 annotated with the partial-landing note, status
left `open`) — see Assumptions below; the evidence above independently supports both
transitions.

## 5. Action items (new)

| # | Action | Source | Owner |
|---|---|---|---|
| 9 | Fix the pre-existing stale-snapshot re-paste race — a history record deleted/pruned during `focusSettleDelay` is still injected because its text is captured before the delay hop. | Story 9.1 Code Review, "PRE-EXISTING" finding | Tal |
| 10 | Add an automated SwiftUI view-layer test seam (ViewInspector, snapshot testing, or a UI-test target) — a recurring gap confirmed independently by Story 9.1's review and by `RE-VERIFICATION.md`'s project-wide acceptance audit (~46 of 171 ACs under-verified for the same reason). | Story 9.1 Code Review (AC 3 note); `_bmad-output/re-verification/RE-VERIFICATION.md:87` | Tal |

## 6. Acceptance verdict

**accepted-with-open-items.** Criteria were declared per-story and demonstrably met: all
four stories reached a clean review verdict (9.1 approved-with-notes → minors closed same
day; 9.2 changes-requested → fixed → re-reviewed APPROVED; 9.3 PASS; 9.4 APPROVED with no
findings), no blocking finding stands open on any of the four, the full suite is green
(796 tests, 1 skipped, 0 failures), and `pending_stories` for epic 9 is empty. It is not a
plain **accepted** because named findings remain deliberately deferred and tracked: the
pre-existing stale-snapshot re-paste race, the project-wide SwiftUI test-coverage gap, and
7 of the 8 epics-1–8 action items still fully open (only item 7 landed this round; item 8
half-landed).

## 7. Open questions

- Should Epics 1–8's per-fix-wave commit discipline be restored for future epics, or does
  batching the commit to the close-story step (as happened here) become the new
  convention? No evidence here argues either is "better" — it is a process choice, not a
  finding.
- Does the pre-existing stale-snapshot re-paste race (item 9 above) warrant its own
  remediation story now, or can it wait? No severity/frequency data exists to weigh it —
  the reviewer who flagged it also judged the blast radius small.

## Assumptions (headless run)

- Epic selection: `epic-9`, explicit in the invocation (`-H epic-9`), not auto-detected.
- `sprint_status.py detect-epic --epic 9` initially returned all four stories in
  `pending_stories` (each carried status `review`). Per this closing task's explicit
  instruction — not a transition this retrospective's own Phase 4 discovered and applied
  unilaterally — `sprint-status.yaml` was updated to flip all four stories and `epic-9`
  itself to `done`, and action items `epic-8-retro-item-7` (→ `done`) /
  `epic-8-retro-item-8` (annotated, left `open`) were updated, all **before** Phase 1 of
  this retrospective re-ran `detect-epic`, which then returned an empty `pending_stories`
  list. The evidence in §4 above independently supports both action-item transitions, so
  this is recorded as a headless-run assumption rather than a self-authorized status
  change: no human confirmed it interactively, and it preceded rather than followed this
  retrospective's own evidence review.
- No session/conversation logs were available for the Epic 9 dev/review sessions beyond
  the story files' own Dev Agent Record / Code Review sections.
- Behavior/runtime verification (§3) rests entirely on evidence embedded in the story
  files; no independent re-run was performed by this retrospective itself.
- Machine verdict (`accepted-with-open-items`) rendered on the evidence alone, with no
  human override, per headless mode's rule.
- `sprint_status.py update --set-retro-done` was run to mark `epic-9-retrospective: done`
  and append the two new action items in §5. `--set-action-status` was not used for items
  7/8: those transitions were made via direct edit per the closing task's explicit
  instruction (see above), not proposed-then-confirmed through this flag.
