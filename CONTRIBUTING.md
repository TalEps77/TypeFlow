# Contributing to TypeFlow

Thanks for considering it. TypeFlow is a small, opinionated app, so the most
useful contributions are focused ones.

## Before you start

* **Open an issue first** for anything larger than a bug fix. It saves you from
  building something that does not fit.
* **Bug reports need**: your TypeFlow version (Settings → About), macOS version,
  Mac model, the language you were dictating in, and what you expected versus
  what happened. If the hotkey or text injection is involved, say which app you
  were typing into — behaviour differs between apps.
* **Hebrew and RTL issues are welcome and wanted.** Include the exact text you
  spoke and the exact text that came out; word-order and punctuation-side bugs
  are impossible to guess at from a description.

## Development setup

Requirements: macOS 13+, an Apple Silicon Mac, and Swift 5.9+ (Xcode 15+).

```bash
git clone https://github.com/TalEps77/TypeFlow.git
cd TypeFlow
make build        # build TypeFlow.app into the repo root
make test         # run the test suite
make run          # launch the build you just made
make install      # build and install to /Applications, then launch
```

`make help` lists every target.

### The permissions trap

TypeFlow needs Accessibility and Input Monitoring, and macOS keys those grants
to the *code signature and path* of the bundle. Building without a Developer ID
certificate means ad-hoc signing, so **every rebuild invalidates your grants**.

The way to stay sane while developing: grant Microphone, Accessibility and Input
Monitoring to your terminal app once, and use `make run` — the permissions are
inherited from the terminal and never reset.

### Regenerating the README screenshots

The app can photograph itself — no Screen Recording permission needed:

```bash
make install
osascript -e 'tell application "TypeFlow" to quit'
TYPEFLOW_CAPTURE_DIR=/tmp/typeflow-shots open -a TypeFlow --env TYPEFLOW_CAPTURE_DIR=/tmp/typeflow-shots
```

It writes `settings-<section>.png` for every Settings section and `history.png`,
then keeps listening: posting the distributed notification `il.typeflow.capture`
dumps every visible window. See `Sources/VocaMac/App/DebugCapture.swift`; it is
inert unless the environment variable is set.

## Pull requests

* Keep the diff focused; one concern per PR.
* `make test` must pass. Add tests for behaviour you change.
* Match the surrounding Swift style rather than introducing your own.
* Do not bundle unrelated reformatting into a feature PR.
* Write commit messages that say *why*, not just what.

## Licensing of contributions

TypeFlow is **AGPL-3.0-or-later**, inherited from upstream VocaMac. By opening a
pull request you agree that your contribution is licensed under the same terms.
There is no CLA.

If you are contributing something derived from another project, say so in the PR
and name its license — AGPL-incompatible code cannot be merged.

## What is unlikely to be merged

* Cloud transcription, analytics, telemetry, or crash reporting that phones
  home. The point of TypeFlow is that nothing leaves the machine.
* Intel Mac support. The app is `arm64`-only by design.
* Restoring the in-app update checker without repointing it at this repository's
  own releases (see `UpdateChecker.updatesEnabled`).
