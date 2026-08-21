# AGENTS.md audit — local-whisper (VocaMac/TypeFlow fork)

Date: 2026-08-22
Method: bmad-project-context skill (audit intent), run non-interactively as a subagent —
findings verified directly against repo state rather than via user interview, per the
orchestrating task's explicit brief (facts pre-supplied: TypeFlow branding, Xcode 26.6,
swift test ~767 tests, Apple Development auto-detected signing, ad-hoc forbidden).

No `project-context.md` existed anywhere in the repo or `_bmad-output/` — confirmed the
"bmad-generate-project-context never ran" premise. AGENTS.md itself (single file, no
`_bmad` block markers) was the only artifact to audit.

## Verification method
- Read Package.swift, Package.resolved, Makefile, scripts/app-name.sh, scripts/build.sh,
  .github/workflows/*.yml, docs/, web/, Sources/ and Tests/ trees directly.
- Cross-checked against `~/.claude/projects/.../memory/local-whisper-project.md`, which
  independently confirms the branding split, signing identity, and Xcode/test facts.
- Counted test functions via grep (784) — consistent with the "~767 tests" figure.

## Findings: wrong or stale claims in AGENTS.md

1. **Logging framework — flatly false.** AGENTS.md said "we don't have a logging
   framework yet — use print()". `Sources/VocaMac/Services/Logger.swift` is a full
   `VocaLogger` framework: `os.Logger` integration, categorized logging (`LogCategory`),
   rotating file logs under `~/Library/Application Support/VocaMac/logs`, flush/export
   APIs. This would have actively misled an agent into introducing print()-based logging
   into a codebase that already standardized on something else. **Fixed.**

2. **Website tech stack — wrong.** AGENTS.md described `web/` as "Pure HTML/CSS/JS — no
   build tools", tested via `python3 -m http.server`. Actual `web/` is a **Hugo** static
   site (`content/`, `layouts/`, `hugo.toml`), built via `hugo --minify` in CI
   (`peaceiris/actions-hugo`). Raw files under `web/content/` are Markdown, not directly
   viewable — the old "serve as static files" instruction would produce a broken preview.
   Also: CNAME moved to `web/static/CNAME` (was documented as `web/CNAME`). **Fixed.**

3. **Repository structure diagram — stale.** Missing two entire source directories that
   now carry core architecture: `Sources/VocaMac/Stores/` (JSONFileStore-backed
   persistence) and `Sources/VocaMac/Pipeline/` + `Pipeline/Stages/` (the transcript
   post-processing pipeline: Dictionary, Snippet, PostProcess, Rehydrate stages). Also
   missing the `Sources/VocaMacObjC/` target (declared in Package.swift). `Resources/`
   was documented as a ".gitkeep placeholder" but now holds real assets (AppIcon.icns,
   dmg backgrounds). `docs/` listed a `PRD.md` that doesn't exist and omitted
   `HOMEBREW.md`/`RELEASE.md` that do. **Fixed.**

4. **Makefile commands — incomplete.** AGENTS.md's Build & Run section only listed
   `build`/`install`/`install-cli`/`test`/`clean`. The Makefile also has `dmg`, `release
   VERSION=X.Y.Z`, `run`, and `reset` (destructive — deletes all local app data). Missing
   `reset` in particular is a hazard: an agent unaware of it might hand-roll a
   `rm -rf ~/Library/Application Support/VocaMac` instead. **Fixed.**

5. **Code signing — incomplete, missed the actual local-dev path.** AGENTS.md implied a
   binary choice: Developer ID (release) vs. ad-hoc (local, if no cert). Reading
   `scripts/build.sh` shows a 3-tier auto-detect: `Developer ID Application` →
   `Apple Development` → ad-hoc (last resort). On a machine with an Apple Development
   cert but no Developer ID cert (Tal's setup, confirmed independently in project
   memory), the actual local-dev path is **Apple Development signing**, not ad-hoc —
   and ad-hoc must be avoided entirely since every ad-hoc rebuild changes the cdhash
   and resets Accessibility/Input Monitoring TCC grants. The old wording made ad-hoc
   sound like an acceptable, expected fallback rather than something to actively avoid.
   **Fixed** (macOS-Specific Considerations + Common Pitfalls #4).

6. **WhisperKit version — outdated.** Table said "0.9.4+" (the `Package.swift` floor).
   `Package.resolved` pins the actual resolved version at **0.18.0**. **Fixed** to show
   both.

7. **No mention of the TypeFlow/VocaMac branding split anywhere.** This is exactly the
   kind of thing a fresh agent flags as a bug (bundle id `com.vocamac.app` vs. product
   name "TypeFlow") unless told it's deliberate. `scripts/app-name.sh` carries a detailed
   comment block explaining the rationale (existing installs must keep their prefs/models
   across the rename) but AGENTS.md never pointed to it. **Added** a short note to
   Project Overview per the orchestrator's explicit instruction not to flag this as a
   mismatch.

## Left unchanged (verified correct)
- Repository structure top-level shape, Swift Conventions, Architecture Patterns,
  Performance section, Testing "what to test / not to test", Git branch naming/commit
  conventions, PR workflow, Release Notes out-of-tree policy, entitlements/LSUIElement/
  MenuBarExtra notes, remaining Common Pitfalls (#1, #2, #3, #5).
- CI runner (`macos-15`) and `swift build` + `swift test` as the CI gate — confirmed
  against `.github/workflows/ci.yml`.

## Not touched (out of scope per task boundaries)
- No source code changes.
- No commits.
- Did not reconcile the internal contradiction in the project's own memory file
  (`local-whisper-project.md` says both "No Xcode.app on this Mac... swift test
  impossible" and, later, "Xcode 26.6 installed... swift test works" — the memory file
  itself is stale on the first claim). That file is outside AGENTS.md's scope; flagging
  here in case the user wants it cleaned up separately.
