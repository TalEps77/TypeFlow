# Post-hoc acceptance re-verification — Epics 5 & 6

**Project:** local-whisper (VocaMac fork, ships as TypeFlow) · macOS Swift/SwiftPM menu-bar dictation
**Lenses:** verification-gap, edge-case-hunter (BMAD `bmad-review`)
**Method:** every acceptance criterion in `_bmad-output/planning-artifacts/epics.md` §Epic 5 / §Epic 6 traced to implementing code and to a test that pins the claim. No story files or per-story reviews exist; this report replaces them.
**Suite state:** 784 test functions across 40 files, 0 failures (count independently confirmed).
**Scope discipline:** read-only. No repo edits, no commits.

---

## Verdict summary

| Epic | ACs | SATISFIED | PARTIAL | VIOLATED | UNVERIFIABLE |
|---|---|---|---|---|---|
| 5 — Dictionary & Snippets | 34 | 28 | 6 | 0 | 0 |
| 6 — Command Mode | 17 | 8 | 7 | 1 | 1 |
| **Total** | **51** | **36** | **13** | **1** | **1** |

**One acceptance criterion is violated: AC-6.3.2** — the spoken instruction *can* be injected into the user's document, via History re-paste. Details in Epic 6 below; this is the headline finding of the audit and the only defect here that damages user data in normal use.

Every PARTIAL is one of three shapes: a deliberate documented deviation from the written AC (5.1.3), an untested SwiftUI surface whose underlying model logic *is* tested (5.3.1, 5.3.4, 5.5.1, 5.5.2, 6.1.4, 6.1.5), or a bound that holds in code but is not pinned by a test (5.6.6, 6.1.3, 6.1.6, 6.2.1, 6.2.2, 6.3.3). The single UNVERIFIABLE (6.2.3) is a genuine tooling limit, not an omission: no SwiftPM unit test can perform a successful Accessibility write.

---

## Epic 5 — Dictionary and Snippets

### Story 5.1 — Hebrew normalization

| AC | Verdict | Code | Test |
|---|---|---|---|
| 5.1.1 `enum` + `static` pure funcs in `Models/`, dependency-free leaf | SATISFIED | `Sources/VocaMac/Models/HebrewNormalizer.swift:15`; only `import Foundation` at `:13` | structural (compiler-enforced); no I/O anywhere in file |
| 5.1.2 niqqud + cantillation stripped | SATISFIED | `HebrewNormalizer.swift:37-61` | `HebrewNormalizerTests.testStripsNiqqudVowelPoints`, `.testStripsCantillationMarks`, `.testDoesNotStripMaqafOrSofPasuq` |
| 5.1.3 matres lectionis (ו/וו, י/יי) unified | **PARTIAL** | `HebrewNormalizer.swift:104-116` exists but is **not called by `normalize` (`:177-184`)** and is dead in production | `.testCollapsesDoubledVav`, `.testCollapsesDoubledYod`, `.testCollapsesARunOfThreeIdenticalLetters` — and `.testNormalizeDoesNotMergeDistinctWordsThatDifferOnlyByAMatresLectionis` asserts the **opposite** for the shipping normalizer |
| 5.1.4 final forms → base forms | SATISFIED | `HebrewNormalizer.swift:118-131` | `.testNormalizesAllFiveFinalForms`, `.testNormalizesFinalFormsInsideAWord`, `.testLeavesBaseFormsAlone` |
| 5.1.5 geresh + gershayim handled | SATISFIED | `HebrewNormalizer.swift:143-160`, adjacency guard `:21-34`, `:156` | `.testConvertsApostropheAfterHebrewLetterToGeresh`, `.testConvertsQuoteAfterHebrewLetterToGershayim`, `.testGereshAtStringStartIsUnchanged` |
| 5.1.6 Latin passes through unchanged | SATISFIED | adjacency guard `:143-157`; all other steps touch only Hebrew code points | `.testPureLatinTextIsUntouchedByTheFullPipeline`, `.testLeavesEnglishApostropheUnchanged`, `.testLeavesEnglishQuoteUnchanged` |
| 5.1.7 variant-pair table; side-effect free | SATISFIED | whole file | `.testVariantPairsNormalizeIdentically` |
| 5.1.V all five stated verifications | SATISFIED | — | independent + combined (`.testCombinedTransformationsAllApplyTogether`), idempotence (`.testNormalizeIsIdempotent`), Latin, empty/whitespace (`.testEmptyStringNormalizesToEmptyString`, `.testWhitespaceOnlyInputPassesThroughUnchanged`) |

**5.1.3 in detail.** `normalizeMatresLectionis` is implemented, tested, and deliberately excluded from `normalize`. The rationale at `HebrewNormalizer.swift:88-103` is sound and, in my judgement, better than the AC: collapsing ו/וו and י/יי merges *genuinely distinct* Hebrew words (מוות/מות, ראייה/ראיה, חייב/חיב), and because the exact-match tiers bypass every similarity threshold, the collapse silently rewrote words the user actually said. Edit distance already subsumes the intended benefit (a doubled letter is exactly one insertion). **The code is right and the epic is stale.** Action: amend AC 5.1.3 in `epics.md` to record the exclusion, rather than "fixing" the code.

