# local-whisper (VocaMac) — Architecture, Visually

A walkthrough for the project owner: how a dictation actually moves through the app, what Command Mode does differently, which model files exist where, and what does (and never does) touch disk or network. Grounded against `Sources/VocaMac/**` and `_bmad-output/planning-artifacts/architecture.md`; where the two disagreed, the code won.

Companion file: `ARCHITECTURE-VISUAL.html` (same content, rendered with inline SVG diagrams — open that one for the visuals; this file keeps the same structure in text/ASCII form for diffing).

---

## 1. Big picture — what's actually running

VocaMac is a macOS menu-bar app (`MenuBarExtra`, no Dock icon). `AppState` (`Sources/VocaMac/Models/AppState.swift`) is a single `@MainActor` `ObservableObject` that owns every service instance and is the only thing that calls between them — services never call each other or call back into `AppState` except through closures.

```
                         ┌─────────────────────┐
                         │   MenuBarView /      │  Presentation (SwiftUI)
                         │   SettingsView /      │
                         │   HistoryView         │
                         └──────────┬───────────┘
                                    │ @EnvironmentObject
                                    ▼
                         ┌─────────────────────┐
                         │      AppState         │  Coordination (@MainActor)
                         │  (the only orchestrator)
                         └──┬───────┬────────┬──┘
             ┌──────────────┘       │        └───────────────┐
             ▼                      ▼                        ▼
  ┌───────────────────┐   ┌──────────────────┐    ┌─────────────────────┐
  │  HotKeyManager      │   │ AXContextReader   │    │ CommandModeCoordinator│
  │  (2 bindings:        │   │ (frontmost app +  │    │  (2nd route, AD-4)    │
  │   dictation, command)│   │  cursor context)   │    └─────────┬────────────┘
  └─────────┬───────────┘   └──────────────────┘              │
            ▼                                                  │
  ┌───────────────────┐                                        │
  │   AudioEngine        │  mic tap 48kHz → 16kHz mono           │
  │   + VoiceActivity-    │  Float32 (WhisperKit format)          │
  │   Detector (VAD/RMS)  │                                       │
  └─────────┬───────────┘                                        │
            ▼                                                    │
  ┌───────────────────┐                                          │
  │   WhisperService      │◄─────────────────────────────────────┘  (Command Mode
  │   → WhisperKit/CoreML │                                          transcribes the
  │   → Apple Neural Eng. │                                          spoken instruction
  └─────────┬───────────┘                                          the same way)
            ▼
  ┌─────────────────────────────────────────────────────────┐
  │              TranscriptPipeline (AD-1, AD-3, fixed order) │
  │   Dictionary → Snippet-protect → PostProcess → Rehydrate  │
  │                              │                             │
  │                              ▼                             │
  │                     ┌──────────────────┐                   │
  │                     │  LM Studio (ext.) │  http://localhost:1234
  │                     │  Qwen3-4B-Instruct │  OpenAI-compatible API
  │                     └──────────────────┘                   │
  └─────────────────────────────┬─────────────────────────────┘
                                 ▼
                       ┌───────────────────┐
                       │    TextInjector      │  AX direct insert, else
                       │  (AX / clipboard+⌘V)  │  clipboard + simulated ⌘V
                       └─────────┬───────────┘
                                 ▼
                       ┌───────────────────┐
                       │    HistoryStore       │  history.json (local, 0600)
                       └───────────────────┘

  Side systems (all reachable from AppState, all local JSON via JSONFileStore):
    ProfileManager / ProfileStore   → profiles.json      (bundle-id → Profile)
    DictionaryService / Store       → dictionary.json     (mis-transcription fixes)
    SnippetService / Store          → snippets.json       (cue → body expansion)
    CorrectionLearner / Dismissed…  → dismissed-corrections.json
    Settings (scalars)              → UserDefaults (.standard), not JSON
```

**What this shows:** everything left of `TranscriptPipeline` is unchanged legacy dictation (capture → transcribe); everything from `TranscriptPipeline` onward is where post-ASR features live. `PostProcessService` is the **only** node in the whole app that opens a network socket, and it only ever talks to `localhost:1234`. `CommandModeCoordinator` is a parallel, separate route — it shares `TextInjector`, `WhisperService`, and `PostProcessService` with the dictation path, but never touches `TranscriptPipeline` and never falls back the way dictation does (see §3).

---

## 2. Sequence — an ordinary dictation

