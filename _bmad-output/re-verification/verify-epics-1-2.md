# Post-hoc acceptance re-verification — Epics 1 & 2

**Project:** local-whisper (VocaMac fork, branded TypeFlow) — macOS Swift/SwiftPM menu-bar dictation app
**Date:** 2026-08-22
**Lenses:** verification-gap + adversarial (`bmad-review`)
**Source of ACs:** `/Users/talepstein/Projects/local-whisper/_bmad-output/planning-artifacts/epics.md` lines 102–362
**Suite state at audit:** 784 tests, 0 failures (reported by caller; not re-run in full)

## Why this audit exists

`_bmad-output/implementation-artifacts/sprint-status.yaml` marks all seven stories of Epics 1–2 `done`,
plus `epic-1-retrospective: done` and `epic-2-retrospective: done`. The tracker declares
`story_location: _bmad-output/implementation-artifacts/stories` — **that directory does not exist**.
`_bmad-output/gate-ledger.yaml` records the deliberate skip of `bmad-create-story` and
`bmad-check-implementation-readiness`, deferring assurance to "post-hoc per-epic acceptance
re-verification". This audit is therefore the **only acceptance gate these two epics have ever had**.

All line-number citations inside `epics.md` predate implementation and are stale. Every citation
below is a re-derived current location.

## Verdict legend

| Verdict | Meaning |
|---|---|
| SATISFIED | Implementing code found **and** a test that fails if the behavior regresses |
| PARTIAL | Implemented, but a clause is unimplemented or the behavior has no test that would catch its loss |
| VIOLATED | The AC as written is not a property of the delivered code |
| SUPERSEDED | A later epic replaced the surface; AC met in substance on the replacement |
| UNVERIFIABLE | Cannot be pinned by a unit test at the inference/manual boundary |

---

## Epic 1 — Hebrew ASR Accuracy