### Story 5.2 — Post-ASR dictionary replacement

| AC | Verdict | Code | Test |
|---|---|---|---|
| 5.2.1 Dictionary stage runs first | SATISFIED | `Sources/VocaMac/Pipeline/TranscriptPipeline.swift:40-47`; reached from `Models/AppState.swift:461` ← `App/VocaMacApp.swift:219` | `RehydrateStageTests.testStageOrderIsDictionaryThenSnippetThenPostProcessThenRehydrate` — asserts against the **real** `TranscriptPipeline.production(...)`, not a fixture |
| 5.2.2 exact trigger → canonical form | SATISFIED | `Services/DictionaryService.swift:164-171`, write at `:125-127` | `DictionaryServiceTests.testExactTriggerAsAWholeWordIsReplaced`, `.testATriggerWithGershayimMatches`, `.testAMultiWordTriggerMatchesAsAPhrase` |
| 5.2.3 near-match by edit distance over normalized forms; refused below threshold | SATISFIED (stricter than written) | `DictionaryService.swift:176-201`; operative line `:197` uses **strict `>`** | `.testNearMatchAboveThresholdIsReplaced` (0.857), `.testNearMatchExactlyAtThresholdIsNotReplaced` (0.75), `.testNearMatchBelowThresholdIsNotReplaced` (0.25), `.testTheShippedThresholdDoesNotFireOnTheFeminineInflection` |
| 5.2.4 whitespace/punctuation preserved; no substring match | SATISFIED | original-span copying `DictionaryService.swift:117,125,139`; boundaries `Models/WordTokenizer.swift:20-35`; trailing punctuation `:90-98` | `.testSurroundingWhitespaceAndPunctuationArePreserved`, `.testTriggerDoesNotMatchInsideALongerUnrelatedWord` (לך vs מלך), `.testTriggerCarryingABoundPrefixIsNotReplaced`, `.testATriggerWithATrailingGereshTakesItWithIt` |
| 5.2.5 overlapping entries deterministic | SATISFIED | array-order only; no `Set`/`Dictionary` iteration in the match path (`:82-94`, `:165-200`) | `.testOverlappingEntriesResolveByArrayOrderExactMatchFirst`, `.testExactMatchInALaterEntryOutranksAFuzzyMatchInAnEarlierEntry`, `.testALongerTriggerOutranksAShorterOneAtTheSamePosition` |
| 5.2.6 empty/disabled → identity | SATISFIED | `Pipeline/Stages/DictionaryStage.swift:38-47`; runner guard `TranscriptPipeline.swift:63-67` | `DictionaryStageTests.testDisabledStageIsIdentityAcrossTheCorpus` (forces the mock to return `"THIS MUST NEVER APPEAR"` and proves the runner still cannot install it) |

The epic's "within vs below threshold" wording is ambiguous; the code resolves it **exclusively** (at-threshold is refused), which is the conservative reading SM-C2 asks for. All three boundary cases are pinned.

Notably, the classic normalized-index-into-original-string bug is **absent by construction**: replacement indices come from `tokens[].range` over the original text (`:117/125/129`) while normalization lives in a parallel array (`:100`).

### Story 5.3 — Dictionary settings UI and persistence

| AC | Verdict | Code | Test |
|---|---|---|---|
| 5.3.1 CRUD with canonical form + ≥1 trigger | **PARTIAL** | `Views/SettingsView.swift:62,131`; `Views/VocabularySettingsTab.swift:132-140`, `:486-567`, `:444-457` | `DictionaryStoreTests.testAddAppendsAnEntry`, `.testUpdateReplacesTheMatchingEntry`, `.testDeleteRemovesAnEntry` — store CRUD pinned; the tab has no test and no ViewModel, so the "≥1 trigger" invariant (enforced only by the disabled Done button at `:552`) is unverified: `DictionaryStore.add` accepts `triggers: []` |
| 5.3.2 persisted via `JSONFileStore`, survives restart | SATISFIED | `Stores/DictionaryStore.swift:26` → `Stores/JSONFileStore.swift:116-142` | `.testEntriesSurviveAFreshInstanceAtTheSameFile` (fresh store over the same file after `flush()` — restart simulated exactly as the app does it) |
| 5.3.3 pre-existing Vocabulary untouched and distinct | SATISFIED | `Services/WhisperService.swift:314-318` (`"Glossary: "`), still fed to `kit.transcribe` at `:163,166,169` | `DictationLanguageTests.testGlossaryIsSentForHebrew`, `.testGlossaryIsWithheldForEnglish`, `.testGlossaryIsWithheldInAutoDetect`; `git log` shows no Epic-5 commit touched `WhisperService.swift` |
| 5.3.4 export/import round-trips | **PARTIAL** | export `VocabularySettingsTab.swift:254-271`, import `:273-297` → `DictionaryStore.sanitizedForImport` (`:80-110`) | `.testReplaceAllRoundTripsThroughJSONEncodingAndDecoding` **re-implements** encode/decode in the test body; the real `exportEntries`/`importEntries`/`decodeOffMainThread` are private, NSPanel-driven, and have zero coverage |

