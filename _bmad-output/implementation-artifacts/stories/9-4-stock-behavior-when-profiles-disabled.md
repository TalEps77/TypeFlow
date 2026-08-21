# Story 9.4: Restore pristine stock behavior when Profiles is disabled

Status: done

<!-- Remediation story. Source: adversarial acceptance audit, 2026-08-22.
Violates Epic 4 AC ("Given Profiles are disabled entirely... the Default
Profile always applies and behavior matches Epic 2's" — epics.md:575-577,
Story 4.2). -->

## Story

As a user who turns the Profiles master toggle off,
I want dictation to behave exactly like it did in Epic 2 — no leftover
prompt override or toggle changes from whatever I'd edited into the Default
Profile,
So that disabling Profiles is a real, complete opt-out rather than a
partial one.

## Context / Defect

Epic 4's AC for disabling Profiles is explicit: "the Default Profile always
applies and behavior matches Epic 2's" (epics.md:575-577) — i.e. stock,
pre-Profiles behavior: no prompt override, default toggles.

`ProfileManager.resolve(bundleIdentifier:profilesEnabled:)`
(`Sources/VocaMac/Services/ProfileManager.swift:32-37`) is:

```swift
func resolve(bundleIdentifier: String?, profilesEnabled: Bool) -> Profile {
    guard profilesEnabled, let bundleIdentifier else {
        return defaultProfile()
    }
    return store.profiles.first { $0.bundleIdentifiers.contains(bundleIdentifier) } ?? defaultProfile()
}
```

`defaultProfile()` (`ProfileManager.swift:43-45`) returns
`store.profiles.first { $0.isDefault }` — the **persisted, user-editable**
Default Profile record. The Profiles settings UI lets the user edit the
Default Profile's `promptOverride`, `postProcessEnabled`, and
`contextCaptureEnabled` (`Profile.swift:23-29`) like any other Profile. If
the user has edited the Default Profile — e.g. added a prompt override —
and then flips the Profiles master toggle **off**, `resolve` still returns
that edited record, because the `guard profilesEnabled, let bundleIdentifier
else` short-circuits straight to `defaultProfile()` without ever discarding
the user's edits. The edited prompt override (and any toggle changes) leak
through into what is supposed to be a full opt-out back to Epic 2 stock
behavior.

`Profile.makeDefault()` (`Profile.swift:66-77`) is the pristine built-in
Default: `promptOverride: ""`, `postProcessEnabled: true`,
`contextCaptureEnabled: false` — exactly Epic 2's stock behavior. The
existing test
`testProfilesDisabledAlwaysResolvesToDefaultEvenWithAMatchingProfile`
(`Tests/VocaMacTests/ProfileManagerTests.swift:80-88`) doesn't catch this
gap because it seeds the store with an *unedited* `Profile.makeDefault()`
as the Default — the edited-Default case is never exercised.

## Acceptance Criteria

1. With Profiles disabled (`profilesEnabled == false`), `ProfileManager
   .resolve` returns pristine built-in defaults — no prompt override, stock
   toggles (`postProcessEnabled: true`, `contextCaptureEnabled: false`) —
   **even when** the user has edited the persisted Default Profile in the
   store. Implement via whichever is the smaller diff: returning a fresh
   `Profile.makeDefault()` instance directly for the disabled case, or
   otherwise bypassing the store's edited record for that path. Do not
   change what "Default" means for the *enabled* case.
2. With Profiles enabled, the persisted (possibly user-edited) Default
   Profile still wins exactly as it does today — this story must not
   change resolution behavior when `profilesEnabled == true` in any way
   (matching bundle id, no match, nil bundle id all unchanged).
3. Unit tests pin both (1) and (2):
   - A disabled-resolution test where the store's Default Profile has been
     edited (non-empty `promptOverride`, and/or `postProcessEnabled:
     false` / `contextCaptureEnabled: true`) — asserts the resolved
     Profile matches `Profile.makeDefault()`'s values (empty override,
     stock toggles), not the edited store record.
   - An enabled-resolution test with the same edited store Default —
     asserts the resolved Profile **is** the edited record (its
     `promptOverride` and toggles come through unchanged), guarding
     against an overcorrection that breaks the enabled path.
4. Full suite green (`swift test`).

## Tasks / Subtasks