| AC | Summary | Verdict | Implementing code | Covering test | Note |
|---|---|---|---|---|---|
| 1.1-AC1 | ivrit entry appears in Settings→Models with name/size/RAM; selecting loads via `WhisperService.loadModel`; Hebrew dictation produces a transcript | PARTIAL | `Sources/VocaMac/Views/SettingsView.swift:689,731,735,804-809`; `Sources/VocaMac/Models/AppState.swift:1870-1919` | `Tests/VocaMacTests/AppStateTests.swift:408-431`; `Tests/VocaMacTests/ModelTests.swift:128-131` | Model/state layer wired and tested; row-rendering and Hebrew end-to-end clauses are manual-only with no recorded execution |
| 1.1-AC2 | Arms in all five exhaustive switches + `whisperKitModelName` + the two non-exhaustive string ladders | SATISFIED | `Sources/VocaMac/Models/WhisperModel.swift:74,93,119,138,157`; `Sources/VocaMac/Services/ModelManager.swift:284-285`; ladders `Sources/VocaMac/Services/WhisperService.swift:325-327`, `Sources/VocaMac/Models/AppState.swift:1931-1934` | `Tests/VocaMacTests/WhisperServiceTests.swift:59-62`; `Tests/VocaMacTests/ModelTests.swift:148-163` | Five switches compiler-enforced; the `WhisperService` ladder has a real ordering regression test. The `AppState` ladder arm is dead code (extras) |
| 1.1-AC3 | Support from on-disk presence, not `WhisperKit.recommendedModels()`; entry in `standardCatalog` | SATISFIED | `Sources/VocaMac/Services/ModelManager.swift:331-333,297-308`; `Sources/VocaMac/Models/WhisperModel.swift:55-57,42` | `Tests/VocaMacTests/ModelTests.swift:268-296,128-131,298-302` | Strongest coverage in the epic — both absent and present states against a temp dir; non-vacuous |
| 1.1-AC4 | No download attempted for it; existing download + chip/RAM recommendation unchanged | PARTIAL | `Sources/VocaMac/Views/SettingsView.swift:776-780`; `Sources/VocaMac/Views/OnboardingView.swift:543-555`; `Sources/VocaMac/Models/AppState.swift:683,866` | none found (searched `Tests/` for `isSideloadOnly`, `downloadModel`, `deviceRecommendedModel`) | Suppression is **UI-only**; `ModelManager.downloadModel` (`:437`) has no sideload guard, unlike `deleteModel` (`:523`) |
| 1.2-AC1 | Absent/incomplete → "Not Installed", not selectable, expected path shown, no download, no crash | PARTIAL | `Sources/VocaMac/Views/SettingsView.swift:693-702,742-749,776-780`; `Sources/VocaMac/Models/WhisperModel.swift:209-211` | none found (repo has zero SwiftUI view tests) | All four clauses implemented correctly but entirely unguarded by assertions |
| 1.2-AC2 | `startupFallbackModel` picks a known-good model, with exactly one clear message | PARTIAL | `Sources/VocaMac/Models/AppState.swift:861-875`; message `:2158-2164` | `Tests/VocaMacTests/AppStateTests.swift:377-405,408-431` — selection only | The "exactly one clear message" half is entirely unasserted |
| 1.2-AC3 | Hebrew present and selectable in the picker; stores `"he"`; prior value preserved on upgrade | SUPERSEDED | `Sources/VocaMac/Views/SettingsView.swift:336-347`; `Sources/VocaMac/Models/DictationLanguage.swift:32-35,60` | `Tests/VocaMacTests/DictationLanguageTests.swift:36-37,51` | Epic 8.2 replaced 19 hand-written rows with the shared `DictationLanguage` list; Hebrew is `Choice(code:"he")`. Presence covered; the `.tag` binding and upgrade-preservation are not |
| 1.3-AC1 | Record carries recording/ASR/post-process ms; zero (not missing) for skipped stages | SATISFIED | `Sources/VocaMac/Models/HistoryRecord.swift:45,49,53` (non-optional `Double`); populated `Sources/VocaMac/Models/AppState.swift:1326-1327,1648-1660` | `Tests/VocaMacTests/HistoryStoreTests.swift:386-397,439,465,65-66` | Real recording path driven; the zero case uses `TranscriptPipeline.production()` so it isn't vacuous |
| 1.3-AC2 | History view shows model + ASR duration; two models directly comparable | PARTIAL | `Sources/VocaMac/Views/HistoryView.swift:145,186-190` | none found (searched `Tests/` for `HistoryView`, `millisecondsLabel`) | Comparability actively undermined by a model-name mislabel — see below |
| 1.3-AC3 | Measurement adds no perceptible latency, no main-thread stalls (NFR-4) | UNVERIFIABLE | Values reused from existing `result.duration` / `StageReport.duration`; no new clock started | none found | Construction argument is strong; nothing measures it |

**Epic 1 counts (10 ACs):** SATISFIED 3 · PARTIAL 5 · SUPERSEDED 1 · UNVERIFIABLE 1 · VIOLATED 0

---

## Epic 2 — LLM Post-Processing

### Story 2.1 — Pipeline scaffolding

| AC | Summary | Verdict | Implementing code | Covering test | Note |
|---|---|---|---|---|---|
| 2.1-AC1 | Exactly one new call `await transcriptPipeline.run(context)` at the seam; no other logic in AppState | SATISFIED | `Sources/VocaMac/Models/AppState.swift:1281` (decl `:238`, init `:461`) | `Tests/VocaMacTests/PipelineTests.swift:238,247,266` | Still the only `.run` call. AD-1's "no other logic" has since eroded via Epics 4/8 — unguarded (extras) |
| 2.1-AC2 | Empty pipeline returns input unchanged byte for byte | SATISFIED | `Sources/VocaMac/Pipeline/TranscriptPipeline.swift:49-67` | `Tests/VocaMacTests/PipelineTests.swift:35-45` — asserts `Array(String.utf8)`, genuinely byte-level | |
| 2.1-AC3 | `run` cannot throw; failures captured as `StageOutcome`; `TranscriptContext` struct carries all six fields | SATISFIED | `Sources/VocaMac/Pipeline/TranscriptStage.swift:127,14-35`; `Sources/VocaMac/Pipeline/TranscriptContext.swift:11,16,20,24,58,69` | `Tests/VocaMacTests/PipelineTests.swift:69-95,157-177` | Non-throwing `run` is compiler-enforced — stronger than a test |
| 2.1-AC4 | Identity corpus: Hebrew+niqqud, mixed HE/EN, empty, whitespace-only | SATISFIED | as AC2 | `Tests/VocaMacTests/PipelineTests.swift:16-31` | All four required members present individually (`:17`, `:18-20`, `:22-23`, `:24`) plus emoji/ZWJ and a 500-word case |
| 2.1-AC5 | `@MainActor` + `async`; no `actor`; no strict-concurrency flags | SATISFIED | `Sources/VocaMac/Pipeline/TranscriptPipeline.swift:10`; `Package.swift:39-41` (`-parse-as-library` only) | Build-enforced | `rg` over `Sources/` finds zero `actor` declarations and zero `StrictConcurrency`/`swiftLanguageMode` |

