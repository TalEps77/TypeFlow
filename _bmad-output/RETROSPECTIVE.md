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