### Story 5.4 — Snippet expansion with placeholder protection

| AC | Verdict | Code | Test |
|---|---|---|---|
| 5.4.1 Snippet after Dictionary, before post-processing; Rehydrate after | SATISFIED | `TranscriptPipeline.swift:40-47`, mapping folded on at `:79-81`; placeholder mint `Services/SnippetService.swift:37-39`, `:121-124` | `RehydrateStageTests.testStageOrderIsDictionaryThenSnippetThenPostProcessThenRehydrate` |
| 5.4.2 LLM sees only placeholders | SATISFIED | `Pipeline/Stages/PostProcessStage.swift:95-101` | `.testSnippetBodySurvivesARealPostProcessRoundTrip` asserts `postProcessService.lastText == "please add my ⟦S0⟧ here"` |
| 5.4.3 dropped/altered placeholder → whole LLM result rejected, body still substituted | SATISFIED | `Pipeline/Stages/RehydrateStage.swift:33-45`, exactly-once validation `:55-66` | `.testFallsBackToPreLLMTextWhenAPlaceholderIsMissingEntirely`, `.testFallsBackWhenAPlaceholderIsAlteredRatherThanDropped`, `.testDuplicatedPlaceholderIsRejectedRatherThanPastedTwice`, `.testCorruptedPlaceholderRejectsTheWholeCleanupResult` |
| 5.4.4 case-insensitive + normalized matching; multi-line verbatim; multiple cues | SATISFIED | `SnippetService.swift:69-81`; body copied verbatim `:123`; lowercasing `Models/WordTokenizer.swift:81` | `SnippetServiceTests.testMatchIsToleratesNiqqud`, `.testMatchIsCaseInsensitiveForLatinCues`, `.testMultiLineBodyIsPreservedVerbatim`, `.testMultipleDistinctCuesAllExpand` |
| 5.4.5 expands with post-processing off | SATISFIED | `PostProcessStage.swift:59-61`; `RehydrateStage` has no toggle | `.testSnippetsExpandWithPostProcessingDisabled` (asserts `cleanCallCount == 0` and the body still expanded) |
| 5.4.V all six stated verifications | SATISFIED | — | all six exist and assert the claim |

The `⟦S<n>⟧` design is unusually well hardened: the closing bracket makes `⟦S1⟧` a non-prefix of `⟦S10⟧`; substitution runs in descending index order (`RehydrateStage.swift:68-81`) so a body containing a placeholder-shaped token cannot be re-expanded by hash-order accident; blank-bodied snippets never mint a placeholder at all (`SnippetService.swift:69-76`); and `SnippetService.containsPlaceholder` (`:46-48`) is a last-line pipeline guard.

### Story 5.5 — Snippets settings UI

| AC | Verdict | Code | Test |
|---|---|---|---|
| 5.5.1 CRUD with multi-line body editor | **PARTIAL** | `VocabularySettingsTab.swift:611-686`, `TextEditor` at `:642` | `SnippetStoreTests.testAddAppendsASnippet`, `.testUpdateReplacesTheMatchingSnippet`, `.testDeleteRemovesASnippet`, `.testMultiLineBodySurvivesAFreshInstanceAtTheSameFile` — store side pinned; the editor sheet has no test |
| 5.5.2 persists, survives restart, exports as JSON | **PARTIAL** | `Stores/SnippetStore.swift:24`; export `VocabularySettingsTab.swift:345-362`, import `:364-388` | persistence SATISFIED (`.testMultiLineBodySurvivesAFreshInstanceAtTheSameFile`); export/import functions themselves untested — same gap as 5.3.4 |
| 5.5.3 colliding Cue rejected with a clear message | SATISFIED | `VocabularySettingsTab.swift:672-675`, `:221`; `SnippetStore.collisionKey` `:74-97` | `.testHasCollisionIsCaseAndNormalizationTolerant`, `.testTwoCuesThatTokenizeIdenticallyCollide`, `.testCuesSeparatedDifferentlyDoNotCollide`, `.testHasCollisionExcludesTheSnippetBeingEdited`, `.testImportDropsCollidingCuesWithinTheSameFile` |

**A suspected defect was chased and disproved.** The audit hypothesised that collision detection might be exact-match while expansion matching is normalized+case-insensitive — an inconsistency that would let two cues coexist while only the first ever fires. It does not exist: `SnippetStore.collisionKey` (`:74-84`) builds its key from `WordTokenizer.phrase(cue, normalizing: HebrewNormalizer.normalize)`, and `WordTokenizer.phrase:81` lowercases **every** word, so collision detection and matching use identical keys. (The extra `.lowercased()` on `words[0]` at `SnippetStore.swift:79` is redundant but harmless.)

### Story 5.6 — Propose Dictionary Entries from user corrections

