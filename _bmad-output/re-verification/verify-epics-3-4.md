# Post-hoc acceptance re-verification — Epics 3 & 4

**Project:** local-whisper (TypeFlow, VocaMac fork) — macOS Swift/SwiftPM menu-bar dictation app
**Date:** 2026-08-22
**Method:** BMad `bmad-review` — lenses **verification-gap** + **adversarial**, run over the delivered code against the acceptance criteria in `/Users/talepstein/Projects/local-whisper/_bmad-output/planning-artifacts/epics.md` (Epic 3: lines 364–506; Epic 4: lines 509–658).
**Constraint:** read-only on the repo. One targeted `swift test --filter TextInjectorTests` run (22 tests, 1 skipped, 0 failures) plus a subagent-run 24-test filter over the Epic 4 privacy/import tests.
**Content class:** code. Both lenses ran independently on the same content; overlap between them is retained, not deduplicated.

---

## 1. Verdict summary

| Epic | ACs checked | SATISFIED | PARTIAL | VIOLATED | UNVERIFIABLE |
|---|---|---|---|---|---|
| Epic 3 — Transcription History | 22 | 16 | 5 | 0 | 1 |
| Epic 4 — Profiles & Cursor Context | 27 | 18 | 7 | 0 | 2 |
| **Total** | **49** | **34** | **12** | **0** | **3** |

No acceptance criterion was found violated. Every PARTIAL is a **verification** shortfall — the behavior is implemented and reads correctly, but nothing in the suite would fail if it broke — except **4.2 "Profiles disabled ⇒ behavior matches Epic 2's"**, which is a genuine behavioral shortfall (see F-06).

**Verdict key.** `SATISFIED` = implemented *and* a test would fail if it regressed. `SATISFIED (untested)` is recorded as SATISFIED where the AC does not itself demand a test and the code was read end-to-end. `PARTIAL` = the AC is only partly met, or the AC explicitly demands a test that is missing or vacuous. `UNVERIFIABLE` = only real Accessibility-API or perceptual behavior can settle it; manual-only by nature.

---

## 2. Epic 3 — Transcription History

### Story 3.1 — Persist every dictation via a shared JSON file store

| # | Acceptance criterion | Verdict | Implementation | Verification |
|---|---|---|---|---|
| 3.1-a | `JSONFileStore<T: Codable>` under `Sources/VocaMac/Stores/`; atomic write to `~/Library/Application Support/VocaMac/`; serial `.utility` queue; non-blocking | **PARTIAL** | `Stores/JSONFileStore.swift:12` (type), `:58` (serial `.utility` queue), `:116-142` (encode + `.atomic` write off-main), `:61-65` (default directory) | `JSONFileStoreTests.swift:73` asserts the write is enqueued, not inline; `:59` the file lands; `:173`/`:187` concurrent saves serialize. **The default directory is never asserted** — every test injects `directoryURL: tempDirectory` (`:27-29`). See **F-01** |
| 3.1-b | Corrupt/unreadable file → empty value, logged, no crash, startup not blocked | SATISFIED | `JSONFileStore.swift:71-89`; quarantine `:95-105` | `JSONFileStoreTests.swift:151` (corrupt), `:161` (wrong-shape JSON), `:89` (original preserved rather than overwritten) |
| 3.1-c | Record captures raw transcript, final text, timestamp, bundle id, profile name, model, per-stage latencies, fallback, mode | SATISFIED | `Models/HistoryRecord.swift:23-76`; written at `Models/AppState.swift:1823-1834` | `HistoryStoreTests.swift:16` (round-trip), `:339`, `:371` (recording/ASR ms), `:457` (post-process ms), `:468` (`didFallback`) |
| 3.1-d | Each record carries a `UUID id` | SATISFIED | `HistoryRecord.swift:23`, `:79` | `HistoryStoreTests.swift:16` |
| 3.1-e | Records survive app restart | SATISFIED | `HistoryStore.swift:46` (load on init), `:112` | `HistoryStoreTests.swift:130` (fresh instance at the same file) |
| 3.1-f | No field capable of holding cursor context; **a test asserts** a serialized record contains no context payload | **PARTIAL** | `HistoryRecord.swift` — the type genuinely has no such field | `HistoryStoreTests.swift:50` exists but the schema lock is vacuous. See **F-02** |
| 3.1-g | Never transmitted; excluded from any diagnostic export | SATISFIED (untested) | Export is log lines + `SystemInfo` only (`Services/Logger.swift:302-328`); the only network call sites are `ModelManager`, `PostProcessService`, `UpdateChecker`, none of which reads history | No assertion; `LoggerTests.swift:137`/`:145` only check the header and system-info lines. See **F-03** |

### Story 3.2 — Browse, search, and clear history

| # | Acceptance criterion | Verdict | Implementation | Verification |
|---|---|---|---|---|
| 3.2-a | Newest-first list with timestamp, target app, text preview | SATISFIED | `HistoryStore.swift:46`/`:68`; `Views/HistoryView.swift:26-37`; `HistoryRowView:124-157` | `HistoryStoreTests.swift:119` (newest-first at the store). No view-level test; the row prints the raw bundle id — see **F-15** |
| 3.2-b | Detail shows both Raw Transcript and Final Text | SATISFIED (untested) | `HistoryView.swift:202-209` — when the two are identical one merged "Transcript" section is shown; a Command Mode record shows only the instruction, by design (AD-5) | none |
| 3.2-c | Search field filters the list | SATISFIED | `HistoryStore.swift:92-99`; `HistoryView.swift:17`, `:40` | `HistoryStoreTests.swift:173`, `:184`, `:196` (niqqud folding), `:203` (Hebrew), `:214` |
| 3.2-d | Delete one, delete all, set a retention limit | SATISFIED | `HistoryStore.swift:73-81`, `:26`; `HistoryView.swift:33`, `:47`, `:91-98` | `HistoryStoreTests.swift:149`, `:161`, `:263`, `:306` |
| 3.2-e | Retention enforced automatically as records arrive | SATISFIED | `HistoryStore.swift:69`, `:104-109` | `HistoryStoreTests.swift:224`, `:237` (boundary), `:248` (0 = unlimited), `:274` (enforced on load too) |

