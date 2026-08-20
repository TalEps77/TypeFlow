// DictationLanguageTests.swift
// VocaMac Tests
//
// Epic 8's bilingual dictation shipped with no tests at all (MEDIUM 4). This
// file covers the pieces the adversarial review found broken or unverified:
// the language codes the two UI surfaces have to agree on, the decoding
// options each language produces (MAJOR 3), the post-processing prompt that
// gets picked for each (MAJOR 1), and the requested-wins-over-detected
// precedence that decides both (MEDIUM 1, MEDIUM 2).

import XCTest
@testable import VocaMac

// MARK: - The shared language list (MAJOR 2)

final class DictationLanguageListTests: XCTestCase {

    /// The bug this list exists to prevent: the menu bar's segmented control
    /// has three segments, Settings offers nineteen choices, and both write the
    /// same key. Any code Settings can store must either be representable in
    /// the quick toggle or be *known* not to be, so the menu bar can render a
    /// label instead of a picker with no valid selection.
    func testEveryQuickToggleCodeIsOfferedBySettings() {
        let offered = Set(DictationLanguage.all.map(\.code))
        for code in DictationLanguage.quickToggleCodes {
            XCTAssertTrue(offered.contains(code), "\(code) is a quick-toggle segment with no Settings row")
        }
    }

    func testSettingsOffersNineteenDistinctCodes() {
        XCTAssertEqual(DictationLanguage.all.count, 19)
        XCTAssertEqual(Set(DictationLanguage.all.map(\.code)).count, 19, "a duplicate tag makes a SwiftUI Picker ambiguous")
        XCTAssertEqual(DictationLanguage.all.first?.code, "auto", "Auto-detect leads the list")
    }

    func testOnlyHebrewEnglishAndAutoCanQuickToggle() {
        XCTAssertTrue(DictationLanguage.canQuickToggle("he"))
        XCTAssertTrue(DictationLanguage.canQuickToggle("en"))
        XCTAssertTrue(DictationLanguage.canQuickToggle("auto"))
        // The sixteen that force the menu bar into label mode.
        for code in ["es", "fr", "de", "it", "pt", "nl", "zh", "ja", "ko", "hi", "ar", "ru", "tr", "pl", "sv", "uk"] {
            XCTAssertFalse(DictationLanguage.canQuickToggle(code), "\(code) has no segment and must not claim one")
        }
    }

    // MARK: - Display names (MINOR 7)

    func testDisplayNameIsTheSameStringForListAndDetail() {
        // The History list used to uppercase the raw code ("HE") while the
        // detail pane printed it verbatim ("he").
        XCTAssertEqual(DictationLanguage.displayName(for: "he"), "Hebrew")
        XCTAssertEqual(DictationLanguage.displayName(for: "en"), "English")
        XCTAssertEqual(DictationLanguage.displayName(for: "auto"), "Auto-detect")
    }

    func testDisplayNameIsCaseInsensitiveAndHandlesLegacyHebrewCode() {
        XCTAssertEqual(DictationLanguage.displayName(for: "HE"), "Hebrew")
        XCTAssertEqual(DictationLanguage.displayName(for: "iw"), "Hebrew", "deprecated ISO code some detectors still emit")
    }

    func testDisplayNameFallsBackToTheCodeRatherThanNothing() {
        XCTAssertEqual(DictationLanguage.displayName(for: "xx"), "XX")
    }

    func testDisplayNameIsNilForNoLanguage() {
        XCTAssertNil(DictationLanguage.displayName(for: nil))
        XCTAssertNil(DictationLanguage.displayName(for: ""))
    }
}

// MARK: - Decoding options table (MAJOR 3 / MEDIUM 4)

final class DecodingOptionsLanguageTests: XCTestCase {