| AC | Verdict | Code | Test |
|---|---|---|---|
| 5.6.1 off by default | SATISFIED | `Models/CorrectionLearningSettings.swift:24` (`static let enabled = false`); bound at `Models/AppState.swift:164` | `CorrectionLearningIntegrationTests.testCorrectionLearningIsOffByDefault` (clears the `UserDefaults` key in `setUp`, so it pins the real default) |
| 5.6.2 field re-read after a delay and diffed | SATISFIED | `Services/CorrectionLearner.swift:84-104`, `:112-133`; AX path `Services/AXContextReader.swift:132`, `:201-230` | `CorrectionLearnerTests.testASingleWordEditProposesExactlyOneCandidate`, `.testCancellingBeforeTheReReadFiresPreventsIt`. Delay is **injectable** (`CorrectionLearner.swift:59`), not a hard sleep; uses a cancellable `DispatchWorkItem` |
| 5.6.3 small localized word-level diff → candidate | SATISFIED | `Models/CorrectionDiffing.swift:48-92` | `CorrectionDiffingTests.testSingleWordSubstitutionIsACandidate`, `.testSingleWordEditInHebrewIsACandidate`, `.testEditAtTheFirstWordIsStillDetected`, `.testEditAtTheLastWordIsStillDetected` |
| 5.6.4 proposed, never added silently | SATISFIED | propose = append only (`AppState.swift:1677-1681`); the **only** `dictionaryStore.add` in the feature is `AppState.swift:1703`, reachable only from `confirmCorrectionCandidate` (`:1698`) ← button at `VocabularySettingsTab.swift:56` | `.testConfirmingACandidateAddsALearnedDictionaryEntry`, `.testDismissingACandidateRecordsItAndClearsPending` (asserts `dictionaryStore.entries.isEmpty`). Repo-wide grep confirms no second write path |
| 5.6.5 dismissal persists | SATISFIED | `CorrectionLearner.swift:130`; `Stores/DismissedCorrectionsStore.swift:110-122`; keys normalized then salted-SHA256 `:38-45` | `.testADismissedPairIsNeverProposedAgain`, `.testDismissalsPersistAcrossAFreshInstanceAtTheSameFile`, `.testIsDismissedIsNormalizationAndCaseTolerant` (so a niqqud variant stays dismissed) |
| 5.6.6 bounded to single-token edits; diffuse diffs produce nothing | **PARTIAL** | one differing token per window `CorrectionDiffing.swift:67-73`; unique-window guard `:82`; Levenshtein ≤2 `:26`/`:105`; similarity ≥0.5 `:31`/`:109`; field ceiling 5 000 words `:36`/`:54` | accept + reject both pinned (`.testMultipleDifferingWordsProducesNoCandidate`, `.testAnAmbiguousLocationProducesNoCandidate`, `.testADifferenceOnlyInNiqqudProducesNoCandidate`) — **but** `maximumFieldWords = 5_000` has no test, and the single-token bound applies only *inside the located window*: text outside it may differ arbitrarily |
| 5.6.7 stays quiet unless opted in | SATISFIED | gates at `AppState.swift:1307`, `CorrectionLearner.swift:85` and again at fire time `:116`; only UI surface is the passive list at `VocabularySettingsTab.swift:53-61` | `.testDisabledLearningNeverObservesAnInjection`, `.testDisabledLearnerNeverReadsOrProposesAnything`, `.testTurningTheToggleOffInsideTheDelayStopsTheRead`. No `UNUserNotification`/`NSAlert`/badge anywhere in the correction path |

---

## Epic 6 — Command Mode

### Story 6.1 — Second hotkey binding