### Story 2.2 — PostProcessService

| AC | Summary | Verdict | Implementing code | Covering test | Note |
|---|---|---|---|---|---|
| 2.2-AC1 | Sole owner of HTTP client; one chat-completions request; content returned as cleaned text | PARTIAL | `Sources/VocaMac/Services/PostProcessService.swift:711-735,737-787,890-922` | request shape `Tests/VocaMacTests/PostProcessServiceTests.swift:58,139,164`; **success path through the real service: none found** (zero hits for `URLProtocol`/`protocolClasses`) | No test ever drives `send` to a 2xx; the success branch is dead code from the suite's view |
| 2.2-AC2 | Connection error caught, input returned unchanged, reason logged + reported | SATISFIED | `Sources/VocaMac/Services/PostProcessService.swift:912-921` | `Tests/VocaMacTests/PostProcessServiceTests.swift:611-621` (real refused connection); `Tests/VocaMacTests/PostProcessStageTests.swift:121-143` | Logging itself unasserted |
| 2.2-AC3 | Deadline via **both** URLSession config and outer Task; elapsed bounded | SATISFIED | `Sources/VocaMac/Services/PostProcessService.swift:240` (request timeout), `:898-902` (watchdog) | `Tests/VocaMacTests/PostProcessServiceTests.swift:623-643` — real never-replying loopback socket, asserts `.timedOut(1.0)` **and** `elapsed < 2.0` | Both mechanisms genuinely present; `timeoutIntervalForResource` unset (extras) |
| 2.2-AC4 | Reject non-2xx, malformed JSON, empty content, disproportionate length | SATISFIED | `Sources/VocaMac/Services/PostProcessService.swift:413-462,267-278` | `Tests/VocaMacTests/PostProcessServiceTests.swift:216,223,228,236,241,246`; boundaries `:260-269,271-290` | Ratio guard tested on both sides of both bounds |
| 2.2-AC5 | Prompt construction + validation pure and separately unit-tested; defaults `static let` in `Prompts.swift` | SATISFIED | `Sources/VocaMac/Services/PostProcessService.swift:143-244,248-463`; `Sources/VocaMac/Models/Prompts.swift:26,116` | `Tests/VocaMacTests/PostProcessServiceTests.swift:15-182` (builder), `:184-586` (validator) | 39 network-free tests |
| 2.2-AC6 | Requests target **only** the configured loopback endpoint (NFR-1) | **VIOLATED** | `Sources/VocaMac/Services/PostProcessService.swift:156-170,747` — accepts any scheme/host; UI-only warning `Sources/VocaMac/Views/PostProcessSettingsTab.swift:22-27,54-58` | `Tests/VocaMacTests/PostProcessServiceTests.swift:175-181` — **vacuous** | No loopback enforcement anywhere in the service |

### Story 2.3 — Wire post-processing behind a master toggle