- [x] Task 1 — Fix `resolve` (AC: 1, 2)
  - [x] In `ProfileManager.resolve(bundleIdentifier:profilesEnabled:)`
        (`ProfileManager.swift:32-37`), split the current combined guard so
        the disabled case is handled on its own and returns
        `Profile.makeDefault()` directly, without touching `store.profiles`
        at all:
        ```swift
        func resolve(bundleIdentifier: String?, profilesEnabled: Bool) -> Profile {
            guard profilesEnabled else { return Profile.makeDefault() }
            guard let bundleIdentifier else { return defaultProfile() }
            return store.profiles.first { $0.bundleIdentifiers.contains(bundleIdentifier) } ?? defaultProfile()
        }
        ```
        (Illustrative — match existing style; the essential change is that
        `profilesEnabled == false` must never reach `defaultProfile()`/
        `store.profiles`.)
  - [x] Confirm `defaultProfile()` (`ProfileManager.swift:43-45`) is
        otherwise untouched — it's still correct for the enabled,
        nil-bundle-identifier and no-match paths.
- [x] Task 2 — Tests (AC: 3)
  - [x] Add to `Tests/VocaMacTests/ProfileManagerTests.swift`, near
        `testProfilesDisabledAlwaysResolvesToDefaultEvenWithAMatchingProfile`
        (line 80):
        - `testProfilesDisabledIgnoresAnEditedDefaultProfile`: seed the
          store with an edited Default (e.g. `Profile(id:
          Profile.defaultProfileID, name: "Default", promptOverride: "be
          extremely formal", postProcessEnabled: false,
          contextCaptureEnabled: true, isDefault: true)`) plus an unrelated
          bound Profile. Call `manager.resolve(bundleIdentifier: ...,
          profilesEnabled: false)`. Assert the result equals
          `Profile.makeDefault()` on the fields that matter
          (`promptOverride == ""`, `postProcessEnabled == true`,
          `contextCaptureEnabled == false`) — not the edited record's
          values.
        - `testProfilesEnabledStillUsesTheEditedDefaultProfile`: same
          seeded edited Default, call `resolve(bundleIdentifier: nil,
          profilesEnabled: true)` (or a non-matching bundle id). Assert
          the result's `promptOverride`/toggles match the **edited**
          record, proving the enabled path is unaffected by this fix.
- [x] Task 3 — Full suite (AC: 4)
  - [x] `swift test` green.

## Dev Notes

- Repo is Swift/SwiftPM (Xcode 26.6 installed); baseline 784 tests green.
- `Profile` is `Equatable` (`Profile.swift:10`), but comparing whole structs
  directly in the new "disabled" test would also compare `id` — a fresh
  `Profile.makeDefault()` and the resolved value should both carry
  `Profile.defaultProfileID` (`Profile.swift:64, 69`), so whole-struct
  equality against `Profile.makeDefault()` should work; if it doesn't
  (e.g. due to `bundleIdentifiers` differing), assert the individual fields
  called out in the AC instead.
- Do not touch `Profile.swift`, `ProfileStore`, or the Profiles settings UI
  — this defect is entirely inside `ProfileManager.resolve`.
- No commits by the dev agent.

### Project Structure Notes

- Touches only `Sources/VocaMac/Services/ProfileManager.swift` and
  `Tests/VocaMacTests/ProfileManagerTests.swift`.

### References

- [Source: Sources/VocaMac/Services/ProfileManager.swift:1-47]
- [Source: Sources/VocaMac/Models/Profile.swift:10-77]
- [Source: Tests/VocaMacTests/ProfileManagerTests.swift:1-88]
- [Source: _bmad-output/planning-artifacts/epics.md:509-590 (Epic 4, Story 4.2 AC)]

## Dev Agent Record

### Agent Model Used

claude-opus-5[1m] (BMAD dev agent, `bmad-build`)

### Debug Log References

- `swift test` — 786 tests, 1 skipped, 0 failures (baseline 784 + the 2 added
  here). One earlier run aborted with "input file HistoryView.swift was
  modified during the build" — a concurrent agent's edit, unrelated to this
  story; the immediate re-run was clean.

### Completion Notes List

- The fix is the split guard from Task 1, verbatim in shape: `guard
  profilesEnabled else { return Profile.makeDefault() }` ahead of the
  nil-bundle-identifier guard, so the disabled path never reaches
  `defaultProfile()` or `store.profiles`. `defaultProfile()` is untouched.
