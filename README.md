<p align="center">
  <img src="web/static/logo.png" alt="TypeFlow" width="128" height="128">
</p>

<h1 align="center">TypeFlow</h1>

<p align="center"><strong>Hebrew and English dictation for macOS that never leaves your Mac.</strong></p>

<div align="center">

[![Release](https://img.shields.io/github/v/release/TalEps77/TypeFlow?include_prereleases&label=Download&color=2ea44f)](https://github.com/TalEps77/TypeFlow/releases)
[![Build & Test](https://github.com/TalEps77/TypeFlow/actions/workflows/ci.yml/badge.svg)](https://github.com/TalEps77/TypeFlow/actions/workflows/ci.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)
[![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-lightgrey.svg?logo=apple&logoColor=white)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-native-black.svg)](#requirements)
[![Privacy: 100% local](https://img.shields.io/badge/Privacy-100%25%20local-brightgreen.svg)](#privacy)
[![עברית](https://img.shields.io/badge/%D7%A2%D7%91%D7%A8%D7%99%D7%AA-first--class-0038b8.svg)](#hebrew)

</div>

<p align="center">
Hold a key. Speak. Your words appear at the cursor — in any app, in Hebrew or English.<br>
No cloud, no account, no subscription, no telemetry. The audio never leaves the machine.
</p>

---

<p align="center">
  <img src="docs/screenshots/popover.png" alt="TypeFlow menu bar: ivrit.ai Hebrew model active, עב / EN / Auto language toggle, Hold Right Option" width="380">
</p>

## Why this fork exists

TypeFlow is a fork of [VocaMac](https://github.com/jatinkrmalik/vocamac) by Jatin Kumar Malik,
rebuilt around one question upstream doesn't ask: **what does dictation look like when Hebrew is
a first-class language rather than entry 34 in a dropdown?**

The answer turned out to be a Hebrew-tuned recognizer, a Hebrew text normalizer, per-app
Profiles, Snippets, spoken editing commands, and an optional cleanup pass that runs on a language
model on *your* machine — with the "local-only" part enforced in code rather than promised in a
privacy policy.

## Features

| | |
|---|---|
| 🇮🇱 **Hebrew, properly** | A dedicated Hebrew recognizer, Hebrew-aware text matching, hand-tuned Hebrew cleanup, and a one-click **עב / EN / Auto** toggle in the menu bar. [Details ↓](#hebrew) |
| 🔒 **Nothing leaves the Mac** | Transcription is on-device. The optional cleanup step is *refused* if you point it anywhere but localhost — redirects included. |
| ⌨️ **Types anywhere** | Slack, VS Code, Mail, browsers, terminals — text is injected at the cursor. |
| 🎤 **Push-to-talk or toggle** | Hold Right Option and speak, or double-tap to toggle hands-free. |
| 🗂️ **Profiles** | Different behaviour per app. Force English in Slack while the menu bar stays on Hebrew. |
| ✂️ **Snippets** | Say a cue, get a block of text — verbatim, never rewritten. |
| 🗣️ **Command Mode** | Select text, hold a second key, say *"make this shorter"* — the selection is rewritten in place. |
| 🧰 **Developer vocabulary, built in** | 360 tech terms said with a Hebrew accent — קומיט, פוש, פול ריקווסט, קלוד אמדי — written as code writes them: `commit`, `push`, `pull request`, `CLAUDE.md`. Prefixes survive: הקומיט → ה־commit. |
| 📖 **Personal dictionary** | Names and jargon the recognizer keeps getting wrong, fixed deterministically after the fact. |
| 🕘 **History + undo** | Every dictation kept locally, searchable, re-pastable. One click undoes the last injection. |
| ⚡ **Apple Silicon native** | CoreML + Neural Engine via [WhisperKit](https://github.com/argmaxinc/WhisperKit). |

## Requirements

| | |
|---|---|
| **macOS** | 13 Ventura or later |
| **Hardware** | **Apple Silicon only** (M1–M4). Intel Macs are not supported. |
| **Disk** | 0.4–1.5 GB for a Whisper model (downloaded on first launch) · 1.5 GB for the Hebrew model · ~2.5 GB for the optional cleanup model |
| **RAM** | 8 GB is fine for English. Hebrew model + local cleanup together are comfortable on 16 GB and target 24 GB. |

TypeFlow needs three macOS permissions: **Microphone** (capture), **Accessibility** (hotkeys and
text injection) and **Input Monitoring** (system-wide key detection). It asks on first launch.
After granting Input Monitoring, quit and relaunch the app.

---

## Install

### 1 · Get the app

**Download** — grab `TypeFlow-<version>-arm64.dmg` from the
[**Releases page**](https://github.com/TalEps77/TypeFlow/releases), open it, and drag TypeFlow to
Applications.

> **First launch on a downloaded build.** TypeFlow is not yet signed with an Apple Developer ID,
> so macOS will say it *"cannot verify"* the app or that it is *"damaged"*. The file is fine — that
> is Gatekeeper's message for any unsigned download. Once, in Terminal:
>
> ```bash
> xattr -cr /Applications/TypeFlow.app
> ```
>
> then open it normally. If macOS still refuses, use **System Settings → Privacy & Security →
> Open Anyway**. You can also skip all of this by building from source, below.

**Or build from source** — needs Xcode 15+ (the full app, not just the command-line tools):

```bash
git clone https://github.com/TalEps77/TypeFlow.git
cd TypeFlow
make install
```

That builds `TypeFlow.app`, installs it to `/Applications`, and launches it. It lives in the menu
bar; there is no Dock icon. To update later: `git pull && make install`.

### 2 · First dictation

Grant the three permissions, then let TypeFlow download the Whisper model it recommends for your
Mac — the one time it needs the internet. Then hold **Right Option**, speak, and release. That
works in English and in Hebrew straight away; the Hebrew-specific model below makes Hebrew better.

<a id="hebrew-setup"></a>

### 3 · Hebrew model (recommended for Hebrew)

Standard Whisper models understand Hebrew. The **[ivrit.ai](https://www.ivrit.ai) fine-tune of
Whisper Large v3 Turbo** was trained on hundreds of hours of Hebrew speech and is the recognizer
TypeFlow's Hebrew mode was tuned around. The app treats it as a side-loaded model — it never
downloads or deletes it on its own — so install it once with the bundled script:

```bash
./scripts/install-hebrew-model.sh
```

It fetches the CoreML conversion from
[`eranshir/ivrit-ai-whisper-large-v3-turbo-coreml`](https://huggingface.co/eranshir/ivrit-ai-whisper-large-v3-turbo-coreml)
on Hugging Face (about 1.5 GB, 29 files; resumable), verifies the required components are present,
and places them where TypeFlow looks. Relaunch TypeFlow, open **Settings → Models**, and select
**ivrit.ai Hebrew (Large v3 Turbo)**.

<p align="center">
  <img src="docs/screenshots/settings-models.png" alt="Settings → Models: Active model ivrit.ai Hebrew (Large v3 Turbo)" width="760">
</p>

Prefer to do it by hand? The files go in
`~/Library/Application Support/VocaMac/models/models/argmaxinc/whisperkit-coreml/ivrit-ai_whisper-large-v3-turbo/`
— the same path Settings → Models shows next to the *Not Installed* label.

<a id="optional-local-cleanup"></a>

### 4 · Local cleanup (optional)

Raw speech-to-text keeps your *אה*, *אמ*, *כאילו*, "um", false starts and missing punctuation.
TypeFlow can pass each transcript through a small language model **running on your own Mac** to
remove fillers, punctuate, split run-ons, apply self-corrections, format spoken lists, and resolve
spoken punctuation. It is **off by default**.

The setup TypeFlow was tuned against is [LM Studio](https://lmstudio.ai) serving
**Qwen3-4B-Instruct-2507**:

1. Install LM Studio — from [lmstudio.ai](https://lmstudio.ai), or `brew install --cask lm-studio`.
2. In LM Studio's model search, download **`lmstudio-community/Qwen3-4B-Instruct-2507-MLX-4bit`**
   (~2.5 GB; the MLX build is the fast one on Apple Silicon).
3. Open LM Studio's **Developer** tab, load the model, and start the local server. The default
   address is `http://localhost:1234` — leave it.
4. In TypeFlow, **Settings → Cleanup**: turn on *Clean transcripts with a local LLM*, check that
   the model name matches the identifier LM Studio shows for the loaded model (TypeFlow's default
   is `qwen3-4b-instruct-2507-mlx`), and press **Test Connection**.

Any other OpenAI-compatible server on localhost works the same way (Ollama, llama.cpp, mlx-lm…);
only the address and model name change.

<p align="center">
  <img src="docs/screenshots/settings-cleanup.png" alt="Settings → Cleanup: local LLM at http://localhost:1234, Test Connection, editable system prompt" width="760">
</p>

**This is not a privacy loophole.** The endpoint is checked against loopback before every request
and HTTP redirects are refused outright, so cleanup cannot be pointed at a cloud API even
deliberately. There is no API-key field, because there is nowhere to send a key. If the server is
unreachable, slow, or answers with something that isn't your transcript, the pipeline silently
returns the original text — cleanup can never eat your words.

---

<a id="hebrew"></a>

## Hebrew — what "supported" means here

Most dictation tools list Hebrew and stop there. Concretely, TypeFlow adds:

**A Hebrew-specific recognizer.** The ivrit.ai fine-tune above, alongside the standard Whisper
models, selectable per Profile.

**Hebrew is the default language,** and the menu bar carries a **עב / EN / Auto** toggle so
switching mid-flow costs one click. Profiles can pin a language per app.

**Text matching that understands Hebrew.** A dedicated normalizer strips niqqud and cantillation,
folds final forms (ך/ם/ן/ף/ץ), decomposes Yiddish ligatures, and canonicalizes geresh/gershayim —
only after a Hebrew letter, so `don't` in English survives untouched. Acronyms like מנכ״ל and צה״ל
are matched as single tokens. This drives Snippets, the Dictionary, and correction learning.

**English tech terms, spelled the way code spells them.** Say *"תפתח פול ריקווסט אחרי הקומיט
ותפרוס לורסל"* and get *"תפתח pull request אחרי ה־commit ותפרוס ל־Vercel"*. A built-in pack of
**360 developer terms** — git verbs, tools, cloud services, AI tooling (Claude Code, `CLAUDE.md`,
MCP), languages, frameworks, agile vocabulary — is applied deterministically after transcription,
no language model involved. Hebrew's bound prefixes (ה/ל/ב/ו/מ/ש/כ) are peeled off and re-joined
with a maqaf, the way Hebrew typography attaches them to Latin words. Fresh installs get the pack
automatically; it's one button in **Settings → Vocabulary** otherwise, and every term is an ordinary
Dictionary entry you can edit or delete. Words with an accepted Hebrew spelling (אובייקט, פונקציה)
and transliterations that collide with real Hebrew words (פול, פורק) are deliberately left out —
a wrong replacement costs more than a missed one.

**Mixed Hebrew–English dictation.** Cleanup picks its prompt from the *script of what you actually
said*, not from the toggle — dictate Hebrew while set to English and you still get the Hebrew
prompt. The recognizer glossary is deliberately withheld on Auto-detect and English, because a
Hebrew glossary was found to skew language detection toward Hebrew.

**Spoken punctuation and numbering, in Hebrew.** *נקודה* → `.` · *פסיק* → `,` · *נקודתיים* → `:` ·
*סימן שאלה* → `?` · *סימן קריאה* → `!` · *שורה חדשה* → line break · *מספר אחת / שתיים / שלוש* →
a numbered list. Said as prose (*"שמתי נקודה בסוף המשפט"*) it stays prose.

> **Two honest caveats.** Spoken punctuation is implemented as instructions to the cleanup model,
> so it **only works with [cleanup](#optional-local-cleanup) enabled** and is best-effort rather
> than deterministic. And TypeFlow has **no RTL/bidi handling of its own** — injected text is plain
> Unicode, so how a mixed Hebrew/Latin line renders is up to the app you type into.

---

## Using it

| Action | Result |
|---|---|
| **Hold Right Option**, speak, release | Transcribe and type at the cursor |
| **Double-tap Right Option** | Start/stop hands-free (switch modes in Settings → General) |
| **עב / EN / Auto** in the menu bar | Change dictation language |
| **Select text, hold Right Command, speak an instruction** | Command Mode rewrites the selection in place |
| **Menu bar → Undo Last Injection** | Remove what was just typed |

<p align="center">
  <img src="docs/screenshots/settings-general.png" alt="Settings → General: activation mode, hotkey, Command Mode" width="760">
</p>

**Command Mode ships off** — enabling it reserves Right Command system-wide while TypeFlow runs.
By design, *every* Command Mode failure leaves your text untouched: it will never paste your spoken
instruction over your paragraph.

### Profiles

<p align="center">
  <img src="docs/screenshots/settings-profiles.png" alt="Settings → Profiles: per-app profiles, Cursor Context off by default" width="760">
</p>

A Profile binds settings to the app you are typing into: its own cleanup prompt, its own language,
cleanup on or off. Three starters ship — Chat (Slack/Messages), Mail, Code Editor (VS Code/Xcode).
Drag to set precedence; export and import as JSON to share them.

Profiles can optionally read the text around your cursor to match tone. That is the most invasive
thing in the app, so it is **off by default, needs two separate toggles**, is never logged or
persisted, and a reply that merely echoes your document is rejected.

### Snippets and dictionary

<p align="center">
  <img src="docs/screenshots/settings-vocabulary.png" alt="Settings → Vocabulary: Dictionary and Correction Learning" width="760">
</p>

**Snippets** — say a cue, get a block of text: expanded verbatim, line breaks intact, shielded from
the cleanup model so it can never reword them. Works with cleanup off.

**Dictionary** — deterministic post-recognition fixes for names and jargon, with Hebrew-aware fuzzy
matching. Ships with the 360-term developer pack described [above](#hebrew); add your own on top. Optional **correction learning** notices a single-word edit you make right after
dictating and *offers* to remember it — off by default; dismissals are stored as one-way hashes.

---

## Privacy

- Audio is captured, transcribed and discarded **on your Mac**. No servers, no accounts, no telemetry.
- Cleanup, when enabled, is enforced loopback-only in code.
- History, snippets, dictionary and profiles are plain files under `~/Library/Application Support/VocaMac/`.
- Uninstall removes all of it: `./scripts/uninstall.sh`.

The only network calls TypeFlow makes on its own are model downloads from Hugging Face the first
time you select a model. After that it runs fully offline.

## Status

TypeFlow is in daily use by its author and is **beta**. Where it stands, plainly:

- **The Hebrew accuracy claim is unmeasured.** The ivrit.ai fine-tune is expected to beat general
  Whisper models on Hebrew, but no held-out benchmark has been run in this project. Treat it as a
  strong default, not a proven number.
- Downloads are **not Developer-ID signed or notarized** yet, so the first launch needs the
  `xattr` step above. Builds from source without a Developer ID use ad-hoc signing, which makes
  macOS reset Accessibility/Input Monitoring on every rebuild — [CONTRIBUTING.md](CONTRIBUTING.md)
  has the way around that.
- No RTL/bidi handling; mixed-direction rendering is the target app's business.
- Recordings longer than 30 seconds can lose roughly the last second to chunking.
- Some Hebrew fuzzy-matching edge cases are known and accepted (bound prefixes such as
  בדיקה/בבדיקה can over-match).

**800+ tests** cover the models, pipeline, matching and stores; all pass in a headless runner except
three that need a real microphone and speaker. SwiftUI view wiring is largely manual-tested.

---

## Development

```bash
make build   # build TypeFlow.app into the repo root
make test    # swift test
make run     # launch the local build (inherits your terminal's permissions)
make dmg     # package a DMG into dist/
make help    # every target
```

Architecture notes: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md), [`docs/DATA_MODEL.md`](docs/DATA_MODEL.md);
the fork's own design decisions and conventions: [`AGENTS.md`](AGENTS.md).
Contributions: [CONTRIBUTING.md](CONTRIBUTING.md). The bug reports that matter most are Hebrew and
RTL ones — include the text you spoke and the text you got.

## Credits and license

TypeFlow is a fork of **[VocaMac](https://github.com/jatinkrmalik/vocamac)** by
[@jatinkrmalik](https://github.com/jatinkrmalik) — the foundation this is built on. Transcription is
[WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax, running
[OpenAI Whisper](https://github.com/openai/whisper) models. Hebrew recognition uses the
[ivrit.ai](https://www.ivrit.ai) fine-tune, converted to CoreML by
[Eran Shir](https://huggingface.co/eranshir).

Licensed under **AGPL-3.0-or-later** — see [LICENSE](LICENSE); attribution and the record of
modifications in [NOTICE](NOTICE); dependency licenses in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
Bug reports about TypeFlow belong here, not upstream.

<div align="center"><sub>Built for people who think faster than they type — in either direction.</sub></div>