| AC | Summary | Verdict | Implementing code | Covering test | Note |
|---|---|---|---|---|---|
| 2.3-AC1 | Hebrew fillers removed, sentence-final punctuation present | UNVERIFIABLE | Prompt rules 2–3 `Sources/VocaMac/Models/Prompts.swift:34-35` (HE), `:124-125` (EN) | inference boundary; **Hebrew prompt text itself unpinned** — EN twin exists at `Tests/VocaMacTests/DictationLanguageTests.swift:143-156` | Prompt clauses survive the rule-11 additions, but nothing would catch their deletion |
| 2.3-AC2 | Spoken enumeration formatted as a list | UNVERIFIABLE | Prompt rule 5 `Sources/VocaMac/Models/Prompts.swift:37,127` + example `:85-89` | EN only `Tests/VocaMacTests/DictationLanguageTests.swift:154`; Hebrew: none found | Same shape — Hebrew clause unasserted |
| 2.3-AC3 | "נפגש בשתיים… בעצם בשלוש" → only the corrected time | UNVERIFIABLE | Prompt rule 4 `Sources/VocaMac/Models/Prompts.swift:36` + worked example `:67` | EN only `Tests/VocaMacTests/DictationLanguageTests.swift:146-151`; Hebrew: none found | |
| 2.3-AC4 | A dictated question stays a question, is not answered | UNVERIFIABLE | Prompt rule 6 `Sources/VocaMac/Models/Prompts.swift:38,128` | rule-6 substring incidentally pinned by `Tests/VocaMacTests/CommandModeTests.swift:272`; validator backstops `Tests/VocaMacTests/PostProcessServiceTests.swift:381,367,394` | Best covered of the four; the question *example* at `Prompts.swift:82-83` is still unpinned |
| 2.3-AC5 | Toggle off ⇒ **no HTTP request at all**; byte-identical to pre-epic | SATISFIED | `Sources/VocaMac/Pipeline/Stages/PostProcessStage.swift:59-61` (toggle checked before any work) | `Tests/VocaMacTests/PostProcessStageTests.swift:72-84` — asserts `cleanCallCount == 0`, not merely unchanged text; `:86-97` corpus; `:285` production pipeline; `Tests/VocaMacTests/HistoryStoreTests.swift:405-442` through real AppState | The strongest AC in the epic, and correctly tested as a call-count spy |
| 2.3-AC6 | Any failure ⇒ raw transcript injected, **no modal**; raw retained alongside final | PARTIAL | `Sources/VocaMac/Pipeline/Stages/PostProcessStage.swift:110-113`; log-only `Sources/VocaMac/Pipeline/TranscriptPipeline.swift:113-116`; both fields `Sources/VocaMac/Models/AppState.swift:1823-1834` | pass-through `Tests/VocaMacTests/PostProcessStageTests.swift:121-143`; distinct raw vs final persisted `Tests/VocaMacTests/HistoryStoreTests.swift:351-359`; **"no modal": none found** | Raw-alongside-final properly covered with *different* values; the no-modal clause is structurally true but unasserted |

### Story 2.4 — Post-processing settings tab

| AC | Summary | Verdict | Implementing code | Covering test | Note |
|---|---|---|---|---|---|
| 2.4-AC1 | New tab in the `TabView` alongside the existing six; own file per `StatsSettingsTab` precedent | SUPERSEDED | `Sources/VocaMac/Views/SettingsView.swift:129` (`case .cleanup: PostProcessSettingsTab()`); own file `Sources/VocaMac/Views/PostProcessSettingsTab.swift` | none found | The `TabView` was replaced by a `NavigationSplitView` sidebar (commit `0c33320`); the tab is genuinely reachable, so met in substance, but "alongside the existing six" no longer describes the UI |
| 2.4-AC2 | Endpoint/model/timeout/temperature editable, persisted under `vocamac.postProcess.*`, correct defaults | SATISFIED | `Sources/VocaMac/Models/PostProcessSettings.swift:16-36` | `Tests/VocaMacTests/PostProcessSettingsTabTests.swift:35,49,70,98` | Defaults verified against AC: `http://localhost:1234`, `qwen3-4b-instruct-2507-mlx`, `5.0`s, `0.0`. No drift |
| 2.4-AC3 | Editable system prompt with "Restore default" from `Prompts.swift` | PARTIAL | `Sources/VocaMac/Views/PostProcessSettingsTab.swift:123-138` | `Tests/VocaMacTests/PostProcessSettingsTabTests.swift:84-94` — **broken verification**: the test performs the assignment itself under the comment "What the tab's Restore Default button does" | Confirmation alert before restoring; no test can fail from any change to the button |
| 2.4-AC4 | "Test connection" reports the responding model id; failure is actionable; UI never blocks | PARTIAL | `Sources/VocaMac/Services/PostProcessService.swift:842-875`; `Sources/VocaMac/Views/PostProcessSettingsTab.swift:168-185` | none found — only `Tests/VocaMacTests/Mocks/MockServices.swift:642`, whose `testConnectionResult` no test ever reads | The real `testConnection` is never exercised by any test |