```
User          HotKeyMgr      AppState         AXContextReader   AudioEngine        WhisperService/WhisperKit   Pipeline (4 stages)        LM Studio        TextInjector    HistoryStore
 │ hold key      │               │                  │                │                      │                        │                      │                │              │
 ├──────────────►│               │                  │                │                      │                        │                      │                │              │
 │               ├──onRecordingStart──►               │                │                      │                        │                      │                │              │
 │               │               ├──capture()───────►│  bundle id +   │                      │                        │                      │                │              │
 │               │               │◄─────────────────┤  cursor ctx*    │                      │                        │                      │                │              │
 │               │               ├──startRecording(vad:)─────────────►│  tap installed        │                      │                        │                      │                │              │
 │ speaks…       │               │                  │                │  (~instant, <50ms)     │                      │                        │                      │                │              │
 │               │               │                  │                │  48kHz tap → 16kHz     │                      │                        │                      │                │              │
 │               │               │                  │                │  mono via AVAudioConverter                    │                      │                        │                      │                │              │
 │               │               │                  │                │  VAD: EnergyVADDetector│                      │                        │                      │                │              │
 │               │               │                  │                │  100ms frames, RMS>0.006 = speech             │                      │                        │                      │                │              │
 │ release key   │               │                  │                │  (or legacy RMS detector, threshold 0.01)     │                      │                        │                      │                │              │
 ├──────────────►│               │                  │                │                      │                        │                      │                │              │
 │               ├──onRecordingStop──►               │                │                      │                        │                      │                │              │
 │               │               ├──stopRecording()──────────────────►│                       │                      │                        │                      │                │              │
 │               │               │◄────────────[Float] 16kHz mono──────┤                      │                        │                      │                │              │
 │               │               ├──transcribe(audio, language, vocab)────────────────────────►│  loads selected model  │                      │                        │                      │                │              │
 │               │               │                  │                │                      │  from ~/Library/Application Support/VocaMac/models/…               │                      │                │              │
 │               │               │                  │                │                      │  default: openai large-v3-v20240930_626MB          │                      │                │              │
 │               │               │                  │                │                      │  (or ivrit-ai_whisper-large-v3-turbo if user selected it)          │                      │                │              │
 │               │               │                  │                │                      │  runs via CoreML on the Neural Engine, ~0.3–2s typical for a short utterance │                      │                │              │
 │               │               │◄─────────────────────────────────────────VocaTranscription (raw text)──────────────┤                      │                        │                      │                │              │
 │               │               ├──pipeline.run(context)─────────────────────────────────────────────────────────────►│                      │                        │                      │                │              │
 │               │               │                  │                │                      │                        │  1. Dictionary: fixes recurring ASR errors, fuzzy match on Hebrew-normalized     │                │              │
 │               │               │                  │                │                      │                        │     forms, similarity > 0.8 (sub-ms; no-op if no entries) — identity if disabled│                │              │
 │               │               │                  │                │                      │                        │  2. Snippet-protect: matched Cues → ⟦S0⟧ placeholders (sub-ms; no-op if none)   │                │              │
 │               │               │                  │                │                      │                        ├──POST /v1/chat/completions (5s hard timeout)──►│                      │                │              │
 │               │               │                  │                │                      │                        │  3. PostProcess: Qwen3-4B cleans filler words, self-corrections, punctuation    │                │              │
 │               │               │                  │                │                      │                        │◄─────────────cleaned text (or timeout/refusal → identity)──────┤                │              │
 │               │               │                  │                │                      │                        │  4. Rehydrate: ⟦S0⟧ → real Snippet body; if a placeholder is missing/duplicated,│                │              │
 │               │               │                  │                │                      │                        │     the WHOLE PostProcess result is discarded, falls back to pre-LLM text        │                │              │
 │               │               │◄─────────────────────────────────────────────────────────────────────Final Text + [StageOutcome] + didFallback───────────────────┤                      │                │              │
 │               │               ├──inject(finalText, preserveClipboard)──────────────────────────────────────────────────────────────────────────────────────────────►│              │
 │               │               │                  │                │                      │                        │                      │                │  Strategy 1: AX direct insert (no clipboard)
 │               │               │                  │                │                      │                        │                      │                │  Strategy 2: clipboard + simulated ⌘V, restored ~50ms later
 │               │               ├──record(raw, final, model, asrMillis, postProcessMillis, didFallback)──────────────────────────────────────────────────────────────────────────►│
 │ sees text     │               │                  │                │                      │                        │                      │                │              │
```
`*` Cursor context is only captured when both the global toggle and the resolved Profile's own toggle allow it (both default **off**), and it is dropped from memory the instant `PostProcessStage` has read it — never written to `HistoryStore`.

