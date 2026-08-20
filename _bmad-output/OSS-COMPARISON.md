# local-whisper (VocaMac fork) vs. Open-Source Dictation Alternatives

Research date: 2026-08-20. Sources: GitHub READMEs, `gh api`/`gh repo view` stats, and this repo's own `_bmad-output/DELIVERY.md`, `LICENSE`, `README.md`, and `Sources/` tree.

---

## 0. Our app, restated for comparison

**local-whisper** — Swift/SwiftUI, SwiftPM, ~9,500+ LOC base (now larger post-fork), menu-bar only, arm64 macOS 13+, Apple Silicon required (ANE via CoreML/WhisperKit).

- **ASR:** WhisperKit + a side-loaded **ivrit.ai** Hebrew large-v3-turbo CoreML fine-tune, fully local, plus WhisperKit's stock multilingual catalog.
- **LLM post-processing:** Qwen3-4B via **LM Studio** over loopback only, hard deadline, validated against truncation (`finish_reason`) and echo/laundering (similarity + length-ratio checks), silent fallback to raw transcript on any failure.
- **Hebrew:** first-class — dedicated ASR fine-tune, plus Hebrew-aware fuzzy dictionary matching (niqqud stripping, matres lectionis normalization, edit-distance tuned around Hebrew inflection).
- **Feature set:** per-app Profiles (chat/mail/code presets) + optional Accessibility cursor-context grounding (off by default, privacy-gated); Dictionary + Snippets + correction learning; Command Mode (select text, speak an instruction, LLM rewrites in place, never falls back to raw injection); History with search/re-paste/best-effort undo; EnergyVAD auto-stop + `.vad` parallel chunking.
- **Maturity:** 233 commits, single-operator project, built via a formal BMAD process — PRD → architecture (13 ADs) → 27 stories across 7 epics → **per-epic adversarial review by a separate reviewer agent** (≈13 blockers + 47 majors found and fixed) → fix cycle. Not "vibe coded" — reviewed against its own stated acceptance criteria, with real bugs caught (truncation-acceptance, undo deleting user's own typing, context-laundering into history, dead second hotkey, VAD frame-length math never actually engaging).
- **License:** AGPL-3.0 (inherited from upstream VocaMac/jatinkrmalik). Personal/local use only — no distribution obligations yet, but any distributed or network-served build must open its source.

---

## 1. Comparison table

| | **Ours (local-whisper)** | **VoiceInk** | **Knuckles92/OpenWhisper** | **Rajvardhman05/openwhisper-app** | **Handy** | **FluidVoice** |
|---|---|---|---|---|---|---|
| Platform | macOS (arm64 only) | macOS 14.4+ | Windows/macOS/Linux | macOS 14+ (Apple Silicon) | Cross-platform (Tauri) | macOS + Windows |
| Stack | Swift/SwiftUI, SwiftPM | Swift/SwiftUI | Python 3.11-3.12, PyQt6 | Swift 5.10/SwiftUI, SwiftPM | Rust + React (Tauri) | Native Swift |
| ASR engine | WhisperKit (CoreML/ANE) + ivrit.ai Hebrew fine-tune | whisper.cpp + Parakeet + Cohere Transcribe + cloud (AssemblyAI/Cartesia) + Apple Speech | faster-whisper (local, CTranslate2) + OpenAI API/GPT-4o (cloud) | WhisperKit (CoreML/ANE), fully on-device | whisper.cpp, offline | Multi-engine: Nemotron, Parakeet, Cohere, Apple Speech, Whisper |
| Local ASR? | Yes, always | Yes (whisper.cpp/Parakeet default) + optional cloud | Yes (faster-whisper) + optional cloud | Yes, always | Yes | Yes + optional cloud |
| LLM post-processing | Qwen3-4B via LM Studio, local-only, hardened (truncation + echo/laundering guards) | "Smart Modes" + AI Assistant + "VoiceInk Refine" (on-device) + multiple cloud LLM providers | None | Optional **Ollama** cleanup (filler removal, grammar/punctuation), local-only | Unconfirmed | Own "Fluid Intelligence" local LLM + OpenAI/Groq cloud |
| Hebrew support | **First-class**: dedicated ASR fine-tune + Hebrew-normalized fuzzy dictionary | Not mentioned anywhere; no RTL handling documented | Not mentioned | **Yes** — Hebrew explicitly listed among 29 supported languages | Unknown | Not mentioned |
| Per-app profiles/context | Yes (Profiles + optional cursor-context grounding) | Yes ("Smart Modes" + screen-context awareness) | No | No | Unknown | Unknown |
| Dictionary/vocabulary | Yes, Hebrew-aware fuzzy matching | Yes (personal dictionary/text replacements) | No | No | Unknown | Unknown |
| Snippets | Yes | Not confirmed | No | No | Unknown | Unknown |
| Command Mode (voice rewrite of selection) | Yes, hardened against stale/abandoned rewrites | Not confirmed | No | No | Unknown | Unknown |
| History/undo | Yes, with a validated "is this still our injected text" guard on undo | Not confirmed from docs | Yes (history + retranscribe, no undo) | No | Unknown | Unknown |
| VAD | EnergyVAD (fixed frame-length bug found and fixed) + `.vad` chunking | Unconfirmed | Not documented | Not documented | Unknown | Unknown |
| License | **AGPL-3.0** | GPLv3 claimed (GitHub API shows `NOASSERTION`/"other" — unresolved); PRs currently closed | MIT | MIT | MIT | GPLv3 (relicensed from Apache-2.0, Feb 2026) |
| Stars | n/a (private) | ~6,000 | 158 | 10 | ~30,000 | ~10,700 |
| Commits | 233 (this fork alone) | Very active, daily | 297 | 11 | Very active | Very active |
| Contributors | 1 (+ agent-driven dev) | 38 | 4 | 1 | Many | Many |
| Last activity | 2026-08-20 (today) | 2026-08-12 (v2.11) | 2026-08-20 (today) | 2026-07-12 (~5 weeks quiet) | Within a day | Daily |
| Adversarial/independent review | Yes — formal per-epic review, ~13 blockers/47 majors found & fixed | Unknown/not documented | Unknown | Unknown (single dev, no CI/tests visible in top-level tree) | Unknown | Unknown |

---

## 2. Per-project notes

### VoiceInk (github.com/Beingpax/VoiceInk) — re-check since July 2026

- **Correction to the July assessment:** VoiceInk is **whisper.cpp**-based, not WhisperKit-based as previously recorded. It has since become multi-engine (added Parakeet via FluidAudio, Cohere Transcribe, plus AssemblyAI/Cartesia cloud options, Apple Speech fallback).
- LLM layer expanded a lot: "Smart Modes" (per-context writing-style presets), a built-in conversational AI Assistant, screen-content context awareness, and — new in v2.11 (12 Aug 2026) — **"VoiceInk Refine,"** an on-device enhancement path (previously cloud-LLM-only for the AI features).
- **Still no Hebrew support** anywhere — not in the supported-language list, not in recent localization additions (German/Simplified Chinese UI only), no RTL handling.
- **License status is murkier than "GPLv3"**: the LICENSE file says GPLv3 but GitHub's own license detector returns `NOASSERTION`/"other" — worth treating as unresolved rather than confirmed-copyleft. The repo has also stopped accepting external PRs — a governance tightening, not full closed-sourcing, but a step away from community-driven.
- Maturity: ~6,000 stars, 866 forks, 38 contributors, 114 open issues, active same-day commits. Still the most feature-rich OSS competitor by raw surface area, but Hebrew is a hard gap for Tal's use case regardless of feature breadth.

### Knuckles92/OpenWhisper

- Python/PyQt6, cross-platform (Windows/macOS/Linux), local ASR via `faster-whisper` + optional OpenAI API/GPT-4o cloud fallback. No LLM cleanup layer at all — pure STT.
- No Hebrew-specific support documented (relies on whatever faster-whisper/Whisper's underlying multilingual models provide, uncalled-out).
- 158 stars, 297 commits, 4 contributors, 22 forks, 0 open issues, MIT, very active (pushed today). Real, maintained project — but architecturally a different animal (generic cross-platform STT utility, not a Hebrew-first Mac-native dictation assistant with LLM cleanup, profiles, dictionary, or command mode).

### Rajvardhman05/openwhisper-app

- The most structurally similar alternative found: **Swift/SwiftUI + WhisperKit**, fully on-device, macOS 14+ Apple Silicon only. Right-Option hotkey with hold-to-talk and hands-free (tap-Space-to-lock) modes.
- **Does support Hebrew** — one of 29 listed languages — and has an **optional Ollama-based grammar/filler cleanup** layer, entirely local. This is architecturally the closest thing to "our app, but smaller and less hardened."
- No dictionary, no per-app profiles, no snippets, no command mode, no history/undo, no VAD tuning mentioned — it's the WhisperKit-hotkey-Ollama skeleton without any of the epics 3-7 layers we built.
- Maturity is thin: 10 stars, 11 commits total, **1 contributor**, no CI/workflows or tests visible in the repo tree, 2 open issues, and the last push was 2026-07-12 — about five weeks quiet at time of writing versus VoiceInk/Knuckles92's same-day activity. Reads as an early-stage solo side project, not yet adversarially reviewed or hardened for the failure modes our own epic reviews caught (truncation, echo/laundering, undo-safety, stale-rewrite races).

### Broader landscape scan (15-minute cap)

- **Handy** (cjpais/handy) — Tauri (Rust + React), cross-platform, whisper.cpp-based local ASR, MIT, **~30,000 stars**, daily activity — the largest and most active project in the whole scan by a wide margin. Hebrew support unconfirmed. Worth watching for UX/momentum even though it's not Mac-native Swift.
- **FluidVoice** (altic-dev/FluidVoice) — native Swift, macOS + Windows, multi-engine ASR (Nemotron, Parakeet, Cohere, Apple Speech, Whisper), own local "Fluid Intelligence" LLM enhancement plus OpenAI/Groq cloud. GPLv3 (relicensed *from* Apache-2.0 in Feb 2026 — became more copyleft, not less). ~10,700 stars, daily commits. The closest Swift-native, multi-ASR competitor to VoiceInk. Hebrew not mentioned.
- **OpenWhispr** (OpenWhispr/openwhispr — different project from Knuckles92's, confusingly similar name) — Electron/JS, cross-platform, local Parakeet/Whisper + cloud BYOK, MIT, ~5,600 stars, active. Hebrew unconfirmed.
- **whisper-mac** (Explosion-Scratch/whisper-mac) — TypeScript, macOS-only, multi-backend (Parakeet/whisper.cpp/Vosk/Apple Speech), no declared license, only 64 stars, quiet since March 2026.
- Several tiny (4-36 star) Whisper/whisper.cpp/MLX-Whisper wrappers exist with no confirmed Hebrew support or meaningful traction.
- **No project found in the scan advertises Hebrew support as a first-class feature** except Rajvardhman05/openwhisper-app (Hebrew listed among 29 languages, unverified in practice) and, implicitly, anything built on stock multilingual Whisper (which technically covers Hebrew but without tuning, dictionary help, or RTL-aware post-processing).

---

## 3. Three answers

### Q1 — Is what we built better for Tal's use case (Hebrew-first, fully local, privacy-hard, M4 Mac)?

**Yes, clearly, for Hebrew specifically — and by a wide margin.** Every OSS alternative surveyed either has no Hebrew story at all (VoiceInk, Knuckles92, Handy, FluidVoice, whisper-mac) or lists Hebrew only as one of Whisper's generic 99 languages with zero tuning (Rajvardhman05). None ship a Hebrew-specific ASR fine-tune, Hebrew-aware fuzzy dictionary normalization, or Hebrew-conscious safety validation. Our app's core differentiator — ivrit.ai + Hebrew-normalized dictionary matching — doesn't exist anywhere else in this scan. On the privacy axis, several competitors (VoiceInk, FluidVoice, Knuckles92) default toward or prominently offer cloud LLM/ASR paths; ours is local-only by construction with a hard-failing loopback-only LLM call and documented identity-fallback guarantee. On maturity/robustness, ours is the only project in the set with a documented adversarial review process that found and fixed real correctness bugs (truncation acceptance, undo deleting the user's own typing, context laundering into history, a dead hotkey, and a VAD that silently never engaged) — none of the OSS repos document anything comparable.

### Q2 — Should we move to something pre-made instead of maintaining ours?

**No.** The two most feature-rich alternatives (VoiceInk, FluidVoice) have no Hebrew support and would require the same Hebrew ASR + dictionary + validator work we already built, on top of someone else's codebase and someone else's roadmap (VoiceInk isn't even accepting PRs right now). The two directly-named repos (Knuckles92, Rajvardhman05) are strictly less capable than ours today — one has no LLM layer or Hebrew at all, the other has Hebrew + Ollama cleanup but is an 11-commit, single-contributor, quiet-for-5-weeks skeleton with none of Profiles/Dictionary/Snippets/Command-Mode/History/VAD-tuning and no visible tests or CI. Migrating would mean giving up a hardened, Hebrew-first, adversarially-reviewed pipeline for a smaller and less-proven one, with no clear win to justify the switch. Keep maintaining ours.

### Q3 — What features do they have that we missed and should steal (design only — AGPL-3.0 vs their licenses)?

License notes: our app is AGPL-3.0. VoiceInk claims GPLv3 (unresolved per GitHub's detector) and FluidVoice is GPLv3 — GPLv3 and AGPL-3.0 are compatible for combined works (AGPL §13 explicitly permits linking/combining with GPLv3 code), but PR policy and unclear licensing at VoiceInk make copying risky regardless; treat both as **design-reference only, no copying**, and reimplement independently. Knuckles92 and Rajvardhman05 are MIT, which is compatible for actual code reuse if ever wanted — but given their small feature surface relative to ours, there's little there worth lifting code-for-code anyway. See top-5 list below.

---

## 4. Top 5 features worth stealing (design-only, reimplement independently)

1. **VoiceInk's screen-content/window-context awareness** — feeds broader on-screen context (not just cursor-adjacent text) into the LLM prompt, a richer signal than our current per-app Profile + optional narrow cursor-context window.
2. **VoiceInk's "Smart Modes"** — user-defined, switchable enhancement presets beyond our fixed chat/mail/code starter Profiles, letting a user hand-author new tone/format presets without code changes.
3. **FluidVoice / VoiceInk's multi-engine ASR fallback** (Parakeet, Cohere Transcribe, Apple Speech as alternates to Whisper) — a pluggable ASR backend so a second local engine can be tried if WhisperKit/ivrit.ai underperforms on a given accent or audio condition.
4. **Rajvardhman05's hands-free "hold-then-tap-Space-to-lock" recording mode** — a lighter-weight alternative activation gesture alongside push-to-talk and double-tap-toggle, worth considering as a third activation mode.
5. **Knuckles92/OpenWhisper's "retranscribe from history"** — re-running ASR (or now, our LLM cleanup) on a past recording/transcript from the history view, useful when a model/profile changes after the fact, distinct from our existing re-paste/undo.

Note: none of these require touching GPL/AGPL-incompatible code — all are described at the feature/behavior level for independent reimplementation against our own architecture (AD-1..AD-13), consistent with avoiding GPL code copying into an AGPL-3.0 codebase.