**Epic 2 counts (21 ACs):** SATISFIED 11 · PARTIAL 4 · VIOLATED 1 · SUPERSEDED 1 · UNVERIFIABLE 4

---

## Gap detail — every non-SATISFIED row

**1.1-AC1.** The two clauses `epics.md:139` marked manual (row renders; Hebrew dictation produces a transcript against real or stubbed weights) have no recorded outcome anywhere — no story file, review, or note. The epic explicitly required recording whether the real-weights check was pending. Smallest uncaught regression: reorder the branch chain at `SettingsView.swift:776-820` and the ivrit row silently loses its Load button; 784 tests stay green. Close it with a headless assertion that `AppState.availableModels` contains the ivrit entry with `isSupported == true` given a fixture directory.

**1.1-AC4.** "No download is attempted" lives only in two view branches. `ModelManager.downloadModel(size:)` (`ModelManager.swift:437-450`) builds a WhisperKit config for `ivrit-ai_whisper-large-v3-turbo` and would hit HuggingFace for a repo that does not exist there — **verified: there is no `isSideloadOnly` guard**, while `deleteModel` (`:523`) does guard the mirror-image invariant. Separately, the "recommendation logic unchanged" clause is false in a good way: `AppState.swift:683,866` now filter `!$0.size.isSideloadOnly`, untested. Close with `XCTAssertThrowsError(try manager.downloadModel(size: .ivritAiWhisperLargeV3Turbo))`.

**1.2-AC1.** All four clauses are implemented in SwiftUI body code the test target cannot reach, and "cannot be selected" is expressed as the *absence* of a Load button rather than a positive disabled state. Smallest uncaught regression: move `else if model.isActive` above the sideload guard at `SettingsView.swift:776` — exactly what the comment at `:778-779` warns against — and a row shows "Active" while its files are gone. Close by extracting the row's decision into a pure `action(for:) -> Action` and asserting `.none` plus a non-empty expected path.

**1.2-AC2.** `AppStateTests.swift:377-405` asserts only which model was selected. Delete `AppState.swift:2159-2161` entirely and the user gets a silently swapped model with no explanation while both tests pass. Close with `XCTAssertEqual(appState.errorMessage, "…is no longer available — using Small instead")` plus an assertion that no second message follows.

**1.2-AC3 (SUPERSEDED).** Epic 8.2 replaced the picker wholesale; Hebrew is back and `DictationLanguageTests.swift:36-37` genuinely fails if `"he"` leaves the list. Residual gap: nothing asserts the picker's selection binding writes `"he"`. Change `SettingsView.swift:340` from `.tag($0.code)` to `.tag($0.name)` and every selection stores a display name — WhisperKit then receives `"Hebrew"` — with no test failing. Close with a round-trip of `vocamac.selectedLanguage` through a fresh `AppState`.

**1.3-AC2.** Two problems. (a) `millisecondsLabel` is `fileprivate` inside `HistoryDetailView` and the repo has no view tests; delete the `• ASR …` interpolation at `HistoryView.swift:145` and the story's whole point vanishes green. (b) **Verified bug:** `WhisperService.modelSizeFromName` (`WhisperService.swift:323-338`) tests `contains("v20240930")` before any size suffix, so the default model folder `openai_whisper-large-v3-v20240930_626MB` resolves to `.largeV3Latest`, not `.largeV3LatestCompact`. History therefore records "Large v3 Latest (Best)" for dictations that actually ran on the Compact model — directly defeating "the two models' typical latencies are directly comparable". Close with `XCTAssertEqual(service.modelSizeFromName("openai_whisper-large-v3-v20240930_626MB"), .largeV3LatestCompact)`, which fails today.

**1.3-AC3.** No new clock is started (values are reused from `result.duration` / `StageReport.duration`) and `HistoryStore` saves off the main path, so the construction argument holds; nothing measures it. Recorded UNVERIFIABLE rather than PARTIAL — a perf test here would cost more than it protects.