    /// The combination that was shipped untested: `detectLanguage: true`
    /// alongside `usePrefillPrompt: true`, i.e. a Hebrew glossary prefilled
    /// ahead of the language detection it would then skew. The fix gates the
    /// glossary off in Auto (in `AppState`), which is what makes the
    /// `promptTokens == nil` row below the only Auto row reachable in practice
    /// — but `decodingOptions` is asserted across the whole table so a future
    /// caller cannot quietly reintroduce the bad cell.
    func testDecodingOptionsTable() {
        struct Row {
            let language: String?
            let promptTokens: [Int]?
            let expectedUsePrefill: Bool
            let expectedDetect: Bool
            let label: String
        }

        let glossary = [1, 2, 3]
        let rows: [Row] = [
            Row(language: "he", promptTokens: glossary, expectedUsePrefill: true, expectedDetect: false,
                label: "Hebrew + glossary — the everyday path"),
            Row(language: "he", promptTokens: nil, expectedUsePrefill: true, expectedDetect: false,
                label: "Hebrew, no glossary"),
            Row(language: "en", promptTokens: nil, expectedUsePrefill: true, expectedDetect: false,
                label: "English — glossary always gated off upstream"),
            Row(language: nil, promptTokens: nil, expectedUsePrefill: false, expectedDetect: true,
                label: "Auto after the MAJOR 3 fix — detection with no prefill"),
            Row(language: nil, promptTokens: glossary, expectedUsePrefill: true, expectedDetect: true,
                label: "Auto + glossary — the untested cell AppState no longer produces")
        ]

        for row in rows {
            let options = WhisperService.decodingOptions(
                language: row.language,
                translate: false,
                promptTokens: row.promptTokens
            )

            XCTAssertEqual(options.language, row.language, row.label)
            XCTAssertEqual(options.usePrefillPrompt, row.expectedUsePrefill, row.label)
            XCTAssertEqual(options.detectLanguage, row.expectedDetect, row.label)
            XCTAssertEqual(options.promptTokens, row.promptTokens, row.label)
            XCTAssertEqual(options.task, .transcribe, row.label)
        }
    }

    func testTranslateFlagSwitchesTheTask() {
        let options = WhisperService.decodingOptions(language: "he", translate: true, promptTokens: nil)
        XCTAssertEqual(options.task, .translate)
    }
}

// MARK: - Prompt selection (MAJOR 1)

final class LanguageAwarePromptTests: XCTestCase {

    func testHebrewAndAutoGetTheHebrewPrompt() {
        XCTAssertEqual(Prompts.cleanTranscriptSystemPrompt(for: "he"), Prompts.cleanTranscriptSystemPrompt)
        XCTAssertEqual(Prompts.cleanTranscriptSystemPrompt(for: nil), Prompts.cleanTranscriptSystemPrompt,
                       "Auto with nothing detected keeps the Hebrew-first default")
    }

    func testEnglishGetsTheEnglishPrompt() {
        XCTAssertEqual(Prompts.cleanTranscriptSystemPrompt(for: "en"), Prompts.cleanTranscriptSystemPromptEN)
    }

    /// The English prompt exists because the Hebrew one demonstrates nothing an
    /// English dictation can copy. Assert the specific things that were missing
    /// rather than just "it is a different string".
    func testEnglishPromptTeachesEnglishSelfCorrectionAndFillers() {
        let prompt = Prompts.cleanTranscriptSystemPromptEN

        for marker in ["no", "actually", "sorry", "I mean", "wait"] {
            XCTAssertTrue(prompt.contains(marker), "English correction marker \"\(marker)\" is missing from rule 4")
        }
        XCTAssertTrue(prompt.contains("Transcript: we ship Tuesday no Wednesday"),
                      "the self-correction few-shot is the example that makes the rule fire")
        XCTAssertTrue(prompt.contains("Cleaned: We ship Wednesday."))
        XCTAssertTrue(prompt.contains("um"), "filler-removal examples")
        XCTAssertTrue(prompt.contains("leave?"), "a dictated question must stay a question")
        XCTAssertTrue(prompt.contains("- chairs"), "enumeration becomes a list")
        XCTAssertFalse(prompt.contains("אה"), "the English prompt must not show Hebrew fillers — being shown Hebrew is what invited Hebrew answers")
    }

    func testNonHebrewNonEnglishLanguagesGetTheEnglishPrompt() {
        // Deliberate: no hand-tuned prompt exists for the other seventeen, and
        // the English one's rules are language-neutral apart from its marker
        // list. Its rule 1 is what keeps the answer in the spoken language.
        XCTAssertEqual(Prompts.cleanTranscriptSystemPrompt(for: "es"), Prompts.cleanTranscriptSystemPromptEN)
        XCTAssertEqual(Prompts.cleanTranscriptSystemPrompt(for: "ja"), Prompts.cleanTranscriptSystemPromptEN)
    }

    // MARK: - The stage's substitution rule

