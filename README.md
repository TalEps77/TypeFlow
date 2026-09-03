<p align="center">
  <img src="web/static/logo.png" alt="TypeFlow" width="128" height="128">
</p>

<h1 align="center">TypeFlow</h1>

<p align="center"><strong>Hebrew and English dictation for macOS that never leaves your Mac.</strong></p>

<div align="center">

[![Build & Test](https://github.com/TalEps77/TypeFlow/actions/workflows/ci.yml/badge.svg)](https://github.com/TalEps77/TypeFlow/actions/workflows/ci.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)
[![Platform: macOS 13+](https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey.svg)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-black.svg?logo=apple&logoColor=white)](#requirements)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Privacy: 100% local](https://img.shields.io/badge/Privacy-100%25%20local-brightgreen.svg)](#privacy)
[![עברית](https://img.shields.io/badge/%D7%A2%D7%91%D7%A8%D7%99%D7%AA-supported-blue.svg)](#hebrew)

</div>

<p align="center">
Hold a key. Speak. Your words appear at the cursor — in any app.<br>
No cloud, no account, no subscription, no telemetry. The audio never leaves the machine.
</p>

<p align="center">
  <img src="docs/screenshots/popover-panel.png" alt="TypeFlow menu bar popover" width="420">
</p>

---

## Why this fork exists

TypeFlow is a fork of [VocaMac](https://github.com/jatinkrmalik/vocamac) by Jatin Kumar Malik,
rebuilt around one question upstream doesn't answer: **what does dictation look like when
Hebrew is a first-class language rather than entry number 34 in a dropdown?**

Everything below the "Dictation" line is new here: a Hebrew-tuned recognizer, a Hebrew text
normalizer, per-app Profiles, Snippets, spoken editing commands, and an optional cleanup pass
that runs on a model on *your* machine.

---

## Features

| | |
|---|---|
| 🇮🇱 **Hebrew, properly** | A dedicated Hebrew recognizer, Hebrew-aware text matching, and hand-tuned Hebrew cleanup. [Details ↓](#hebrew) |
| 🔒 **Nothing leaves the Mac** | Transcription is on-device. The optional cleanup step is *refused* if you point it anywhere but localhost — enforced in code, not just documented. |
| ⌨️ **Types anywhere** | Slack, VS Code, Mail, browsers, terminals — text is injected at the cursor. |
| 🎤 **Push-to-talk or toggle** | Hold Right Option and speak, or double-tap to toggle hands-free. |
| 🗂️ **Profiles** | Different behaviour per app. Force English in Slack while the menu bar stays on Hebrew. |
| ✂️ **Snippets** | Say a cue, get a block of text — verbatim, never rewritten. |
| 🗣️ **Command Mode** | Select text, hold a second key, say *"make this shorter"* — the selection is rewritten in place. |
| 📖 **Personal dictionary** | Names and jargon the recognizer keeps getting wrong, fixed deterministically after the fact. |
| 🕘 **History + undo** | Every dictation kept locally, searchable, re-pastable. One click undoes the last injection. |
| ⚡ **Apple Silicon native** | CoreML + Neural Engine via [WhisperKit](https://github.com/argmaxinc/WhisperKit). |

<a id="hebrew"></a>

## Hebrew — what "supported" actually means here

Most dictation tools list Hebrew and stop there. Concretely, TypeFlow adds:

**A Hebrew-specific recognizer.** Alongside the standard Whisper models, TypeFlow can run the
[ivrit.ai](https://www.ivrit.ai) Hebrew fine-tune of Whisper Large v3 Turbo. It is **side-loaded,
not downloaded** — see [Hebrew setup](#hebrew-setup).

**Hebrew is the default language,** and the menu bar carries a one-click **עב / EN / Auto**
toggle so switching mid-flow costs nothing.

**Text matching that understands Hebrew.** A dedicated normalizer strips niqqud and cantillation,
folds final forms (ך/ם/ן/ף/ץ), decomposes Yiddish ligatures, and canonicalizes geresh/gershayim —
but only after a Hebrew letter, so `don't` in English survives untouched. Acronyms like מנכ״ל and
צה״ל are matched as single tokens.

**Mixed Hebrew–English dictation.** Cleanup picks its prompt from the *script of what you actually
said*, not from the toggle — dictate Hebrew while set to English and you still get the Hebrew
prompt. The recognizer glossary is deliberately withheld on Auto-detect and English, because a
Hebrew glossary skewed language detection toward Hebrew.

**Spoken punctuation and numbering, in Hebrew.** *נקודה* → `.` · *פסיק* → `,` · *נקודתיים* → `:` ·
*סימן שאלה* → `?` · *סימן קריאה* → `!` · *שורה חדשה* → line break · *מספר אחת / שתיים / שלוש* →
a numbered list. Said as prose (*"שמתי נקודה בסוף המשפט"*) it stays prose.

> **Two honest caveats.** Spoken punctuation is implemented as instructions to the cleanup model,
> so it **only works with [cleanup](#optional-local-cleanup) enabled** and is best-effort, not
> deterministic. And the app has **no RTL/bidi handling of its own** — injected text is plain
> Unicode, so how mixed Hebrew/Latin lines render is up to the app you type into.

---

## Requirements

| | |
|---|---|
| **macOS** | 13 (Ventura) or later |
| **Hardware** | **Apple Silicon only** (M1–M4). Intel Macs are not supported. |
| **Build tools** | Xcode 15+ / Swift 5.9+ (building from source is currently the only install route) |
| **Disk** | ~0.4 GB for the bundled Tiny model; ~1.5 GB for the Hebrew model |
| **RAM** | 8 GB is fine for English. Hebrew model + local cleanup together target a 24 GB machine. |

TypeFlow needs three macOS permissions: **Microphone** (capture), **Accessibility** (hotkeys and
text injection) and **Input Monitoring** (system-wide key detection). After granting Input
Monitoring, restart the app.

---

## Install

> **There are no published releases yet.** Build from source — it takes one command.
> Any VocaMac DMG, Homebrew cask or nightly you find online is **upstream**, not TypeFlow.

```bash
git clone https://github.com/TalEps77/TypeFlow.git
cd TypeFlow
make install
```

That builds `TypeFlow.app`, installs it to `/Applications`, and launches it. It appears in the
menu bar — there is no Dock icon.

**First run:** grant the three permissions, let WhisperKit fetch the model recommended for your
Mac, then hold **Right Option**, speak, and release.

To update: `git pull && make install`. The in-app update check is deliberately switched off — it
pointed at upstream's release feed, so an "update" would have replaced TypeFlow with VocaMac.

<a id="hebrew-setup"></a>

### Hebrew setup (optional but recommended)

The ivrit.ai Hebrew model is **not downloadable from inside the app** — it is side-loaded. Place
the WhisperKit/CoreML model files, together with the tokenizer assets, at:

```
~/Library/Application Support/VocaMac/models/models/argmaxinc/whisperkit-coreml/ivrit-ai_whisper-large-v3-turbo/
```

Until the files are there, **Settings → Models** shows the entry as *Not Installed* along with the
exact path it expects. Once present, it is selectable like any other model; the app will never try
to download or delete it.

Hebrew dictation also works on the standard multilingual Whisper models — the ivrit.ai fine-tune is
an accuracy upgrade, not a prerequisite.

<a id="optional-local-cleanup"></a>

### Optional: local cleanup

Raw speech-to-text keeps your *אה*, *אמ*, *כאילו*, "um", false starts and missing punctuation.
TypeFlow can pass each transcript through a language model **running on your own machine** to
clean it up — remove fillers, punctuate, split run-ons, apply self-corrections, format spoken
lists, and resolve spoken punctuation.

It is **off by default**. To enable it, run any OpenAI-compatible server locally — the defaults
target [LM Studio](https://lmstudio.ai) on `http://localhost:1234` with `qwen3-4b-instruct-2507-mlx` —
then turn it on in **Settings → Cleanup**.

**This is not a privacy loophole.** The endpoint is checked against loopback before every request
and redirects are refused outright, so it cannot be pointed at a cloud API even deliberately. There
is no API-key field, because there is nowhere to send a key. If the server is unreachable, slow, or
returns something suspicious, the pipeline silently returns your original transcript — cleanup can
never eat your words.

---

## Using it

| Action | Result |
|---|---|
| **Hold Right Option**, speak, release | Transcribe and type at the cursor |
| **Double-tap Right Option** | Start/stop hands-free (switch modes in Settings → General) |
| **עב / EN / Auto** in the menu bar | Change dictation language |
| **Select text, hold Right Command, speak an instruction** | Command Mode rewrites the selection in place |
| **Menu bar → Undo Last Injection** | Remove what was just typed |

**Command Mode ships off** — enabling it reserves Right Command system-wide while TypeFlow runs.
By design, *every* Command Mode failure leaves your text untouched: it will never paste your
spoken instruction over your paragraph.

### Profiles

A Profile binds settings to the app you are typing into: its own cleanup prompt, its own language,
cleanup on or off. Three starters ship — Chat (Slack/Messages), Mail, Code Editor (VS Code/Xcode).
Drag to set precedence; export and import as JSON to share them.

Profiles can optionally read the text around your cursor to match tone. That is the most invasive
thing in the app, so it is **off by default, needs two separate toggles to switch on**, is never
logged or persisted, and a reply that merely echoes your document is rejected.

### Snippets and dictionary

**Snippets**: say a cue, get a block of text — expanded verbatim, line breaks intact, protected
from the cleanup model so it can never reword them. Works with cleanup off.

**Dictionary**: deterministic post-recognition fixes for names and jargon, with Hebrew-aware fuzzy
matching. Optional **correction learning** watches for a single-word edit you make right after
dictating and *offers* to remember it — off by default, and dismissals are stored as one-way hashes.

---

## Privacy

- Audio is captured, transcribed and discarded **on your Mac**. No servers, no accounts, no telemetry.
- Cleanup, when enabled, is enforced loopback-only in code.
- History, snippets, dictionary and profiles are plain files under `~/Library/Application Support/VocaMac/`.
- Uninstall removes all of it: `./scripts/uninstall.sh`.

The one network call TypeFlow makes on its own is downloading a Whisper model from Hugging Face the
first time you select one.

---

## Status

TypeFlow is used daily by its author and is **beta**. Being straight about where it stands:

- **The Hebrew accuracy claim is unmeasured.** The ivrit.ai fine-tune is expected to beat the
  general Whisper models on Hebrew, but no held-out benchmark has been run in this project. Treat
  it as a reasonable default, not a proven number.
- No signed release build exists yet, so building from source is the only route, and ad-hoc signing
  means macOS resets Accessibility/Input Monitoring on every rebuild. See
  [CONTRIBUTING.md](CONTRIBUTING.md) for the way around that.
- No RTL/bidi handling; mixed-direction rendering is the target app's business.
- Recordings longer than 30 seconds can lose roughly the last second to chunking.
- Some Hebrew fuzzy-matching edge cases are known and accepted (bound prefixes such as
  בדיקה/בבדיקה can over-match).

797 tests cover the model, pipeline, matching and store layers. SwiftUI view wiring is largely
manual-tested.

---

## Development

```bash
make build   # build TypeFlow.app into the repo root
make test    # swift test
make run     # launch the local build (inherits your terminal's permissions)
make dmg     # package a DMG into dist/
make help    # every target
```

Architecture notes live in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and
[`docs/DATA_MODEL.md`](docs/DATA_MODEL.md); the fork's own design decisions are in
[`AGENTS.md`](AGENTS.md). Contributions: [CONTRIBUTING.md](CONTRIBUTING.md). Bugs that matter most
are Hebrew and RTL ones — include the text you spoke and the text you got.

---

## Credits and license

TypeFlow is a fork of **[VocaMac](https://github.com/jatinkrmalik/vocamac)** by
[@jatinkrmalik](https://github.com/jatinkrmalik) — the foundation this is built on. Transcription is
[WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax, running
[OpenAI Whisper](https://github.com/openai/whisper) models. Hebrew recognition uses the
[ivrit.ai](https://www.ivrit.ai) fine-tune.

Licensed under **AGPL-3.0-or-later** — see [LICENSE](LICENSE), with attribution and the record of
modifications in [NOTICE](NOTICE) and dependency licenses in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md). Bug reports about TypeFlow belong here, not
upstream.

<div align="center"><sub>Built for people who think faster than they type — in either direction.</sub></div>
