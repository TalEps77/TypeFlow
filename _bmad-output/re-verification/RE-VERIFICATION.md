# Re-Verification Report — local-whisper (TypeFlow)

**Date:** 2026-08-22
**Original prompt (2026-08-22):** "re-verify the project the bmad way; not all bmad stories/steps ran last round; goal: best product we could have delivered."

This document closes a re-verification round on a project where all 8 planned epics had already been implemented and marked done, but the BMad process that should have accompanied that work only partly ran. The goal was not to re-litigate scope, but to find what was never actually checked, and fix what checking found broken.

---

## 1. What last round skipped

An audit at the start of this round found the following gaps in how Epics 1–8 were delivered:

- **Zero story files** for 27 stories marked "done." No `Dev Agent Record`, no acceptance-criteria checklist, no reviewer sign-off artifact existed for any of them on disk.
- **No story validation** — stories were never checked against the PRD/epics before being called done.
- **No per-story code review**, except a single adversarial pass at the end of Epic 8.
- **No PRD validation** — the PRD's own definition of success was never checked against what shipped.
- **No readiness gate** (`bmad-check-implementation-readiness`) ever ran.
- **No e2e test step.**
- **No `project-context.md`/AGENTS.md audit** — agent-facing repo instructions had drifted from the actual codebase with no one checking.

## 2. What ran this round

