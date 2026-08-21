# Validation Report — local-whisper PRD

- **PRD:** `_bmad-output/planning-artifacts/PRD.md`
- **Cross-checked against:** `_bmad-output/planning-artifacts/epics.md` (also spot-checked `_bmad-output/RETROSPECTIVE.md`)
- **Rubric:** bmad-prd quality rubric (7 dimensions) + FR/NFR/SM coverage cross-check
- **Run at:** 2026-08-22T00:00:00Z
- **Grade:** Fair

## Context for this validation

This validation was never run during planning. All 8 epics (25 FRs across Epics 1–7, plus an ad-hoc Epic 8) are already implemented and marked done. Per the requester's framing, the point of this pass is **not** to re-litigate scope — §10 Settled Decisions stands — but to find requirements that were **never satisfied, never checked, or were not actually testable as written**, now that "done" is a claim rather than a plan.

## Overall verdict

The PRD itself is well-built as a requirements contract: FRs are numbered, nested, and mostly carry sharp Given/testable-consequence structure; Non-Goals, Assumptions, and Settled Decisions are explicit rather than implied; the Assumptions Index round-trips cleanly against inline tags; and the epics.md FR Coverage Map confirms all 25 FRs landed in a story. Where it falls short is exactly where "done" needs the most scrutiny: **the PRD's own definition of success (§7 Success Metrics) was never operationalized into any story, and appears never to have been measured** — the flagship claim of the whole project (ivrit.ai beats the baseline on Hebrew WER, SM-1) has no verification step anywhere in epics.md or the retrospective. Two Open Questions that the PRD explicitly gated on ("before Phase 1 closes," "before significant investment") also show no evidence of resolution despite Phase 1 having long since shipped. These are gaps in *closing the loop*, not gaps in the PRD's drafting quality.

## Dimension verdicts

- Decision-readiness — adequate
- Substance over theater — strong
- Strategic coherence — adequate
- Done-ness clarity — thin
- Scope honesty — strong
- Downstream usability — adequate
- Shape fit — strong

## Findings by severity

### High (2)

**[Strategic coherence / Decision-readiness]** Success Metrics (SM-1 through SM-6) were never operationalized or measured (§7)
The PRD defines six Success Metrics as the criteria for whether the product succeeded — most centrally **SM-1**: "Word error rate on a fixed held-out set of Hebrew dictations is lower with the ivrit.ai model than with `large-v3-v20240930_626MB`." This is the single claim the whole Phase 1 bet rests on (§1 Vision: "on Hebrew accuracy... a locally-run ivrit.ai fine-tune should beat a general-purpose cloud model outright"). Searching `epics.md` and `RETROSPECTIVE.md` for any of SM-1–SM-6 finds zero hits — only the three counter-metrics (SM-C1, SM-C2, SM-C3) are ever referenced, inside unrelated manual-test notes. Story 1.1's own manual verification step is "dictate a Hebrew sentence, confirm text appears" — not a WER comparison. No held-out set exists, is defined, or is referenced anywhere. The same is true for SM-2 (send-ready majority), SM-4 (latency budget), SM-5 (fallback bound), and SM-6 (corrections don't recur) — none has a story, AC, or verification step tied back to it by ID.
*Fix:* Either add a lightweight story/checklist item that actually runs the SM-1 WER comparison against a defined held-out set (even a small one), or explicitly downgrade SM-1–SM-6 in the PRD from "Success Metrics" to "future validation criteria — not measured in this release" so the document doesn't imply they were checked.

**[Decision-readiness]** Two gate-conditioned Open Questions show no evidence of resolution despite the gate having passed (§9)
§9.4 states the ivrit.ai-model + Q4-LLM memory-headroom question "needs measurement **before Phase 1 closes**." Story 1.3's verification step only says the question "can now be investigated" (present tense, instrumentation only) — not that it was answered. §9.5 says AGPL distribution obligations are "worth confirming with the relevant party **before significant investment**"; investment (8 completed epics) has since happened, with no confirmation recorded anywhere in `epics.md` or the retrospective. Both items were explicitly framed as needing closure by a checkpoint that has now passed, and both remain open in every artifact reviewed.
*Fix:* Record the actual peak-memory measurement (or note it was skipped and why) against OQ-4, and get and record the AGPL confirmation against OQ-5 — or explicitly mark both "deferred, accepted risk" in the PRD/retrospective so the gate isn't silently missed.

### Medium (3)

**[Downstream usability]** NFR-7 (Licensing) has no epic assignment in the FR Coverage Map and no verification step (epics.md §"FR Coverage Map", "Requirements Inventory")
NFR-7 ("Licensing — AGPL-3.0 retained, no VoiceInk code copied") is listed in the Requirements Inventory table but is the only NFR never assigned to any epic in the FR Coverage Map, and no story's acceptance criteria or verification section checks it. Every other NFR (1–6) appears against at least one epic. This isn't necessarily unsatisfied in practice — no VoiceInk code copying is plausible by omission — but it is the one inventoried requirement with zero traceable downstream coverage, which is exactly what the coverage map exists to prevent.
*Fix:* Either add NFR-7 to an epic's coverage row (e.g. a one-line "no VoiceInk-derived code" check in code review) or note explicitly in epics.md why it's covered by process rather than a story.

