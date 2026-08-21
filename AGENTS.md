# VocaMac — AI Coding Agent Guidelines

## Project Overview

VocaMac is a **native macOS menu bar application** for local voice-to-text dictation, built with **Swift 5.9+** and **SwiftUI**. It uses **WhisperKit** (CoreML-based) for on-device speech recognition. The project also includes a **Hugo-based marketing website** (`web/`) deployed to GitHub Pages at [vocamac.com](https://vocamac.com).

- **Branding split (deliberate — do not "fix"):** The app ships as **TypeFlow** (`DISPLAY_NAME` in `scripts/app-name.sh`, `/Applications/TypeFlow.app`), while the executable name, bundle id (`com.vocamac.app`), entitlements file, single-instance check, and `~/Library/Application Support/VocaMac` data directory all stay on the original `VocaMac`/`APP_NAME` identifiers so existing installs keep their preferences and models across the rename. See the comment block at the top of `scripts/app-name.sh` for the full rationale.
- **License:** AGPL-3.0
- **Minimum target:** macOS 13 (Ventura)
- **Build system:** Swift Package Manager
- **CI:** GitHub Actions (`.github/workflows/ci.yml`)
- **Website deployment:** GitHub Pages via release trigger (`.github/workflows/deploy-website.yml`)

---

## Critical Rule: Use Git Worktrees for Parallel Tasks

**When asked to perform multiple unrelated tasks simultaneously, ALWAYS use git worktrees.**

```bash
# Create worktrees in /tmp — never pollute the main workspace
git worktree add /tmp/vocamac-<task-name> -b <branch-name> main

# After work is complete, clean up
git worktree remove /tmp/vocamac-<task-name>
git worktree prune
```

**Why:** Concurrent work on the same directory causes branch conflicts, overwritten files, and corrupted state. Each worktree gets its own isolated copy of the repo on its own branch.

**Rules:**
- Create worktrees in `/tmp/` with the prefix `vocamac-`
- One worktree per branch, one branch per PR
- Always prune worktrees after pushing and creating PRs
- Never modify files in the main workspace when worktrees are active for that task

---

## Repository Structure

```
VocaMac/
├── Sources/VocaMac/
│   ├── App/              # App entry point (VocaMacApp.swift)
│   ├── Models/           # AppState, TranscriptionResult, WhisperModel, Prompts, ...
│   ├── Services/         # AudioEngine, HotKeyManager, ModelManager, Logger,
│   │                     #   SystemInfo, TextInjector, WhisperService, PostProcessService, ...
│   ├── Stores/           # JSONFileStore-backed persistence: History, Profile, Dictionary, Snippet, ...
│   ├── Pipeline/         # TranscriptPipeline + Stages/ (Dictionary, Snippet, PostProcess, Rehydrate)
│   ├── Views/            # MenuBarView, SettingsView, HistoryView, OnboardingView, ...
│   └── Resources/        # AppIcon.icns, dmg-background images
├── Sources/VocaMacObjC/  # Objective-C helpers (exception catching, etc.)
├── Tests/VocaMacTests/   # Unit tests (~780 test functions, XCTest)
├── web/                  # Hugo static site (content/, layouts/, static/) → vocamac.com via GitHub Pages
├── Makefile              # make build, install, install-cli, dmg, release, test, run, clean, reset
├── scripts/              # app-name.sh, build.sh, dist.sh, install.sh, uninstall.sh, release.sh
├── docs/                 # ARCHITECTURE.md, DATA_MODEL.md, HOMEBREW.md, RELEASE.md, screenshots/
├── Package.swift         # SPM manifest
└── VocaMac.entitlements  # App sandbox entitlements
```

---

## Build & Run

```bash
# Build + install to /Applications (recommended)
make install

# Build .app bundle in repo root (fast dev iteration)
make build

# Install CLI commands (vocamac, vocamac-build) to ~/.local/bin
make install-cli

# Build a DMG for distribution
make dmg

# Tag and push a release (triggers CI signing + notarization)
make release VERSION=X.Y.Z

# Run tests
make test

# Launch the locally built .app
make run

# Delete all local app data (models, cache, prefs) — app must not be running
make reset

# Clean build artifacts
make clean
```

Or use the scripts directly:

```bash
./scripts/build.sh              # Build .app bundle (dev)
./scripts/install.sh            # Build + install to /Applications
./scripts/install.sh --cli      # Install CLI commands
```

The project builds on **macOS only** (requires AppKit, CoreML, AVFoundation). CI runs on `macos-15`.

---

## Code Style & Best Practices

### Swift Conventions
- Use **SwiftUI** for all views — no AppKit views unless absolutely necessary for system integration
- Use **`@Observable`** (or `ObservableObject` with `@Published`) for state management
- Prefer **`async/await`** over callbacks and closures for asynchronous work
- Use **`guard`** for early returns; avoid deep nesting
- Follow Apple's [Swift API Design Guidelines](https://swift.org/documentation/api-design-guidelines/)
- Use meaningful names: `isRecording` not `flag`, `audioLevel` not `val`
- Mark sections with `// MARK: -` for organization
- Add doc comments (`///`) on all public types, methods, and non-trivial private methods

### Architecture Patterns
- **Single source of truth:** `AppState` is the central observable state object
- **Service layer:** Business logic lives in `Services/` (AudioEngine, WhisperService, etc.)
- **Views are thin:** Views observe state and dispatch actions — no business logic in views
- **Dependency injection:** Pass dependencies via `@EnvironmentObject` or init parameters

### Error Handling
- Never force-unwrap (`!`) unless the value is guaranteed (e.g., system symbols)
- Use `do/catch` with meaningful error types
- Surface errors to the user via `AppState.appStatus = .error` with clear messages
- Log via `VocaLogger` (`Sources/VocaMac/Services/Logger.swift`) — e.g. `VocaLogger.error(.audioEngine, "message")`. It wraps `os.Logger` (Console.app integration) plus rotating file logs under `~/Library/Application Support/VocaMac/logs`. Do not use bare `print()` for anything beyond throwaway debugging — add a `LogCategory` case if the component doesn't have one yet.

### Performance
- This is a **menu bar app** — it must be lightweight and responsive
- Avoid unnecessary polling; prefer event-driven updates
- `ProcessMonitor` polls every 5 seconds — don't add more frequent timers
- Heavy work (transcription, model loading) runs on background threads
- UI updates must dispatch to `@MainActor`

---

## Testing Requirements

### Test Coverage
- **All new logic must have corresponding tests** in `Tests/VocaMacTests/`
- Test file naming: `<ClassName>Tests.swift` (e.g., `WhisperServiceTests.swift`)
- Use **XCTest** framework
- Run tests with `swift test` — this is what CI executes. Requires a full Xcode install (not just CLI Tools) for the XCTest module; currently ~780 test functions, full suite runs in well under a minute

### What to Test
- Model logic and state transitions in `AppState`
- Service layer methods (parsing, formatting, validation)
- Data model encoding/decoding
- Edge cases: empty input, nil values, boundary conditions

### What NOT to Test
- SwiftUI view rendering (no snapshot tests currently)
- System APIs (microphone, accessibility, pasteboard) — these require real hardware
- WhisperKit internals — that's a third-party dependency

---

## Website (`web/`)

- **Hugo static site generator** — content in `web/content/` (Markdown), templates in `web/layouts/`, static assets in `web/static/`
- Built via `hugo --minify` (see `.github/workflows/deploy-website.yml`, uses `peaceiris/actions-hugo`)
- Deployed to GitHub Pages on release via `.github/workflows/deploy-website.yml`
- Custom domain: `vocamac.com` (configured via `web/static/CNAME`)
- Logo: `web/static/logo.png`
- Test locally: `cd web && hugo server` (requires Hugo installed — `brew install hugo`). Raw files under `web/content/` are Markdown, not directly viewable HTML.

---

## Git & PR Workflow

### Branch Naming
- `feat/<description>` — new features
- `fix/<description>` — bug fixes
- `ui/<description>` — UI/UX improvements
- `chore/<description>` — maintenance, config, tooling
- `docs/<description>` — documentation updates
- `ci/<description>` — CI/CD changes

### Commit Messages
Follow [Conventional Commits](https://www.conventionalcommits.org/):
```
feat: add CPU monitoring to popover panel
fix: menu bar icon not showing colored states
ui: enlarge popover panel for Retina displays
docs: update README badges
chore: change license to AGPL-3.0
ci: add GitHub Actions build workflow
```

### Pull Requests
- **NEVER commit directly to main** — always create a feature branch and raise a PR
- One logical change per PR — don't bundle unrelated changes
- Write descriptive PR titles and bodies
- PRs must pass CI (`swift build` + `swift test`) before merge
- Squash merge preferred for clean history
- Wait for the user to review and merge — do not merge PRs yourself

### Release Notes — Do NOT Commit Them to the Repo

**Never create or commit `docs/RELEASE_NOTES_v*.md` files** (or any other per-version release-notes file inside the repo). These files clutter the source tree, become stale the moment the release ships, and duplicate content that already lives on the GitHub Release page.

The release-notes lifecycle is:

1. **Draft** the notes in a scratch location *outside* the repo (e.g. `/tmp/RELEASE_NOTES_vX.Y.Z.md`, a Gist, or directly in the GitHub Release "draft" UI).
2. **Reuse** that draft to update the version-bump PR description, the `gh release create --notes-file ...` invocation, and any related comms.
3. **Paste** the final text into the GitHub Release description when publishing.
4. **Delete** the local scratch file after the release goes live.

If a version bump PR needs changelog context, put the changelog table in the **PR description**, not in a tracked file. The single source of truth for shipped release notes is the **GitHub Release page** itself, which is also what the in-app update checker surfaces to users.

See `docs/RELEASE.md` → **Release Notes (out-of-tree)** for the full process.

---

## Key Dependencies

| Dependency | Purpose | Version |
|-----------|---------|---------|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | On-device speech-to-text via CoreML | 0.18.0 (resolved; `Package.swift` floor is `from: "0.9.4"`) |

Keep dependencies minimal. This app values being lightweight and self-contained.

---

## macOS-Specific Considerations

- **Entitlements** (`VocaMac.entitlements`): App uses microphone access and accessibility APIs
- **LSUIElement:** App runs as a menu bar agent (no dock icon)
- **Code signing:** `scripts/build.sh` auto-detects a signing identity in this priority order: `Developer ID Application` → `Apple Development` → ad-hoc (`-`) as a last resort. Release builds (CI) are Developer ID signed and notarized; local dev machines without a Developer ID cert commonly sign with an auto-detected `Apple Development` identity instead. Override with the `CODE_SIGN_IDENTITY` env var; set it to `-` only if you deliberately want to force ad-hoc.
- **Permissions:** With Developer ID *or* Apple Development signing, the code signature (and its TCC grants) stays stable across rebuilds. **Ad-hoc signing must be avoided for local dev** — every ad-hoc rebuild changes the cdhash, which resets Accessibility/Input Monitoring TCC grants and forces re-granting permissions from scratch.
- **MenuBarExtra limitations:** The label only renders `Image` or `Text` — custom SwiftUI views like `Canvas` won't appear. Use `NSImage` with `isTemplate = false` for colored menu bar icons.

---

## Common Pitfalls

1. **MenuBarExtra ignores SwiftUI colors** — Use `NSImage` with `sourceAtop` tinting and `isTemplate = false` for colored states
2. **`Canvas` doesn't work in menu bar** — It renders in popovers but not in `MenuBarExtra` labels
3. **Browser caches SVG/PNG aggressively** — When testing website changes, always hard refresh (`Cmd+Shift+R`)
4. **Accessibility/Input Monitoring permissions reset on rebuild** — Only happens with ad-hoc signing (`CODE_SIGN_IDENTITY=-`); never force ad-hoc for local dev. Developer ID and Apple Development signing both keep permissions stable across rebuilds
5. **WhisperKit model download** — First run requires internet to download the whisper model; all subsequent runs are offline