The story's own "Known gap" note (target app read "Unknown app" until Story 4.1) is closed: `AppState.swift:1826` now populates `targetBundleId` and `AXContextReaderTests.swift:73` asserts it.

### Story 3.3 — Re-paste a previous transcription

| # | Acceptance criterion | Verdict | Implementation | Verification |
|---|---|---|---|---|
| 3.3-a | Menu-bar re-paste injects the most recent Final Text via the same `TextInjector` path | SATISFIED | `AppState.swift:1770-1776`; `Views/MenuBarView.swift:468-487` | `HistoryStoreTests.swift:518`, `:531` |
| 3.3-b | Re-paste any listed record from the history view | SATISFIED | `HistoryView.swift:31`, `:60` → `AppState.swift:1728` | `HistoryStoreTests.swift:485` |
| 3.3-c | **No duplicate History Record** | SATISFIED | `AppState.rePaste` never touches `historyStore.record` (`AppState.swift:1728-1749`) | `HistoryStoreTests.swift:495` asserts `recordCallCount == 0` |
| 3.3-d | With clipboard preservation on, prior clipboard restored exactly as in a normal injection | **PARTIAL** | flag forwarded at `AppState.swift:1747`; restore at `Services/TextInjector.swift:894-960` | `HistoryStoreTests.swift:504` only asserts the flag reaches the mock. See **F-04** |

Beyond the AC, re-paste carries two hardening behaviors with tests: an idle gate (`AppState.swift:1729`, tests `HistoryStoreTests.swift:545-587`) and focus hand-back to the previous app (`AppState.swift:1755-1767`).

### Story 3.4 — Undo the last injection

| # | Acceptance criterion | Verdict | Implementation | Verification |
|---|---|---|---|---|
| 3.4-a | Injected text is removed from the target application | **PARTIAL** | `TextInjector.swift:290-330` | Dispatch is verified (`ServiceTests.swift:209`, `undoCount == 1`); the removal itself is not observable in-process. The `AppState` seam is entirely untested — see **F-05** |
| 3.4-b | Offered only within a short window with the same app still frontmost | SATISFIED | `TextInjector.swift:276-279`, `:332-368` | `ServiceTests.swift:168` (window), `:181` (different app), `:194` (happy path), `:274`/`:293` (self-transparency guard) |
| 3.4-c | When unsafe, **unavailable rather than destructive** | SATISFIED | `TextInjector.swift:291`, `:298` (record consumed up front, so a refusal stays refused) | `ServiceTests.swift:163`, `:178`, `:191`, `:209` (unrepeatable), `:253` (AX refuses without a recorded element) |
| 3.4-d | The UI states the best-effort limitation | **PARTIAL** | `MenuBarView.swift:510` — a `.help()` tooltip only | none. See **F-16** |
| 3.4-e | AX path retracts precisely | **UNVERIFIABLE** | `TextInjector.swift:381-…` — proves focus is still the written element and the span reads back as exactly our text before deleting | only the refusal branch is tested (`ServiceTests.swift:253`); the read-back proof has no test and needs a live AX element |
| 3.4-f | Clipboard path synthesizes ⌘Z; app-dependence an accepted documented limitation | SATISFIED | `TextInjector.swift:328` | `ServiceTests.swift:209` (exactly one ⌘Z), `:234` (reports failure when the keystroke cannot be dispatched) |

---

## 3. Epic 4 — Profiles and Cursor Context

### Story 4.1 — Capture the frontmost application at recording start

| # | Acceptance criterion | Verdict | Implementation | Verification |
|---|---|---|---|---|
| 4.1-a | `AXContextReader` is a `@MainActor` service with a protocol in `ServiceProtocols.swift` (AD-7) | SATISFIED (pre-approved deviation) | `Services/AXContextReader.swift:34` (`@MainActor protocol ContextReading`), `:71`; pointer stub `Services/ServiceProtocols.swift:208-213`; injected protocol-typed at `AppState.swift:239`, `:574`, `:580` | Compile-time + mock at `Tests/…/Mocks/MockServices.swift:650`. Placement deviation is documented and accepted at `epics.md:541-555` |
| 4.1-b | Bundle id captured **at recording start** via `NSWorkspace`, not at stop | SATISFIED | `AXContextReader.swift:111`; called from `AppState.swift:1073` inside `startRecording()` | `AXContextReaderTests.swift:34` (`captureCallCount == 1` after start), `:47` (stop without start ⇒ `captureCallCount == 0`) |
| 4.1-c | Switching apps mid-dictation uses the originally-captured id | SATISFIED | `AppState.swift:1264`, `:1283` | `AXContextReaderTests.swift:96` mutates the mock mid-flight and asserts the record still names TextEdit |
| 4.1-d | No frontmost app → nil id, pipeline proceeds | SATISFIED | `AXContextReader.swift:113-117`; nil tolerated at `AppState.swift:1283` | `AXContextReaderTests.swift:84` |
| 4.1-e | Bundle id persisted to the History Record | SATISFIED | `AppState.swift:1826`; field `HistoryRecord.swift:35` | `AXContextReaderTests.swift:73` |

### Story 4.2 — Resolve a Profile from the bundle identifier