**2.2-AC1.** Every transport test exercises a failure. There is no `URLProtocol` stub, no responding local server, and `PostProcessService.init(session:)` is never called with a session in any test — so the success branch (`:770-786`) is unexecuted. Smallest uncaught regression: return `0` instead of `http.statusCode` at `:909` and every real request fails with `.httpStatus(0)` while all 784 tests pass and the user silently never sees cleanup. Close with an injected stub session returning a 200 and a valid body.

**2.2-AC6 — VIOLATED.** `PostProcessRequestBuilder.endpointURL` rejects a base URL only when it lacks a scheme or host. A user who types `https://api.example.com` gets an orange caption warning and then their transcripts — plus, with Story 4.4 on, surrounding document text — are POSTed to that host. `isEndpointLoopback` is `private` on a SwiftUI `View` and unreachable from tests. The one test named for this AC feeds in `http://localhost:1234` and asserts the host is `localhost` — a tautology about its own input that would pass if the builder had no host handling at all. This is both a violated AC and a broken-verification gap. The warn-not-block decision is recorded only in a source comment; the AC was never renegotiated.

**2.3-AC1…AC4 (UNVERIFIABLE by design).** These four are LLM-semantic outcomes; per the verification-gap lens the inference boundary is where verification stops. The prompt-delivery chain *is* fully pinned (`PostProcessServiceTests.swift:58`, `DictationLanguageTests.swift:197-221`), and every clause the ACs name still exists in `Prompts.swift` (rules 2–6), surviving the recent rule-11 additions. **But the content of the Hebrew prompt — the one this fork's users actually receive — is unpinned, while the English variant has a real content test** (`DictationLanguageTests.swift:143-156`). Smallest uncaught regression: delete rule 5 (`Prompts.swift:37`) and the `- כיסאות` example (`:85-89`); Hebrew enumerations silently stop becoming lists and 784 tests stay green. Close with a Hebrew mirror of that English test asserting the rule text and worked examples are present.

**2.3-AC6.** Nothing asserts the absence of user-facing error surfacing on a post-process failure. Structurally it holds — the only `errorMessage` writes on the dictation path are the ASR catch block (`AppState.swift:1348`) and Command Mode, and `TranscriptPipeline.swift:113-116` only logs. Smallest uncaught regression: someone adds `errorMessage = "Post-processing failed…"` beside that log; the AC breaks, the suite stays green, and the user gets a banner on every LM Studio hiccup. Close by extending `HistoryStoreTests.swift:468-477` with `XCTAssertNil(appState.errorMessage)` and `XCTAssertEqual(appState.appStatus, .idle)` after a `.failed` PostProcess report.

**2.4-AC1 (SUPERSEDED).** `TabView` → `NavigationSplitView` sidebar (commits `c7e2581`/`0c33320`), made precisely because nine tabs collapsed into an overflow chevron and rendered Cleanup unreachable. The tab is in its own file per the `StatsSettingsTab` precedent, enumerated at `SettingsView.swift:20,30,44`, grouped under "AI" at `:62`, and dispatched at `:129` — met in substance. Residual gap: deleting `case .cleanup: PostProcessSettingsTab()` compiles clean and passes 784 tests, re-introducing the exact bug the sidebar was built to fix. Close with `XCTAssertTrue(SettingsSection.allCases.contains(.cleanup))` plus an assertion that it appears in the section groups.

**2.4-AC3.** `testRestoreDefaultPromptReturnsTheDocumentedPrompt` (`PostProcessSettingsTabTests.swift:84-94`) sets `appState.postProcessSystemPrompt = Prompts.cleanTranscriptSystemPrompt` itself — under a comment that admits it is only imitating "what the tab's Restore Default button does" — then asserts it equals that same constant. It mocks away the thing under test. Smallest uncaught regression: change `PostProcessSettingsTab.swift:134` to assign a different prompt constant, or flip the `.disabled(...)` predicate at `:127` so the button is permanently greyed out. Close by extracting the restore action into a testable function and asserting its result, plus asserting the enable predicate.