| AC | Verdict | Code | Test |
|---|---|---|---|
| 6.1.1 shares the existing `CGEventTap` | SATISFIED | sole hotkey tap at `Services/HotKeyManager.swift:121`; `Services/HotKeyBinding.swift:22-24` "Owns no tap and no run loop source". The two other `CGEvent.tapCreate` sites (`Services/PermissionManager.swift:137,188`) are permission probes, not input taps | structural + `HotKeyManagerTests.testEachBindingFiresOnlyItsOwnCallbacks` |
| 6.1.2 dedicated callbacks, not a generalized state machine | SATISFIED | `HotKeyBinding.swift` — per-binding instance extracted as a **move**, not a rewrite (header `:6-16`) | `.testEachBindingFiresOnlyItsOwnCallbacks`, `.testDisablingTheCommandBindingStopsItFiring` |
| 6.1.3 same push-to-talk and double-tap conventions | **PARTIAL** | PTT `HotKeyBinding.swift:243-264`, double-tap `:266-286` — same code, one instance per binding | PTT pinned at event level (`.testInterleavedPressesKeepSeparateState`, `.testModifierKeysDriveTheTwoBindingsIndependently`); **`.doubleTapToggle` is never driven by an event for the command binding** — only its configuration is pushed |
| 6.1.4 separately configurable | **PARTIAL** | `Models/CommandModeSettings.swift:20`; UI `Views/SettingsView.swift:286-327`; `AppState.swift:169-171` | storage and push path pinned (`.testSyncPushesTheCommandBindingConfiguration`, `.testStartupConfiguresTheCommandBinding`, `.testStartupLeavesTheCommandBindingDisabledWhenTheFeatureIsOff`); the SwiftUI control itself untested |
| 6.1.5 same-key collision rejected with a clear message | **PARTIAL** | `Views/HotKeySelectionControl.swift:124-133`, wired at `SettingsView.swift:255,315`; model-layer refusal `AppState.swift:181-183`, `HotKeyManager.swift:214-230` | refusal pinned by `.testCommandBindingRefusesTheDictationKeyCode`, `.testACollidingCommandKeyMakesTheBindingUnusable`; **zero** tests reference `HotKeySelectionControl` or `rejectionMessage`, so the "clear message" half is unpinned |
| 6.1.6 shipped defaults do not conflict | **PARTIAL** | Command Mode `= 54` (Right Command) at `CommandModeSettings.swift:41`; Dictation `= 61` (Right Option) at `AppState.swift:97` / `HotKeyManager.swift:94` | the two literals genuinely differ and Command Mode ships off (`CommandModeSettings.swift:34`) — but **no test asserts they are distinct**, so a future default change collides silently (backstopped, not prevented, by the tested refusal) |
| 6.1.7 `HotKeyManagerConfigurationTests` + `HotKeyManagerResetStateTests` still pass | SATISFIED | — | both classes still exist: `HotKeyManagerTests.swift:11` and `:470`. Not deleted, not renamed |
| 6.1.8 new `_handleTestEvent` tests cover both bindings, interleaved + stuck-key | SATISFIED | — | `.testInterleavedPressesKeepSeparateState` (`:353`), `.testStuckKeyRecoveryIsPerBinding` (`:381`), `.testModifierKeysDriveTheTwoBindingsIndependently` (`:439`) |

### Story 6.2 — Read and replace the selection via Accessibility

| AC | Verdict | Code | Test |
|---|---|---|---|
| 6.2.1 read via `kAXSelectedTextAttribute` | **PARTIAL** | `Services/TextInjector.swift:653` | `.testReadSelectionResultReportsWhyItFailed` — the test **branches on the environment**; under CI it takes the `.failure` path and asserts nothing about `kAXSelectedTextAttribute`. No AX seam |
| 6.2.2 nil with no selection or no accessible element | **PARTIAL** | `TextInjector.swift:642-657`; nil-shape at `ServiceProtocols.swift:198` | **Empty string is correctly never leaked** — triple guard: unreadable range → `.noSelection` (`:645`), `range.length > 0` (`:648`, catches caret-only), `!text.isEmpty` (`:655`). PARTIAL only because the assertions are environment-conditional |
| 6.2.3 `replaceSelection(_:)` replaces the selection in the target app | **UNVERIFIABLE** | `TextInjector.swift:680-724`, write at `:717`, landing check `verifyWrite` at `:740-784` | only the refusal path is exercised (`.testReplaceSelectionRefusesAStaleSnapshotRatherThanWriting`). No seam for `AXUIElementSetAttributeValue`; every "it writes" claim rests on `MockTextInjector` (`Mocks/MockServices.swift:494`), which skips all snapshot checks. Manual verification only |
| 6.2.4 write failure reported, not swallowed | SATISFIED | `Result<Void, SelectionError>` at `:679-680`; consumed `CommandModeCoordinator.swift:232-234`; surfaced `AppState.swift:1528-1530`; `writeNotApplied` vs `writeUnverified` distinguished | `.testAnUnwritableTargetIsReportedRatherThanIgnored`, `.testAnUnwritableTargetAbortsAndRecordsNothing`, `.testAnUnverifiableWriteDoesNotClaimNothingWasChanged` |
| 6.2.5 existing `inject(...)` path, role gate, pasteboard snapshot/restore, changeCount guard unchanged; `TextInjectorTests` pass | SATISFIED | `370183e` is **+280/−0** on `TextInjector.swift` (pure addition). `593678c` only hoisted the injection role literal to `static let injectableRoles` — **identical** set `["AXTextField","AXSearchField","AXComboBox"]` — and rewrote `verifyWrite`. `inject()` `:217`, role gate `:512`/`:567`, pasteboard `:894-960`, changeCount `:907`/`:951` all byte-equivalent | `TextInjectorTests` still at `Tests/VocaMacTests/ServiceTests.swift:67` (never moved); `.testInjectionPathIsUnaffectedBySelectionSupport`, `.testSelectableRolesCoverProseAndExcludeSecureFields` |

### Story 6.3 — Rewrite the selection by voice

