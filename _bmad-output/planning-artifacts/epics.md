---
stepsCompleted: [1, 2, 3, 4]
inputDocuments:
  - _bmad-output/planning-artifacts/PRD.md
  - _bmad-output/planning-artifacts/architecture.md
---

# local-whisper - Epic Breakdown

## Overview

This document decomposes the PRD requirements and Architecture decisions into implementable stories. Every story is sized for a single dev-agent session, carries testable acceptance criteria, and lists explicit verification steps.

Stories are ordered by dependency. Within an epic, a story never depends on a later story in the same epic. Across epics, Epic 2 (the pipeline) is the substrate for Epics 5 and 6; Epic 3 (history) is a precondition for Story 5.6.

**Universal verification baseline.** Every story must satisfy these before it moves to review, in addition to its own listed steps:

- `make build` succeeds with no new warnings.
- `make test` — full `swift test` suite green, no skipped or disabled tests.
- New logic has unit tests in `Tests/VocaMacTests/`; new services have a `Mock<Name>` in `Mocks/MockServices.swift` threaded through `TestMocks` and `AppState.makeTestState` (AD-7).
- The AD-13 identity test stays green: with all new features disabled, the pipeline is a byte-for-byte no-op.
- Manual smoke: launch the app, dictate one Hebrew sentence with the new feature **off**, confirm behavior is unchanged from before the story.

## Requirements Inventory

### Functional Requirements

| FR | Capability |
| --- | --- |
| FR-1 | Register a side-loaded local model |
| FR-2 | Present an absent side-loaded model as unavailable |
| FR-3 | Record per-stage latency |
| FR-4 | Clean the transcript via the local LLM |
| FR-5 | Fall back transparently on any failure |
| FR-6 | Configure post-processing |
| FR-7 | Verify the LLM connection on demand |
| FR-8 | Persist every dictation |
| FR-9 | Re-paste a previous transcription |
| FR-10 | Undo the last injection |
| FR-11 | Browse, search, and clear history |
| FR-12 | Resolve a Profile from the frontmost application |
| FR-13 | Create and manage Profiles |
| FR-14 | Supply Cursor Context to the LLM |
| FR-15 | Replace transcript terms from the Dictionary |
| FR-16 | Normalize Hebrew for matching |
| FR-17 | Manage Dictionary Entries |
| FR-18 | Learn from user corrections |
| FR-19 | Expand a spoken Cue into a text block |
| FR-20 | Manage Snippets |
| FR-21 | Rewrite the selection by voice |
| FR-22 | Fail safely when preconditions are unmet |
| FR-23 | Detect speech instead of amplitude |
| FR-24 | Parallelize long-recording transcription |
| FR-25 | Show partial results while speaking |

### NonFunctional Requirements

| NFR | Requirement |
| --- | --- |
| NFR-1 | Offline-first — only loopback network traffic |
| NFR-2 | Graceful degradation — every stage independently disableable, identity on failure |
| NFR-3 | Resource ceiling — app + ASR model + Q4 4B LLM coexist on 24 GB |
| NFR-4 | Concurrency safety — no races, no main-thread stalls |
| NFR-5 | Backwards compatibility — existing settings, Vocabulary, stats survive upgrade |
| NFR-6 | Testability — post-ASR transformations pure and unit-testable |
| NFR-7 | Licensing — AGPL-3.0 retained, no VoiceInk code copied |

### Additional Requirements

Architecture decisions AD-1 through AD-13 bind implementation. The load-bearing ones for story work: **AD-1** (one call in `AppState`), **AD-2** (identity fallback), **AD-3** (stage order), **AD-4** (Command Mode does not fall back), **AD-5** (context never persisted), **AD-7** (protocol + mock), **AD-8** (no actors), **AD-11** (model support bypass), **AD-13** (identity is a test).

### FR Coverage Map

| Epic | FRs | NFRs |
| --- | --- | --- |
| Epic 1 — Hebrew ASR Accuracy | FR-1, FR-2, FR-3 | NFR-3, NFR-5 |
| Epic 2 — LLM Post-Processing | FR-4, FR-5, FR-6, FR-7 | NFR-1, NFR-2, NFR-4, NFR-6 |
| Epic 3 — Transcription History | FR-3, FR-8, FR-9, FR-10, FR-11 | NFR-2, NFR-4 |
| Epic 4 — Profiles and Cursor Context | FR-12, FR-13, FR-14 | NFR-1, NFR-2 |
| Epic 5 — Dictionary and Snippets | FR-15, FR-16, FR-17, FR-18, FR-19, FR-20 | NFR-2, NFR-6 |
| Epic 6 — Command Mode | FR-21, FR-22 | NFR-2, NFR-4 |
| Epic 7 — Responsive Capture | FR-23, FR-24, FR-25 | NFR-3, NFR-4 |

## Epic List

| # | Epic | Phase | Stories | Depends on |
| --- | --- | --- | --- | --- |
| 1 | Hebrew ASR Accuracy | 1 | 3 | — |
| 2 | LLM Post-Processing | 1 | 4 | — |
| 3 | Transcription History | 1 | 4 | Epic 2 (Story 2.1 for latency fields) |
| 4 | Profiles and Cursor Context | 2 | 4 | Epic 2 |
| 5 | Dictionary and Snippets | 2 | 6 | Epic 2 (5.6 also needs Epic 3) |
| 6 | Command Mode | 3 | 3 | Epic 2 |
| 7 | Responsive Capture | 3 | 3 | — |

**Recommended execution order:** 1.1 → 1.2 → 2.1 → 2.2 → 2.3 → 2.4 → 3.1 → 1.3 → 3.2 → 3.3 → 3.4 → 4.1 → 4.2 → 4.3 → 4.4 → 5.1 → 5.2 → 5.3 → 5.4 → 5.5 → 5.6 → 6.1 → 6.2 → 6.3 → 7.1 → 7.2 → 7.3

Story 1.3 (latency persistence) is deliberately sequenced after 3.1, because latency belongs on the History Record. Epic 7 is independent of everything else and can be pulled forward if VAD frustration outweighs feature appetite.

---

## Epic 1: Hebrew ASR Accuracy

Make the ivrit.ai Hebrew fine-tune selectable and loadable, so the ASR stage produces materially better Hebrew than the current `large-v3-v20240930_626MB`. This is the one axis where the product can beat Wispr Flow outright rather than catch up to it. Covers FR-1, FR-2, FR-3.

### Story 1.1: Register the side-loaded ivrit.ai Hebrew model

As a Hebrew dictation user,
I want to select the ivrit.ai Hebrew model from the model picker,
So that my transcripts are more accurate than a general-purpose Whisper model can manage.

**Acceptance Criteria:**

**Given** the ivrit.ai CoreML model directory is present under `~/Library/Application Support/VocaMac/models/models/argmaxinc/whisperkit-coreml/`,
**When** I open Settings → Models,
**Then** the ivrit.ai entry appears in the list with a display name, size, and RAM estimate,
**And** selecting it loads the model successfully through the existing `WhisperService.loadModel` path,
**And** dictating Hebrew afterwards produces a transcript.

**Given** the new `ModelSize` case is added,
**When** the project is compiled,
**Then** arms exist in all five exhaustive switches in `Models/WhisperModel.swift` — `displayName` (`:49`), `fileSizeBytes` (`:67`), `ramRequiredGB` (`:92`), `relativeSpeed` (`:110`), `qualityDescription` (`:128`),
**And** `ModelManager.whisperKitModelName(for:)` (`:233`) maps it to its on-disk folder name,
**And** the two **non-exhaustive string ladders** the compiler will not catch are updated: `WhisperService.modelSizeFromName(_:)` (`:310`) and the ladder in `AppState.loadModel` (`:749-772`).

**Given** `ModelManager.isModelSupported(_:)` (`:285`) gates on `WhisperKit.recommendedModels()`, which never endorses a custom local model,
**When** support is evaluated for the ivrit.ai entry,
**Then** support is determined by **on-disk presence** rather than WhisperKit's endorsement (AD-11),
**And** the entry is present in `ModelSize.standardCatalog` (`:32`) so `AppState.modelCatalog()` (`:419`) surfaces it.

**Given** the model is side-loaded and not downloadable,
**When** the entry is shown or selected,
**Then** no download is attempted for it,
**And** existing models' download behavior and the chip/RAM recommendation logic are unchanged.