**2.4-AC4.** `PostProcessService.testConnection` (`:842-875`) is never exercised — the only `testConnection` in `Tests/` is `MockServices.swift:642` returning a canned value. Untested: extracting the responding model id, the `.httpStatus(n)` mapping, and the "response did not name a model" rejection. Smallest uncaught regression: return `configuration.model` instead of `decoded.model` at `:874` and "Test connection" would confirm success against a backend serving an entirely different model — the exact confusion the feature exists to prevent. Close with a stub session returning a 200 whose body names a different model, asserting the reported id is the response's.

---

## Adversarial extras

1. **Model-name mislabel in history for the default model** (see 1.3-AC2b). The most consequential finding: the epic's stated purpose is measuring model A against model B, and the app's own default model is recorded under the wrong name.
2. **`AppState.loadModel`'s ivrit ladder arm is dead code.** `AppState.swift:1931-1934` is only reached when `modelManager.modelSize(from:)` returns nil, but that matches the ivrit folder exactly (`ModelManager.swift:284-285`). Harmless, but it is one of the two ladders AC 1.1-AC2 insisted on and it is untested precisely because it is unreachable.
3. **`HistoryRecord`'s three millis fields are non-optional `Double` with no custom decoder.** Memberwise-init defaults do **not** apply to synthesized `Codable` decoding, so any `history.json` lacking those keys throws. No such file should exist (they shipped with Story 3.1), but `language` is the only field with a decode-compat test (`DictationLanguageTests.swift:483`).
4. **Asymmetric sideload defense:** `deleteModel` guards, `downloadModel` does not.
5. **The AppState fallback tests exercise the mock's AD-11 bypass, not the real one.** `MockServices.swift:325-333` re-implements the bypass. Delete the real one at `ModelManager.swift:331-333` and `AppStateTests.swift:377-431` stays green — only `ModelTests.swift:268-296` catches it. That single test carries AD-11 alone.
6. **AD-1's "no other logic in AppState" has quietly eroded.** The seam was 5 lines at first delivery; `AppState.swift:1259-1298` now carries captured-context consumption, `effectiveLanguage` resolution, a six-argument context construction and a generation guard. Each traces to a later story, but no story re-asserted the constraint and nothing would notice further accretion.
7. **The shipping pipeline is not the empty pipeline the byte-level corpus tests.** `TranscriptPipeline.production` registers four stages unconditionally. The 14-member `utf8` corpus runs against `stages: []`. The production shape is covered by `PostProcessStageTests.swift:285` with a 4-member corpus asserting `XCTAssertEqual(String, String)` — Swift string equality is canonical-equivalence-based, so an NFC↔NFD renormalization of `"שָׁלוֹם עוֹלָם"` would pass while changing injected bytes. Add `Array(...utf8)` there.
8. **`timeoutIntervalForResource` is never set.** The only URLSession-layer deadline is the per-request `timeoutInterval`, which the code itself documents as idle-only. The wall-clock guarantee rests entirely on one `Task.sleep` watchdog.
9. **Two `PostProcessService` instances exist** — `PostProcessSettingsTab.swift:18` builds its own for Test Connection, so AD-6's "sole owner of the HTTP client" is now sole owning *type*, not sole instance.
10. **`recordingMillis` is audio length, not wall-clock hold time** (`AppState.swift:1326`). Defensible and documented, but VAD-trimmed silence is invisible and the field does not answer "how long did I hold the key".
11. **No story files and no per-story code reviews exist for any of the seven stories.** The MAJOR/MINOR annotations threaded through the sources imply reviews happened; they were never written down. Every "Manual:" step in `epics.md:136-141, 169-173, 200-203, 241-244, 284-288, 324-327, 357-360` is unevidenced.
12. **Cosmetic signature drift:** AC 2.2 names `clean(text:prompt:)`; the shipped shapes are `clean(text:systemPrompt:)` / `clean(text:systemPrompt:configuration:)`.
13. **There is no end-to-end test of the *enabled* post-processing path.** `AppState.swift:440` injects `postProcessService` only into `CommandModeCoordinator`; the dictation path's stage constructs its own concrete `PostProcessService()` (`TranscriptPipeline.swift:44`, `PostProcessStage.swift:26`), so there is no seam. The one real-pipeline AppState test (`HistoryStoreTests.swift:405`) deliberately runs with the toggle **off**, and `PostProcessStageTests.swift:292-301` scrubs the key for the same reason. Every enabled-path assertion stops at the stage boundary.
14. **`PostProcessSettingsTab` is untestable by construction** — `PostProcessSettingsTab.swift:18` holds `private let postProcessService = PostProcessService()`, the concrete class rather than the `PostProcessing` protocol, so the `ConnectionState` machine (`:29-34,144-164`) cannot be covered without a network. Relatedly, `PostProcessSettingsTabTests` never instantiates the tab: all five tests operate on `AppState`'s `@AppStorage` properties, and the file's coverage would be identical if the tab source were deleted.
15. **Timeout slider allows up to 15s** (`PostProcessSettingsTab.swift:66`, range `1...15`) while AC 2.4-AC2 calls for low single-digit seconds. Only the *default* is guarded (`PostProcessSettingsTabTests.swift:42` asserts `< 10.0`). Defensible as a user knob, but the AC's latency intent is enforced on the default alone.
16. **`PostProcessRequestBuilder.modelsURL` is dead code** — `PostProcessService.swift:152`, tested at `PostProcessServiceTests.swift:49`, **verified to have no caller in `Sources/`**. Presumably a `/v1/models`-based Test Connection replaced by the ping-completion approach. Flagged, not recommended for deletion.
17. **`testEveryFailureModeReturnsTheInputUnchanged`** (`PostProcessStageTests.swift:141`) asserts `.failed(reason: failure.reason)` — the error's reason compared against itself. It proves pass-through, which is its point, but pins no wording, so the "actionable reason" half of 2.4-AC4 gets no help from it.