**[Done-ness clarity]** SM-2 and SM-3's evidence model conflicts with the PRD's own no-telemetry stance, and the PRD never names the conflict
SM-2 ("the majority need no manual editing") and SM-3 ("still in daily use one month after Phase 1 ships") are outcome metrics that would normally be checked via usage telemetry — but §8 Cross-Cutting NFRs states "no telemetry, no crash reporting, no remote configuration" as non-negotiable, and History Records are explicitly local-only and excluded from any diagnostic export (FR-8). The PRD never reconciles how SM-2/SM-3 could be measured at all without either violating the privacy stance or relying entirely on the single user's subjective impression (in which case they should be labeled as such, not as measured metrics).
*Fix:* Either state SM-2/SM-3 are self-assessed, not instrumented (which is fine for a one-user product), or specify a local-only, non-transmitted mechanism (e.g., a periodic Settings-screen self-check prompt) that respects the offline constraint.

**[Done-ness clarity]** Several FR/NFR/SM consequences use unquantified soft bounds that the rubric flags as untestable-as-written
- FR-6: "a low single-digit-second timeout" — no actual number in the PRD (epics.md Story 2.4 doesn't pin one either; it just says "a low single-digit-second timeout" again).
- FR-14 / FR-25: "negligible latency" (used twice, no bound given).
- FR-14: "truncated to a bounded character budget" — no number.
- SM-4: "stays within a comfortable interactive budget" — no number or upper bound.
These are exactly the "reasonable performance" / adjective-only phrasings the rubric calls out as failing done-ness clarity, even though the majority of FR consequences elsewhere in the same PRD are admirably precise (e.g., FR-16's normalization rules, FR-22's abort conditions).
*Fix:* Pin at least one concrete number per item (even a rough one, e.g. "≤3 seconds," "≤500 characters each side") so downstream stories have a bound to test against rather than inferring one themselves, as several evidently did at implementation time.

### Low (1)

**[Scope honesty]** SM-3 ("daily use sustained one month after Phase 1 ships") has no scheduled checkpoint anywhere to actually revisit it
Even if SM-3 is accepted as self-assessed (see Medium finding above), nothing in the PRD, epics.md, or the retrospective schedules a revisit at the one-month mark. As currently written it will simply never be checked unless someone remembers to look.
*Fix:* A one-line note in the retrospective or a follow-up reminder is sufficient — this is a process gap, not a document defect.

## Mechanical notes

- **Glossary drift:** none found. All key terms (Dictionary Entry vs. Dictionary, Cursor Context, Profile, Snippet, Command Mode, etc.) are used consistently and identically across the PRD and are carried through into epics.md without renaming.
- **ID continuity:** clean. FR-1–FR-25 are contiguous with no gaps or duplicates; UJ-1–UJ-5 and SM-1–SM-6/SM-C1–SM-C3 are contiguous. The epics.md FR Coverage Map confirms all 25 FRs are assigned to an epic (Epic 3 and Epic 1 both legitimately claim FR-3, since latency spans ASR and History).
- **Assumptions Index roundtrip:** clean. All 6 inline `[ASSUMPTION: …]` tags (FR-5, FR-10, FR-13, FR-18, §8, §4.1) are indexed verbatim in §11; no orphaned index entries.
- **UJ protagonist naming:** clean. All 5 UJs carry "Tal" as a named protagonist with context inline, per the rubric's preference over floating/anonymous UJs.
- **NFR-7 coverage gap:** repeated here as a mechanical fact — see Medium finding above.

## Coverage cross-check summary (PRD → epics.md)

| Requirement class | Total in PRD | Assigned to an epic | Verified by a specific AC/test | Notes |
| --- | --- | --- | --- | --- |
| Functional Requirements (FR-1–FR-25) | 25 | 25 / 25 | 25 / 25 (via story ACs) | Full coverage confirmed |
| Non-Functional Requirements (NFR-1–NFR-7) | 7 | 6 / 7 | 6 / 7 | NFR-7 (Licensing) has no epic row |
| Primary Success Metrics (SM-1–SM-3) | 3 | 0 / 3 | 0 / 3 | Never referenced in epics.md or retrospective |
| Secondary Success Metrics (SM-4–SM-6) | 3 | 0 / 3 | 0 / 3 | Never referenced by ID |
| Counter-metrics (SM-C1–SM-C3) | 3 | 3 / 3 | 3 / 3 (referenced in manual test notes) | Only these three SM-family IDs appear anywhere in epics.md |
| Open Questions gated on a checkpoint (§9.4, §9.5) | 2 | — | 0 / 2 | Gate passed; no recorded resolution |

## Reviewer files

- This report was produced directly by the bmad-prd rubric walk plus a manual ID-level cross-check between `PRD.md` and `epics.md` (no separate `review-*.md` intermediate files were retained — this is the consolidated output).
