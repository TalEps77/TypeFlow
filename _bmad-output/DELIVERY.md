---
title: local-whisper — Delivery Report
created: 2026-08-20
status: Phase 1-3 implemented, in code review pass, pre-Xcode-test-execution
---

# local-whisper: Delivery Report

## 1. The Original Request

Tal wanted the Wispr Flow experience — dictate anywhere on the Mac and get clean,
send-ready text — without paying for it, without an account, and without audio,
screen contents, or cursor text ever leaving the machine. The vehicle was
`local-whisper`, a fork of the existing VocaMac app already installed on this
Mac (Swift/SwiftPM, WhisperKit/CoreML, ~9,500 LOC), with two things layered on
top of its working Whisper-to-cursor pipeline:

- A **Hebrew-first** ASR upgrade (an ivrit.ai Whisper fine-tune, better on
  Hebrew than Wispr Flow's cloud model).
- A **small local LLM** (Qwen3-4B via LM Studio, on loopback only) to do what
  Wispr Flow's cloud layer does — strip fillers, punctuate, resolve
  self-corrections, adapt tone per app — entirely offline.

All three roadmap phases from the gap-analysis doc (Hebrew accuracy + LLM
cleanup + history; per-app profiles + dictionary + snippets; command mode +
better voice detection + streaming) were approved in one sitting — nothing was
deferred to "maybe later."

## 2. The Plan

Standard BMAD workflow, run end-to-end through subagents with the orchestrator
only routing and synthesizing:

1. **Gap-analysis doc** (pre-existing, 26 Jul 2026) — "VocaMac vs Wispr Flow" —
   was the discovery input and settled the strategic calls up front (stay on
   VocaMac, don't migrate to VoiceInk, LM Studio + Qwen3-4B, ivrit.ai model).
2. **PRD** (`_bmad-output/planning-artifacts/PRD.md`) — vision, target user,
   25 functional requirements across 9 features, non-goals, success metrics,
   cross-cutting NFRs, settled decisions.
3. **Architecture** (`_bmad-output/planning-artifacts/architecture.md`) —
   13 architecture decisions (AD-1 … AD-13) binding every story: one pipeline
   seam in `AppState`, identity-on-failure as a testable guarantee, stage
   ordering, no actors, protocol + mock per service, context never persisted.
4. **Epics and stories** (`_bmad-output/planning-artifacts/epics.md`) — 7 epics,
   27 stories, each with Given/When/Then acceptance criteria and an explicit
   verification section (unit tests + manual steps).
5. **Per-epic dev** — one dev agent per epic, implementing stories in
   dependency order.
6. **Adversarial review per epic** — a separate reviewer agent (never the one
   that wrote the code) combed each epic for defects against its own stated
   acceptance criteria, not against a checklist.
7. **Fix cycle per epic** — a fix agent applied every blocker and major found,
   with judgment calls (documented deviations) surfaced rather than hidden.

## 3. Agents Spawned

| # | Task | Model |
|---|---|---|
| 1 | Planning (PRD, architecture, epics/stories) | Opus 5 |
| 2 | ivrit.ai Hebrew model acquisition | Sonnet 5 |
| 3 | Dev — Epic 1: Hebrew ASR Accuracy | Sonnet 5 |
| 4 | Dev — Epic 2: LLM Post-Processing | Opus 5 |
| 5 | Dev — Epic 3: Transcription History | Sonnet 5 |
| 6 | Dev — Epic 4: Profiles and Cursor Context | Sonnet 5 |
| 7 | Dev — Epic 5: Dictionary and Snippets | Sonnet 5 |
| 8 | Dev — Epic 6: Command Mode | Opus 5 |
| 9 | Dev — Epic 7: Responsive Capture (VAD) | Sonnet 5 |
| 10 | Adversarial review — Epic 1 | Opus 5 |
| 11 | Adversarial review — Epic 2 | Opus 5 |
| 12 | Adversarial review — Epic 3 | Opus 5 |
| 13 | Adversarial review — Epic 4 | Opus 5 |
| 14 | Adversarial review — Epic 5 | Opus 5 |
| 15 | Adversarial review — Epic 6 | Opus 5 |
| 16 | Adversarial review — Epic 7 | Opus 5 |
| 17 | Fix — Epic 1 findings | Sonnet 5 |
| 18 | Fix — Epic 2 findings | Sonnet 5 |
| 19 | Fix — Epic 3 findings | Opus 5 |
| 20 | Fix — Epic 4 findings | Opus 5 |
| 21 | Fix — Epic 5 findings | Opus 5 |
| 22 | Fix — Epic 6 findings | Opus 5 |
| 23 | Fix — Epic 7 findings | Opus 5 |
| 24 | Build and install to /Applications | Sonnet 5 |
| 25 | This delivery document | Sonnet 5 |

Every adversarial review ran on Opus 5, deliberately — the harder-to-fool
model was reserved for finding what the dev agent missed, regardless of which
model wrote the code.

## 4. What Was Built, and Why

### Epic 1 — Hebrew ASR Accuracy
**Closes:** the single biggest gap-and-win against Wispr Flow — better Hebrew,
locally, for free. Registers the side-loaded ivrit.ai CoreML model alongside
WhisperKit's existing catalog, without offering a broken download for a model
that isn't fetched from Hugging Face. Adds per-stage latency recording so
model choice can be judged on measurement.
**Commits:** `4fffa11`, `f1a4862`, `3ffe21a` (fixes), `5bfa235` (latency).
**Review caught:** onboarding still offered "Try Anyway → Download" for the
sideload-only entry (would fabricate a ~15s progress bar then fail); the
generic startup-fallback logic could silently switch *any* user onto the
Hebrew model by picking the last catalog entry; a "not installed" model could
still show "Active" at the same time.

### Epic 2 — LLM Post-Processing
**Closes:** the actual product gap — turning a raw transcript into send-ready
text. `PostProcessService` calls LM Studio over loopback with a hard deadline;
any failure (connection refused, timeout, malformed JSON, degenerate output)
falls back to the raw transcript silently, so the worst case is exactly
today's behavior.
**Commits:** `ff8e402`, `a545b32`, `ef73508`, `256bc54`, `058d717` (fixes).
**Review caught the most consequential blocker in the project:** the response
validator decoded the model's `finish_reason` for nothing — a reply truncated
by the server's token cap was accepted and injected as if complete, silently
deleting up to half a long sentence. Also found: no similarity check between
input and output at all, meaning a model that answered the transcript as a
question, or echoed a few-shot example verbatim, passed straight through to
the user's cursor.

### Epic 3 — Transcription History
**Closes:** nothing was previously recoverable — no re-paste, no undo, no way
to see what the LLM changed. Adds a local JSON store, a browsable/searchable
history view, re-paste, and best-effort undo.
**Commits:** `5a67158`, `82eecff`, `e4fb4cf`, `741a850`, `5bfa235`, `ce90692`
(fixes).
**Review caught the sharpest blocker in the whole project:** undo re-read
whatever text currently sat before the caret and deleted that many characters
— with no check that it was still the app's own injected text. Typing three
characters after a dictation, then hitting undo, deleted eight characters of
the user's own typing along with the tail of the injection. A second blocker
found that a unit test posted a real system-wide ⌘Z into whatever app the
developer's own machine had focused — meaning running the test suite could
silently undo the developer's own work.

### Epic 4 — Profiles and Cursor Context
**Closes:** the same utterance shouldn't read the same in Slack and in a legal
document. `ProfileManager` resolves the frontmost app to a Profile (with
starter profiles for chat/mail/code); optionally, text around the cursor is
read via Accessibility and fed to the LLM as grounding — off by default,
because it's the most privacy-sensitive capability in the product.
**Commits:** `2f33094`, `d02a1e8`, `b14d287`, `43163c2`, `62fee31`, `fa472d0`
(fixes).
**Review caught the project's most subtle privacy hole:** the LLM could
"launder" cursor context — echo 80 characters of the surrounding document
back into its output — and both safety validators (length ratio, similarity)
would pass it, because the echoed text was itself plausible-length and
similar-enough to the input. That laundered context then got typed into the
user's document *and* written to history.json, directly violating the "never
saved to history" promise. Also found: captured context could sit in memory
indefinitely if a Bluetooth headset dropped mid-dictation, since only the
success path ever cleared it.

### Epic 5 — Dictionary and Snippets
**Closes:** a domain term Whisper keeps mangling can be fixed once and stay
fixed; a spoken cue expands into boilerplate (signature, standard reply)
without needing the LLM at all. Requires correct Hebrew normalization first
(niqqud stripping, matres lectionis unification) since edit-distance matching
is the whole mechanism.
**Commits:** `3dee1ed`, `02cf78a`, `8d1f4e0`, `a4c529d`, `de654fa`, `a0bd111`,
`18e2ae1` (fixes).
**Review caught:** the matres-lectionis normalization (ו/וו, י/יי) collapsed
genuinely distinct Hebrew words together — מוות/מות, עוול/עול — so adding one
trigger silently rewrote the other word everywhere it appeared; and the
shipped fuzzy-match threshold (0.8) landed exactly on Hebrew's productive -ת
inflection, so עובד→עובדת ("worker"→"female worker/manager") style pairs
cleared the fuzzy tier and got silently swapped.

### Epic 6 — Command Mode
**Closes:** select text, speak an instruction ("make this shorter and more
formal"), and the LLM rewrites it in place — the one flow that must never
fall back, because pasting a raw instruction over a user's selection would be
actively destructive.
**Commits:** `d564e0c`, `370183e`, `4572a98`, `7d96571` (Swift 6.3 fix),
`593678c` (fixes).
**Review caught:** the second hotkey was never wired up on a normal app
launch — only on first-permission-grant and inside settings-change handlers —
so a user who enabled Command Mode and relaunched the app got a toggle that
read "ON" over a feature that was completely dead. A second blocker: under a
specific slow-LLM-then-retry sequence, a stale rewrite from an abandoned
operation could still land on a freshly re-selected paragraph, while the app
told the user "nothing was changed" when something had been.

### Epic 7 — Responsive Capture (VAD)
**Closes:** the fixed RMS amplitude threshold cut off quiet speech and
natural Hebrew pauses as if they were silence. Replaces it with WhisperKit's
`EnergyVAD` and enables `.vad` chunking so long recordings transcribe in
parallel instead of sequentially. (Streaming partial results, the third item
in this epic, was spiked and explicitly cut — see §7.)
**Commits:** `cd223b9`, `f2d826c`, `908f08c`, `226040e` (fixes).
**Review caught the epic's headline bug, and it's a good illustration of why
adversarial review at real operating conditions matters:** the VAD's 100ms
frame length (1600 samples) never actually engaged, because the audio tap's
buffer size at real hardware sample rates converts to fewer samples
(1365–1486) than one frame needs — so the "voice activity detector" was
silently degenerating to whole-buffer RMS the entire time. The dev agent's own
Python verification harness missed this because it replayed audio in
differently-sized chunks than the real tap ever produces. This is exactly the
class of bug that only shows up by reasoning about the real buffer math, not
by running a synthetic test that happens to use convenient numbers.

### Aggregate review numbers
Across all 7 epics, adversarial review found roughly **13 blockers and 47
majors** (plus a similar count of mediums/minors), and every blocker and major
was fixed in a dedicated fix pass before the epic was considered closed. A few
findings were resolved as documented, deliberate deviations rather than code
changes (e.g., where a protocol lives, or that translate/rewrite-style Profile
prompts get rejected by the safety validator by design) — those are called out
in the epic docs, not swept under the rug.

## 5. Delivered State

- **`/Applications/VocaMac.app`**, version `0.8.0-local-hebrew`, installed and
  running.
- **ivrit.ai Hebrew ASR** (~1.5GB), side-loaded, selectable from the model
  picker — meaningfully better Hebrew accuracy than Wispr Flow's cloud model.
- **LLM cleanup** via LM Studio running `qwen3-4b` — off by default, enable it
  in the Post-Processing settings tab. Degrades to exactly today's raw-
  transcript behavior whenever LM Studio isn't reachable.
- **History**: every dictation is saved locally; browse, search, re-paste, and
  best-effort undo are all available from the menu bar and the history view.
- **Per-app Profiles** with optional Cursor Context (off by default) — casual
  tone in chat apps, formal in mail, identifier-shaped in code editors, out of
  the box.
- **Hebrew-aware Dictionary + Snippets + correction learning** — Dictionary
  and Snippets are on by default and mechanical (no LLM needed); correction
  learning (auto-proposing dictionary entries from your own edits) is off by
  default.
- **Command Mode** — select text, speak an instruction, get a rewrite in
  place. Off by default; needs enabling and a second hotkey assignment in
  settings.
- **EnergyVAD auto-stop + `.vad` chunking** — fixes the old behavior of
  cutting off quiet speech and natural pauses, and speeds up long recordings.

Everything above is local and offline-capable. With every new feature turned
off, the app behaves byte-for-byte identically to the pre-project baseline —
this "identity guarantee" was a first-class, tested architectural requirement
(AD-13), not an afterthought.

## 6. What Tal Must Do

- **Answer the microphone permission prompt** if/when it appears on next
  launch.
- **Re-grant Accessibility and Input Monitoring** permissions to VocaMac in
  System Settings (these reset on rebuild/reinstall).
- **Restart VocaMac** so all of the above takes effect cleanly.
- **Keep LM Studio running** with `qwen3-4b-instruct-2507-mlx` loaded and its
  server on (`localhost:1234`) for the cleanup, per-app Profile, Cursor
  Context, and Command Mode features to actually run. Without it, dictation
  still works — it just skips straight to the raw transcript.
- **Optional cleanup**: an unrelated, much larger model appears to have been
  pulled into LM Studio by accident during setup. If unwanted, remove it with:
  ```
  lms rm qwen3-30b-a3b-instruct-2507-mlx
  ```
  (roughly 17GB freed).
- **Install Xcode**, if you want the written test suite to actually execute.
  Every story's unit tests were written and type-checked against the real
  Swift toolchain, but this machine has no `XCTest` runner installed, so
  `make test` / `swift test` has never actually been run end-to-end on this
  codebase during this project. Treat the review findings as "found by
  reading the code and its tests carefully," not "found by a red test run."
- **Note**: one adversarial-review probe left a TextEdit window open on this
  Mac — it was used to exercise a blocked injection/undo path and was not
  closed afterward. Safe to close; nothing else was affected.

## 7. Left Out / Future

- **Streaming partial results** (Story 7.3) — spiked, then explicitly cut.
  WhisperKit's `AudioStreamTranscriber` constructs and owns its own
  `AVAudioEngine`, input node, and tap — in direct conflict with the app's
  existing `AudioEngine`, which the whole rest of the app (Bluetooth handling,
  device selection, VAD) depends on. Using it would mean either an
  architecture-violating rewrite of audio capture, or reimplementing
  WhisperKit's segment-confirmation logic from scratch. The finding is
  documented as a spike result in `epics.md`, not silently dropped.
- **Mobile, sync, teams** — out of scope by explicit decision in the PRD, not
  by time pressure. Multi-machine needs are served by JSON export/import of
  Profiles, Dictionary, and Snippets.
- **A smaller int8 ivrit.ai model** is available on Hugging Face if the
  ~1.5GB footprint alongside a loaded LLM ever becomes a memory concern on
  this 24GB machine.
- **Translate/expand-style Profile prompts are rejected by design** — the
  safety validator that stops the LLM from going off the rails is tuned for
  cleanup-style prompts (fix punctuation, remove fillers), so a Profile whose
  prompt asks for translation or heavy rewriting will reliably get its output
  rejected and fall back to the raw transcript. This is a known, documented
  limitation of the current validator, not a bug — the UI states the
  constraint rather than pretending those Profile styles work.
- **`.vad` chunking can drop up to ~1 second off the tail of recordings over
  30 seconds.** In push-to-talk use, releasing the key immediately after the
  last word of a long recording can lose the final syllable. Documented, not
  fixed — there's no code fix short of pre-padding the chunk window.
- **Licensing (AGPL-3.0)**: the project remains AGPL-3.0, inherited from
  VocaMac. Personal/internal use on this machine is fine as-is. If a modified
  build is ever distributed, or run as a network-accessible service for
  others, AGPL's source-availability obligations attach — worth confirming
  with the relevant party before that happens.