| AC | Verdict | Code | Test |
|---|---|---|---|
| 6.3.1 coordinator reads selection, transcribes, sends both in command mode, replaces | SATISFIED | `Services/CommandModeCoordinator.swift:134-236`; LLM call `:190-196` | `CommandModeTests.testHappyPathReplacesTheSelectionWithTheRewrite`, `.testCommandBodyUsesTheCommandPromptAndMessageShape`, `.testTheCommandPromptIsNotTheCleanupPrompt` |
| 6.3.2 instruction never injected into the document | **VIOLATED** | on the Command Mode route itself the instruction never reaches the injector, and echoes are rejected (`PostProcessService.swift:619`) — **but** a command record stores the instruction in *both* text fields (`AppState.swift:1653-1654`), and `AppState.rePaste` injects `record.finalText` with **no mode filter** (`:1738`, `:1747`), as does `rePasteMostRecent` on `records.first` unconditionally (`:1770-1776`). `HistoryView.swift:202` labels the record "Instruction (spoken)" and then renders an **ungated Re-paste button** at `:212` | `injectCallCount == 0` is asserted on four command-route tests, and `.testRejectsAnEchoOfTheInstruction` covers the LLM echo — **no test covers the re-paste route**, which is how the violation survived |
| 6.3.3 every failed precondition aborts, changes nothing, plays the error sound, leaves the selection intact | **PARTIAL** | no selection `AppState.swift:1409-1412`; LLM/timeout `CommandModeCoordinator.swift:199-200`; unwritable `:232-234`; no pipeline by construction; `PostProcessService.swift:604-625` (missing `finish_reason` ⇒ reject; empty ⇒ `.emptyContent`; length ceiling and floor) | all four abort paths pinned with `replaceSelectionCallCount == 0`: `.testNoSelectionAbortsBeforeAnythingIsWritten`/`.testNoSelectionAbortsWithoutEverRecording`, `.testAnUnreachableLLMAbortsWithoutWriting`/`.testAnUnreachableLLMLeavesTheSelectionUntouched`, `.testATimeoutAbortsWithoutWriting`/`.testATimeoutLeavesTheSelectionUntouched`, `.testAnUnwritableTargetAbortsAndRecordsNothing`; messaging `.testEveryFailureMessageSaysNothingWasChanged`. **Failing sub-clause — the error sound:** `playErrorSound` fires at `AppState.swift:1580` (abort) and `:1601` (refuse), but the only test, `.testTheErrorCuePlaysOnAbortWhenSoundIsOn`, exercises the *refuse* path; no test asserts the cue on the LLM, timeout or write aborts |
| 6.3.4 History Record distinguishable by mode field | SATISFIED | `Models/HistoryRecord.swift:18` (`enum Mode`), `:59`, `:90` | `.testHappyPathRewritesAndRecordsACommandModeHistoryRecord`, `.testTheHistoryRecordNeverHoldsTheSelectionOrTheRewrite` |

**The Command Mode route itself is the most defensively written code in either epic.** It handles by construction nearly every edge case this audit went looking for: empty-string selection (`:648,655`), focus or selection moving between read and write (`:683-713` — element identity **and** range **and** text all re-verified), re-entrancy of two racing operations (`CommandModeCoordinator.swift:214` operation-token check), a timeout landing after an abort (same check), an LLM echoing the instruction or returning empty/truncated output (`PostProcessService.swift:604-625`), and a model returning the selection verbatim (`:223`). The clipboard is never touched by `replaceSelection`.

**AC-6.3.2 fails at the one boundary that route does not own.** The violation is not in Command Mode; it is in History, which was built for Dictation Mode and never taught that a command record's text is an *instruction*, not content. `HistoryView` knows enough to relabel the field — and then offers the same Re-paste button anyway. Reproduction: run any Command Mode rewrite, open History (or trigger re-paste-most-recent), press Re-paste — the spoken instruction, e.g. "make this shorter and more formal", is injected into the frontmost document. The fix is a mode gate on the Re-paste button (`HistoryView.swift:212`), on `rePaste` (`AppState.swift:1729`), and on `rePasteMostRecent`'s `records.first` (`:1770`) — all three, since `rePasteMostRecent` bypasses the view entirely.

---

## Uncovered edge cases

Ordered by risk. None of these has a test.

### Tier 0 — confirmed defect (AC-6.3.2, above)

0. **History re-paste of a Command Mode record injects the spoken instruction.** `AppState.swift:1728`/`:1770` with no mode filter; Re-paste button ungated at `HistoryView.swift:212`. Verified by inspection of all three call sites. Highest priority in this report.

### Tier 1 — plausible silent data corruption

1. **Transcript already containing a literal `⟦S0⟧` while a Cue also matches.** `SnippetService.protect` mints indices from 0 (`SnippetService.swift:87,121`) with no check for placeholder-shaped text already in the input. `RehydrateStage.everyPlaceholderIntact` then sees two occurrences, falls back to `textBeforePostProcess` — which contains both — and `replacingOccurrences` (`RehydrateStage.swift:78`) replaces **both**, overwriting the user's own text with the snippet body. The pipeline guard (`TranscriptPipeline.swift:132`) never fires because no placeholder remains. Silent and unrecoverable.
2. **Hebrew bound-prefix particle whose letter equals the trigger's first letter defeats the first-character anchor.** Trigger `בדיקה` vs spoken `בבדיקה`: the anchor at `DictionaryService.swift:192` passes (ב==ב), distance 1 over 6 → similarity 0.833 > 0.8 → **false replacement**. Same for ו/ה/ל/מ/ש/כ triggers of ≥5 letters. This is the exact failure class the MAJOR 2 fix was written to close, reachable by a route the fix does not cover.
3. **Maqaf (U+05BE) compounds.** `WordTokenizer.swift:24` treats maqaf as a non-letter, so `בית־ספר` tokenizes as two words: a single-word trigger `בית` matches and rewrites half the compound, leaving `Xספר`. Untested in both the Dictionary and correction-learning paths.
4. **LLM re-ordering placeholders.** `RehydrateStage.everyPlaceholderIntact` counts occurrences only (`:55-66`), so a reordered result validates and bodies land wherever the model moved them — a signature block silently relocated, with nothing flagged.