| # | Acceptance criterion | Verdict | Implementation | Verification |
|---|---|---|---|---|
| 4.2-a | Captured id resolves to a matching Profile | SATISFIED | `Services/ProfileManager.swift:36` | `ProfileManagerTests.swift:37`; wiring asserted at `AXContextReaderTests.swift:241` |
| 4.2-b | No match → Default Profile | SATISFIED | `ProfileManager.swift:36`, `:43-45` | `ProfileManagerTests.swift:46`, `:56`, `:67` |
| 4.2-c | The Profile's prompt override steers the LLM | SATISFIED | `Pipeline/Stages/PostProcessStage.swift:79-88` | `PostProcessStageTests.swift:199`, `:209`/`:225` (blank override falls back), `:239` |
| 4.2-d | Per-feature toggles for post-processing and context capture honored | SATISFIED | `PostProcessStage.swift:66-68`; `AppState.swift:1076` (`global && profile`) | `PostProcessStageTests.swift:249`, `:262`, `:274`; `AXContextReaderTests.swift:128`/`:139`/`:150` |
| 4.2-e | Profiles disabled entirely → Default always applies **and behavior matches Epic 2's** | **PARTIAL** | `ProfileManager.swift:33-35` returns the *user-editable* Default, not a pristine one | `ProfileManagerTests.swift:80` (a matching profile is ignored when disabled); `AXContextReaderTests.swift:260`. No test edits the Default and then disables Profiles. See **F-06** |
| 4.2-f | Profile name persisted to the History Record | SATISFIED | `AppState.swift:1827`; field `HistoryRecord.swift:39` | `AXContextReaderTests.swift:250` |
| 4.2-g | Default Profile editable but **not deletable** | SATISFIED | `Stores/ProfileStore.swift:70-77` refuses; `isDefault` is `let` (`Models/Profile.swift:34`); `Profile.sanitizedForImport:112-145` re-asserts exactly one Default | `ProfileStoreTests.swift:106` (delete returns `false`, profile survives), `ProfileTests.swift:94`. Enforced in the store, not merely hidden in the UI |

### Story 4.3 — Profiles settings tab, starter profiles, JSON export

| # | Acceptance criterion | Verdict | Implementation | Verification |
|---|---|---|---|---|
| 4.3-a | Create, edit, reorder, delete Profiles | **PARTIAL** | `Views/ProfilesSettingsTab.swift:90` (add), `:60`/`:111` (edit sheet), `:64` (`.onMove`), `:67` (`.onDelete`); store ops `ProfileStore.swift:55`, `:60`, `:70`, `:79` | Store layer tested (`ProfileStoreTests.swift:70`, `:80`, `:94`, `:116`). No view test exists at all. See **F-07**, **F-17** |
| 4.3-b | Each Profile exposes name, bundle ids, prompt override, both toggles | SATISFIED (untested) | `ProfilesSettingsTab.swift:284` (name), `:288-321` (bundle ids), `:323` (override), `:373-375` (toggles) | none |
| 4.3-c | Pick from currently-running applications | **UNVERIFIABLE** | `ProfilesSettingsTab.swift:272-280` (`NSWorkspace.shared.runningApplications`, `.regular` only), picker `:309-319` | none — it is a `private var` on a `private struct` view |
| 4.3-d | Fresh install ships chat / mail / code-editor starters | SATISFIED | `Models/Profile.swift:152-182`; seeded at `ProfileStore.swift:37-42`; prompts `Models/Prompts.swift:339`, `:365`, `:389` | `ProfileStoreTests.swift:34` (exact set and count on a fresh store); `ProfileTests.swift:27` (three names, non-default, bound, distinct non-empty overrides) |
| 4.3-e | Export writes Profiles as a single JSON file | **PARTIAL** | `ProfilesSettingsTab.swift:148-165` (`NSSavePanel` + `JSONEncoder().encode(profileStore.profiles)`) | `ProfileTests.swift:61` round-trips `[Profile]` through Foundation's coders — that tests Foundation, not `exportProfiles()`. See **F-08** |
| 4.3-f | Importing that file restores them | **PARTIAL** | `ProfilesSettingsTab.swift:189` (decode) → `:203` (`replaceAll`) → `ProfileStore.swift:95-100` | `ProfileStoreTests.swift:128`, `:141` cover `replaceAll`; `ProfileTests.swift:167` covers sanitizing. Nothing covers the file→store path |
| 4.3-g | Malformed import rejected with a clear message, existing Profiles uncorrupted | **PARTIAL** | `ProfilesSettingsTab.swift:181-215`: size guard `:183`, empty-array guard `:190`, `catch` → `importErrorMessage` `:214`. `replaceAll` is reachable only after a complete successful decode, so no partial write is structurally possible | **No test exercises a malformed payload anywhere.** See **F-09**, **F-18** |

### Story 4.4 — Supply Cursor Context to the LLM, off by default

| # | Acceptance criterion | Verdict | Implementation | Verification |
|---|---|---|---|---|
| 4.4-a | Both toggles on → text before/after read via AX and truncated to a bounded budget | **PARTIAL** | gate `AppState.swift:1076`; AX read `AXContextReader.swift:124-129`; budget `:77` (500/side); primary windowing `:257-271`; fallback slicing `:148-165` | `CursorContextTests.swift:18-153` exercises `slice` exhaustively (per-side budget, caret at ends, clamping, selection exclusion, surrogate pairs) — but `slice` is only the **fallback**. The primary parameterized-attribute path has zero coverage. See **F-10** |
| 4.4-b | Context is included in the post-processing request | SATISFIED | `PostProcessStage.swift:95-101`; `Services/PostProcessService.swift:182-194` | `AXContextReaderTests.swift:162` drives a real start→stop through a real `PostProcessStage`; `PostProcessServiceTests.swift:97`, `:111` |
| 4.4-c | Off by default — nothing read, nothing sent | SATISFIED | Global `AppState.swift:148` (`@AppStorage … = false`, and there is no `register(defaults:)` anywhere in `Sources/`, so the literal is the shipped default); per-profile `Profile.swift:48`, `:74`, `:159`/`:166`/`:179`; import can never arm it (`Profile.swift:134` hardcodes `false`) | `AXContextReaderTests.swift:118`; `ProfileTests.swift:20`, `:41`, `:77` (hostile import cannot arm it); `PostProcessServiceTests.swift:78` (a no-context request is byte-for-byte unchanged) |
| 4.4-d | No readable context → post-processing proceeds without it | **PARTIAL** | `AXContextReader.swift:124-127`; role allow-list `:90-93`; secure-field deny-list `:99-102`; pid re-check `:222-226` | "Proceeds without it" is covered indirectly (nil-context fixtures complete and record). The allow-list/deny-list themselves have no test. See **F-11** |
| 4.4-e | Never in the History Record, never to `VocaLogger` **at any level**, never persisted | SATISFIED | `HistoryRecord.swift:23-76` has no such field; `AXContextReader.swift` contains zero `VocaLogger` calls; `PostProcessService.swift:71-76` reports the echo case by **length only**; `TranscriptPipeline.swift:115` logs only a sanitized reason; `PostProcessService.swift:727` sets `configuration.urlCache = nil` | `CursorContextTests.swift:223-300` — full start→stop with a distinctive token, `VocaLogger.setLogLevel(.debug)` at `:215`, a sanity check that the token *did* reach the service (`:265`), then absence assertions against the encoded record (`:274`), the log file (`:280`), `exportLogs` (`:286`), and `profiles.json` (`:295`). This is the strongest test in either epic |
| 4.4-f | Released from memory immediately after the request | SATISFIED | `AppState.swift:1266-1268`, `:1090`, `:1338`, `discardCapturedContext():1005-1016`; `TranscriptPipeline.swift:108-111` and `:158-159` | `CursorContextTests.swift:341` (guards against a vacuous fixture), `:348`, `:364`, `:378`, `:398`, `:410`, `:422`; `AXContextReaderTests.swift:199` |
| 4.4-g | A test asserts no log output and no persisted record contains the payload | SATISFIED | — | `CursorContextTests.swift:271-288` is exactly that test, and the `.debug` override at `:214-215` is what gives it the power to fail |
| 4.4-h | Read on the main thread, negligible latency, never blocks injection (NFR-4) | **UNVERIFIABLE** | `AXContextReader` is `@MainActor` (`:71`), bounded by `contextCharacterBudget = 500` (`:77`) and `maximumWholeValueCharacters = 200_000` (`:84`); structurally cannot block injection — capture is at recording *start* (`AppState.swift:1073`), injection at stop (`AppState.swift:1300`) | No latency test anywhere; manual-only |