**Verification:**
- Unit: `ModelSizeTests` covers the new case across all five metadata properties; `ModelManagerTests` covers `whisperKitModelName` and the on-disk support bypass with a temp directory.
- Unit: a regression test asserts `modelSizeFromName` round-trips the new folder name.
- Manual: with the real model directory present, select it, dictate a Hebrew sentence, confirm text appears. If the parallel model-acquisition effort has not delivered yet, verify against a directory stub containing the required CoreML component layout (`MelSpectrogram.mlmodelc`, `AudioEncoder.mlmodelc`, `TextDecoder.mlmodelc`, tokenizer files) and record that the end-to-end load check is pending real weights.
- Manual: confirm existing models still download and load.

### Story 1.2: Handle an absent side-loaded model, and restore Hebrew to the language picker

As a user whose model files are not yet in place,
I want the app to tell me clearly what is missing and where to put it,
So that I am not staring at a broken picker entry with no explanation.

**Acceptance Criteria:**

**Given** the ivrit.ai model directory is missing or incomplete,
**When** I open Settings → Models,
**Then** the entry is marked "Not installed" and cannot be selected,
**And** the expected on-disk path is displayed so I can place the files,
**And** no download is offered or attempted,
**And** no crash or unhandled error occurs.

**Given** the ivrit.ai model is the selected model and its files are subsequently removed,
**When** the app next starts,
**Then** `AppState.startupFallbackModel(for:)` (`:460`) selects a known-good model instead,
**And** exactly one clear message explains the fallback.