    @MainActor
    func testStageSubstitutesTheLanguageVariantWhenThePromptIsStillTheDefault() {
        XCTAssertEqual(
            PostProcessStage.languageAwarePrompt(Prompts.cleanTranscriptSystemPrompt, language: "en"),
            Prompts.cleanTranscriptSystemPromptEN
        )
        XCTAssertEqual(
            PostProcessStage.languageAwarePrompt(Prompts.cleanTranscriptSystemPrompt, language: "he"),
            Prompts.cleanTranscriptSystemPrompt
        )
    }

    /// The guard that matters more than the substitution: a user who has edited
    /// the prompt must get their text, in every language. There is one prompt
    /// field in Settings, so silently swapping it out would discard work with
    /// nowhere to recover it from.
    @MainActor
    func testStageNeverOverridesAnEditedPrompt() {
        let edited = Prompts.cleanTranscriptSystemPrompt + "\n\nAlways end with a full stop."

        XCTAssertEqual(PostProcessStage.languageAwarePrompt(edited, language: "en"), edited)
        XCTAssertEqual(PostProcessStage.languageAwarePrompt(edited, language: "he"), edited)
        XCTAssertEqual(PostProcessStage.languageAwarePrompt("totally custom", language: "en"), "totally custom")
    }

    /// End-to-end through the stage, since the substitution is only useful if
    /// the prompt actually reaches the service.
    @MainActor
    func testStageSendsTheEnglishPromptForAnEnglishDictation() async {
        let service = MockPostProcessService()
        service.cleanResult = .success("We ship Wednesday.")
        let stage = PostProcessStage(
            service: service,
            settingsProvider: { PostProcessSettings(isEnabled: true) }
        )

        let result = await stage.run(TranscriptContext(rawTranscript: "we ship Tuesday no Wednesday", language: "en"))

        XCTAssertEqual(result.text, "We ship Wednesday.")
        XCTAssertEqual(service.lastSystemPrompt, Prompts.cleanTranscriptSystemPromptEN)
    }

    @MainActor
    func testStageSendsTheHebrewPromptForAHebrewDictation() async {
        let service = MockPostProcessService()
        service.cleanResult = .success("נפגש ביום רביעי.")
        let stage = PostProcessStage(
            service: service,
            settingsProvider: { PostProcessSettings(isEnabled: true) }
        )

        _ = await stage.run(TranscriptContext(rawTranscript: "נפגש ביום שלישי אה לא ביום רביעי", language: "he"))

        XCTAssertEqual(service.lastSystemPrompt, Prompts.cleanTranscriptSystemPrompt)
    }

    /// A Profile override is an explicit instruction about this app's tone, in
    /// whatever language the user wrote it. It outranks the language variant.
    @MainActor
    func testProfileOverrideStillWinsOverTheLanguageVariant() async {
        let service = MockPostProcessService()
        service.cleanResult = .success("cleaned")
        let stage = PostProcessStage(
            service: service,
            settingsProvider: { PostProcessSettings(isEnabled: true) }
        )
        let profile = Profile(name: "Code Editor", promptOverride: "keep it terse")

        _ = await stage.run(TranscriptContext(rawTranscript: "raw", resolvedProfile: profile, language: "en"))

        XCTAssertEqual(service.lastSystemPrompt, "keep it terse")
    }
}

// MARK: - Language resolution in the recording flow (MEDIUM 1, MEDIUM 2, MINOR 8)

@MainActor
final class RecordingLanguageResolutionTests: XCTestCase {

    /// Restores the process-wide scratch defaults suite these tests write
    /// through @AppStorage, so nothing leaks into a later test.
    private func withLanguageSetting(_ value: String, _ body: (AppState, TestMocks) async -> Void) async {
        let (appState, mocks) = AppState.makeTestState()
        let previous = appState.selectedLanguage
        appState.selectedLanguage = value
        mocks.audioEngine.stopRecordingResult = [0.1, 0.2, 0.3]
        await body(appState, mocks)
        appState.selectedLanguage = previous
    }

    // MARK: MEDIUM 2 — the language is fixed at recording start

    func testLanguageIsCapturedAtRecordingStart() async {
        await withLanguageSetting("he") { appState, mocks in
            await appState.startRecording()
            XCTAssertEqual(appState.capturedLanguage, "he")

            // The user flips the menu-bar toggle mid-sentence. The speech was
            // already Hebrew; decoding it as English would be a guess about
            // audio that has already been captured.
            appState.selectedLanguage = "en"

            await appState.stopRecordingAndTranscribe()

            XCTAssertEqual(mocks.whisperService.lastLanguage, "he",
                           "a mid-recording toggle flip must not retroactively change the language")
        }
    }