**Timing, order of magnitude (not measured benchmarks — actual per-dictation numbers are recorded in `HistoryRecord.asrMillis` / `postProcessMillis`):**

| Stage | Typical order of magnitude | Hard ceiling |
| --- | --- | --- |
| Audio tap start | tens of ms | — |
| ASR (WhisperKit/CoreML, Neural Engine, short utterance) | ~0.3–2s depending on model size | — (bounded by `maxRecordingDuration`, default 180s, on the input side) |
| Dictionary / Snippet-protect / Rehydrate | sub-millisecond | — |
| PostProcess (LM Studio round trip) | ~0.3–2s typical on a warm local server | **5s hard timeout** (`URLSession` timeout + outer `Task` deadline), configurable |
| Text injection | near-instant (AX) or ~50–100ms (clipboard settle + restore) | — |

**Identity-fallback, concretely:** with post-processing off (its shipped default) and no Dictionary entries/Snippets defined, this entire pipeline is a no-op — the raw ASR transcript is what gets injected, byte for byte (`AD-2`, tested by `AD-13`). Turning post-processing on does not remove that guarantee: any failure mode (LM Studio unreachable, non-2xx, bad JSON, empty/disproportionate output, timeout) makes `PostProcessStage` return the *input text unchanged* — the user never sees an error dialog, only the raw transcript instead of the cleaned one.

---

## 3. Sequence — Command Mode (select → speak an instruction → rewrite)

Command Mode is **not** part of `TranscriptPipeline`. It is its own coordinator (`CommandModeCoordinator`) with the opposite failure philosophy: dictation always falls back to *something safe* (the raw transcript); Command Mode's "safe fallback" would be pasting the spoken instruction itself over the user's selected text — which is destructive — so instead **any failure aborts and changes nothing** (AD-4).

```
User                    HotKeyMgr           CommandModeCoordinator      TextInjector (AX)     WhisperService      PostProcessService/LM Studio
 │ select some text        │                       │                        │                    │                     │
 │ press 2nd hotkey         │                       │                        │                    │                     │
 ├─────────────────────────►│                       │                        │                    │                     │
 │                          ├──onCommandStart───────►│                        │                    │                     │
 │                          │                       ├──captureSelection()───►│                     │                     │
 │                          │                       │                        │  reads AX selection │                     │
 │                          │                       │◄──── no selection ─────┤                     │                     │
 │                          │                       │  ABORT — nothing changed. Error sound. (exit 1: no selection / not trusted)
 │                          │                       │◄──── selection text ───┤                     │                     │
 │ speaks instruction        │                       │  (captured once, at gesture start — not      │                     │
 │ release key                │                       │   re-read later, same reasoning as AD-5)     │                     │
 ├─────────────────────────►│                       │                        │                    │                     │
 │                          ├──onCommandStop────────►│                        │                    │                     │
 │                          │                       ├──transcribe(instruction audio)───────────────►│                     │
 │                          │                       │◄─────── instruction text ─────────────────────┤                     │
 │                          │                       │  empty instruction? ABORT — nothing changed. (exit 2: silence/no speech)
 │                          │                       ├──command(selection, instruction, systemPrompt)──────────────────────►│
 │                          │                       │                        │                    │   separate system prompt
 │                          │                       │                        │                    │   from cleanup — Command
 │                          │                       │                        │                    │   Mode's LLM call is
 │                          │                       │                        │                    │   validated by a
 │                          │                       │                        │                    │   DIFFERENT validator:
 │                          │                       │                        │                    │   length band + instruction-
 │                          │                       │                        │                    │   echo guard + verbatim-
 │                          │                       │                        │                    │   repeat guard
 │                          │                       │◄──────────── LLM unreachable / timeout / bad answer ─────────────────┤
 │                          │                       │  ABORT — nothing changed. Error sound. (exit 3: LLM failure)
 │                          │                       │◄──────────── rewritten text ───────────────────────────────────────┤
 │                          │                       │  rewritten == selection? ABORT — nothing changed. (exit 4: model
 │                          │                       │                                                    declined / no-op)
 │                          │                       ├──replaceSelection(rewritten, replacing: snapshot)─►│                │
 │                          │                       │                        │  re-verifies focus/range/text still match  │
 │                          │                       │◄──── write refused (selection moved/changed) ──────┤                │
 │                          │                       │  ABORT — nothing changed. (exit 5: target changed under us)
 │                          │                       │◄──── write unverified (could not confirm) ──────────┤                │
 │                          │                       │  "may have changed — check it" (exit 6: the one case that is NOT a
 │                          │                       │                                        clean no-op — see note below)
 │                          │                       │◄──── write confirmed ────────────────────────────────┤                │
 │ sees rewritten selection  │                       │  SUCCESS                │                    │                     │
```