**Given** `selectedLanguage` defaults to `"he"` (`AppState.swift:105`) but the Settings language `Picker` (`SettingsView.swift:110-135`) has **no Hebrew option** — a pre-existing defect that makes Hebrew unrecoverable once the picker is touched,
**When** I open the language picker,
**Then** Hebrew is present and selectable,
**And** selecting it stores `"he"`,
**And** the previously-stored value is preserved on upgrade (NFR-5).
*(The "selecting it stores `"he"`" clause has no automated test — it is verified manually only, per the picker's manual verification step below.)*

**Verification:**
- Unit: model-support evaluation against a temp directory in three states — complete, partially complete, absent.
- Unit: startup fallback selects a valid model when the configured one is unavailable.
- Manual: rename the model directory, relaunch, confirm the "Not installed" state, the displayed path, and the fallback message.
- Manual: open the language picker, select Hebrew, relaunch, confirm it persisted.

### Story 1.3: Record per-stage latency on the History Record

As someone deciding between a large model and a smaller model plus an LLM,
I want to see how long each stage actually took,
So that I choose based on measurement rather than impression.

**Depends on:** Story 2.1 (`TranscriptContext` timing fields), Story 3.1 (`HistoryStore`).

**Acceptance Criteria:**

**Given** a dictation completes,
**When** the History Record is written,
**Then** it carries recording duration, ASR duration, and post-processing duration in milliseconds,
**And** the values are non-zero and plausible for stages that ran,
**And** stages that did not run record zero rather than a missing field.

**Given** I have dictated with two different ASR models,
**When** I open the history view,
**Then** each record shows its model and its ASR duration,
**And** the two models' typical latencies are directly comparable.

**Given** timing instrumentation is added,
**When** dictation runs,
**Then** measurement adds no perceptible latency and introduces no main-thread stalls (NFR-4).

**Verification:**
- Unit: timing fields populate correctly, including the zero case for skipped stages.
- Manual: dictate five sentences on each of two models; confirm ASR durations are recorded and differ as expected.
- Manual: confirm the memory ceiling question (NFR-3, R-7) can now be investigated — record peak memory with the ivrit.ai model loaded alongside LM Studio running Qwen3-4B Q4.

---

## Epic 2: LLM Post-Processing

Introduce the pipeline substrate and the LLM stage that turns a Raw Transcript into send-ready text. This is the largest single product gap versus Wispr Flow, and the epic is structured so the risky part (the LLM) lands on top of a proven-inert foundation. Covers FR-4, FR-5, FR-6, FR-7.

### Story 2.1: Transcript pipeline scaffolding with a proven identity guarantee

As a developer,
I want an ordered, testable pipeline between transcription and injection that provably does nothing yet,
So that every later feature plugs in without touching `AppState` and without risking the existing dictation path.

**Acceptance Criteria:**

**Given** the pipeline types are added under `Sources/VocaMac/Pipeline/`,
**When** `AppState.stopRecordingAndTranscribe()` runs,
**Then** exactly **one** new call exists — `await transcriptPipeline.run(context)` — inserted between `let trimmedText = ...` (`AppState.swift:633`) and the `if !trimmedText.isEmpty` injection guard (`:634`) (AD-1),
**And** no other logic is added to `AppState`.

**Given** the pipeline contains no stages,
**When** it runs on any input,
**Then** it returns that input unchanged, byte for byte (AD-2).

**Given** the `TranscriptStage` protocol is defined,
**When** a stage is implemented,
**Then** it cannot throw out of `run`; failures are captured as a `StageOutcome` recorded on the context and the input is passed through,
**And** `TranscriptContext` is a `struct` carrying at minimum: raw transcript, current text, target bundle id, per-stage timings, protected-span map, and stage outcomes.

**Given** the identity property is load-bearing (AD-13),
**When** the test suite runs,
**Then** a test asserts byte-identical pass-through for a corpus including Hebrew with niqqud, mixed Hebrew/English, empty string, and whitespace-only input.

**Given** `TranscriptPipeline` is `@MainActor` and `async` (AD-8),
**When** it runs,
**Then** no `actor` is introduced anywhere and no strict-concurrency flags are enabled.

**Verification:**
- Unit: the identity corpus test; a stage-failure test using a deliberately-throwing test stage confirming pass-through and a recorded outcome.
- Unit: `MockTranscriptPipeline` added to `MockServices.swift` and threaded through `TestMocks`/`makeTestState` (AD-7).
- Manual: dictate before and after the change; output must be identical.

### Story 2.2: PostProcessService — LLM client with a hard deadline and transparent fallback

As a user,
I want the local LLM contacted safely,
So that a slow or absent LM Studio never degrades my dictation.

**Acceptance Criteria:**

**Given** `PostProcessService` is the sole owner of the HTTP client (AD-6),
**When** `clean(text:prompt:)` is called,
**Then** a single OpenAI-compatible chat-completions request is issued to the configured endpoint,
**And** the response content is returned as the cleaned text.

**Given** LM Studio is not running,
**When** `clean` is called,
**Then** the connection error is caught and the input text is returned unchanged,
**And** the failure reason is logged and reported as a `StageOutcome`.

**Given** the LLM is slower than the configured timeout,
**When** the deadline elapses,
**Then** the request is cancelled via both `URLSession` configuration and an outer `Task` deadline,
**And** the input text is returned,
**And** total elapsed time does not exceed the timeout by a meaningful margin.

**Given** the LLM returns a non-2xx status, malformed JSON, empty content, or output wildly disproportionate in length to the input,
**When** the response is validated,
**Then** the input text is returned unchanged,
**And** the specific rejection reason is recorded.

**Given** prompt construction and response validation must be testable without a network (NFR-6),
**When** those functions are implemented,
**Then** they are pure and separately unit-tested,
**And** default prompts live as `static let` constants in `Models/Prompts.swift`.

**Given** the offline guarantee (NFR-1),
**When** any request is issued,
**Then** it targets only the configured loopback endpoint, and the app remains fully functional with no internet route.

**Verification:**
- Unit: prompt construction; response validation across every rejection case; the length-ratio guard at its boundaries.
- Unit: timeout behavior with a stubbed slow transport; connection-refused behavior.
- Manual: with LM Studio stopped, call "Test connection" and confirm an actionable failure. With it running, confirm success.
- Manual: disable all network interfaces; confirm the app still dictates normally.

### Story 2.3: Wire post-processing into the pipeline behind a master toggle

As a user,
I want my Hebrew transcripts cleaned, punctuated, and self-corrections resolved,
So that what lands at my cursor is ready to send.

**Acceptance Criteria:**

**Given** post-processing is enabled,
**When** I dictate a Hebrew sentence containing filler words,
**Then** the injected text has fillers removed and sentence-final punctuation present.

**Given** I dictate a spoken enumeration,
**When** post-processing runs,
**Then** the result is formatted as a list.

**Given** I dictate "נפגש בשתיים… בעצם בשלוש",
**When** post-processing runs,
**Then** the injected text contains only the corrected time.

**Given** I dictate a question,
**When** post-processing runs,
**Then** the output is the cleaned question, **not** an answer to it.

**Given** the master toggle is off,
**When** I dictate,
**Then** **no HTTP request is made at all**,
**And** behavior is byte-identical to before this epic (AD-2, AD-13).

**Given** any post-processing failure occurs,
**When** injection happens,
**Then** the Raw Transcript is injected with no modal and no dialog,
**And** the Raw Transcript is retained alongside the Final Text for the History Record.

**Verification:**
- Unit: `PostProcessStage` with a mock service covering success, each failure mode, and the disabled path.
- Manual: dictate five real Hebrew sentences with fillers and a self-correction; confirm the cleanup and that meaning is unchanged (SM-C1 — if you find yourself checking the LLM's work, the prompt is too aggressive; note this and tune).
- Manual: stop LM Studio mid-session, dictate, confirm raw text appears with no interruption and only the timeout's delay.

### Story 2.4: Post-processing settings tab

As a user,
I want to configure and verify the LLM connection,
So that I can point at my own setup and confirm it works without guessing.

**Acceptance Criteria:**

**Given** a new settings tab is added to the `TabView` in `Views/SettingsView.swift`,
**When** I open Settings,
**Then** a post-processing tab is present alongside the existing six,
**And** it is defined in its own file following the `StatsSettingsTab.swift` precedent.

**Given** the tab is open,
**When** I edit settings,
**Then** endpoint base URL, model identifier, timeout, and temperature are editable and persisted under `vocamac.postProcess.*` keys (AD-9),
**And** defaults are `http://localhost:1234`, Qwen3-4B-Instruct, a low single-digit-second timeout, and temperature 0.

**Given** the system prompt is editable,
**When** I modify it and then choose "Restore default",
**Then** the documented default from `Models/Prompts.swift` is restored.

**Given** I press "Test connection",
**When** LM Studio is reachable,
**Then** success is reported along with the responding model's identifier,
**And** when it is unreachable, the failure reason is actionable — refused, timed out, or the HTTP status,
**And** in neither case does the UI block or become stuck.

**Verification:**
- Unit: settings persistence round-trip; restore-to-default.
- Manual: change the endpoint to a wrong port, test connection, confirm an actionable error and a responsive UI; change it back, confirm success.
- Manual: relaunch and confirm all settings persisted.

---

## Epic 3: Transcription History

Persist what the app produced, so nothing is lost, injections can be re-pasted or retracted, and later features have the substrate they need. The cheapest epic in the plan and a precondition for Story 5.6. Covers FR-3, FR-8, FR-9, FR-10, FR-11.

### Story 3.1: Persist every dictation via a shared JSON file store

As a user,
I want every transcript saved locally,
So that nothing the app produced is ever lost.

**Acceptance Criteria:**

**Given** `JSONFileStore<T: Codable>` is added under `Sources/VocaMac/Stores/` (AD-10),
**When** it saves,
**Then** it writes atomically to `~/Library/Application Support/VocaMac/`, on a serial `.utility` queue, without blocking the caller — modeled on `StatsManager.swift:24-38`.

**Given** the store's file is corrupt or unreadable,
**When** it loads,
**Then** the type's empty value is returned and the failure is logged,
**And** the app does not crash and startup is not blocked.

**Given** a dictation completes,
**When** the History Record is written,
**Then** it captures raw transcript, final text, timestamp, target bundle id, profile name, model, per-stage latencies, whether a fallback occurred, and the mode,
**And** each record carries a `UUID id`,
**And** records survive app restart.

**Given** Cursor Context must never be persisted (AD-5),
**When** the `HistoryRecord` type is defined,
**Then** **no field exists** capable of holding cursor context,
**And** a test asserts that a serialized record contains no context payload.

**Given** history is local-only,
**When** records are stored,
**Then** they are never transmitted and are excluded from any diagnostic export.

**Verification:**
- Unit: `JSONFileStore` round-trip, atomic write, corrupt-file recovery, concurrent-save safety.
- Unit: `HistoryRecord` encode/decode; the no-context-field assertion.
- Manual: dictate three times, quit, relaunch, confirm all three records are present with correct metadata.

### Story 3.2: Browse, search, and clear history

As a user,
I want to review what I dictated and see what the LLM changed,
So that I can recover text and build trust in the post-processing.

**Acceptance Criteria:**

**Given** I open the history view,
**When** it loads,
**Then** records are listed newest-first with timestamp, target app, and a text preview.

**Given** I select a record,
**When** its detail is shown,
**Then** both the Raw Transcript and the Final Text are visible, making the LLM's edit inspectable.

**Given** I type in the search field,
**When** the query changes,
**Then** the list filters to matching records.

**Given** I want to manage storage,
**When** I use the management controls,
**Then** I can delete an individual record, delete all, and set a retention limit,
**And** the retention limit is enforced automatically as new records arrive.

**Verification:**
- Unit: search filtering including Hebrew queries; retention enforcement at the boundary.
- Manual: dictate ten times, browse the list, search for a term, delete one record, verify the count.
- Manual: set retention to 5, dictate three more, confirm the oldest are pruned.

**Known gap — "target app" read "Unknown app" until Epic 4 (closed by Story 4.1):**
The first acceptance criterion asks for the target app in each row, but at the
time this story shipped nothing populated `HistoryRecord.targetBundleId` yet:
the frontmost application was not captured until Story 4.1. Every row and
detail pane showed "Unknown app" for records written before that story landed.
This was a sequencing artifact, not a defect — the field, the schema, and the
UI that reads it were all in place from the start and began showing real
values as soon as 4.1 started populating them. Story 4.1 now captures the
frontmost application's bundle identifier at recording start (via
`AXContextReader`) and threads it through to `HistoryRecord.targetBundleId`.
Records written before Story 4.1 keep `nil` permanently; they were not
backfilled.

### Story 3.3: Re-paste a previous transcription

As a user whose injection landed in the wrong window,
I want to re-paste it where I actually meant it to go,
So that I do not have to dictate the whole thing again.

**Acceptance Criteria:**

**Given** at least one dictation exists,
**When** I choose the menu-bar re-paste action,
**Then** the most recent Final Text is injected at the current cursor via the same `TextInjector` path as a live dictation.

**Given** I am in the history view,
**When** I choose re-paste on any listed record,
**Then** that record's Final Text is injected.

**Given** a re-paste occurs,
**When** it completes,
**Then** **no duplicate History Record is created**.

**Given** the clipboard-preservation setting is on,
**When** re-paste uses the clipboard strategy,
**Then** the prior clipboard contents are restored exactly as in a normal injection.

**Verification:**
- Unit: re-paste calls the injector with the expected text and creates no new record.
- Manual: dictate into TextEdit, switch to another app, re-paste from the menu bar, confirm the text lands and the clipboard is restored.

### Story 3.4: Undo the last injection

As a user whose text landed somewhere it should not have,
I want to retract it immediately,
So that a misfire is not something I have to clean up by hand.

**Acceptance Criteria:**

**Given** text was just injected,
**When** I choose undo,
**Then** the injected text is removed from the target application.

**Given** undo is best-effort (FR-10, R-9),
**When** the safety conditions are evaluated,
**Then** undo is offered only within a short window with the same application still frontmost,
**And** when it cannot be performed safely the action is **unavailable rather than destructive**,
**And** the UI states the best-effort limitation.

**Given** the injection used the Accessibility path,
**When** undo runs,
**Then** the text is retracted precisely.

**Given** the injection used the clipboard path,
**When** undo runs,
**Then** ⌘Z is synthesized, and inconsistent behavior across applications is an accepted, documented limitation.

**Verification:**
- Unit: the safety-window and frontmost-app guards; the unavailable state.
- Manual: dictate into TextEdit (AX path) and undo — text removed. Dictate into a terminal (clipboard path) and undo — note actual behavior.
- Manual: dictate, switch apps, confirm undo is unavailable rather than firing into the wrong window.

---

## Epic 4: Profiles and Cursor Context

Make the same utterance produce app-appropriate text — casual in chat, formal in mail, identifier-shaped in an editor — using only local signals. Covers FR-12, FR-13, FR-14.

### Story 4.1: Capture the frontmost application at recording start

As a user who switches windows while thinking,
I want the app to remember where I started dictating,
So that my text is shaped for the app I was actually aiming at.

**Acceptance Criteria:**

**Given** `AXContextReader` is added as a `@MainActor` service with a protocol in `ServiceProtocols.swift` (AD-7),
**When** recording starts,
**Then** the frontmost application's bundle identifier is captured at that moment via `NSWorkspace` — **not** when recording stops (AD-5).

**Given** I switch to a different application mid-dictation,
**When** the transcript is processed,
**Then** the originally-captured bundle identifier is used.

**Given** no frontmost application can be determined,
**When** capture runs,
**Then** a nil identifier is recorded and the pipeline proceeds normally.

**Given** the captured identifier flows through the pipeline,
**When** the History Record is written,
**Then** the bundle identifier is persisted (Story 3.1's field is populated for real).

**Verification:**
- Unit: capture-at-start semantics with a mock reader; the nil path.
- Manual: start dictating in TextEdit, switch to Safari mid-utterance, release; confirm the history record names TextEdit.

**Accepted deviation — protocol placement (Stories 4.1, 4.2):**
The first acceptance criterion asks for `AXContextReader`'s protocol in
`ServiceProtocols.swift` (AD-7). `ContextReading` is instead declared in
`AXContextReader.swift`, alongside the vocabulary it is written in terms of
(`CapturedContext`); `ProfileResolving` is declared the same way in
`ProfileManager.swift`. Both are registered in `ServiceProtocols.swift` with a
pointer comment, and both are mocked and threaded through `TestMocks` /
`AppState.makeTestState` exactly as AD-7 requires. This follows the precedent
set by `PostProcessing` in Epic 2, which was placed in
`PostProcessService.swift` for the same reason and reviewed as acceptable
there: splitting a protocol from the types in its own signatures makes both
files harder to read, and AD-7's substance — every service is behind a
protocol, and every protocol has a mock — is fully met. Deliberate, consistent
across the three services that have done it, and not to be "fixed" by a later
pass without also moving `PostProcessing`.

### Story 4.2: Resolve a Profile from the bundle identifier

As a user,
I want each application mapped to a dictation Profile,
So that the LLM is told what kind of text this app expects.

**Acceptance Criteria:**

**Given** `Profile`, `ProfileStore`, and `ProfileManager` exist,
**When** a dictation starts,
**Then** the captured bundle identifier resolves to a matching Profile,
**And** when no Profile matches, the Default Profile is used.

**Given** a Profile is resolved,
**When** post-processing runs,
**Then** the Profile's prompt override steers the LLM,
**And** the Profile's per-feature toggles for post-processing and context capture are honored.

**Given** Profiles are disabled entirely,
**When** a dictation runs,
**Then** the Default Profile always applies and behavior matches Epic 2's.

**Given** a Profile is resolved,
**When** the History Record is written,
**Then** the Profile name is persisted.

**Given** the Default Profile is special,
**When** profile management operations run,
**Then** it can be edited but **not deleted**.

**Verification:**
- Unit: resolution for a matching id, a non-matching id, an empty profile set, and the disabled state; default-profile deletion is rejected.
- Manual: create a Profile bound to TextEdit with a distinctive prompt; dictate into TextEdit and into another app; confirm the outputs differ as the prompts dictate.

### Story 4.3: Profiles settings tab with starter profiles and JSON export

As a user,
I want to create and manage Profiles without editing files,
So that tuning per-app behavior is a normal settings task.

**Acceptance Criteria:**

**Given** a Profiles settings tab is added,
**When** I use it,
**Then** I can create, edit, reorder, and delete Profiles,
**And** each Profile exposes name, bundle identifiers, prompt override, and its two toggles.

**Given** typing bundle identifiers by hand is error-prone,
**When** I add one,
**Then** I can pick from currently-running applications instead.

**Given** a fresh install,
**When** Profiles load for the first time,
**Then** starter Profiles ship for a chat app, a mail app, and a code editor, illustrating casual, formal, and identifier-shaped output.

**Given** I want my configuration on another machine (AD-9, FR-13),
**When** I export,
**Then** Profiles are written as a single JSON file,
**And** importing that file restores them,
**And** an import of a malformed file is rejected with a clear message rather than corrupting existing Profiles.

**Verification:**
- Unit: CRUD operations; export/import round-trip; malformed-import rejection.
- Manual: create a Profile via the running-apps picker, restart, confirm persistence; export, delete all, import, confirm restoration.

### Story 4.4: Supply Cursor Context to the LLM, off by default

As a user dictating into an existing document,
I want the LLM to see what surrounds my cursor,
So that the inserted text matches the register and formatting already there.

**Acceptance Criteria:**

**Given** context capture is enabled both globally and on the active Profile,
**When** recording starts,
**Then** text before and after the insertion point is read via the Accessibility API and truncated to a bounded character budget,
**And** it is included in the post-processing request.

**Given** context capture is off — **which is the default** — ,
**When** a dictation runs,
**Then** no context is read and none is sent.

**Given** the target application exposes no readable context,
**When** capture is attempted,
**Then** post-processing proceeds without it rather than failing.

**Given** Cursor Context is the highest-privacy-cost capability here (AD-5, R-8),
**When** a dictation completes,
**Then** the context is **never** written to the History Record, **never** passed to `VocaLogger` at any level, and never persisted anywhere,
**And** it is released from memory immediately after the request,
**And** a test asserts that no log output and no persisted record contains the context payload.

**Given** context is read on the main thread,
**When** capture runs,
**Then** it adds negligible latency and never blocks injection (NFR-4).

**Verification:**
- Unit: budget truncation; the both-toggles-required gate; the no-readable-context path.
- Unit: the privacy assertion — capture context, run a full pipeline, inspect logs and the persisted record for leakage.
- Manual: enable context, dictate into the middle of an existing Hebrew paragraph, confirm the insertion matches surrounding register.
- Manual: confirm the feature is off on a fresh profile.

---

## Epic 5: Dictionary and Snippets

Fix recurring mis-transcriptions permanently, and expand spoken cues into fixed text blocks. Both operate on the transcript; both depend on correct Hebrew normalization, which is why that lands first as its own story. Covers FR-15 through FR-20.

### Story 5.1: Hebrew normalization

As a developer,
I want a correct, pure Hebrew normalizer,
So that every fuzzy match in this epic compares like with like.

**Acceptance Criteria:**

**Given** `HebrewNormalizer` is added as an `enum` with `static` pure functions in `Models/` (AD-8, a dependency-free leaf),
**When** it normalizes text,
**Then** niqqud and cantillation marks are stripped,
**And** matres lectionis variants (ו/וו, י/יי) are unified,
**And** final-form letters are normalized to their base forms,
**And** geresh and gershayim are handled.

**Given** transcripts mix Hebrew and English technical terms,
**When** normalization runs,
**Then** Latin text passes through unchanged.

**Given** normalization is the foundation for every match in this epic (NFR-6),
**When** it is tested,
**Then** it is unit-tested against a table of Hebrew variant pairs asserting that variants of the same word normalize identically,
**And** the functions are side-effect free and require no audio, no LLM, and no AX.

**Verification:**
- Unit: a variant-pair table covering each transformation independently and in combination; idempotence (normalizing twice equals normalizing once); the Latin pass-through; empty and whitespace input.
- No manual step — this story is pure logic and stands entirely on its tests.

### Story 5.2: Post-ASR dictionary replacement

As a user with domain terms Whisper keeps getting wrong,
I want them corrected automatically after transcription,
So that I stop fixing the same word by hand.

**Depends on:** Story 5.1, Story 2.1.

**Acceptance Criteria:**

**Given** `DictionaryService` and `DictionaryStage` exist,
**When** the pipeline runs,
**Then** the Dictionary stage runs **first**, before snippet protection and before post-processing (AD-3), so the LLM reasons over corrected terms.

**Given** a transcript contains an exact trigger,
**When** replacement runs,
**Then** it is replaced with the canonical form.

**Given** a transcript contains a near-match,
**When** it is compared using edit distance over `HebrewNormalizer`-normalized forms,
**Then** it is replaced if within the configured threshold,
**And** **not** replaced if below it — a conservative miss is preferred to a wrong replacement (SM-C2).

**Given** replacement must not corrupt surrounding text,
**When** it runs,
**Then** surrounding whitespace and punctuation are preserved,
**And** a trigger does not match inside a longer unrelated word.

**Given** entries may overlap,
**When** multiple could apply,
**Then** replacement is deterministic and ordered so results are reproducible.

**Given** the Dictionary is empty or the feature is disabled,
**When** the stage runs,
**Then** it returns its input unchanged (AD-2).

**Verification:**
- Unit: exact match; near-match at, above, and below threshold; the no-substring-match guard; whitespace/punctuation preservation; overlapping-entry determinism; empty-dictionary identity.
- Manual: add a term you know is mis-transcribed, dictate a sentence containing it, confirm correction.

### Story 5.3: Dictionary settings UI and persistence

As a user,
I want to curate my Dictionary in settings,
So that maintaining it is not a file-editing exercise.

**Acceptance Criteria:**

**Given** a vocabulary settings tab is added,
**When** I use it,
**Then** I can create, edit, and delete Dictionary Entries, each with a canonical form and one or more trigger variants.

**Given** entries are persisted via `JSONFileStore` (AD-10),
**When** I restart the app,
**Then** my entries are intact.

**Given** the existing Vocabulary (`promptTokens`, `"Glossary: "`) is a different mechanism operating before transcription,
**When** I manage Dictionary Entries,
**Then** the Dictionary is clearly distinct from it in the UI,
**And** the existing Vocabulary is **not modified** (NFR-5).

**Given** portability matters,
**When** I export,
**Then** the Dictionary is written as JSON alongside Profiles and Snippets, and imports round-trip.

**Verification:**
- Unit: CRUD; persistence round-trip; export/import.
- Manual: add three entries, restart, confirm persistence; confirm the existing Vocabulary field is untouched and still biases the decoder.

### Story 5.4: Snippet expansion with placeholder protection

As a user,
I want a spoken cue to expand into a fixed block of text,
So that signatures and boilerplate do not have to be dictated or typed.

**Depends on:** Story 5.1, Story 2.1.

**Acceptance Criteria:**

**Given** `SnippetService`, `SnippetStage`, and `RehydrateStage` exist,
**When** the pipeline runs,
**Then** `SnippetStage` runs **after** the Dictionary stage and **before** post-processing, replacing each matched Cue with an opaque placeholder (`⟦S0⟧`, `⟦S1⟧`, …) and recording the mapping on the context (AD-3),
**And** `RehydrateStage` runs **after** post-processing, substituting the real bodies.

**Given** the LLM must not rewrite snippet bodies,
**When** post-processing runs,
**Then** it sees only placeholders, never the body text.

**Given** the LLM drops or alters a placeholder,
**When** rehydration validates,
**Then** the entire post-processing result is rejected and the pre-LLM text is used,
**And** the snippet body is still correctly substituted.

**Given** a Cue is matched,
**When** substitution occurs,
**Then** matching is case-insensitive and uses `HebrewNormalizer`, so a Cue matches despite niqqud or spelling variance,
**And** multi-line bodies are preserved verbatim,
**And** multiple distinct Cues in one transcript all expand.

**Given** post-processing is disabled,
**When** I speak a Cue,
**Then** the Snippet still expands — Snippets do not require the LLM.

**Verification:**
- Unit: single cue; multiple cues; multi-line body preservation; normalization-tolerant matching; the dropped-placeholder rejection path; expansion with post-processing off.
- Manual: define a signature snippet, dictate its cue with post-processing on, confirm the body is verbatim and unmangled.

### Story 5.5: Snippets settings UI

As a user,
I want to manage cue-to-text mappings in settings,
So that I can add and adjust boilerplate easily.

**Acceptance Criteria:**

**Given** the vocabulary settings tab hosts Snippets,
**When** I use it,
**Then** I can create, edit, and delete Snippets with a multi-line body editor.

**Given** Snippets persist via `JSONFileStore` (AD-10),
**When** I restart,
**Then** my Snippets are intact,
**And** they export as JSON alongside Profiles and the Dictionary.

**Given** cues must be unambiguous,
**When** I enter a Cue that collides with an existing one,
**Then** it is rejected with a clear message.

**Verification:**
- Unit: CRUD; collision rejection; export/import round-trip.
- Manual: create a multi-line snippet, restart, confirm the body survived line breaks exactly.

### Story 5.6: Propose Dictionary Entries from user corrections

As a user,
I want the app to notice when I fix a word by hand,
So that my Dictionary builds itself instead of needing curation.

**Depends on:** Story 5.3, Story 3.1.

**Acceptance Criteria:**

**Given** correction learning is enabled — **it is off by default**,
**When** text has been injected,
**Then** the text field's content is re-read after a short delay and diffed against what was injected.

**Given** a small, localized, word-level difference is found,
**When** it is evaluated,
**Then** it is treated as a candidate correction,
**And** the candidate is **proposed for confirmation, never added silently**.

**Given** I dismiss a candidate,
**When** the same pair occurs again,
**Then** it is not proposed again.

**Given** unrelated typing must not generate noise (R-6),
**When** the diff runs,
**Then** it is bounded to word-level, single-token edits,
**And** large or diffuse differences produce no candidate.

**Given** the feature proves noisy in practice,
**When** it is evaluated,
**Then** it remains off by default and shipping it loud is not an option (PRD §9.3).

**Verification:**
- Unit: candidate detection for a single-word edit; rejection of large/diffuse diffs; dismissal persistence; the disabled path producing nothing.
- Manual: dictate a sentence, immediately retype one word correctly, confirm exactly one sensible candidate is proposed.
- Manual: dictate, then type a full new paragraph; confirm **no** candidates are proposed. If this produces noise, record it and leave the feature off.

---

## Epic 6: Command Mode

Act on selected text by voice instead of inserting new text. The one flow that deliberately inverts the fallback rule, because pasting a spoken instruction over a user's selection would be destructive. Covers FR-21, FR-22.

### Story 6.1: Add a second hotkey binding

As a user,
I want a separate hotkey for commanding,
So that dictating and rewriting are distinct gestures.

**Acceptance Criteria:**

**Given** `HotKeyManager` currently drives one binding through a 643-line dual state machine (R-5),
**When** a second binding is added,
**Then** it shares the **existing** `CGEventTap` — no second tap is created,
**And** it is exposed through dedicated callbacks rather than by generalizing the existing state machine.

**Given** the second binding is configured,
**When** I use it,
**Then** it honors the same push-to-talk and double-tap conventions as the existing hotkey,
**And** it is separately configurable in settings.

**Given** two bindings could collide,
**When** I try to assign the same key to both,
**Then** the UI rejects it with a clear message,
**And** the shipped default for Command Mode does not conflict with the Dictation Mode default.

**Given** the input path is the app's most load-bearing (R-5),
**When** this story lands,
**Then** existing `HotKeyManagerConfigurationTests` and `HotKeyManagerResetStateTests` still pass,
**And** new tests using the `_handleTestEvent` escape hatch (`HotKeyManager.swift:458`) cover both bindings, including interleaved and stuck-key cases.

**Verification:**
- Unit: both bindings fire their own callbacks; interleaved presses; stuck-key recovery on each; collision rejection.
- Manual: configure both hotkeys, exercise dictation repeatedly, confirm zero regression in the existing flow. This is the highest-regression-risk story in the plan — smoke it hard.

### Story 6.2: Read and replace the selection via Accessibility

As a developer,
I want reliable selection read and write,
So that Command Mode can operate on what the user actually highlighted.

**Acceptance Criteria:**

**Given** `TextInjector` gains selection support,
**When** `readSelection()` is called,
**Then** the current selection is read via `kAXSelectedTextAttribute`,
**And** nil is returned when there is no selection or no accessible focused element.

**Given** a rewrite must be written back,
**When** `replaceSelection(_:)` is called,
**Then** the selection is replaced in the target application,
**And** failure to write is reported to the caller rather than silently swallowed.

**Given** `TextInjector` is load-bearing and must not regress (Inherited Invariants),
**When** this story lands,
**Then** the existing `inject(text:preserveClipboard:)` path, its role gate, its pasteboard snapshot/restore, and its changeCount guard are **unchanged**,
**And** existing `TextInjectorTests` still pass.

**Verification:**
- Unit: selection read returns nil without a focused element; write-failure reporting; existing injection tests unaffected.
- Manual: select text in TextEdit, confirm read and replace work; repeat in a non-AX-writable target and confirm the failure is reported.

### Story 6.3: Rewrite the selection by voice

As a user,
I want to select text, speak an instruction, and have the text rewritten,
So that editing is as fast as dictating.

**Depends on:** Story 6.1, Story 6.2, Story 2.2.

**Acceptance Criteria:**

**Given** `CommandModeCoordinator` orchestrates the flow,
**When** I press the Command Mode hotkey and speak an instruction,
**Then** the selection is read, the utterance is transcribed, both are sent to `PostProcessService` in command mode, and the response replaces the selection.

**Given** the instruction is an instruction and not content,
**When** the flow completes,
**Then** the instruction text is **never** injected into the document.

**Given** Command Mode does not use the pipeline and does not fall back (AD-4),
**When** any precondition fails — no selection, LLM unreachable, timeout, or an unwritable target,
**Then** the operation **aborts and changes nothing**,
**And** the existing error sound plays,
**And** the selection is left exactly as it was.

**Given** a Command Mode operation completes,
**When** the History Record is written,
**Then** it is distinguishable from a Dictation Mode record by its mode field.

**Verification:**
- Unit: the happy path with mocks; each abort precondition asserting **no** write occurred; the mode field on the record.
- Manual: select a clumsy Hebrew paragraph, say "make this shorter and more formal", confirm in-place rewrite.
- Manual: with **no** selection, press the hotkey and speak — confirm the error sound and that nothing anywhere was modified.
- Manual: stop LM Studio, select text, run a command — confirm the selection is untouched.

---

## Epic 7: Responsive Capture

Stop cutting people off mid-sentence, transcribe long recordings faster, and show progress while speaking. Independent of Epics 2-6 and safely pullable forward. Covers FR-23, FR-24, FR-25.

### Story 7.1: Replace the RMS threshold with voice activity detection

As a user who pauses mid-sentence and sometimes speaks quietly,
I want the app to know the difference between silence and thinking,
So that it stops cutting me off.

**Acceptance Criteria:**

**Given** a `VoiceActivityDetecting` protocol is added with a WhisperKit `EnergyVAD`-backed implementation and an `RMSThresholdDetector` preserving today's behavior,
**When** `AudioEngine` evaluates the stop condition,
**Then** only the threshold comparison at `AudioEngine.swift:486-495` delegates to the detector.

**Given** the audio-level indicator must not regress (AD-12),
**When** this story lands,
**Then** `calculateRMSEnergy` (`:546`) and the ~15 Hz `onAudioLevel` path (`:457-461`) are **retained unchanged**,
**And** the cursor overlay animation is visually identical.

**Given** I speak quietly or whisper,
**When** VAD evaluates,
**Then** it is classified as speech and does not trigger auto-stop.

**Given** I pause naturally mid-sentence,
**When** VAD evaluates at the default setting,
**Then** auto-stop is not triggered.

**Given** VAD may regress on real speech (R-1 class risk),
**When** I open settings,
**Then** sensitivity and silence duration are configurable,
**And** `RMSThresholdDetector` remains selectable as a fallback.

**Given** the detector runs on the `AVAudioEngine` tap thread (AD-8 threading rules),
**When** it executes,
**Then** it holds no UI state, takes no contended locks, and is allocation-free in steady state.

**Verification:**
- Unit: detector classification over synthetic buffers — speech, silence, low-amplitude speech; the RMS detector reproduces today's threshold behavior exactly.
- Manual: dictate a 60-second Hebrew passage with deliberate pauses; confirm no premature stop. Repeat whispering.
- Manual: switch to the RMS detector and confirm the old behavior returns.
- Manual: watch the cursor overlay throughout; confirm the level animation is unchanged.

### Story 7.2: Parallelize long recordings with VAD chunking

As a user dictating long passages,
I want long recordings transcribed faster,
So that a two-minute dictation does not feel like a two-minute wait.

**Depends on:** Story 7.1.

**Acceptance Criteria:**

**Given** `DecodingOptions.chunkingStrategy` is currently `nil` (`WhisperService.swift:178`),
**When** it is set to `.vad`,
**Then** long recordings are chunked on speech boundaries and transcribed concurrently.

**Given** a recording substantially longer than Whisper's 30-second window,
**When** it is transcribed,
**Then** it completes measurably faster than with sequential chunking,
**And** accuracy is equal or better.

**Given** short recordings are the common case,
**When** they are transcribed,
**Then** there is **no regression** in latency or accuracy.

**Given** memory headroom is a live concern (NFR-3, R-7),
**When** parallel chunks are processed,
**Then** peak memory remains within a safe margin on 24 GB with the ivrit.ai model loaded.

**Verification:**
- Unit: `DecodingOptions` construction asserts the chunking strategy (note: `WhisperServiceTests` currently tests only pure static helpers — this may need the first test that inspects options construction).
- Manual: time a 90-second Hebrew dictation before and after; record both numbers using Story 1.3's instrumentation.
- Manual: time ten short dictations before and after; confirm no regression.
- Manual: monitor peak memory during a long parallel transcription.

**Known limitations (as delivered — documented, not fixed):**

- **Up to ~1 second can be dropped from the tail of a chunked recording.** `VADAudioChunker` pads its windows by `windowPadding` = 16000 samples (1 s at 16 kHz), so the last chunk can lose up to a second of trailing audio. In push-to-talk, a user who releases the key immediately after the last word can lose the final syllable. Chunking only engages for recordings longer than 30 s, so short dictations are unaffected. There is no code fix in this story.
- **With auto-detect, language detection runs per chunk.** When the transcription language is `nil`, WhisperKit detects the language separately for each chunk, so a long mixed-language dictation can switch script mid-transcript between chunks. Low impact in practice: `selectedLanguage` defaults to `"he"` (Hebrew), so the language is normally pinned and per-chunk detection never runs.

### Story 7.3: Streaming partial results — spike, then implement or cut

As a user,
I want to see transcription progress while I speak,
So that long dictations do not feel like dead air.

**Depends on:** Story 7.1.

**Outcome: CUT after the spike.** `AudioStreamTranscriber.startStreamTranscription()` calls `audioProcessor.startRecordingLive()`, which (WhisperKit `Core/Audio/AudioProcessor.swift:975-1019`, `setupEngine()`) constructs its own `AVAudioEngine`, acquires its own input node, installs its own tap, and calls `engine.start()` — entirely independent of, and in direct conflict with, `AudioEngine`'s own installed tap on the same physical input device (R-1; confirmed by reading WhisperKit 0.18.0 source, not by running the conflict live). There is no supported way to hand `AudioStreamTranscriber` an already-running engine and tap, so using it means either re-architecting `AudioEngine` to hand capture ownership to WhisperKit's `AudioProcessor` — an AD-8-violating rewrite of the Bluetooth, device-selection, and exception-catching logic Epics 1-6 depend on — or reimplementing `AudioStreamTranscriber`'s segment-confirmation, VAD-gating, and early-stop logic from scratch against `AudioEngine`'s own captured buffer. Both are the re-architecture the spike-phase criterion below says to cut on, so the feature was cut per that explicit branch and no streaming code was written.

**Acceptance Criteria — spike phase (do this first):**

**Given** `AudioStreamTranscriber` may own its own audio capture and conflict with `AudioEngine`'s installed tap (R-1),
**When** the spike is performed,
**Then** the conflict is definitively characterized,
**And** if resolving it requires re-architecting capture, **the feature is cut** and this story closes with the finding recorded — its value is perceptual and explicitly the lowest priority in the plan.

**Acceptance Criteria — implementation phase — NOT DELIVERED, superseded by the cut:**

The spike did not clear, so the implementation phase was never entered. The criteria below are retained for the record only; the story closes against the spike-phase branch above, not against them. In particular, the concurrency protection `WhisperService.transcriptionLock` was declared for was never implemented — deferred with the cut, not fixed. (The unused lock and its misleading comment were themselves removed by the Epic 7 review follow-up, so the file no longer claims a guarantee it does not provide; nothing about the cut changed.)

**Given** streaming is enabled — **it is off by default**,
**When** I dictate,
**Then** partial hypotheses appear in the cursor overlay or menu bar.

**Given** partial hypotheses revise themselves (SM-C3),
**When** any partial text exists,
**Then** it is **never** injected into the target application,
**And** only the final result passes through the pipeline to `TextInjector`,
**And** a test asserts that no partial text ever reaches the injector.

**Given** streaming must not change results,
**When** the same audio is transcribed with streaming on and off,
**Then** the final text is identical,
**And** end-to-end latency does not increase and accuracy does not degrade.

**Given** streaming is off,
**When** I dictate,
**Then** the pipeline behaves exactly as before this story (AD-2).

**Given** memory is constrained (NFR-3),
**When** streaming runs,
**Then** peak memory does not threaten the working set of the largest supported model on 24 GB.

**Given** `WhisperService.transcriptionLock` (`:48`) is declared and never used, with a comment describing unimplemented concurrency protection,
**When** this story touches `WhisperService`,
**Then** the lock is either genuinely used or deleted — the misleading comment does not survive.

**Verification:**
- Spike: document the capture-ownership finding before writing feature code. If it is a conflict, stop and close the story.
- Unit: no-partial-text-reaches-injector assertion; the streaming-off identity path.
- Manual: dictate a 60-second passage with streaming on; confirm partials appear and only the final text is injected.
- Manual: transcribe identical audio with streaming on and off; compare final text and timings.

Only the spike bullet was performed; the remaining bullets were not, because the implementation phase was cut (see **Outcome** above).

---

## Epic 8: Rebrand and Bilingual Dictation

Two independent, ad-hoc stories requested directly (not derived from the PRD): give the app its own public identity, and let the same install dictate both Hebrew and English. Covers no FR/NFR from the original inventory — both are additive, post-launch requests layered on the finished Epics 1-7 product.

### Story 8.1: Rebrand to "TypeFlow"

As the maintainer of this fork,
I want the app's user-visible identity to read "TypeFlow" instead of "VocaMac",
So that it has its own public name while everything that would break if renamed — bundle id, on-disk data, git history, internal types — stays exactly as it was.

**Acceptance Criteria:**

**Given** every user-visible surface names the app,
**When** the app is built and run,
**Then** the Settings, Onboarding, and History window titles, the menu bar header and quit/restart labels, the About tab, permission/error/tooltip text that names the app, and the README's title/tagline/features intro all read "TypeFlow",
**And** the top of the README states the fork relationship: "TypeFlow is a fork of VocaMac by jatinkrmalik, licensed under AGPL-3.0."

**Given** the bundle identifier, the `~/Library/Application Support/VocaMac/` data path (models, history, profiles, dictionary), git history, and the ~9,500 LOC of internal `VocaMac*` type names carry real cost to rename (TCC re-grant, user data migration, churn) and zero user-visible value,
**When** the rebrand lands,
**Then** none of them change: `com.vocamac.app` stays the bundle id, the Application Support folder stays named `VocaMac`, and no Swift type is renamed.

**Given** `scripts/build.sh` drove both the internal executable name and the user-visible product name from one `APP_NAME` variable,
**When** the generator is updated,
**Then** it is split into `APP_NAME="VocaMac"` (executable filename, xcodebuild scheme, entitlements — unchanged, so `VocaMacApp.ensureSingleInstance`'s `pgrep -x "VocaMac"` keeps matching the real binary) and `DISPLAY_NAME="TypeFlow"` (`CFBundleName`, `CFBundleDisplayName`, `NSMicrophoneUsageDescription`),
**And** the delivered bundle folder itself is named from `DISPLAY_NAME` (`APP_DIR="${DISPLAY_NAME}.app"`), so the shipped app is `TypeFlow.app` containing an unchanged `VocaMac` executable and `com.vocamac.app` identifier,
**And** that definition lives in exactly one place — `scripts/app-name.sh` — sourced by `build.sh`, `dist.sh`, `install.sh`, `uninstall.sh` and the `Makefile`, with the four workflow YAMLs and both Homebrew casks updated to match.

*(AC amended after Epic 8 adversarial review, BLOCKER 1. `build.sh` began emitting `TypeFlow.app` while every consumer still looked for `VocaMac.app`: CI's `test -d`, all three release/nightly/pr-build codesign and packaging steps, `dist.sh`'s DMG staging and AppleScript layout, `install.sh`'s copy to /Applications, `uninstall.sh`'s cleanup, `make run`/`make clean`, and both cask `app` stanzas. A stale pre-rebrand `VocaMac.app/` also sat untracked at the repo root, so `make run` and `install.sh` launched the **old** app. Deleted, and `.gitignore` now ignores both names — it previously ignored only `VocaMac.app/`, so the first build after the rename dropped an untracked multi-GB `TypeFlow.app/` where a `git add -A` would have committed it (BLOCKER 2).)*

**Given** Accessibility and Input Monitoring grants are keyed to the bundle's **path**, so renaming the folder invalidates every existing grant and strands a `VocaMac` row in System Settings whose toggle stays on while granting nothing,
**When** an existing install is upgraded,
**Then** the stuck-permission hint, `install.sh`, `uninstall.sh`, and the README all lead with "remove the old VocaMac row from both Accessibility and Input Monitoring, then add TypeFlow", with `tccutil reset` demoted to a second suggestion and noted as unreliable for Accessibility specifically,
**And** `install.sh` removes a leftover `/Applications/VocaMac.app` itself rather than leaving two apps sharing one bundle id.

*(AC added after Epic 8 adversarial review, MAJOR 4 + MINOR 4.)*

**Given** the inherited update checker polls `jatinkrmalik/vocamac/releases/latest` while this fork has no release repo of its own,
**When** an upstream release compares as newer,
**Then** nothing happens: update checking is switched off behind `UpdateChecker.updatesEnabled = false`, the Settings "Check for Updates…" button is gone, and the menu-bar banner is gated on the same flag.

*(AC added after Epic 8 adversarial review, BLOCKER 4. Left on, the app would have shown "TypeFlow 0.7.x Available", handed the user a DMG containing upstream's `VocaMac.app`, and told them to drag it into /Applications — replacing this build with one that has none of Epics 1-8 while keeping the same bundle id and Application Support directory. The Homebrew branch had the same defect from the other side. The machinery is intact and tested behind the flag, since the fix is a real fork release repo, not a different endpoint.)*

**Given** renaming the SwiftPM product/target to "TypeFlow" was evaluated first,
**When** the cascade was checked,
**Then** it was rejected: the product name drives xcodebuild's scheme and the Contents/MacOS binary filename (`scripts/build.sh`'s `-scheme VocaMac` and `BINARY=".../${APP_NAME}"`), and the target name is the Swift module every one of the ~35 files in `Tests/VocaMacTests/` imports via `@testable import VocaMac` — renaming either cascades into the build script and every test file for zero user-visible gain, so `Package.swift` is untouched and the rename happens only at the `.app`-bundle-and-Info.plist layer.

**Given** SettingsView's Debug tab has a permission "Re-check Permissions" affordance that blended in next to the more prominent "Reset All Permissions" button,
**When** the Debug tab is viewed,
**Then** "Re-check Permissions" carries a matching icon and `.bordered` style so it reads as equally actionable,
**And** once any permission has read `.denied` for 30+ seconds of polling, a red hint appears next to the existing denied-permissions text telling the user (dev/ad-hoc builds) to remove and re-add the app in System Settings, or run `tccutil reset All com.vocamac.app` — the same fix the Reset button already performs.

**Verification:**
- Build: `swift build` clean. **Post-review:** `swift test` now actually runs and is green (763 tests, ~14s) — the earlier "typecheck harness" note stood in for a suite that could not be executed, and the `HistoryStoreTests.swift:61` cast bug it excused was fixed in e473210.
- Build: `./scripts/build.sh` produces `TypeFlow.app` with `CFBundleName`/`CFBundleDisplayName` = TypeFlow, `CFBundleExecutable` = VocaMac, `CFBundleIdentifier` = com.vocamac.app; the bundled executable launches and is killable by `killall VocaMac`.
- Manual: grep confirms every remaining `VocaMac` string in `Views/`, `App/`, and the scripts is internal (header comments, log messages, the process-match string, the Application Support path) — none of it user-visible. Default export/debug-log filenames were still `VocaMac-*` and are now `TypeFlow-*` (MINOR 2).
- Manual: `ensureSingleInstance`'s `pgrep -x "VocaMac"` still matches the actual `Contents/MacOS/VocaMac` executable name after the bundle-name split.
- Post-review: permission-denial clocks moved from `@State` on the Debug tab to `PermissionManager`, so switching tabs no longer restarts the 30-second timer (MINOR 3), and permission polling slows to 30s after all grants rather than stopping, so a mid-session revoke is noticed (MINOR 5).

### Story 8.2: Bilingual (Hebrew + English) dictation

As a user who dictates in both Hebrew and English,
I want a fast way to tell the app which language I'm speaking,
So that I don't have to dig into the 19-language Settings picker every time I switch.

**Empirical test performed first (throwaway harness, scratchpad-only, never touched the repo):** `say -v Samantha`/`say -v Carmit` synthesized one English and one Hebrew clip, transcribed through the real ivrit-ai model at the real decoding options (`DecodingOptions` mirrored exactly from `WhisperService.decodingOptions`). Verdict: **the ivrit.ai Hebrew fine-tune's English quality is good** — with `language: "en"` forced, the English clip transcribed perfectly ("The quarterly report is due next Tuesday at 03:30."). Hebrew with `language: "he"` or auto both transcribed correctly. The one caveat: WhisperKit's `detectLanguage` (true auto-detect, `language: nil`) is unreliable for language *identification* on this fine-tune — it mislabeled the English clip's `detectedLanguage` as `"he"` even though the decoded *text* was still correct English. This is a labeling quirk, not a transcription-quality problem, and is documented rather than worked around (fixing language-ID bias inside a third-party fine-tune is out of scope).

**Given** the evidence showed good English quality in the existing single-model, explicit-language path,
**When** the feature is implemented,
**Then** the design keeps the **single ivrit-ai model** (no second model, no reload-on-toggle) and adds a fast menu-bar toggle over the same `AppState.selectedLanguage` the existing 19-language Settings picker already used — a menu bar quick-switch, not a new decoding path.

**Given** the menu bar toggle, and that the segmented control has three segments while Settings offers nineteen choices over the same key,
**When** I open the popover,
**Then** a three-way עב/EN/Auto segmented control sits under the header bound to `selectedLanguage` whenever the stored value is one of those three,
**And** a stored value outside them (any of the other sixteen Settings languages) is rendered as a read-only "&lt;Language&gt; — change in Settings" label instead, because a segmented picker whose selection is outside its own tags shows nothing highlighted and silently rewrites the user's choice the moment a segment is touched,
**And** a Profile that pins a language for the frontmost app is shown the same way — "EN — from Slack Profile" — since that override, not the toggle, is what the next dictation will use.

*(AC amended after Epic 8 adversarial review, MAJOR 2 + MEDIUM 3. The original wording — "reflects whatever is currently selected (including a value picked from the full Settings list)" — described behavior a three-segment control cannot have. `DictationLanguage` is now the single list both surfaces read.)*

**Given** a Profile may need to force a language regardless of the toggle (e.g. a Slack Profile always in English),
**When** `Profile` gains an optional `language: String?` field (`nil` = follow the app-wide toggle, following the same optional-with-default pattern as its other fields),
**Then** the resolved language is `capturedProfile?.language ?? selectedLanguage`, captured at **recording start** alongside the Profile and the bundle identifier — not read at stop time, where a mid-recording toggle flip retroactively changed the language of speech already captured (MEDIUM 2) — before mapping `"auto"` to `nil`,
**And** a "Language for this Profile" picker in the Profiles settings tab exposes App Default / Hebrew / English / Auto-detect,
**And** Command Mode resolves its instruction's language the same way rather than ignoring Profiles (MINOR 8).

**Given** the custom Vocabulary glossary is written with Hebrew dictation in mind,
**When** the resolved language for a recording is explicitly `"en"` **or is Auto**,
**Then** the vocabulary/`promptTokens` hint is not passed to WhisperKit for that recording.

*(AC amended after Epic 8 adversarial review, MAJOR 3. The original carved out Auto — "Auto mode still gets it, since the language isn't known until decode completes" — which is exactly the defect: passing `promptTokens` with `language: nil` makes `decodingOptions` set `usePrefillPrompt: true` alongside `detectLanguage: true`, so a Hebrew glossary was prefilled ahead of the language detection it then skewed. That combination was never tested. Auto now decodes with `usePrefillPrompt: false`, the shipped path, and `DecodingOptionsLanguageTests.testDecodingOptionsTable` pins the whole he/en/auto × glossary/none table.)*

**Given** dictations should show what language was actually used,
**When** a `HistoryRecord` is written,
**Then** it carries a new optional `language: String?` holding the **requested** language whenever one was requested, falling back to `VocaTranscription.detectedLanguage` only in Auto — `nil`-safe for every record written before this story — and both the History list row and detail view display it as a name ("Hebrew", not "HE"/"he").

*(AC amended after Epic 8 adversarial review, MEDIUM 1 + MINOR 7. Populating it unconditionally from `detectedLanguage` made English-forced dictations record themselves as Hebrew — the very `detectLanguage` mislabeling this story's own empirical test documented as a known caveat of the ivrit.ai fine-tune.)*

**Given** the post-processing prompt is what turns a raw transcript into clean text,
**When** an English dictation is cleaned,
**Then** it is sent an English prompt variant (English correction markers and English few-shot examples), selected from the resolved language — and a prompt the user has edited is always sent verbatim, in every language.

*(AC added after Epic 8 adversarial review, MAJOR 1. Story 8.2 shipped bilingual ASR against a monolingual cleanup prompt: `Prompts.cleanTranscriptSystemPrompt` names only Hebrew correction markers and all ten of its few-shots are Hebrew, so English self-correction never fired. Live-verified against LM Studio / qwen3-4b-instruct-2507-mlx — the Hebrew prompt on "we ship Tuesday no Wednesday" returns the Hebrew "נשלחים שניים"; the English variant returns "We ship Wednesday.")*

**Given** two-model auto-detect-per-recording was considered and rejected (only relevant to the "ivrit English degraded" branch, which the empirical test did not find),
**When** documenting the decision,
**Then** Auto mode continues to mean "one model, `detectLanguage: true`" exactly as it already did — no model-switch-on-toggle logic was added, since the empirical evidence did not call for it.

**Verification:**
- Empirical: throwaway harness output recorded above (ivrit English quality verdict, detectLanguage mislabeling caveat).
- Live: a harness compiled directly against the real, unmodified `Sources/VocaMac/Services/WhisperService.swift` (not a reimplementation) loads the real ivrit-ai model once and calls the real `transcribe()` with `language: "he"` then `language: "en"` then `language: "he"` again on the same loaded model instance — mirroring exactly what toggling the menu bar control now does — both languages transcribed correctly with no reload.
- Build: `swift build` clean.
- **Automated (added post-review, MEDIUM 4).** This story originally shipped with **zero** tests. `Tests/VocaMacTests/DictationLanguageTests.swift` now covers: the shared 19-code list and its 3-code quick-toggle subset; display-name mapping including the legacy `iw` code; the full `decodingOptions` he/en/auto × glossary/none table; prompt-variant selection plus the never-override-an-edited-prompt guard, end-to-end through `PostProcessStage`; language captured at recording start and cleared once consumed; Profile-override precedence; the glossary gate for English and Auto; requested-wins-over-detected in `HistoryRecord`; the menu-bar override accessor; and legacy decode + import carry-through for both `Profile.language` and `HistoryRecord.language`.
- **Live post-processing (added post-review, MAJOR 1).** Both prompts run against LM Studio at `localhost:1234` / `qwen3-4b-instruct-2507-mlx` / temperature 0. English: "we ship Tuesday no Wednesday" → "We ship Wednesday."; filler removal, question preservation, and mid-sentence correction all fire; four held-out cases not present as few-shots also pass ("call the vendor on Thursday actually on Friday morning" → "Call the vendor on Friday morning."). Hebrew regressions unchanged ("נפגש ביום שלישי אה לא ביום רביעי" → "נפגש ביום רביעי."), plus two held-out Hebrew cases. Control case reproducing the defect: the **Hebrew** prompt on the same English transcript returns "נשלחים שניים" — a Hebrew mistranslation, exactly the Hebrew-flip the validator would then silently reject.
- Manual (pending real device use): profile-language override actually overrides the toggle for its bound app; History rows show the recorded language.

---

<!-- checkpoint: all 7 epics dev+review+fix complete; app installed as 0.8.0-local-hebrew; tracker synced all-done 2026-08-20; Epic 8 (rebrand + bilingual) added and completed same session -->
<!-- checkpoint 2026-08-20: real XCTest run landed (e473210, 727 green) — the deadlock, the HistoryStoreTests:61 cast, and the stale default assertions are fixed. Epic 8 adversarial review applied: 4 blockers, 4 majors, 5 mediums, 8 minors. Suite now 763 green. ACs above amended in place where the review found the AC itself wrong (MAJOR 2 segmented picker, MAJOR 3 Auto glossary carve-out, MEDIUM 1 detected-vs-requested language) rather than only the code. Two things remain open by decision, both blocked on the same missing thing — this fork has no release repo of its own: the update checker stays off behind UpdateChecker.updatesEnabled, and both Homebrew casks still point their `url` at upstream (flagged in-file as unpublishable as-is). One test, testSelectedModelSizeDefault, is order-dependent and left as-is under its own task chip. -->