- **Full test suite**, twice: **784 tests green** as the starting baseline, **796 tests green** as the final state after Epic 9 remediation (net +12: new regression tests added, one vacuous test removed and replaced). See `test-run.md` for the baseline run.
- **PRD validation** (`_bmad-output/planning-artifacts/prd-validation-report.md`) — **verdict: Fair.** The PRD is well-structured as a requirements contract (FR/NFR/SM IDs, Assumptions Index, and epics.md's FR Coverage Map all round-trip cleanly), but its own Success Metrics were never operationalized: **SM-1 through SM-6 — including the flagship claim that the ivrit.ai model beats the baseline on Hebrew WER — were never measured**, and **two Open Questions gated on "before Phase 1 closes" / "before significant investment" (memory headroom, AGPL confirmation) remain unresolved** despite that checkpoint having long passed.
- **AGENTS.md audit** (`project-context-audit.md`) — **7 stale facts found and fixed**: a claimed absence of a logging framework (a full `VocaLogger` exists), a wrong website tech stack (documented as static HTML/JS, actually Hugo), a stale repository-structure diagram (missing `Stores/`, `Pipeline/`, an entire target), an incomplete Makefile command list (missing the destructive `reset` target), an incomplete code-signing description (missed the actual local-dev path — Apple Development signing, not ad-hoc), an outdated WhisperKit version floor, and no mention of the deliberate TypeFlow/VocaMac branding split.
- **Per-epic acceptance audit** across all 8 epics — every acceptance criterion in `epics.md` traced to its implementing code and to a test that actually pins the claim (not just a passing-but-vacuous one). Full detail in the four `verify-epics-*.md` files in this directory. Totals across all 8 epics:

  | Verdict | Count | Meaning |
  |---|---|---|
  | SATISFIED | 106 | Implemented and a test would fail if it regressed |
  | PARTIAL | 46 | Implemented correctly but under-verified, or a documented deliberate deviation |
  | **VIOLATED** | **2** | The AC as written is not actually a property of the delivered code |
  | UNVERIFIABLE | 10 | Only real Accessibility-API/perceptual behavior can settle it — manual-only by nature |
  | Superseded/cut | 7 | Explicitly decided out of scope (e.g. story 7.3's spike concluded CUT) |
  | **Total ACs audited** | **171** | |

  The 2 VIOLATED ACs are the ones Epic 9 exists to fix (§3).

- **`epics.md` corrected in 3 places** (annotated in-place as "amended 2026-08-22 post-audit," not rewritten):
  1. **Story 7.2** — the "measurably faster" performance claim was not met. The commit's own measurement showed a statistical wash (6.42s unchunked vs. 6.29s chunked on a 71.7s clip); chunking was kept for correctness (the unchunked path silently drops a transcript segment), not speed. The AC is now marked satisfied on correctness grounds only.
  2. **Story 5.1** — the matres-lectionis normalization AC ("ו/וו, י/יי unified") does not match the shipped `HebrewNormalizer.normalize` pipeline, which deliberately excludes that collapsing (it would merge distinct words like מוות/מות, עוול/עול). The standalone function exists and is tested but is intentionally not wired in.
  3. **Story 8.2** — a test-citation correction: `DecodingOptionsLanguageTests` is real, but it lives in `DictationLanguageTests.swift`, not in a file of its own name as the original citation implied.

## 3. Epic 9 — Remediation

Four stories, each run through a full create → validate → dev → review cycle, targeting the defects the acceptance audit surfaced. Full detail in `_bmad-output/implementation-artifacts/stories/9-*.md`.

| Story | Defect | Fix | Review verdict |
|---|---|---|---|
| **9.1** — Gate Command Mode records out of Re-paste | Re-paste injected a Command Mode record's spoken *instruction* into the document unfiltered (violates Epic 6 AC 6.3.2 — "instruction text is never injected into the document") | Added a `mode != .command` guard in `AppState.rePaste`/`rePasteMostRecent`, hid the Re-paste controls for command records in `HistoryView` | **APPROVED-WITH-NOTES** — security contract holds (no reachable injection path); 4 MINOR polish findings, none blocking |
| **9.2** — Enforce a loopback-only LLM endpoint | `PostProcessService` accepted any host as the LLM endpoint — no enforcement of loopback-only traffic (violates Epic 2 AC 2.2-AC6 / NFR-1) | Added a loopback-host predicate before all three request paths (`_clean`, `_command`, `testConnection`); UI copy corrected to state the block instead of a warning | **CHANGES REQUESTED → fixed → APPROVED.** First review found and reproduced a live **307-redirect exfiltration bypass**: even with the loopback guard passing, an HTTP redirect from the configured (trusted) loopback server could re-POST the full transcript to an arbitrary off-box host, since nothing checked `Location` on a redirect. Fixed with a per-task `URLSessionTaskDelegate` (`RedirectBlocker`) that refuses all redirects; independently re-reproduced both broken and fixed behavior with a standalone probe outside the test suite before sign-off. |
| **9.3** — Inert cask workflow, correct size label, isolation-safe test | (a) `update-homebrew-cask.yml` had no disable guard and would push a fabricated checksum to a public tap on a 404; (b) `modelSizeFromName` misclassified the shipped default model; (c) a model-size-default test was order-dependent (poisoned by state left from another test) | (a) `if: false` job-level guard + `curl -fsSL`; (b) reordered branch matching; (c) test now cleans up its own defaults key | **PASS** — all three fixes independently verified, no findings |
| **9.4** — Restore pristine stock behavior when Profiles is disabled | Turning the Profiles master toggle off still applied a user-edited Default Profile record (leftover prompt override/toggle changes) instead of true Epic-2 stock behavior | `ProfileManager.resolve` now returns a pristine `Profile.makeDefault()` when `profilesEnabled` is false, instead of the persisted, user-editable Default Profile | **APPROVED** — no findings |

## 4. Skip ledger

Verbatim from `_bmad-output/gate-ledger.yaml`:

```yaml
bmad_version: 6.11.0
updated: '2026-08-22T00:20:09'
skips:
- step: bmad-create-story
  reason: 'Retroactive: 27 stories implemented+done in prior sessions without story
    files on disk; authoring them post-hoc adds no product value. Replaced by post-hoc
    per-epic acceptance re-verification this session.'
  ts: '2026-08-22T00:00:09'
- step: bmad-check-implementation-readiness
  reason: Never ran; all 8 epics already shipped. Replaced by post-hoc acceptance
    re-verification wave (2026-08-21).
  ts: '2026-08-22T00:00:09'
decisions:
- step: bmad-qa-generate-e2e-tests
  decision: skip
  reason: 'App is a menu-bar AX/TCC-gated dictation app: true e2e needs mic + Accessibility
    grants + a signed UI-test host; no headless seam exists. Coverage rests on 784
    unit/integration tests + manual smoke. Revisit if a release repo/CI signing ceremony
    lands.'
  ts: '2026-08-22T00:20:09'
```

## 5. Residual risks / deliberately not done

- **WER and the other Success Metrics are still unmeasured.** SM-1 (the flagship claim that the local ivrit.ai model beats the baseline on Hebrew WER) has no held-out set, no story, and no verification step anywhere in this project's history. This is the single biggest open item from the PRD validation and was intentionally out of scope for this round (fixing it means designing and running a WER benchmark, not a code fix).
- **Two Open Questions remain open**: AGPL distribution obligations were never confirmed with the relevant party, and ivrit.ai-model + Q4-LLM peak memory headroom was never measured — both were explicitly gated on checkpoints ("before Phase 1 closes" / "before significant investment") that have since passed.
- **The ~46 PARTIAL acceptance criteria are mostly untested UI-layer clauses.** The SwiftUI view layer has no test seam (no ViewInspector, no snapshot testing, no UI-test target) — the underlying model/service logic behind most of these is tested; the view wiring on top of it is verified by reading, not by an automated assertion.
- **A pre-existing stale-snapshot re-paste race is backlogged, not fixed.** Flagged during 9.1's review: a history record deleted or retention-pruned during the `focusSettleDelay` window is still injected, because the record's text is captured before the delay. This predates Epic 9 and is unrelated to the mode-gate fix (the mode value travels with the captured record, so it can't go stale). Deliberately left for a future story per the reviewer's own recommendation.
- **Homebrew casks still point at upstream's release assets**, not this fork's — blocked on this fork having no release repo of its own. Story 9.3 made the cask-update workflow inert rather than trying to stand up a real release pipeline.
- **A handful of Hebrew-matching edge cases are known and accepted, not fixed**: a literal-placeholder collision, a bound-prefix false match, and maqaf-compound handling gaps in the Dictionary/Snippet matchers — surfaced as PARTIAL findings in the Epic 5/6 acceptance audit and judged low-impact enough not to warrant their own Epic 9 story.

## 6. Verification evidence

- **Test counts:** 784 tests green (baseline, `test-run.md`) → 796 tests green (final, after Epic 9). Zero failures at either point.
- **Review verdicts:** 9.1 APPROVED-WITH-NOTES, 9.2 CHANGES REQUESTED → APPROVED (after fixing a real redirect-exfiltration bypass), 9.3 PASS, 9.4 APPROVED. All four reviews were run by a fresh reviewer taking nothing from the Dev Agent Record on trust.
- **Mutation checks:** Story 9.1's reviewer confirmed both new production guards are load-bearing by reverting each independently and watching the corresponding test fail (`testRePasteRefusesACommandModeRecord`, `testRePasteMostRecentSkipsCommandModeRecords`). Story 9.2's re-reviewer reproduced the redirect exfiltration independently outside the test suite (a standalone two-listener probe), confirmed it succeeded against the unfixed code and failed (zero bytes reaching the redirect target) against the fixed code, across all of 301/302/307/308.
- **Independent probes:** 9.2's reviewer ran the shipped loopback predicate against 25+ adversarial host spellings (percent-encoding, octal/decimal IP forms, userinfo tricks, IDN dot variants) resolving each accepted host via `getaddrinfo` — every accepted host genuinely resolves to loopback, zero bypasses found.

---

## Source files in this directory

- `verify-epics-1-2.md` / `.html` — Epic 1–2 acceptance audit
- `verify-epics-3-4.md` / `.html` — Epic 3–4 acceptance audit
- `verify-epics-5-6.md` / `.html` — Epic 5–6 acceptance audit (contains the 6.3.2 VIOLATED finding that led to Story 9.1)
- `verify-epics-7-8.md` — Epic 7–8 acceptance audit (no `.html` twin was produced upstream)
- `test-run.md` — full test suite baseline run (784 green)
- `project-context-audit.md` — AGENTS.md staleness audit (7 fixes)

Related artifacts elsewhere in the repo:
- `_bmad-output/planning-artifacts/prd-validation-report.md` / `.html` — PRD validation (verdict: Fair)
- `_bmad-output/planning-artifacts/epics.md` — corrected in 3 places, in-line amendments
- `_bmad-output/implementation-artifacts/stories/9-1-*.md` … `9-4-*.md` — full Epic 9 story files with Dev Agent Record + Code Review sections
- `_bmad-output/gate-ledger.yaml` — skip/decision ledger quoted in full above