---

## Bottom line

Epic 2's core engineering — the pipeline substrate, the identity guarantee, the deadline, the
validator, and the master toggle — is genuinely well built and genuinely well tested; the
toggle-off AC in particular is verified as a call-count assertion rather than the weaker
text-unchanged check that a call-and-discard implementation would also pass.

Two things should not carry a `done` flag as they stand:

- **NFR-1 is violated** (2.2-AC6). The app will POST transcripts to any host the user types, and
  the test named for that AC verifies nothing. Either enforce loopback or renegotiate the AC — but
  the warn-only decision currently exists solely as a source comment.
- **The Epic 1 measurement story reports the wrong model name** for the app's default model, which
  defeats the comparison the epic was built to enable.

Beyond those, three recurring shapes:

1. **UI-layer ACs across both epics have no automated coverage at all** (1.1-AC1, 1.1-AC4, 1.2-AC1,
   1.3-AC2, 2.4-AC1, 2.4-AC3, 2.4-AC4) because the repo has no SwiftUI view tests, and the manual
   steps that were supposed to cover them have no recorded results anywhere.
2. **Two tests look like coverage and are not** — `testRequestTargetsOnlyTheConfiguredLoopbackHost`
   (tautological) and `testRestoreDefaultPromptReturnsTheDocumentedPrompt` (re-implements the button
   it claims to test). Both are broken-verification gaps, and both sit on ACs otherwise assumed done.
3. **The enabled post-processing path is never exercised end to end.** Every assertion about the
   feature actually working stops at the stage boundary, because the dictation pipeline builds its
   own concrete service with no injection seam.

**Recommended gate verdict:** Epic 1 and Epic 2 should not stay `done` unchanged. Epic 2 carries one
violated NFR; Epic 1 carries a data-correctness bug that defeats its own measurement story. Neither
is large, and both are cheap to close — but "784 tests green" is not, on this evidence, the same
statement as "the acceptance criteria are met".

---

## Method note

Audited with the `bmad-review` verification-gap and adversarial lenses over three parallel auditors
plus an inline pass, with each auditor's load-bearing claims independently re-verified against the
sources before inclusion. Two verdicts in this report (2.3-AC6 and 2.4-AC3) were downgraded from an
initial SATISFIED after a second reader showed the covering test did not actually observe the
behavior — recorded here because it is the same failure mode the report documents in the code.
No builds were run; the suite's green state is taken from the caller.