    func testCapturedLanguageIsClearedOnceConsumed() async {
        await withLanguageSetting("he") { appState, _ in
            await appState.startRecording()
            await appState.stopRecordingAndTranscribe()

            XCTAssertNil(appState.capturedLanguage, "nothing is held past the one run that needs it")
        }
    }

    func testCapturedLanguageIsClearedWhenTheEngineNeverStarts() async {
        await withLanguageSetting("he") { appState, mocks in
            mocks.audioEngine.startRecordingResult = false

            await appState.startRecording()

            XCTAssertNil(appState.capturedLanguage)
        }
    }

    // MARK: Story 8.2 precedence — Profile override beats the app-wide toggle

    func testProfileLanguageOverrideWinsOverTheAppWideToggle() async {
        await withLanguageSetting("he") { appState, mocks in
            mocks.profileManager.resolvedProfile = Profile(
                name: "Slack",
                bundleIdentifiers: ["com.tinyspeck.slackmacgap"],
                language: "en"
            )

            await appState.startRecording()
            XCTAssertEqual(appState.capturedLanguage, "en", "capturedProfile?.language ?? selectedLanguage")

            await appState.stopRecordingAndTranscribe()
            XCTAssertEqual(mocks.whisperService.lastLanguage, "en")
        }
    }

    func testAppWideToggleIsUsedWhenTheProfileHasNoOverride() async {
        await withLanguageSetting("he") { appState, mocks in
            mocks.profileManager.resolvedProfile = Profile(name: "Default", isDefault: true, language: nil)

            await appState.startRecording()

            XCTAssertEqual(appState.capturedLanguage, "he")
        }
    }

    // MARK: MAJOR 3 — the glossary gate

    func testGlossaryIsSentForHebrew() async {
        await withLanguageSetting("he") { appState, mocks in
            appState.customVocabulary = "kubectl, nginx"
            defer { appState.customVocabulary = "" }

            await appState.startRecording()
            await appState.stopRecordingAndTranscribe()

            XCTAssertEqual(mocks.whisperService.lastVocabulary, "kubectl, nginx")
        }
    }

    func testGlossaryIsWithheldForEnglish() async {
        await withLanguageSetting("en") { appState, mocks in
            appState.customVocabulary = "kubectl, nginx"
            defer { appState.customVocabulary = "" }

            await appState.startRecording()
            await appState.stopRecordingAndTranscribe()

            XCTAssertEqual(mocks.whisperService.lastVocabulary, "",
                           "a Hebrew-leaning glossary has no business steering an English recording")
        }
    }

    func testGlossaryIsWithheldInAutoDetect() async {
        await withLanguageSetting("auto") { appState, mocks in
            appState.customVocabulary = "kubectl, nginx"
            defer { appState.customVocabulary = "" }

            await appState.startRecording()
            await appState.stopRecordingAndTranscribe()

            XCTAssertNil(mocks.whisperService.lastLanguage, "Auto passes nil so WhisperKit detects")
            XCTAssertEqual(mocks.whisperService.lastVocabulary, "",
                           "prefilling a glossary ahead of language detection skews the detection (MAJOR 3)")
        }
    }

    // MARK: MEDIUM 1 — requested language wins over detection

    func testHistoryRecordsTheRequestedLanguageNotTheDetectedOne() async {
        await withLanguageSetting("en") { appState, mocks in
            // WhisperKit's detection is a guess, and here it guesses wrong.
            mocks.whisperService.mockTranscriptionResult = VocaTranscription(
                text: "we ship Wednesday",
                duration: 1.0,
                detectedLanguage: "he",
                audioLengthSeconds: 1.0,
                modelUsed: .tiny
            )

            await appState.startRecording()
            await appState.stopRecordingAndTranscribe()

            XCTAssertEqual(mocks.historyStore.lastRecordedRecord?.language, "en",
                           "an English-forced dictation must not be recorded as Hebrew")
        }
    }

    func testHistoryFallsBackToDetectionOnlyInAutoDetect() async {
        await withLanguageSetting("auto") { appState, mocks in
            mocks.whisperService.mockTranscriptionResult = VocaTranscription(
                text: "שלום עולם",
                duration: 1.0,
                detectedLanguage: "he",
                audioLengthSeconds: 1.0,
                modelUsed: .tiny
            )

            await appState.startRecording()
            await appState.stopRecordingAndTranscribe()

            XCTAssertEqual(mocks.historyStore.lastRecordedRecord?.language, "he",
                           "Auto has no request to honor, so detection is all there is")
        }
    }