---

## 4. Finding index

The tables above cross-reference findings by number. Findings themselves are in sections 5 and 6, in the order listed here per lens.

| ID | Lens | Finding | Location |
|---|---|---|---|
| F-01 | verification-gap | Default Application Support directory never asserted | `JSONFileStore.swift:61-65` |
| F-02 | verification-gap | AD-5 schema lock is vacuous for nil Optionals | `HistoryStoreTests.swift:50-77` |
| F-05 | verification-gap | `AppState` undo seam has no test at all | `AppState.swift:1782`, `:1787` |
| F-04 | verification-gap | Clipboard restoration never asserted | `TextInjector.swift:894-960` |
| F-12 | verification-gap | Environment-gated `XCTSkip` makes green machine-dependent | `ServiceTests.swift:405`, `:433`, `:459` |
| F-03 | verification-gap | History-excluded-from-export unasserted | `Logger.swift:302-328` |
| F-13 | verification-gap | `contextCharacterBudget` constant unread by tests | `AXContextReader.swift:77` |
| F-11 | verification-gap | Secure-role allow/deny lists untested | `AXContextReader.swift:90-102` |
| F-10 | verification-gap | Primary AX window math untested (only the fallback is) | `AXContextReader.swift:257-271` |
| F-09 | verification-gap | Malformed Profiles import never exercised | `ProfilesSettingsTab.swift:181-215` |
| F-07 | verification-gap | `.onMove` / `.onDelete` unreachable by any test | `ProfilesSettingsTab.swift:64`, `:67` |
| F-14 | verification-gap | `urlCache = nil` unasserted | `PostProcessService.swift:727` |
| F-19 | verification-gap (other) | Second AX document read outside the AD-5 leak test's scope | `CorrectionLearner.swift:124` |
| F-20 | adversarial | `quarantinedFileURL` has no production consumer | `JSONFileStore.swift:93` |
| F-15 | adversarial | History rows show raw bundle ids, not app names | `HistoryView.swift:137`, `:180` |
| F-16 | adversarial | Undo caveat is a hover tooltip only | `MenuBarView.swift:510` |
| F-21 | adversarial | Undo row visibility is not observable state | `AppState.swift:1782` |
| F-22 | adversarial | `willTerminateNotification` observer never removed | `HistoryStore.swift:58-64` |
| **F-06** | adversarial | **Disabling Profiles does not restore Epic 2 behavior** | `ProfileManager.swift:33-35` |
| F-18 | adversarial | Malformed-import message is `DecodingError`'s generic string | `ProfilesSettingsTab.swift:214` |
| F-17 | adversarial | No visible delete affordance on a Profile row | `ProfilesSettingsTab.swift:64-67` |
| F-08 | adversarial | Export/import have no testable seam | `ProfilesSettingsTab.swift:148`, `:173` |
| F-23 | adversarial | Budget truncation implemented twice | `AXContextReader.swift:148-165`, `:257-271` |
| F-24 | adversarial | Mutually exclusive skips — no machine runs all three | `ServiceTests.swift:405`, `:433`, `:459` |
| F-25 | adversarial | Search re-scans every record on every render | `HistoryView.swift:16-18` |
| F-26 | adversarial | `record()` inserts positionally, not by timestamp | `HistoryStore.swift:68`, `:107` |

---

## 5. Findings — Verification Gap lens