### Tier 2 — feature silently inert or wrong

5. **Gershayim/geresh shatter Hebrew acronyms in the correction-learning path.** `CorrectionDiffing:49-50` uses `WordTokenizer.tokenize` raw (not the `phrase` path), so `מנכ״ל` → `["מנכ","ל"]`. Corrections to or from any acronym are invisible; the fragment pair survives only because the distance thresholds happen to reject it, not by design.
6. **VocaMac itself frontmost when correction learning re-reads.** `AppState.swift:1310` uses `NSWorkspace.shared.frontmostApplication` raw, without the `isSelf` fallback `AXContextReader.capture` applies (`AXContextReader.swift:111-113`) — dictating from the app's own Settings or History window re-reads VocaMac's field, not the user's target.
7. **Focus moving to a different field in the same app during the 1.5 s delay.** Only the pid is captured (`AppState.swift:1310`); no element identity is held, so `focusedTextElement` re-resolves whatever is focused at fire time. Usually a silent nil; a coincidental single-token match proposes a bogus entry. (Contrast Command Mode, which does hold element + range + text.)
8. **No AX permission is indistinguishable from element-not-readable.** Both return nil (`CorrectionLearner`), so the feature can be permanently inert with no diagnostic.
9. **LLM inserting whitespace or a bidi mark inside a placeholder** (`⟦ S0 ⟧`, `⟦S\u{200F}0⟧`). Only the bracket-swap variant is tested. In Hebrew RTL text this discards every cleanup result while presenting as "post-processing stopped working".

### Tier 3 — unpinned invariants (correct today, one refactor from wrong)

10. **Length-changing normalization vs. original-string indices.** Correct today by construction, but no test matches a token whose normalized form differs in length (Yiddish ligature `ײ`→`יי`, niqqud stripping). The classic offset bug has zero regression coverage.
11. **Snippet body containing a placeholder-shaped token.** The descending-order substitution (`RehydrateStage.swift:68-81`) and guard exemption (`TranscriptPipeline.swift:134`) exist *specifically* for this and neither is exercised — `testSubstitutionOrderIsDeterministicAcrossTenAndOne` uses plain `BODY0…BODY10`.
12. **Fuzzy-vs-fuzzy overlap resolves "first over threshold", not "best match"** (`DictionaryService.swift:197`). Deterministic but undocumented as intended; adding an unrelated earlier entry silently changes an existing correction.
13. **`maximumFieldWords = 5_000`** (`CorrectionDiffing.swift:36`) — the NFR-4 cost ceiling has no test at all.
14. **Dictionary-before-Snippet interference**, documented but not fixed at `TranscriptPipeline.swift:30-39`: a fuzzy Dictionary hit inside a Cue kills the expansion. No test asserts the documented behaviour, so widening the fuzzy threshold would break Snippets silently.
15. **Export/import functions are entirely untested** (`VocabularySettingsTab.swift:254-297`, `:345-388`). The round-trip tests mirror the logic rather than invoking it; the 5 MB cap and both error messages are unreachable from tests.
16. **`Snippet` decoding is stricter than `DictionaryEntry` decoding.** `Models/Snippet.swift:13-29` uses synthesized `Codable` with `let id: UUID` and no defaults, so a hand-authored file missing an `id` fails the **whole-array** decode, whereas `DictionaryEntry.init(from:)` (`:56-62`) mints one. Both are presented to the user as hand-authorable.
17. **Dismissal ring buffer evicts FIFO by insertion, not recency** (`DismissedCorrectionsStore.swift:118-120`), and the only escape from a mistaken dismissal is the all-or-nothing clear (`VocabularySettingsTab.swift:68`).
18. **RTL bidi ordering is untested throughout** — no diffing test uses a bidi-mixed string where a visual edit lands at a different logical index, and no rehydration test asserts logical order around a multi-line Hebrew body.

### Tier 4 — Command Mode specifics