    // MARK: MEDIUM 3 — the override is visible before dictating

    func testFrontmostProfileLanguageOverrideIsReportedForTheMenuBar() {
        let (appState, mocks) = AppState.makeTestState()
        mocks.profileManager.resolvedProfile = Profile(
            name: "Slack",
            bundleIdentifiers: ["com.tinyspeck.slackmacgap"],
            language: "en"
        )

        let override = appState.frontmostProfileLanguageOverride

        XCTAssertEqual(override?.language, "en")
        XCTAssertEqual(override?.profileName, "Slack")
    }

    func testNoOverrideReportedWhenTheProfilePinsNothing() {
        let (appState, mocks) = AppState.makeTestState()
        mocks.profileManager.resolvedProfile = Profile(name: "Default", isDefault: true, language: nil)

        XCTAssertNil(appState.frontmostProfileLanguageOverride,
                     "with nothing pinned the menu bar shows its normal segmented control")
    }

    func testNoOverrideReportedWhenProfilesAreDisabled() {
        let (appState, mocks) = AppState.makeTestState()
        mocks.profileManager.resolvedProfile = Profile(name: "Slack", language: "en")
        let previous = appState.profilesEnabled
        appState.profilesEnabled = false
        defer { appState.profilesEnabled = previous }

        XCTAssertNil(appState.frontmostProfileLanguageOverride)
    }
}

// MARK: - Persistence back-compat (MEDIUM 4)

final class LanguagePersistenceTests: XCTestCase {

    /// Every Profile written before Story 8.2 has no `language` key at all.
    /// Decoding must produce `nil` — "fall back to the app-wide toggle" — not
    /// throw and lose the user's whole Profile set.
    func testProfileWithoutLanguageKeyDecodesToNil() throws {
        let legacy = #"""
        {"id":"00000000-0000-0000-0000-000000000001","name":"Default","bundleIdentifiers":[],"promptOverride":"","postProcessEnabled":true,"contextCaptureEnabled":false,"isDefault":true}
        """#

        let profile = try JSONDecoder().decode(Profile.self, from: Data(legacy.utf8))

        XCTAssertNil(profile.language)
        XCTAssertEqual(profile.name, "Default")
    }

    func testProfileLanguageRoundTrips() throws {
        let profile = Profile(name: "Slack", bundleIdentifiers: ["com.tinyspeck.slackmacgap"], language: "en")

        let decoded = try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(profile))

        XCTAssertEqual(decoded.language, "en")
        XCTAssertEqual(decoded, profile)
    }

    /// Import hardening rewrites every field it does not trust. `language` is
    /// one it *does* trust — it can only pick a transcription language, and
    /// dropping it would silently discard a setting from a shared Profile set.
    func testImportCarriesProfileLanguageThrough() {
        let imported = [
            Profile(id: Profile.defaultProfileID, name: "Default", isDefault: true, language: "auto"),
            Profile(name: "Slack", bundleIdentifiers: ["com.tinyspeck.slackmacgap"], language: "en"),
            Profile(name: "Notes", bundleIdentifiers: ["com.apple.Notes"], language: nil)
        ]

        let sanitized = Profile.sanitizedForImport(imported)

        XCTAssertEqual(sanitized.profiles.map(\.language), ["auto", "en", nil])
    }

    func testHistoryRecordWithoutLanguageKeyDecodesToNil() throws {
        let legacy = #"""
        {"id":"11111111-1111-1111-1111-111111111111","timestamp":0,"rawTranscript":"raw","finalText":"final","modelName":"tiny","recordingMillis":0,"asrMillis":0,"postProcessMillis":0,"didFallback":false,"mode":"dictation"}
        """#

        let record = try JSONDecoder().decode(HistoryRecord.self, from: Data(legacy.utf8))

        XCTAssertNil(record.language)
        XCTAssertEqual(record.finalText, "final")
    }

    func testHistoryRecordLanguageRoundTrips() throws {
        let record = HistoryRecord(rawTranscript: "raw", finalText: "final", modelName: "tiny", language: "he")

        let decoded = try JSONDecoder().decode(HistoryRecord.self, from: JSONEncoder().encode(record))

        XCTAssertEqual(decoded.language, "he")
    }
}
