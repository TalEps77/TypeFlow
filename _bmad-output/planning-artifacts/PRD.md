---
title: local-whisper — Private Local Dictation
created: 2026-08-19
updated: 2026-08-19
---

# PRD: local-whisper

*A private, fully-local Wispr Flow alternative for Hebrew dictation on macOS.*

## 0. Document Purpose

This PRD is the requirements contract for evolving `local-whisper` — a fork of [VocaMac](https://github.com/jatinkrmalik/vocamac) (AGPL-3.0, Swift/SwiftPM, WhisperKit/CoreML, ~9,500 LOC) — from a raw speech-to-text menu-bar utility into a context-aware dictation product that matches or beats Wispr Flow for Hebrew, while remaining 100% offline.

It is written for the downstream BMAD workflows: `bmad-architecture` (which turns §4 Features into services), `bmad-create-epics-and-stories` (which turns FRs into stories), and `bmad-dev-story` (which implements them). Discovery is complete — the gap analysis "VocaMac vs Wispr Flow" (26 Jul 2026) is the input, and the strategic decisions listed in §10 are **settled and not open for re-litigation**.

Structure: vocabulary is anchored in §3 Glossary and used verbatim everywhere else. Features in §4 are grouped by delivery phase, with globally-numbered FRs nested underneath. Assumptions are tagged inline and indexed in §11.

## 1. Vision

Today `local-whisper` does one thing well: you hold Right Option, speak Hebrew, and Whisper's raw output lands at your cursor in any app. That output is a faithful transcript — and a faithful transcript is not what anyone actually wants to send. It carries filler words, has no punctuation beyond what Whisper guessed, formats nothing, and preserves mid-sentence self-corrections verbatim ("let's meet at 2… actually at 3" arrives with both times intact).

Wispr Flow solves this with a cloud LLM layer that sits after the ASR, plus context awareness — it knows which app you are dictating into and adapts tone accordingly. It costs $15/month, requires an account, and ships your audio, your screen contents, and the text around your cursor to someone else's servers. For this user, in this environment, that is disqualifying.

The bet here is that the entire value-add above raw transcription is reproducible locally. An LLM running in LM Studio on the same machine can strip fillers, punctuate, format, and resolve self-corrections. `NSWorkspace` and the Accessibility APIs — for which the app already holds permission — supply the same app-and-cursor context Wispr Flow harvests, without a single byte leaving the device. And on the one axis that matters most here, Hebrew accuracy, a locally-run ivrit.ai fine-tune should beat a general-purpose cloud model outright. The goal is not to clone Wispr Flow. It is to reach parity on what actually adds value, win on Hebrew, and never give up the privacy advantage.

## 2. Target User

### 2.1 Jobs To Be Done

- **Functional** — Dictate Hebrew (and mixed Hebrew/English technical) prose into any macOS app and have *send-ready* text appear, not a raw transcript needing cleanup.
- **Functional** — Dictate into a terminal or code editor and get identifier-shaped output (camelCase preserved, no trailing punctuation) rather than prose.
- **Functional** — Fix a recurring mis-transcription **once** and never see it again.
- **Contextual** — Operate in an environment where cloud dictation is not permissible. Offline capability is a hard constraint, not a preference.
- **Emotional** — Trust the tool enough to dictate anything, because nothing is transmitted anywhere.
- **Social** — Produce output whose register matches the channel: a Slack message should not read like a formal email.

### 2.2 Non-Users (v1)

- Teams wanting a shared dictionary, shared snippets, or adoption dashboards.
- Users on Intel Macs, Windows, or mobile. Apple Silicon + macOS 13+ only.
- Users who want cross-device sync of settings, history, or vocabulary.
- Users dictating primarily in languages other than Hebrew and English. The pipeline is not language-locked by design, but only Hebrew is tuned and tested.

### 2.3 Key User Journeys

- **UJ-1. Tal sends a Slack message that reads like he wrote it, not like he dictated it.**
  Tal is mid-conversation in Slack and holds Right Option. He speaks a rambling Hebrew sentence with two "אה"s and a self-correction. On release, the ASR produces the raw transcript; PostProcessService sends it to the local LLM with the Slack Profile's casual-tone prompt; ~600ms later the cleaned, punctuated, correction-resolved text is pasted at his cursor. He hits Enter. He never saw the raw transcript, and never had to. **Edge case:** if LM Studio is not running, the raw transcript is pasted instead with no error dialog and no delay beyond the timeout — the tool degrades to exactly what it does today.

- **UJ-2. Tal dictates a variable name into VS Code and it comes out as an identifier.**
  Tal is in VS Code with the cursor inside a function body. He dictates a Hebrew-accented English phrase describing a variable. ProfileManager resolves the frontmost bundle id to the Code Profile, whose prompt instructs the LLM to emit `camelCase`, no terminal punctuation, and to preserve structure. The result is injected as a valid identifier.

- **UJ-3. Tal corrects a mis-transcribed term once and it sticks.**
  A domain term keeps coming out wrong. Tal opens Settings → Dictionary, adds the correct spelling with the wrong variant as a trigger. The next time the ASR emits any near-match — after Hebrew normalization strips niqqud and reconciles matres lectionis — DictionaryService replaces it before injection. **Edge case:** rather than adding it manually, Tal simply retypes the correct word in-place within seconds of injection; the learning path detects the edit via the history record and offers to add the mapping.

- **UJ-4. Tal rewrites a paragraph he already wrote, by talking to it.**
  Tal selects a clumsy Hebrew paragraph in a document, presses the Command Mode hotkey, and says "make this shorter and more formal." The selection plus the spoken instruction go to the local LLM; the rewritten text replaces the selection in place. **Edge case:** if no text is selected, the app plays the error sound and does nothing rather than injecting the instruction as literal text.

- **UJ-5. Tal dictates a long, pausy paragraph without getting cut off mid-thought.**
  Tal dictates a 90-second passage with natural Hebrew pauses, occasionally dropping to near-whisper volume. The VAD distinguishes speech from silence on signal characteristics rather than raw amplitude, so neither the pauses nor the quiet passages trigger the auto-stop. Partial results appear as he speaks, so he can see it is working.

## 3. Glossary

- **ASR** — Automatic Speech Recognition. Here: Whisper, executed via WhisperKit on the Neural Engine. Produces a **Raw Transcript**. Does not interpret, reformat, or follow instructions.
- **Raw Transcript** — The verbatim `String` output of the ASR after existing hallucination filtering, before any other transformation. The current end-product of the pipeline; after this PRD, an intermediate value.
- **Final Text** — The string actually delivered to the target application. Equals the Raw Transcript when every post-ASR stage is disabled or has fallen back.
- **Post-Processing** — The LLM stage that transforms a Raw Transcript into cleaner prose: filler removal, punctuation, list formatting, self-correction resolution. Owned by **PostProcessService**.
- **LLM Backend** — Qwen3-4B-Instruct (Q4) served by LM Studio over an OpenAI-compatible HTTP API at `http://localhost:1234`. Always local. Never bundled with the app; the user runs it.
- **Fallback** — Returning the input of a stage unchanged when that stage fails, times out, or produces an unusable result. Always silent to the user in the dictation path.
- **Profile** — A named bundle of dictation settings (LLM prompt, tone, post-processing on/off, context capture on/off) bound to one or more application bundle identifiers. Exactly one Profile is active per dictation, resolved from the frontmost application. A **Default Profile** always exists and cannot be deleted.
- **Cursor Context** — Text surrounding the insertion point in the target application, read via the Accessibility API, supplied to the LLM as grounding. Never persisted, never transmitted off-device.
- **Dictionary Entry** — A mapping from one or more trigger variants to a canonical replacement, applied to the transcript after ASR. Distinct from the existing **Vocabulary**.
- **Vocabulary** — The pre-existing list of terms sent to WhisperKit as `promptTokens` ("Glossary: …") to bias the decoder. Operates *before* transcription; retained unchanged. Not a Dictionary Entry.
- **Hebrew Normalization** — The canonicalization applied before fuzzy matching: strip niqqud and cantillation, unify matres lectionis (ו/וו, י/יי), normalize final letters and geresh/gershayim.
- **Snippet** — A mapping from a spoken **Cue** phrase to a fixed block of text, expanded before injection.
- **Command Mode** — A second hotkey flow that reads the current selection, treats the dictated utterance as an instruction rather than content, and replaces the selection with the LLM's rewrite.
- **Dictation Mode** — The existing default flow, where the dictated utterance is content to be inserted.
- **History Record** — A persisted record of one dictation: Raw Transcript, Final Text, timestamp, target bundle id, Profile, model, and per-stage latency.
- **VAD** — Voice Activity Detection. Speech/non-speech classification on signal characteristics, replacing the current fixed RMS amplitude threshold.
- **Injection** — Delivery of Final Text to the target app via `TextInjector` (Accessibility attribute write, or clipboard + ⌘V with pasteboard restore).

## 4. Features

Features are grouped by delivery phase. All three phases are in scope; phases order the work, they do not gate it.

---

### Phase 1 — The Big Win

### 4.1 Hebrew ASR Accuracy (ivrit.ai Model)

**Description:** The single highest-leverage change, and the one place `local-whisper` can beat Wispr Flow outright rather than catching up to it. An ivrit.ai Whisper fine-tune, converted to WhisperKit CoreML format, is registered as a selectable model alongside the existing catalog. Unlike existing entries, this model is **side-loaded**: it is placed on disk out-of-band (a parallel effort is producing it), not downloaded from Hugging Face by the app. The registry must therefore tolerate an entry whose files may be absent, presenting it as unavailable rather than crashing or offering a broken download. Realizes UJ-1 through UJ-5 indirectly — every downstream stage is only as good as its input.

**Functional Requirements:**

#### FR-1: Register a side-loaded local model

The user can select an ivrit.ai Hebrew model from the model picker, alongside the existing WhisperKit models.

**Consequences (testable):**
- A new case exists in the model enumeration with a display name, an on-disk folder name, and an approximate size and RAM estimate.
- The model resolves from `~/Library/Application Support/VocaMac/models/<folder>` using the same path convention as downloaded models.
- Selecting it and dictating produces a transcript through the unchanged WhisperKit code path.
- Existing model entries, their download behavior, and the chip/RAM-based recommendation logic are unaffected.

**Out of Scope:**
- Performing the Hugging Face → CoreML conversion inside the app.
- Bundling model weights in the app binary.

#### FR-2: Present an absent side-loaded model as unavailable

When the side-loaded model's folder is missing or incomplete, the app communicates this rather than failing opaquely.

**Consequences (testable):**
- The picker marks the entry "Not installed" and prevents selection.
- The UI states the expected on-disk path so the user can place the files.
- No download is attempted for this entry, and no crash or unhandled error occurs.
- If the model is selected and its files are later removed, the app falls back to a known-good model and surfaces one clear message.

#### FR-3: Record per-stage latency

Each dictation records how long each stage took, so model choice can be evaluated on evidence rather than impression.

**Consequences (testable):**
- Recording duration, ASR duration, and post-processing duration are captured per dictation and stored on the History Record (FR-8).
- ASR duration is measurable per model, enabling the large-model-vs-small-model-plus-LLM comparison the gap analysis calls for.

---

### 4.2 LLM Post-Processing

**Description:** The heart of the product gap. A new `PostProcessService` sits between the ASR and `TextInjector`. It sends the Raw Transcript to the LLM Backend with a system prompt instructing it to remove fillers, add punctuation, format enumerations as lists, and resolve mid-utterance self-corrections — while changing nothing else and never answering the content as though it were a question. The design constraint that dominates everything: **this stage must never make the product worse than it is today.** If LM Studio is not running, is slow, or returns something unusable, the user gets the Raw Transcript, silently, on a bounded deadline. Realizes UJ-1, UJ-2.

**Functional Requirements:**

#### FR-4: Clean the transcript via the local LLM

When Post-Processing is enabled, the Raw Transcript is transformed into Final Text by the LLM Backend before Injection. Realizes UJ-1.

**Consequences (testable):**
- A single HTTP request is issued to the OpenAI-compatible chat-completions endpoint; the response content becomes the Final Text.
- Filler words are removed; sentence-final punctuation is present; spoken enumerations become formatted lists.
- Given "נפגש בשתיים… בעצם בשלוש", the Final Text contains only the corrected time.
- Given a transcript that is a question, the output is the cleaned question — not an answer to it.
- The Raw Transcript is preserved alongside the Final Text on the History Record.

#### FR-5: Fall back transparently on any failure

Any post-processing failure yields the Raw Transcript with no user-visible interruption of the dictation flow. Realizes UJ-1 (edge case).

**Consequences (testable):**
- Connection refused (LM Studio not running) → Raw Transcript injected; no modal, no dialog.
- Elapsed time exceeds the configured timeout → the request is cancelled and the Raw Transcript is injected; total added latency is bounded by the timeout.
- Non-2xx status, malformed JSON, or empty content → Raw Transcript injected.
- A response that is degenerate — empty, or wildly disproportionate in length to the input — is rejected in favor of the Raw Transcript. `[ASSUMPTION: a length-ratio guard is a sufficient proxy for "the model went off the rails"; the exact bounds are tunable and will be calibrated during implementation.]`
- Every fallback is logged with its reason and reflected on the History Record, so silence to the user is not silence to diagnosis.

#### FR-6: Configure post-processing

The user controls whether post-processing runs and how it connects.

**Consequences (testable):**
- A master on/off toggle exists; when off, no HTTP request is made and behavior is byte-identical to today's.
- Endpoint base URL, model identifier, timeout, and temperature are user-editable and persisted, with working defaults (`http://localhost:1234`, Qwen3-4B-Instruct, a low single-digit-second timeout, temperature 0).
- The system prompt is user-editable, with a documented default and a one-click restore-to-default.

#### FR-7: Verify the LLM connection on demand

The user can confirm the LLM Backend is reachable without having to dictate.

**Consequences (testable):**
- A "Test connection" control issues a real request and reports success with the responding model's identifier, or failure with an actionable reason (refused / timed out / HTTP status).
- The test never blocks the UI and cannot leave the settings screen in a stuck state.

**Feature-specific NFRs:**
- Post-processing adds no more than the configured timeout to end-to-end latency under any failure mode.
- All traffic targets a loopback address. The app must function with no network route to the internet.

---

### 4.3 Transcription History

**Description:** Nothing is currently persisted except aggregate statistics — there is no way to recover a transcript the app produced 30 seconds ago. History is the cheapest feature in this PRD and a precondition for two others: correction-learning (§4.5) needs to know what was injected and where, and latency evaluation (FR-3) needs somewhere to record. It also delivers immediate standalone value: re-paste when an injection lands in the wrong window, and undo when it lands in the right one but shouldn't have. Realizes UJ-3.

**Functional Requirements:**

#### FR-8: Persist every dictation

Each completed dictation is recorded locally.

**Consequences (testable):**
- A History Record captures Raw Transcript, Final Text, timestamp, target bundle id, Profile name, model, per-stage latencies, and whether a Fallback occurred.
- Records persist across app restarts.
- Records are stored unencrypted on the local disk only, are never transmitted, and are excluded from any diagnostic upload.

#### FR-9: Re-paste a previous transcription

The user can re-inject any recent dictation at the current cursor.

**Consequences (testable):**
- A menu-bar action re-injects the most recent Final Text.
- The history list allows re-injecting any listed entry, using the same `TextInjector` path as a live dictation.
- Re-pasting does not create a duplicate History Record.

#### FR-10: Undo the last injection

The user can retract an injection immediately after it lands.

**Consequences (testable):**
- An undo action removes the just-injected text from the target application.
- Undo is offered only while it is plausibly safe — within a short window, with the same application still frontmost.
- When undo cannot be performed safely, the action is unavailable rather than destructive. `[ASSUMPTION: undo is best-effort. The AX write path can retract precisely; the clipboard/⌘V path will synthesize ⌘Z, which some applications handle differently. This limitation is acceptable and will be stated in the UI.]`

#### FR-11: Browse, search, and clear history

The user can review and manage what has been recorded.

**Consequences (testable):**
- A history view lists records newest-first with timestamp, target app, and a text preview.
- Selecting a record reveals both the Raw Transcript and the Final Text, making the LLM's edit visible.
- Text search filters the list.
- Individual delete, delete-all, and a configurable retention limit are available; retention is enforced automatically.

---

### Phase 2 — Personalization

### 4.4 Per-App Profiles and Cursor Context

**Description:** The same utterance should not produce the same text in Slack and in a legal document. `ProfileManager` resolves the frontmost application's bundle identifier to a Profile, and that Profile's prompt steers the LLM. Optionally — and separately toggleable, because it is the most privacy-sensitive capability in this PRD — the text immediately around the cursor is read via Accessibility and supplied to the LLM as grounding, so the model can match the surrounding register, language, and formatting. This is the local, opt-in equivalent of Wispr Flow's context harvesting: same benefit, nothing transmitted. Realizes UJ-1, UJ-2.

**Functional Requirements:**

#### FR-12: Resolve a Profile from the frontmost application

The active Profile is determined automatically at the start of each dictation.

**Consequences (testable):**
- The frontmost application's bundle identifier is captured when recording begins, not when it ends — so switching windows mid-dictation does not change the resolved Profile.
- The bundle identifier maps to a Profile; when no Profile matches, the Default Profile is used.
- The resolved Profile name is recorded on the History Record.
- When Profiles are disabled entirely, the Default Profile always applies.

#### FR-13: Create and manage Profiles

The user can define Profiles for the applications they use.

**Consequences (testable):**
- A Profile has a name, a set of bundle identifiers, a prompt override, and per-Profile toggles for post-processing and context capture.
- Profiles can be created, edited, reordered, and deleted; the Default Profile can be edited but not deleted.
- Bundle identifiers can be picked from running applications rather than typed by hand.
- Sensible starter Profiles ship for a chat app, a mail app, and a code editor, illustrating casual, formal, and identifier-shaped output.
- Profiles persist across restarts and are exportable as a single JSON file. `[ASSUMPTION: file-based export satisfies the multi-machine sync need identified in the gap analysis; no sync service is built.]`

#### FR-14: Supply Cursor Context to the LLM

When enabled, text around the insertion point grounds the post-processing prompt. Realizes UJ-2.

**Consequences (testable):**
- Text before and after the insertion point is read via the Accessibility API and truncated to a bounded character budget.
- Context is included in the LLM request only when both the global toggle and the active Profile's toggle are on. It is **off by default**.
- Context is never written to the History Record, never logged, and never persisted anywhere.
- When the target application exposes no readable context, post-processing proceeds without it rather than failing.
- Reading context adds negligible latency and never blocks Injection.

**Feature-specific NFRs:**
- Cursor Context lives in memory for the duration of a single request and is released immediately after.

---

### 4.5 Learning Dictionary

**Description:** The existing Vocabulary biases the decoder *before* transcription and cannot repair what Whisper got wrong. A Dictionary Entry corrects the transcript *after*, by fuzzy-matching against a canonical list. Hebrew makes this genuinely hard: no ready-made phonetic algorithm exists, so matching runs on top of Hebrew Normalization (niqqud stripping, matres lectionis unification) with edit-distance over the normalized forms. The learning half closes the loop — when the user retypes a word shortly after injection, the app can infer a correction and offer to remember it. Realizes UJ-3.

**Functional Requirements:**

#### FR-15: Replace transcript terms from the Dictionary

Dictionary Entries are applied to the transcript before Injection.

**Consequences (testable):**
- Exact matches are replaced.
- Near-matches within a configured edit-distance threshold, compared over Hebrew-Normalized forms, are replaced.
- Replacement preserves surrounding whitespace and punctuation, and does not match inside longer unrelated words.
- Below-threshold candidates are left untouched — a conservative miss is preferred to a wrong replacement.
- Replacement is deterministic and ordered, so overlapping entries resolve predictably.

#### FR-16: Normalize Hebrew for matching

Hebrew Normalization is applied consistently to both sides of every comparison.

**Consequences (testable):**
- Niqqud and cantillation marks are stripped.
- Matres lectionis variants (ו/וו, י/יי) are unified.
- Final-form letters are normalized to their base forms; geresh and gershayim are handled.
- Normalization is pure, side-effect free, and unit-tested against a table of Hebrew variant pairs.
- Latin text passes through unchanged, so mixed Hebrew/English technical terms still match.

#### FR-17: Manage Dictionary Entries

The user can curate the Dictionary.

**Consequences (testable):**
- Entries are created, edited, and deleted through a settings screen, each with a canonical form and one or more trigger variants.
- The Dictionary persists across restarts and exports as JSON alongside Profiles.
- The Dictionary is distinct from, and does not modify, the existing Vocabulary.

#### FR-18: Learn from user corrections

The app proposes new Dictionary Entries by observing in-place corrections. Realizes UJ-3 (edge case).

**Consequences (testable):**
- After Injection, the text field's content is re-read after a short delay; a small, localized difference against the injected text is treated as a candidate correction.
- Candidates are **proposed for confirmation**, never added silently.
- Candidates are dismissible, and a dismissed candidate is not proposed again for the same pair.
- The entire learning capability is toggleable and **off by default**.
- Unrelated user typing does not generate a flood of candidates; the difference heuristic is bounded to word-level, single-token edits. `[ASSUMPTION: word-level diffing within a short window is precise enough to be useful without being noisy. If it proves noisy in practice, the feature stays off and is revisited rather than shipped loud.]`

---

### 4.6 Snippets

**Description:** The simplest feature in the PRD. A spoken Cue expands into a fixed block of text — a signature, a calendar link, a standard reply — before Injection. Purely mechanical string substitution with no LLM involvement, which makes it fast and completely reliable.

**Functional Requirements:**

#### FR-19: Expand a spoken Cue into a text block

Recognized Cues in the transcript are replaced with their Snippet body.

**Consequences (testable):**
- A Cue matched in the transcript is replaced by its body, with multi-line bodies preserved verbatim.
- Cue matching is case-insensitive and uses Hebrew Normalization (FR-16), so a Cue matches despite niqqud or spelling variance.
- Multiple distinct Cues in one transcript all expand.
- Expansion runs on the transcript and does not require the LLM Backend; Snippets work with post-processing disabled.

#### FR-20: Manage Snippets

The user can curate Cue → body mappings.

**Consequences (testable):**
- Snippets are created, edited, and deleted in settings, with a multi-line body editor.
- Snippets persist across restarts and export as JSON alongside Profiles and the Dictionary.
- A Cue that collides with an existing Cue is rejected with a clear message.

---

### Phase 3 — Polish

### 4.7 Command Mode

**Description:** Instead of inserting what you say, act on what you've selected. A second global hotkey reads the current selection, interprets the dictated utterance as an *instruction* ("summarize this", "translate to English", "make it more concise"), sends both to the LLM, and writes the rewrite back over the selection. Architecturally this is a second route through the same pipeline with a different prompt and a different terminal write — and unlike Dictation Mode, it hard-depends on the LLM Backend. Realizes UJ-4.

**Functional Requirements:**

#### FR-21: Rewrite the selection by voice

Pressing the Command Mode hotkey and speaking an instruction rewrites the selected text in place. Realizes UJ-4.

**Consequences (testable):**
- A second, separately-configurable global hotkey activates Command Mode, using the same push-to-talk and double-tap conventions as the existing hotkey.
- The current selection is read via the Accessibility API at activation.
- The utterance is transcribed and sent to the LLM as an instruction, together with the selection as the subject.
- The response replaces the selection in the target application.
- The instruction text itself is never injected into the document.
- The operation is recorded as a History Record distinguishable from a Dictation Mode record.

#### FR-22: Fail safely when preconditions are unmet

Command Mode does nothing destructive when it cannot proceed. Realizes UJ-4 (edge case).

**Consequences (testable):**
- No selection → the operation aborts with the existing error sound; nothing is injected and nothing is overwritten.
- LLM Backend unreachable or timed out → the operation aborts and the selection is left untouched. There is no Fallback here: unlike Dictation Mode, injecting the raw transcript would be actively wrong.
- The target application does not expose a writable selection → the operation aborts with one clear message.
- The default Command Mode hotkey does not conflict with the Dictation Mode hotkey, and the UI rejects assigning the same hotkey to both.

---

### 4.8 Voice Activity Detection

**Description:** The current auto-stop is a fixed RMS amplitude threshold (0.01 for 1.2s). Amplitude is a poor proxy for speech: it cuts off quiet or whispered passages as though they were silence, and it fires during natural Hebrew pauses. Replacing it with real VAD — WhisperKit ships `EnergyVAD`, and a Silero-class ML model is available as a reference — fixes both. The same change unlocks `chunkingStrategy: .vad`, which lets WhisperKit split long recordings on speech boundaries and transcribe windows in parallel instead of sequentially. Realizes UJ-5.

**Functional Requirements:**

#### FR-23: Detect speech instead of amplitude

Auto-stop is driven by speech/non-speech classification, not by a raw amplitude threshold. Realizes UJ-5.

**Consequences (testable):**
- Recording auto-stops after a configured duration of detected non-speech, replacing the RMS threshold check.
- Whispered and low-volume speech is classified as speech and does not trigger auto-stop.
- Natural mid-sentence pauses do not trigger auto-stop at the default setting.
- The audio-level UI indicator continues to update at its current rate and remains visually smooth.
- VAD sensitivity and the silence duration are user-configurable, and the previous RMS behavior remains selectable as a fallback if VAD regresses in practice.

#### FR-24: Parallelize long-recording transcription

Long recordings are chunked on speech boundaries and transcribed concurrently.

**Consequences (testable):**
- `chunkingStrategy` is set to `.vad` rather than left `nil`.
- A recording substantially longer than Whisper's 30-second window transcribes measurably faster than with sequential chunking, at equal or better accuracy.
- Short recordings show no regression in latency or accuracy.

---

### 4.9 Streaming Partial Results

**Description:** The last and most architecturally invasive item, and deliberately so — its benefit is largely perceptual. Today transcription begins only after the key is released. WhisperKit ships `AudioStreamTranscriber`, currently unused, which emits partial hypotheses during speech. Showing them turns dead air into visible progress. The hard constraint is that partial results are *display only*: they are unstable and revise themselves, so nothing partial may ever reach the target application. Realizes UJ-5.

**Functional Requirements:**

#### FR-25: Show partial results while speaking

In-progress transcription is visible during dictation. Realizes UJ-5.

**Consequences (testable):**
- Partial hypotheses appear in the cursor overlay or menu bar while recording.
- Partial text is **never** injected into the target application; only the final result passes through the post-ASR stages and reaches `TextInjector`.
- The final result is identical to what the non-streaming path would have produced for the same audio.
- Streaming is toggleable and off by default; with it off, the pipeline behaves exactly as before.
- Enabling streaming does not degrade final accuracy or increase end-to-end latency.

**Feature-specific NFRs:**
- Streaming must not increase peak memory enough to threaten the working set of the largest supported model on a 24 GB machine.

## 5. Non-Goals (Explicit)

- **No cloud, ever.** No cloud ASR, no cloud LLM, no telemetry, no crash reporting, no remote configuration. Any feature that cannot be built locally is not built.
- **Not a Wispr Flow clone.** Screenshot-based context, open-application enumeration, and conversation history are explicitly rejected — they are the parts of Wispr Flow's context harvesting whose privacy cost exceeds their value.
- **No mobile, no sync, no teams.** No iOS/Android client, no cross-device sync service, no shared dictionaries, no adoption dashboards. Multi-machine needs are served by JSON export/import.
- **Not migrating to VoiceInk.** Settled — see §10. VoiceInk's GPL-3 source is a permitted *design reference*; no code is copied, and the license mismatch with AGPL-3 is not to be tested.
- **Not shipping an LLM.** The app does not bundle, download, or manage model weights for the LLM Backend. LM Studio is the user's responsibility, and the app must be fully usable without it.
- **No IDE-specific integrations.** Cursor/Windsurf-style file-name tagging requires per-editor work that the gap analysis judged not worth it. Profiles cover the general case.
- **No multi-language auto-detection.** Hebrew stays the configured language. The architecture must not hard-code Hebrew, but no other language is tuned or tested.
- **Not re-architecting what works.** `TextInjector`, `HotKeyManager`, `AudioEngine`, the Vocabulary/`promptTokens` mechanism, and the existing model download manager are load-bearing and stay. New capability plugs in; it does not replace.

## 6. MVP Scope

### 6.1 In Scope

All three phases. Phase 1 is the minimum coherent release:

- **Phase 1** — ivrit.ai model registration (FR-1–FR-3); PostProcessService with transparent fallback and configuration (FR-4–FR-7); transcription history with re-paste and undo (FR-8–FR-11).
- **Phase 2** — Per-app Profiles with opt-in Cursor Context (FR-12–FR-14); learning Dictionary with Hebrew normalization (FR-15–FR-18); Snippets (FR-19–FR-20).
- **Phase 3** — Command Mode (FR-21–FR-22); VAD and `.vad` chunking (FR-23–FR-24); streaming partial results (FR-25).

### 6.2 Out of Scope for MVP

- Automated Hugging Face → CoreML model conversion in-app — one-time out-of-band task; a separate effort owns it.
- Multiple simultaneous LLM backends (Ollama, llama.cpp, cloud) — LM Studio's OpenAI-compatible endpoint is the only target. The HTTP client should not make a second backend *hard* to add later, but no second backend is built. `[NOTE FOR PM: Ollama support is a plausible v2 ask and costs little once the endpoint is abstracted.]`
- Per-Profile ASR model selection — one model per session; switching models mid-session is a model-load cost not worth paying.
- Streaming *injection* of partial results into the target app — display only, permanently.
- Encrypted history storage — deferred; the machine's own disk encryption is the boundary. `[NOTE FOR PM: revisit if history is ever extended to capture Cursor Context, which it currently must not.]`
- Sound-alike phonetic matching for Hebrew — no soundex-equivalent exists; edit distance over normalized forms is the v1 approach.

## 7. Success Metrics

**Primary**

- **SM-1**: **Hebrew accuracy beats the current baseline.** Word error rate on a fixed held-out set of Hebrew dictations is lower with the ivrit.ai model than with `large-v3-v20240930_626MB`. Validates FR-1.
- **SM-2**: **Post-processed output is send-ready.** Across a sample of everyday dictations, the majority need no manual editing before sending. Validates FR-4.
- **SM-3**: **Daily use is sustained.** The tool is still in daily use one month after Phase 1 ships, without reverting to typing for messages of consequence. Validates the product as a whole.

**Secondary**

- **SM-4**: **Bounded added latency.** Median end-to-end time from key release to injected text stays within a comfortable interactive budget with post-processing enabled. Validates FR-4, FR-5.
- **SM-5**: **Fallback is invisible and cheap.** With LM Studio stopped, dictation still works and the added delay is bounded by the timeout. Validates FR-5.
- **SM-6**: **Corrections stop recurring.** Terms added to the Dictionary do not reappear mis-transcribed. Validates FR-15, FR-16.

**Counter-metrics (do not optimize)**

- **SM-C1**: **Do not maximize LLM edit aggressiveness.** A model that rewrites meaning rather than cleaning delivery is a regression, however fluent the output. Counterbalances SM-2. If the user finds themselves *checking* what the LLM did, the prompt is too aggressive.
- **SM-C2**: **Do not maximize Dictionary match rate.** A wrong replacement is worse than a missed one, because it is silent. Counterbalances SM-6.
- **SM-C3**: **Do not optimize perceived latency at the cost of correctness.** Streaming partial results must never leak into the target application to make the tool feel faster. Counterbalances SM-4.

## 8. Cross-Cutting NFRs

- **Offline-first** — Every feature functions with no internet route. The only network traffic is loopback HTTP to LM Studio.
- **Graceful degradation** — Each post-ASR stage is independently disableable, and every stage failing yields the previous stage's output. With all new features off, behavior is byte-identical to today's.
- **Resource ceiling** — The app plus the largest supported ASR model plus a Q4 4B LLM must coexist on a 24 GB M4 without memory pressure. ASR and LLM inference must not run concurrently in a way that spikes peak resident memory.
- **Concurrency safety** — New services must not introduce data races or main-thread stalls. UI-observable state is updated on the main actor; network and file I/O never block it.
- **Backwards compatibility** — Existing settings, the Vocabulary, and accumulated statistics survive upgrade. New settings have working defaults; a fresh install behaves sensibly with everything unconfigured.
- **Testability** — Post-ASR text transformations (normalization, dictionary matching, snippet expansion, prompt construction, response validation) are pure and unit-testable without audio, without the LLM, and without the Accessibility API.
- **Licensing** — The project remains AGPL-3.0. VoiceInk (GPL-3) is a design reference only; no code is copied. `[ASSUMPTION: use remains personal/internal. If a modified build is ever distributed or run as a network-accessible service, AGPL source-availability obligations attach — flagged in §9.]`

## 9. Open Questions

1. **Prompt tuning is empirical.** The default post-processing prompt for Hebrew will need iteration against real dictations. Qwen3-4B's Hebrew instruction-following quality is unverified at Q4; if it proves weak, DictaLM 2.0 is the fallback candidate. This is a tuning risk, not an architectural one — the service contract is unchanged either way.
2. **Undo fidelity varies by application.** Synthesized ⌘Z behaves inconsistently across apps. How far to go beyond best-effort is unresolved; FR-10 deliberately scopes it as best-effort.
3. **Correction-learning precision is unproven.** FR-18's diff heuristic may generate noise in real editing sessions. It ships off by default; if the noise floor is too high it stays off pending a better signal.
4. **Model-load memory interaction.** Whether the ivrit.ai model's resident footprint plus a loaded Q4 4B LLM leaves comfortable headroom on 24 GB needs measurement before Phase 1 closes (FR-3 provides the instrumentation).
5. **AGPL distribution.** If any modified build is shared beyond this machine, source-availability obligations attach. Worth confirming with the relevant party before significant investment.
6. **VAD library choice.** WhisperKit's built-in `EnergyVAD` versus a Silero-class ML model is an implementation-time call — `EnergyVAD` first, escalate only if whisper detection is still inadequate.

## 10. Settled Decisions (Do Not Re-Litigate)

| Decision | Resolution |
| --- | --- |
| Scope | All three phases are in scope. |
| Base codebase | Stay on VocaMac. Do not migrate to VoiceInk. |
| VoiceInk | Permitted as a **design reference only**. No code copying — GPL-3 vs AGPL-3 mismatch. |
| LLM Backend | Qwen3-4B-Instruct Q4 via LM Studio, `http://localhost:1234`, OpenAI-compatible HTTP. |
| Hebrew ASR model | ivrit.ai fine-tune converted to WhisperKit CoreML. Acquired by a parallel effort; lands in `~/Library/Application Support/VocaMac/models` as a new model entry. |
| Target hardware | Apple Silicon M4, 24 GB RAM, macOS 13+. |
| Privacy posture | 100% local and offline. Non-negotiable. |
| Mobile / sync / teams | Out of scope, permanently. |

## 11. Assumptions Index

- **§4.2 / FR-5** — A length-ratio guard is a sufficient proxy for detecting a degenerate LLM response; exact bounds calibrated during implementation.
- **§4.3 / FR-10** — Undo is best-effort. The AX path retracts precisely; the clipboard path synthesizes ⌘Z, whose behavior varies by application. Stated in the UI.
- **§4.4 / FR-13** — JSON export/import satisfies the multi-machine need identified in the gap analysis; no sync service is built.
- **§4.5 / FR-18** — Word-level diffing within a short window is precise enough to propose corrections without excessive noise. If not, the feature stays off rather than shipping loud.
- **§8** — Use remains personal/internal, so AGPL source-availability obligations do not currently attach.
- **§4.1** — The parallel ivrit.ai effort delivers a WhisperKit-compatible CoreML model directory matching the layout WhisperKit expects for a local model. If the layout differs, FR-1 absorbs a conversion-shim cost.