19. **Whitespace-only selection** passes every read guard and is sent to the LLM: only the *instruction* is trimmed (`CommandModeCoordinator.swift:184`), never the selection.
20. **Very large selection / token truncation.** `commandMaxTokens` scales (`PostProcessService.swift:232`), but nothing compares rewrite length to selection length before writing beyond the ceiling/floor checks — a truncated completion that clears the floor replaces the whole selection and the tail is lost.
21. **LLM returns near-empty output.** The coordinator rejects only an *exact* match to the selection (`:223`); a near-empty answer above the validator floor erases most of the selection.
22. **LLM echoes a *reworded* instruction.** Verbatim echo is rejected (`PostProcessService.swift:619`); a restatement above the similarity floor lands in the document.
23. **AX-writable-but-lying target.** `TextInjector.swift:767-771`: a target answering neither `AXStringForRange` nor `AXNumberOfCharacters` returns `.success` unverified, so a discarded write is reported to the user as a completed rewrite.
24. **RTL bidi-mark loss on replace.** `verifyWrite` explicitly tolerates app-side normalization "(smart quotes, autocorrect, RTL marks)" as success (`TextInjector.swift:736-739`) — an app stripping bidi controls reports success while altering the text. No real-AX RTL write test exists.
25. **Safety timer on the command binding.** `HotKeyBinding.swift:320-334` fires `onStop` after up to 65 s, which would run a rewrite against a long-stale selection. Untested for *either* binding.
26. **Command binding in double-tap toggle mode** is never driven by an event in any test — and toggle mode is exactly where selection staleness is worst (see 6.1.3).
27. **Dictation started during an active command recording.** The refusal in the opposite direction is tested (`.testCommandModeIsRefusedWhileADictationIsRecordingAndLeavesItAlone`); `startRecording` while `activeRecordingMode == .command` is not.
28. **Two command gestures racing before the first suspends**, and a gesture arriving between `captureSelection` and `beginCapture`, are uncovered — `isStoppingCommand` (`AppState.swift:1454`) and the operation token cover only discard-then-recapture.
29. **Clipboard invariant unpinned.** `replaceSelection` never touches `NSPasteboard` (verified by inspection), but no test asserts it, so a future clipboard-based replace would slip through silently.

---

## Meta-finding: an unverifiable claim in the retrospective

`_bmad-output/RETROSPECTIVE.md:108` states that Epic 8's adversarial-review pass "added `DictionaryLanguageTests.swift` and others, taking the suite to 763." No file of that name exists in the working tree, and `git log --all -- '*DictionaryLanguageTests*'` returns nothing — it has never existed in this repository's history. The tests it is credited with are not missing wholesale (the suite is now 784), but the specific artifact cited as evidence is not real.

This does not affect any Epic 5 or 6 verdict. It matters because the same document records both epics as "accepted — all ACs met after fix pass", and that judgement now has one demonstrably unverifiable supporting claim attached to it. Worth a correction pass on the retrospective.

---

## Recommended actions

0. **Fix AC-6.3.2 (the only violation).** Gate Re-paste on `record.mode != .command` in all three places: the button at `HistoryView.swift:212`, `AppState.rePaste` (`:1729`), and `rePasteMostRecent`'s `records.first` selection (`:1770`) — `rePasteMostRecent` bypasses the view, so a UI-only fix is incomplete. Add a test asserting `injectCallCount == 0` when re-pasting a `.command` record. Consider whether a command record should store the instruction in `finalText` at all (`AppState.swift:1653-1654`), since that field's contract everywhere else is "text that was injected".
1. **Amend `epics.md` AC 5.1.3** to record that matres-lectionis collapsing is deliberately excluded from `normalize`. The code is right; the epic is stale. This is the largest spec/implementation divergence in either epic.
2. **Close Tier-1 edge case 1** (literal `⟦S0⟧` in a transcript): have `SnippetService.protect` refuse to mint an index already present in the input, or mint from a run-unique prefix.
3. **Close Tier-1 edge case 2** (bound-prefix defeating the first-character anchor): require the *second* character to match too when the candidate is exactly one character longer than the trigger and begins with a bound particle.
4. **Add a ViewModel seam for `VocabularySettingsTab`** so 5.3.1, 5.3.4, 5.5.1 and 5.5.2 can move from PARTIAL to SATISFIED. This is the only structural coverage gap in Epic 5; it is a +305-line file with no direct test.
5. **Correct `RETROSPECTIVE.md:108`.**
6. **Add the two cheap missing assertions in Epic 6:** the error cue on the LLM/timeout/write abort paths (AC-6.3.3's failing sub-clause), and a test that the two shipped hotkey defaults differ (AC-6.1.6).

---

## Method note

Four parallel Opus subagents gathered per-AC evidence (5.1–5.2, 5.3–5.5, 5.6, Epic 6); their findings were cross-checked against my own reads of `HebrewNormalizer`, `DictionaryService`, `SnippetService`, `RehydrateStage`, `TranscriptPipeline`, `TextInjector`, `CommandModeCoordinator`, `SnippetStore` and the git history of the two fix commits. Two agent claims were checked and **disproved** before they reached this report:

- a suspected exact-vs-normalized inconsistency in Snippet cue collision detection (disproved — `WordTokenizer.phrase:81` lowercases every word, so both sides use identical keys);
- a suspected modification of `TextInjector`'s role gate by the Epic 6 fix commit (disproved — the role set is byte-identical; only a local `let` became a `static let`).

One agent claim — the AC-6.3.2 re-paste violation — was independently re-verified at all four call sites before being recorded, because it is the only VIOLATED verdict in the report.