- A four-line comment above the guard records *why* disabled returns a fresh
  built-in rather than the stored record, matching the file's existing habit
  of explaining resolution decisions in place.
- Whole-struct `XCTAssertEqual` against `Profile.makeDefault()` works as the
  Dev Notes predicted — the returned value carries `Profile.defaultProfileID`
  and empty `bundleIdentifiers`, so no per-field fallback was needed. The
  edited-Default fixture is shared by both new tests via a small
  `editedDefault()` helper so the two ACs are pinned against literally the
  same record.
- The enabled-path test asserts both unmatched routes (nil bundle id *and* a
  non-matching bundle id) still return the edited Default, since both flow
  through `defaultProfile()`.
- Checked the one production caller (`AppState.swift:1074`): the resolved
  Profile is consumed by value for the context-capture gate and `language`,
  never used as a store lookup key, so returning a fresh instance changes
  nothing beyond the intended field values. No files outside this story's
  stated surface were touched; no commits made.

### File List

- `Sources/VocaMac/Services/ProfileManager.swift` (modified)
- `Tests/VocaMacTests/ProfileManagerTests.swift` (modified)

## Change Log

| Date | Change |
| --- | --- |
| 2026-08-22 | Story implemented: `resolve` returns pristine `Profile.makeDefault()` when Profiles are disabled; 2 tests added pinning the disabled and enabled paths against the same edited Default. Suite green (786). Status → review. |

---

**Validation: PASSED 2026-08-22** — the fix is a two-line, fully-specified
change with an illustrative diff, and both ACs (disabled-bypasses-edits,
enabled-unaffected) are pinned by tests that seed the exact same edited
Default record so the "smaller diff" instruction can't accidentally
overcorrect the enabled path. No fixes needed.

## Code Review

**Reviewer:** bmad-review-adversarial-general (fresh, no prior context)
**Date:** 2026-08-22
**Verdict: APPROVED**

### Verified

- **Diff matches the spec exactly.** `resolve` now short-circuits `guard
  profilesEnabled else { return Profile.makeDefault() }` before the
  bundle-identifier guard; `defaultProfile()` is untouched
  (`Sources/VocaMac/Services/ProfileManager.swift:33-39`).
- **All call sites traced.** Every production consumer of profile
  resolution goes through `ProfileManager.resolve` with `profilesEnabled`
  correctly threaded — `AppState.swift:891` (menu-bar language override,
  itself gated by an outer `guard profilesEnabled`), `:1074` (dictation
  capture, feeds `capturedProfile` → `resolvedProfile` → the post-ASR
  pipeline at `:1284`), and `:1425` (Command Mode language). None reads
  `store.profiles` or `store.defaultProfile()` directly; there is no
  alternate path into `defaultProfile()` that bypasses the new guard.
- **`Profile.makeDefault()` is genuinely pristine and matches Epic-2
  stock**: `promptOverride: ""`, `postProcessEnabled: true`,
  `contextCaptureEnabled: false`, `bundleIdentifiers: []`, `language: nil`
  (`Profile.swift:67-77`) — the `nil` language falls back to
  `AppState.selectedLanguage`, which is exactly Epic 2's (pre-Profiles,
  pre-8.2) behavior, not a new user-visible default.
- **Tests assert full-struct equality**, not single fields:
  `XCTAssertEqual(resolved, Profile.makeDefault())` and
  `XCTAssertEqual(resolved, edited)` — both meaningful because
  `editedDefault()` shares `id`/`bundleIdentifiers: []`/`language: nil`
  with `makeDefault()`, so the only fields that can make the disabled-path
  assertion pass are the ones the bug leaked (`promptOverride`,
  `postProcessEnabled`, `contextCaptureEnabled`).
- **No regression on the enabled path**: the enabled branch's logic
  (`nil` bundle id → `defaultProfile()`; match → bound profile; no match →
  `defaultProfile()`) is byte-for-byte unchanged, and
  `testProfilesEnabledStillUsesTheEditedDefaultProfile` pins it against the
  same edited fixture, covering both the nil and non-matching-bundle-id
  routes.
- **`swift test --filter ProfileManagerTests`**: 9/9 passed, 0 failures.

### Findings

None — no BLOCKER, MAJOR, or MINOR findings. Scope was held exactly to the
two stated files.

<!-- checkpoint: epic-9 closed 2026-08-22 — story done, code-review approved, suite 796 green, committed with re-verification round -->