**Every abort path, in one table:**

| Exit | Trigger | Result |
| --- | --- | --- |
| No selection | Nothing selected, or Accessibility permission missing | Abort before the mic ever opens. Error sound. |
| Empty instruction | Silence / nothing transcribed from the spoken instruction | Abort. Error sound. |
| LLM failure | LM Studio unreachable, non-2xx, timeout (same 5s-class deadline), or fails Command Mode's own validator | Abort. Error sound. Selection untouched. |
| Unchanged | Model returns the selection verbatim (declined to apply the instruction) | Abort — writing it would dirty the undo stack for no visible change. |
| Write refused | `TextInjector` re-checks focus/selection range/text at write time and they no longer match the snapshot | Abort. Selection untouched. |
| Write unverified | The edit was sent but VocaMac could not confirm it landed | **Only case that is not a guaranteed no-op** — the user is told the selection may have changed and to check it. |
| Abandoned mid-flight | A force-recovery, device change, or new gesture happened while the LLM call was in flight | The stale result is discarded rather than written into whatever the user has since selected/opened. |

The selected text itself is held only in memory for the length of one operation (`CommandModeCoordinator.snapshot`), is never logged beyond its character count, and there is no field on `HistoryRecord` capable of holding it or the rewrite (AD-5 applied to Command Mode).

---

## 4. The models — what's on disk, what's in LM Studio

| Model | Size | Where it lives | Runs on | Used for | Default? |
| --- | --- | --- | --- | --- | --- |
| **ivrit.ai whisper-large-v3-turbo** | ~1.5 GB | `~/Library/Application Support/VocaMac/models/argmaxinc/whisperkit-coreml/ivrit-ai_whisper-large-v3-turbo/` — **side-loaded by the user**, never downloaded by the app | CoreML via WhisperKit → Apple Neural Engine | ASR, Hebrew-tuned | No — selectable in Settings once the files are present on disk |
| **openai whisper-large-v3 (compact)** | 626 MB (`large-v3-v20240930_626MB`) | Same models directory, `openai_whisper-large-v3-v20240930_626MB/` — downloaded automatically through WhisperKit's HuggingFace pipeline | CoreML via WhisperKit → Apple Neural Engine | ASR, general fallback/legacy | **Yes** — `AppState.selectedModelSize` defaults to this exact model |
| **Qwen3-4B-Instruct (MLX, 4-bit)** | ~2.28 GB | Inside **LM Studio**, entirely external/user-managed — not bundled with or downloaded by VocaMac | Apple Silicon GPU/ANE via MLX, served by LM Studio | Transcript cleanup (`PostProcessStage`) and Command Mode rewrites | Yes, as the only backend VocaMac talks to by default (`http://localhost:1234`, model id `qwen3-4b-instruct-2507-mlx`) |

**Why the ivrit.ai model needs manual placement:** WhisperKit's own `recommendedModels()` API can never endorse a model it doesn't know about, so VocaMac's `ModelManager.isModelSupported(_:)` special-cases this one entry (`ModelSize.isSideloadOnly`) to report support based on **on-disk presence of the tokenizer files** instead of WhisperKit's endorsement (AD-11). No download button is ever shown for it; the user places the model folder there themselves, and the model then appears as a normal, loadable entry in the picker.

**RAM footprint (approximate, at inference time):** the compact 626 MB ASR model needs roughly 5 GB resident; the ivrit.ai model roughly 6 GB. Qwen3-4B in LM Studio is a separate process with its own footprint (a 4-bit 4B model is typically several GB resident). The architecture notes flag running the LLM and a large ASR model concurrently as a real memory-pressure risk on a 24 GB Mac (Risk R-7) — the app does not run ASR and LLM inference at the same instant, but both stay resident.

---

## 5. Privacy and data flow