```json
[
  {
    "lens": "verification-gap",
    "location": "Sources/VocaMac/Stores/JSONFileStore.swift:61-65 — the default persistence directory",
    "trigger_condition": "Nothing asserts that the shipped store writes to ~/Library/Application Support/VocaMac/; every test injects a temp directory.",
    "guard_snippet": "One test that constructs JSONFileStore without `directoryURL` and asserts the resolved path ends in \"Application Support/VocaMac/history.json\" — e.g. XCTAssertTrue(JSONFileStore.applicationSupportDirectory().path.hasSuffix(\"Application Support/VocaMac\")).",
    "potential_consequence": "Renaming the folder — precisely what the Epic 8 'TypeFlow' rebrand invites — silently orphans every user's history.json, stats, profiles, dictionary and snippets on upgrade. All 14 JSONFileStoreTests and all HistoryStoreTests stay green because they pass directoryURL: tempDirectory (JSONFileStoreTests.swift:27-29, HistoryStoreTests.swift:107).",
    "gap_shape": "regression-gap",
    "consumer": "the production HistoryStore constructor at Sources/VocaMac/Stores/HistoryStore.swift:45, plus ProfileStore, DictionaryStore, SnippetStore and DismissedCorrectionsStore, which all default the same way",
    "evidence": "Read all of Tests/VocaMacTests/JSONFileStoreTests.swift; makeStore() at :27-29 always passes tempDirectory. grep for 'applicationSupportDirectory' and 'Application Support' across Tests/ returns only a comment at ModelTests.swift:263."
  },
  {
    "lens": "verification-gap",
    "location": "Tests/VocaMacTests/HistoryStoreTests.swift:50-77 — the AD-5 'no context payload' schema lock",
    "trigger_condition": "The schema-lock test cannot detect a newly added Optional field, which is exactly the shape a leaked cursor-context field would take.",
    "guard_snippet": "Populate every field in the fixture (including `language:`) and add `language` to expectedKeys, or drive the assertion off Mirror(reflecting:) over the struct rather than the encoded keys, so a nil-valued new field is still seen.",
    "potential_consequence": "Adding `let cursorContextBefore: String?` to HistoryRecord and leaving it nil in this fixture would keep the test green while the field ships — the AC's explicit guarantee ('no field exists capable of holding cursor context') would be unenforced. The gap is already live: `language` (HistoryRecord.swift:76) is a real field absent from expectedKeys at :63-67 and the test still passes.",
    "gap_shape": "broken-verification-gap",
    "consumer": "Sources/VocaMac/Models/HistoryRecord.swift:23-76 — the persisted history schema",
    "evidence": "Read the test: it encodes HistoryRecord(rawTranscript:finalText:targetBundleId:profileName:modelName:) with no `language:` argument, then asserts Set(keys) == expectedKeys where expectedKeys omits 'language'. Confirmed empirically with a standalone Swift script that JSONEncoder's synthesized encoding omits nil Optionals: `{\"a\":\"x\"}` vs `{\"a\":\"x\",\"ctx\":\"SECRET\"}`."
  },
  {
    "lens": "verification-gap",
    "location": "Sources/VocaMac/Models/AppState.swift:1782 and :1787 — the AppState→TextInjector undo seam",
    "trigger_condition": "Neither AppState.canUndoLastInjection nor AppState.undoLastInjection() is touched by any test, even though MockTextInjector already implements both.",
    "guard_snippet": "Two tests in the AppState suite: set mocks.textInjector.canUndoLastInjection = true and assert appState.canUndoLastInjection; call appState.undoLastInjection() and assert mocks.textInjector.undoLastInjectionCallCount == 1 and the returned Bool is forwarded.",
    "potential_consequence": "Inverting or hard-coding the forwarding (`var canUndoLastInjection: Bool { false }`) makes the Undo row at MenuBarView.swift:489 never render — Story 3.4 disappears from the product — with a fully green suite.",
    "gap_shape": "regression-gap",
    "consumer": "the Undo row in Sources/VocaMac/Views/MenuBarView.swift:489-492, the only entry point to FR-10",
    "evidence": "grep -rn 'canUndoLastInjection|undoLastInjection' over Tests/ returns hits only in Mocks/MockServices.swift:444-456 (the unused mock surface) and ServiceTests.swift, which exercises TextInjector directly and never goes through AppState."
  },
  {
    "lens": "verification-gap",
    "location": "Sources/VocaMac/Services/TextInjector.swift:894-960 — clipboard snapshot and restore",
    "trigger_condition": "AC 3.3's 'the prior clipboard contents are restored exactly' is asserted nowhere; the only re-paste test checks that the boolean reaches a mock.",
    "guard_snippet": "Seed NSPasteboard.general with a sentinel, call inject(text:preserveClipboard: true), wait past the restore delay, and assert the pasteboard reads back the sentinel — the mirror of ServiceTests.swift:457, which already does the false case.",
    "potential_consequence": "Dropping the restore dispatch, or flipping the `preserveClipboard && !isOurOwnContent` condition at TextInjector.swift:911, destroys the user's clipboard on every dictation and every re-paste. Nothing fails: HistoryStoreTests.swift:504 only reads mocks.textInjector.lastPreserveClipboard.",
    "gap_shape": "regression-gap",
    "consumer": "AppState.rePaste at Sources/VocaMac/Models/AppState.swift:1747 and the live dictation injection at AppState.swift:1300",
    "evidence": "Read both real-pasteboard tests — ServiceTests.swift:431 and :457 — and both pass preserveClipboard: false. grep for 'restore' in ServiceTests.swift returns only comments at :81-89 about the restore *delay*."
  },
  {
    "lens": "verification-gap",
    "location": "Tests/VocaMacTests/ServiceTests.swift:405, :433, :459 and :195 — environment-gated XCTSkip",
    "trigger_condition": "Which injection and undo tests actually execute depends on whether the running machine has granted Accessibility permission and can report a frontmost app; the suite reports success either way.",
    "guard_snippet": "Fail rather than skip when the environment is unexpectedly restricted (an explicit opt-out env var for CI), or refactor the AX-trusted branch behind an injectable predicate the way undoKeystrokeDispatcher already is at ServiceTests.swift:143.",
    "potential_consequence": "'784 tests, 0 failures' is machine-conditional. On this Mac `swift test --filter TextInjectorTests` reports 22 executed, 1 skipped; on a permission-less CI box the skips invert and the entire clipboard-fallback path (:459) plus the overlapping-injection guard (:405) stop running, so a regression in either lands green.",
    "gap_shape": "broken-verification-gap",
    "consumer": "the clipboard injection path in Sources/VocaMac/Services/TextInjector.swift:894, reached by every dictation into a non-AX-writable app",
    "evidence": "Ran `swift test --filter TextInjectorTests`: 'Executed 22 tests, with 1 test skipped and 0 failures' — the skip being testInjectCopiesTextToClipboardWhenNotTrusted, skipped because permission IS granted here. The guards at :405 and :459 are the inverse condition."
  },
  {
    "lens": "verification-gap",
    "location": "Sources/VocaMac/Services/Logger.swift:302-328 — the debug log export",
    "trigger_condition": "AC 3.1's 'excluded from any diagnostic export' holds only by the export happening not to mention history; nothing pins it.",
    "guard_snippet": "Record a dictation with a distinctive token, then assert VocaLogger.exportLogs() does not contain it — the same shape CursorContextTests.swift:286 already uses for cursor context.",
    "potential_consequence": "Adding a 'recent transcriptions' section to the troubleshooting export (a natural support request) would put verbatim transcripts into a file users paste into issue trackers, with no failing test.",
    "gap_shape": "regression-gap",
    "consumer": "Sources/VocaMac/Views/SettingsView.swift:1459 exportDebugLogs(), the user-facing 'Export Logs' button",
    "evidence": "Read formatExportedLogs (Logger.swift:302-328): header, SystemInfo, app version, then getLastLines. grep for 'history|History' in Logger.swift returns only the LogCategory case at :24. LoggerTests.swift:137/:145 assert the header and system-info lines only."
  },
  {
    "lens": "verification-gap",
    "location": "Sources/VocaMac/Services/AXContextReader.swift:77 — contextCharacterBudget",
    "trigger_condition": "The bounded-budget guarantee rests on a constant no test reads; every slice test passes its own explicit budget.",
    "guard_snippet": "Assert the constant directly (XCTAssertEqual(AXContextReader.contextCharacterBudget, 500)) and add one end-to-end assertion that the context reaching PostProcessService is ≤ budget per side.",
    "potential_consequence": "Changing 500 to 500_000 keeps every CursorContextTests case green while whole documents start flowing to the LLM on each dictation — the opposite of AD-5's minimization intent.",
    "gap_shape": "regression-gap",
    "consumer": "Sources/VocaMac/Services/AXContextReader.swift:124-129, the live capture called from AppState.swift:1073",
    "evidence": "Reported by the Epic 4 audit; the slice tests at CursorContextTests.swift:18-153 all pass an explicit `budget:` argument and none reads the constant."
  },
  {
    "lens": "verification-gap",
    "location": "Sources/VocaMac/Services/AXContextReader.swift:90-102 — readableRoles / secureRoleIdentifiers",
    "trigger_condition": "The allow-list and secure-field deny-list that keep password fields out of the LLM request are referenced by no test.",
    "guard_snippet": "Mirror the existing TextInjector constant tests: assert secureRoleIdentifiers contains kAXSecureTextFieldSubrole and \"AXSecureTextField\", and that readableRoles is disjoint from it.",
    "potential_consequence": "Deleting kAXSecureTextFieldSubrole from the deny-list, or widening readableRoles, would start shipping password-field and arbitrary-UI text to the LLM with zero test failures.",
    "gap_shape": "regression-gap",
    "consumer": "isReadableTextElement at Sources/VocaMac/Services/AXContextReader.swift:234, the gate on every cursor-context read",
    "evidence": "grep -rn 'readableRoles|secureRoleIdentifiers' over Tests/ returns only ServiceTests.swift:568-571, which tests TextInjector.secureRoleIdentifiers — the parallel constants on the other service. The pattern exists and was simply not applied to AXContextReader."
  },
  {
    "lens": "verification-gap",
    "location": "Sources/VocaMac/Services/AXContextReader.swift:257-271 — the primary parameterized-attribute window math",
    "trigger_condition": "Truncation is implemented twice; only the fallback implementation is tested.",
    "guard_snippet": "Drive cursorContext(around:budget:) through a stubbed AX element that answers kAXNumberOfCharactersAttribute and kAXStringForRangeParameterizedAttribute, and assert the requested ranges — or extract the range arithmetic into a pure function and test it the way slice is tested.",
    "potential_consequence": "Breaking the primary path (e.g. `let beforeStart = 0`) sends the entire document before the caret to the LLM on every real AX read while all 20-plus slice tests stay green, because slice runs only when the parameterized read fails.",
    "gap_shape": "regression-gap",
    "consumer": "AXContextReader.cursorContext(around:budget:), the path actually taken in any app that implements the parameterized attribute (which is most of them)",
    "evidence": "Reported by the Epic 4 audit: the fallback slicing lives at :148-165 and is what CursorContextTests.swift:18-153 exercises; the primary path at :257-271 plus trimmedContextEdge at :306-315 have no test."
  },
  {
    "lens": "verification-gap",
    "location": "Sources/VocaMac/Views/ProfilesSettingsTab.swift:181-215 — Profiles JSON import",
    "trigger_condition": "AC 4.3's own stated verification ('Unit: export/import round-trip; malformed-import rejection') is not met — no test feeds a malformed payload to the import path.",
    "guard_snippet": "Extract the decode-and-validate step into a testable pure function (e.g. Profile.decodeImport(_ data: Data) throws -> [Profile]) and assert: valid data round-trips; truncated/garbage data throws; and that the store is untouched on the failure path.",
    "potential_consequence": "Reordering replaceAll above the decode, or removing the `guard !imported.isEmpty` at :190, would let a malformed file wipe the user's Profiles — the exact outcome the AC forbids — with a green suite.",
    "gap_shape": "regression-gap",
    "consumer": "ProfileStore.replaceAll at Sources/VocaMac/Stores/ProfileStore.swift:95-100, invoked from ProfilesSettingsTab.swift:203",
    "evidence": "Reported by the Epic 4 audit and re-checked: grep -rn 'importErrorMessage|exportProfiles|importProfiles' over Tests/ returns nothing. ProfileTests.swift:61 round-trips [Profile] through JSONEncoder/JSONDecoder directly, which exercises Foundation rather than the app's import."
  },
  {
    "lens": "verification-gap",
    "location": "Sources/VocaMac/Views/ProfilesSettingsTab.swift:64 and :67 — .onMove and .onDelete",
    "trigger_condition": "Reorder and delete are asserted at the store layer only; the UI affordances that reach them have no coverage.",
    "guard_snippet": "The repo's own convention for this is PostProcessSettingsTabTests — assert the tab's bindings and keys rather than the rendered view. A ProfilesSettingsTabTests exercising the same add/update/move/delete calls the tab makes would close it.",
    "potential_consequence": "Deleting either modifier removes reorder or delete from the product while ProfileStoreTests.swift:94 and :116 keep passing, because they call store.delete/store.move directly. Same for the running-apps Picker at :309.",
    "gap_shape": "regression-gap",
    "consumer": "the Profiles settings tab, the only user-facing route to AC 4.3-a",
    "evidence": "No Tests/VocaMacTests/ProfilesSettingsTabTests.swift exists (full test listing checked); grep for 'ProfilesSettingsTab' over Tests/ returns nothing, while PostProcessSettingsTabTests.swift does exist with five tests."
  },
  {
    "lens": "verification-gap",
    "location": "Sources/VocaMac/Services/PostProcessService.swift:727 — configuration.urlCache = nil",
    "trigger_condition": "The one line preventing URLSession from caching a response derived from cursor context is unasserted.",
    "guard_snippet": "Assert the session configuration the service builds has urlCache == nil (and, if reachable, requestCachePolicy set accordingly).",
    "potential_consequence": "Removing the line lets responses shaped by cursor context sit in an in-memory URL cache, contradicting AC 4.4's 'never persisted anywhere'. CursorContextTests.swift:271-300 inspects the record, the log file, exportLogs and profiles.json — not the URL cache.",
    "gap_shape": "regression-gap",
    "consumer": "the LLM request path in Sources/VocaMac/Services/PostProcessService.swift:182-194, which carries the context payload",
    "evidence": "Reported by the Epic 4 audit; confirmed the line exists at PostProcessService.swift:727. Read CursorContextTests.swift's leak assertions (:274, :280, :286, :295) — no cache assertion among them."
  },
  {
    "lens": "verification-gap",
    "location": "Sources/VocaMac/Services/CorrectionLearner.swift:124 — a second Accessibility read of the user's document",
    "trigger_condition": "The AD-5 leak test covers only the cursor-context capture path; a different service reads focused-element text and is outside that test's scope.",
    "guard_snippet": "Widen CursorContextTests' log/record leak assertions to cover a correction-learning cycle, or state explicitly in AD-5 that CorrectionLearner's read is governed separately.",
    "potential_consequence": "Adding a diagnostic VocaLogger line inside CorrectionLearner's read would leak document text to the log file with no failing test — the privacy guarantee users would reasonably read into AD-5 is narrower than it looks.",
    "gap_shape": "other",
    "consumer": "CorrectionLearner.observeInjection, Sources/VocaMac/Services/CorrectionLearner.swift:124",
    "evidence": "grep for 'readFocusedElementText|VocaLogger' in CorrectionLearner.swift returns exactly one line — :124, the AX read — and no VocaLogger call, so nothing leaks today. CursorContextTests.swift:223-300 drives only the dictation capture path."
  }
]
```

## 6. Findings — Adversarial lens

```json
[
  {
    "lens": "adversarial",
    "location": "Sources/VocaMac/Stores/JSONFileStore.swift:93",
    "trigger_condition": "quarantinedFileURL is documented as 'Read by callers that want to tell the user their history was set aside', but it has no production consumer.",
    "guard_snippet": "Surface it — a banner in HistoryView, or an alert on first open, naming the .corrupt-<timestamp> file — or delete the accessor and the comment that promises a caller.",
    "potential_consequence": "A user whose history.json fails to decode opens the History window to an empty list, with no indication that their transcripts still exist on disk under a renamed file. Silent, and indistinguishable from data loss."
  },
  {
    "lens": "adversarial",
    "location": "Sources/VocaMac/Views/HistoryView.swift:137 and :180",
    "trigger_condition": "The 'target app' column prints the raw bundle identifier ('com.apple.TextEdit') rather than a localized application name.",
    "guard_snippet": "Resolve via NSRunningApplication/NSWorkspace localizedName with the bundle id as the fallback, cached per id.",
    "potential_consequence": "Story 3.2's list is meant to help a user find a dictation by where it went; reverse-DNS strings are the least scannable form of that, and unreadable for anyone who does not think in bundle ids."
  },
  {
    "lens": "adversarial",
    "location": "Sources/VocaMac/Views/MenuBarView.swift:510",
    "trigger_condition": "AC 3.4's 'the UI states the best-effort limitation' is met only by a .help() tooltip that requires hovering a menu-bar panel row, and it does not mention the ⌘Z app-dependence the AC also calls out.",
    "guard_snippet": "Render the caveat as visible caption text under the Undo row, and name the clipboard case: 'Uses ⌘Z outside apps we can edit directly — results vary.'",
    "potential_consequence": "A user clicks Undo in a terminal, ⌘Z does something unrelated, and nothing in the interface ever warned them the retraction was best-effort."
  },
  {
    "lens": "adversarial",
    "location": "Sources/VocaMac/Models/AppState.swift:1782 with Sources/VocaMac/Views/MenuBarView.swift:489",
    "trigger_condition": "canUndoLastInjection reads through to non-@Published state on TextInjector, so the Undo row's visibility is whatever it was at the last render rather than current.",
    "guard_snippet": "Publish the undo availability — set an @Published flag when recordInjection fires and clear it on a timer at undoWindow expiry — so the row appears and disappears on time.",
    "potential_consequence": "The row can be stale in both directions while the panel is open: absent right after an injection (the feature looks missing), or present after the window has lapsed (the click silently does nothing). The safety guard re-checks, so this is a visibility defect rather than a destructive one."
  },
  {
    "lens": "adversarial",
    "location": "Sources/VocaMac/Stores/HistoryStore.swift:58-64",
    "trigger_condition": "The willTerminateNotification observer is registered in init and never removed.",
    "guard_snippet": "Hold the returned observer token and remove it in deinit, as the rest of the codebase does for NSWorkspace observers.",
    "potential_consequence": "Every HistoryStore ever constructed stays reachable from NotificationCenter along with its JSONFileStore. In production there is one, so the cost is nil; in the test suite each makeStore() leaks a store bound to a temp directory that tearDown has already deleted."
  },
  {
    "lens": "adversarial",
    "location": "Sources/VocaMac/Services/ProfileManager.swift:33-35 with Sources/VocaMac/Views/ProfilesSettingsTab.swift:323 and :373-375",
    "trigger_condition": "Turning Profiles off resolves to the Default Profile as the user has edited it, so a prompt override, a suppressed post-process toggle, or an enabled context-capture toggle on the Default all survive the master switch.",
    "guard_snippet": "Either return Profile.makeDefault() (pristine) when profilesEnabled is false, or disable promptOverride and the two feature toggles in the editor when profile.isDefault — and add a test that edits the Default, disables Profiles, and asserts Epic 2 behavior.",
    "potential_consequence": "AC 4.2's 'behavior matches Epic 2's' is false. A user who tunes the Default and then switches Profiles off to debug still gets their override steering the LLM, still gets post-processing suppressed, and can still have cursor context read — the master switch does not restore the pre-Profiles path, it only stops bundle-id matching."
  },
  {
    "lens": "adversarial",
    "location": "Sources/VocaMac/Views/ProfilesSettingsTab.swift:214",
    "trigger_condition": "The malformed-import message interpolates error.localizedDescription from a DecodingError, which reads 'The data couldn't be read because it isn't in the correct format.'",
    "guard_snippet": "Switch over DecodingError and name the failing key or index; keep the generic string only as a last resort.",
    "potential_consequence": "AC 4.3's 'rejected with a clear message' degrades to a message that tells the user nothing about which file or which field was wrong. The size and empty-array guards at :183 and :190 already do better, which makes the decode branch the weakest of the three."
  },
  {
    "lens": "adversarial",
    "location": "Sources/VocaMac/Views/ProfilesSettingsTab.swift:64-67",
    "trigger_condition": "Reorder and delete exist only as .onMove and .onDelete on a List inside a Form; ProfileRow (:222-255) has no visible delete control.",
    "guard_snippet": "Add an explicit delete affordance to the row, mirroring the fix already applied to the Vocabulary tab in commit 00c634b.",
    "potential_consequence": "AC 4.3's 'reorder, and delete' may be effectively unreachable on macOS depending on how the List renders inside the Form — the same class of defect the Vocabulary tab just shipped a fix for, and there is no test that would notice."
  },
  {
    "lens": "adversarial",
    "location": "Sources/VocaMac/Views/ProfilesSettingsTab.swift:148 and :173",
    "trigger_condition": "exportProfiles() and importProfiles() are private methods on a SwiftUI view that mix NSSavePanel/NSOpenPanel presentation with encode/decode and validation.",
    "guard_snippet": "Move the pure part — encode [Profile] to Data, and decode-and-validate Data to [Profile] — onto Profile or ProfileStore, and leave only panel presentation in the view.",
    "potential_consequence": "AD-9's export/import contract has no seam, so it cannot be tested at all; the three PARTIAL verdicts on Story 4.3 all trace to this one structural choice rather than to three separate omissions."
  },
  {
    "lens": "adversarial",
    "location": "Sources/VocaMac/Services/AXContextReader.swift:148-165 and :257-271",
    "trigger_condition": "Budget truncation, selection exclusion and surrogate-pair handling are implemented twice — once for the parameterized-attribute path and once for the whole-value fallback.",
    "guard_snippet": "Have the primary path fetch a bounded window and then run the same slice() the fallback uses, so there is one implementation of the budget rule.",
    "potential_consequence": "Two implementations of a privacy-bounded rule drift apart, and the one with all the tests is the one that runs least often."
  },
  {
    "lens": "adversarial",
    "location": "Tests/VocaMacTests/ServiceTests.swift:405, :433, :459",
    "trigger_condition": "Three injection tests skip on conditions derived from the host machine's Accessibility grant, and the conditions are mutually exclusive — no single machine runs all of them.",
    "guard_snippet": "Inject the AXIsProcessTrusted() answer behind a test hook, as undoKeystrokeDispatcher already is at :143, so both branches run everywhere.",
    "potential_consequence": "The headline '784 tests, 0 failures' overstates coverage by an amount that varies per machine, and the clipboard path — the fallback every non-AX app depends on — is the part that goes dark on a CI box."
  },
  {
    "lens": "adversarial",
    "location": "Sources/VocaMac/Views/HistoryView.swift:16-18",
    "trigger_condition": "filteredRecords calls historyStore.search(searchQuery) inside a computed property, so every keystroke and every unrelated re-render re-scans both text fields of every record.",
    "guard_snippet": "Debounce the query, or cache the filtered result keyed on (query, records revision).",
    "potential_consequence": "At the 500-record default this is imperceptible; with retention set to Unlimited and long transcripts, localizedStandardContains over two fields per record per keystroke becomes a visible typing stall in the search field."
  },
  {
    "lens": "adversarial",
    "location": "Sources/VocaMac/Stores/HistoryStore.swift:68 with :107",
    "trigger_condition": "record() inserts at index 0 unconditionally while load() sorts by timestamp, so the newest-first invariant is positional rather than derived.",
    "guard_snippet": "Insert at the sorted position (or sort after insert) so the invariant holds regardless of the incoming record's timestamp.",
    "potential_consequence": "Any caller that records with a non-now timestamp — a backfill, an import, a replayed Command Mode outcome — lands at the top of the list and, once the retention limit bites, prefix(retentionLimit) prunes by position and can drop records newer than the ones it keeps."
  }
]
```

---

## 7. What the evidence says about the epics as delivered

Both epics are substantially built, and the privacy-critical half of Epic 4 is the best-verified code in either: `CursorContextTests.swift:223-300` drives a real pipeline with a distinctive token, raises the log level so the test can actually fail, sanity-checks that the token reached the service, and only then asserts absence from the record, the log file, the export and `profiles.json`. That is the shape every other privacy claim in this codebase should be held to.

The weaknesses cluster in three places rather than spreading evenly:

1. **View layer.** No test exists for `HistoryView` or `ProfilesSettingsTab`. Every Story 4.3 PARTIAL, and the untested halves of 3.2 and 3.4, are downstream of that single omission — and the repo already has a convention for closing it (`PostProcessSettingsTabTests.swift`).
2. **Constants and defaults that carry guarantees.** `contextCharacterBudget`, `readableRoles`/`secureRoleIdentifiers`, the Application Support directory, `urlCache = nil` — each is a single line that a whole acceptance criterion rests on, and none is asserted.
3. **Schema locks that do not lock.** `HistoryStoreTests.swift:50` reads as the AD-5 enforcement point but cannot see a nil Optional; it has already silently fallen behind the real schema by one field.

One behavioral shortfall, not just a verification one: **F-06** — disabling Profiles does not restore Epic 2 behavior when the Default Profile has been edited.