```
 ┌───────────────────────────────┐   ┌───────────────────────────────┐   ┌───────────────────────────┐
 │  TOUCHES DISK (local only)      │   │  NEVER PERSISTED                │   │  NETWORK                     │
 │  ─────────────────────────      │   │  ─────────────────────          │   │  ───────                      │
 │  history.json                    │   │  Cursor context (text around    │   │  Loopback ONLY:                │
 │  profiles.json                   │   │  the caret, read via AX)         │   │  http://localhost:1234         │
 │  dictionary.json                 │   │                                   │   │  → LM Studio (Qwen3-4B)         │
 │  snippets.json                   │   │  Command Mode's selected text     │   │                                 │
 │  dismissed-corrections.json      │   │  (held only for one operation)     │   │  Nothing else in the app         │
 │  All under JSONFileStore:         │   │                                   │   │  opens a socket. No telemetry,   │
 │   • atomic write                 │   │  Both are dropped from memory     │   │  no crash reporting, no update   │
 │   • 0600 file perms (owner-only)  │   │  the instant the one stage/       │   │  check that leaves localhost    │
 │   • .utility background queue     │   │  operation that needed them        │   │  except the explicit, user-      │
 │                                    │   │  has consumed them — never         │   │  visible update checker (a       │
 │  Settings (scalars) via            │   │  written to History, never          │   │  separate, user-initiated path).  │
 │  UserDefaults, not JSON            │   │  logged at any level               │   │                                 │
 │                                    │   │                                    │   │                                 │
 │  App logs (VocaLogger) —           │   │  Correction-learning re-reads a    │   │                                 │
 │  never contain transcript bodies   │   │  focused field once per injection  │   │                                 │
 │  or cursor context at any level    │   │  and only extracts a two-word      │   │                                 │
 │                                    │   │  candidate the user must confirm   │   │                                 │
 └───────────────────────────────┘   └───────────────────────────────┘   └───────────────────────────┘
```

**The load-bearing rule underneath this (AD-5):** cursor context and Command Mode's selection are both captured once, at the moment an action begins, carried on an in-memory value type for exactly the one operation that needs them, and explicitly cleared on **every** exit path — success, failure, timeout, force-recovery, device change, or a superseding new gesture. Neither ever has a field to be written into on `HistoryRecord`. Both privacy-sensitive toggles (global cursor-context capture, correction learning) ship **off by default**.

**What does get written to History:** the raw ASR transcript, the final (post-pipeline) text, which app it targeted, which Profile resolved, which model transcribed it, per-stage timings, and whether any stage had to fall back. Command Mode writes nothing to History at all — by design, since there is no field capable of holding a selection or a rewrite safely.

**Network, precisely:** the only HTTP client in the entire codebase is `PostProcessService`, and its only configured endpoint is `http://localhost:1234` (user-editable, but defaults to — and is only ever exercised against — the local LM Studio server). Every request carries an explicit timeout. There is no cloud fallback, no secondary backend wired up, and no telemetry.

---

## Where to look in the code

| Concern | File |
| --- | --- |
| Orchestration, recording lifecycle, the one pipeline seam | `Sources/VocaMac/Models/AppState.swift` |
| Pipeline runner + identity guarantee | `Sources/VocaMac/Pipeline/TranscriptPipeline.swift`, `TranscriptContext.swift` |
| The four stages | `Sources/VocaMac/Pipeline/Stages/*.swift` |
| Mic capture, 48kHz→16kHz conversion, VAD wiring | `Sources/VocaMac/Services/AudioEngine.swift` |
| VAD implementations | `Sources/VocaMac/Services/VoiceActivityDetector.swift` |
| ASR / WhisperKit boundary | `Sources/VocaMac/Services/WhisperService.swift` |
| Model catalog, sideload bypass, on-disk paths | `Sources/VocaMac/Models/WhisperModel.swift`, `Sources/VocaMac/Services/ModelManager.swift` |
| LLM client, validators, prompts | `Sources/VocaMac/Services/PostProcessService.swift`, `Sources/VocaMac/Models/Prompts.swift` |
| Command Mode | `Sources/VocaMac/Services/CommandModeCoordinator.swift` |
| Text injection strategies | `Sources/VocaMac/Services/TextInjector.swift` |
| Cursor context capture | `Sources/VocaMac/Services/AXContextReader.swift` |
| Persistence | `Sources/VocaMac/Stores/*.swift` |
| Architecture invariants (AD-1…AD-13) | `_bmad-output/planning-artifacts/architecture.md` |
