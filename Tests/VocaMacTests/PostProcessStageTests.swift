// PostProcessStageTests.swift
// VocaMac Tests
//
// The stage's whole job is deciding what reaches the cursor. Every path that
// is not a validated cleaned transcript must leave the text alone (AD-2), and
// the disabled path must not touch the service at all.

import XCTest
@testable import VocaMac

// MARK: - Tests
//
// MockPostProcessService lives in Tests/VocaMacTests/Mocks/MockServices.swift
// (MINOR 9), so it can also be threaded through AppState.makeTestState.

@MainActor
final class PostProcessStageTests: XCTestCase {

    private func makeStage(
        service: MockPostProcessService,
        settings: PostProcessSettings
    ) -> PostProcessStage {
        PostProcessStage(service: service, settingsProvider: { settings })
    }

    private var enabledSettings: PostProcessSettings {
        PostProcessSettings(isEnabled: true, systemPrompt: "SYSTEM")
    }

    // MARK: - Success

    func testCleanedTextIsApplied() async {
        let service = MockPostProcessService()
        service.cleanResult = .success("נפגש בשלוש.")
        let stage = makeStage(service: service, settings: enabledSettings)

        let result = await stage.run(TranscriptContext(rawTranscript: "נפגש בשתיים בעצם בשלוש"))

        XCTAssertEqual(result.text, "נפגש בשלוש.")
        XCTAssertEqual(result.outcome, .applied)
        XCTAssertEqual(service.cleanCallCount, 1)
        XCTAssertEqual(service.lastText, "נפגש בשתיים בעצם בשלוש")
        XCTAssertEqual(service.lastSystemPrompt, "SYSTEM")
    }

    func testStageSeesTheTextTheStageBeforeItProduced() async {
        let service = MockPostProcessService()
        let stage = makeStage(service: service, settings: enabledSettings)
        var context = TranscriptContext(rawTranscript: "raw")
        context.currentText = "text from an earlier stage"

        _ = await stage.run(context)

        XCTAssertEqual(service.lastText, "text from an earlier stage")
    }

    func testUnchangedOutputIsReportedAsSkippedRatherThanApplied() async {
        let service = MockPostProcessService()
        service.cleanResult = .success("הפגישה נדחתה למחר.")
        let stage = makeStage(service: service, settings: enabledSettings)

        let result = await stage.run(TranscriptContext(rawTranscript: "הפגישה נדחתה למחר."))

        XCTAssertEqual(result.text, "הפגישה נדחתה למחר.")
        XCTAssertEqual(result.outcome, .skipped(reason: "no changes needed"))
        XCTAssertTrue(result.didRun,
                       "This skip came *after* a real round trip — its duration is genuine latency (MAJOR 6)")
    }

    // MARK: - The master toggle

    func testDisabledStageMakesNoRequestAtAll() async {
        let service = MockPostProcessService()
        service.cleanResult = .success("THIS MUST NEVER APPEAR")
        let stage = makeStage(service: service, settings: PostProcessSettings(isEnabled: false))

        let result = await stage.run(TranscriptContext(rawTranscript: "שלום עולם"))

        XCTAssertEqual(service.cleanCallCount, 0, "With the master toggle off no HTTP request may be made")
        XCTAssertEqual(result.text, "שלום עולם")
        XCTAssertEqual(result.outcome, .skipped(reason: "post-processing disabled"))
        XCTAssertFalse(result.didRun,
                        "Declining before any work means there is no latency worth reporting (MAJOR 6)")
    }

    func testDisabledStageIsIdentityAcrossTheCorpus() async {
        let service = MockPostProcessService()
        service.cleanResult = .success("THIS MUST NEVER APPEAR")
        let stage = makeStage(service: service, settings: PostProcessSettings(isEnabled: false))
        let pipeline = TranscriptPipeline(stages: [stage])

        for input in ["", " ", "שָׁלוֹם עוֹלָם", "mixed עברית and English", "\n\t"] {
            let result = await pipeline.run(TranscriptContext(rawTranscript: input))
            XCTAssertEqual(result.currentText, input)
        }
        XCTAssertEqual(service.cleanCallCount, 0)
    }

    func testPostProcessingShipsOff() {
        XCTAssertFalse(PostProcessSettings.Default.enabled, "Post-processing must be opt-in")
        XCTAssertFalse(PostProcessSettings().isEnabled)
    }

    // MARK: - Empty input

    func testEmptyAndWhitespaceInputSkipTheService() async {
        let service = MockPostProcessService()
        let stage = makeStage(service: service, settings: enabledSettings)

        for input in ["", "   ", "\n\t "] {
            let result = await stage.run(TranscriptContext(rawTranscript: input))
            XCTAssertEqual(result.text, input)
            XCTAssertEqual(result.outcome, .skipped(reason: "nothing to clean"))
            XCTAssertFalse(result.didRun)
        }
        XCTAssertEqual(service.cleanCallCount, 0)
    }

    // MARK: - Every failure mode passes the raw text through

    func testEveryFailureModeReturnsTheInputUnchanged() async {
        let failures: [PostProcessError] = [
            .timedOut(5),
            .transport("Could not connect to the server."),
            .httpStatus(404),
            .httpStatus(500),
            .malformedResponse("could not decode chat completion"),
            .emptyContent,
            .disproportionateLength(inputCharacters: 20, outputCharacters: 900),
            .invalidEndpoint("nonsense")
        ]

        for failure in failures {
            let service = MockPostProcessService()
            service.cleanResult = .failure(failure)
            let stage = makeStage(service: service, settings: enabledSettings)

            let result = await stage.run(TranscriptContext(rawTranscript: "נפגש מחר בעשר"))

            XCTAssertEqual(result.text, "נפגש מחר בעשר", "\(failure) must not change the transcript")
            XCTAssertEqual(result.outcome, .failed(reason: failure.reason))
        }
    }

    func testFailureKeepsTheRawTranscriptAlongsideTheFinalText() async {
        let service = MockPostProcessService()
        service.cleanResult = .failure(.timedOut(5))
        let stage = makeStage(service: service, settings: enabledSettings)
        let pipeline = TranscriptPipeline(stages: [stage])

        let result = await pipeline.run(TranscriptContext(rawTranscript: "נפגש מחר"))

        XCTAssertEqual(result.rawTranscript, "נפגש מחר")
        XCTAssertEqual(result.currentText, "נפגש מחר")
        XCTAssertEqual(result.reports.first?.outcome, .failed(reason: "timed out after 5.0s"))
    }

    // MARK: - Settings are read per run

    func testSettingsAreReadOnEveryRunNotAtConstruction() async {
        let service = MockPostProcessService()
        var settings = PostProcessSettings(isEnabled: false)
        let stage = PostProcessStage(service: service, settingsProvider: { settings })

        _ = await stage.run(TranscriptContext(rawTranscript: "שלום"))
        XCTAssertEqual(service.cleanCallCount, 0)

        settings.isEnabled = true
        _ = await stage.run(TranscriptContext(rawTranscript: "שלום"))
        XCTAssertEqual(service.cleanCallCount, 1, "Toggling the setting must take effect on the next dictation")
    }

    func testConfigurationIsPassedThroughFromSettings() async {
        let service = MockPostProcessService()
        let settings = PostProcessSettings(
            isEnabled: true,
            baseURL: "http://127.0.0.1:9999",
            model: "some-model",
            timeout: 2.5,
            temperature: 0.3,
            systemPrompt: "P"
        )
        let stage = makeStage(service: service, settings: settings)

        _ = await stage.run(TranscriptContext(rawTranscript: "שלום"))

        XCTAssertEqual(service.lastConfiguration, PostProcessConfiguration(
            baseURL: "http://127.0.0.1:9999",
            model: "some-model",
            timeout: 2.5,
            temperature: 0.3
        ))
    }

    // MARK: - The production pipeline

    // MARK: - Story 4.2: the resolved Profile is honored

    func testProfilePromptOverrideReplacesTheGlobalSystemPrompt() async {
        let service = MockPostProcessService()
        let stage = makeStage(service: service, settings: enabledSettings)
        let profile = Profile(name: "Code Editor", promptOverride: "PROFILE PROMPT")

        _ = await stage.run(TranscriptContext(rawTranscript: "שלום", resolvedProfile: profile))

        XCTAssertEqual(service.lastSystemPrompt, "PROFILE PROMPT")
    }

    func testEmptyProfilePromptOverrideFallsBackToTheGlobalSystemPrompt() async {
        let service = MockPostProcessService()
        let stage = makeStage(service: service, settings: enabledSettings)
        let profile = Profile(name: "Default", promptOverride: "", isDefault: true)

        _ = await stage.run(TranscriptContext(rawTranscript: "שלום", resolvedProfile: profile))

        XCTAssertEqual(service.lastSystemPrompt, "SYSTEM", "An empty override must not shadow the global prompt")
    }

    func testProfileWithPostProcessDisabledMakesNoRequestEvenWhenGloballyEnabled() async {
        let service = MockPostProcessService()
        service.cleanResult = .success("THIS MUST NEVER APPEAR")
        let stage = makeStage(service: service, settings: enabledSettings)
        let profile = Profile(name: "Raw", postProcessEnabled: false)

        let result = await stage.run(TranscriptContext(rawTranscript: "שלום עולם", resolvedProfile: profile))

        XCTAssertEqual(service.cleanCallCount, 0)
        XCTAssertEqual(result.text, "שלום עולם")
        XCTAssertFalse(result.didRun)
    }

    func testNoProfileBehavesLikeEveryToggleEnabled() async {
        // Pre-Epic-4 callers, and any pipeline run before a Profile is
        // resolved, must see exactly Epic 2/3's behavior.
        let service = MockPostProcessService()
        let stage = makeStage(service: service, settings: enabledSettings)

        _ = await stage.run(TranscriptContext(rawTranscript: "שלום"))

        XCTAssertEqual(service.cleanCallCount, 1)
        XCTAssertEqual(service.lastSystemPrompt, "SYSTEM")
    }

    func testGlobalToggleOffWinsEvenWhenProfileAllowsPostProcessing() async {
        let service = MockPostProcessService()
        let stage = makeStage(service: service, settings: PostProcessSettings(isEnabled: false))
        let profile = Profile(name: "Eager", postProcessEnabled: true)

        let result = await stage.run(TranscriptContext(rawTranscript: "שלום", resolvedProfile: profile))

        XCTAssertEqual(service.cleanCallCount, 0)
        XCTAssertEqual(result.outcome, .skipped(reason: "post-processing disabled"))
    }

    func testProductionPipelineIsIdentityWithDefaultSettings() async {
        // The shipping pipeline carries the PostProcess stage, but the feature
        // ships off, so a user who has changed nothing sees no change (AD-13).
        //
        // This reads and writes UserDefaults.standard through the real
        // PostProcessSettings.current() — restore whatever was there before,
        // even if an assertion below fails (MINOR 8).
        let defaults = UserDefaults.standard
        let previousValue = defaults.object(forKey: PostProcessSettings.Key.enabled)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: PostProcessSettings.Key.enabled)
            } else {
                defaults.removeObject(forKey: PostProcessSettings.Key.enabled)
            }
        }
        defaults.removeObject(forKey: PostProcessSettings.Key.enabled)

        let dictionaryStore = DictionaryStore(store: JSONFileStore(
            fileName: "dictionary.json",
            defaultValue: [],
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("vocamac_test_dictionary_\(UUID().uuidString)", isDirectory: true)
        ))
        let snippetStore = SnippetStore(store: JSONFileStore(
            fileName: "snippets.json",
            defaultValue: [],
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("vocamac_test_snippets_\(UUID().uuidString)", isDirectory: true)
        ))
        let pipeline = TranscriptPipeline.production(dictionaryStore: dictionaryStore, snippetStore: snippetStore)
        for input in ["שָׁלוֹם עוֹלָם", "mixed עברית and English", "", "  "] {
            let result = await pipeline.run(TranscriptContext(rawTranscript: input))
            XCTAssertEqual(result.currentText, input)
        }
    }
}

// MARK: - Settings persistence

final class PostProcessSettingsTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "vocamac.tests.postProcess"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsWhenNothingIsStored() {
        let settings = PostProcessSettings.current(from: defaults)

        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.baseURL, "http://localhost:1234")
        XCTAssertEqual(settings.model, "qwen3-4b-instruct-2507-mlx")
        XCTAssertEqual(settings.timeout, 5.0)
        XCTAssertEqual(settings.temperature, 0.0)
        XCTAssertEqual(settings.systemPrompt, Prompts.cleanTranscriptSystemPrompt)
    }

    func testRoundTrip() {
        defaults.set(true, forKey: PostProcessSettings.Key.enabled)
        defaults.set("http://127.0.0.1:8080", forKey: PostProcessSettings.Key.baseURL)
        defaults.set("another-model", forKey: PostProcessSettings.Key.model)
        defaults.set(3.0, forKey: PostProcessSettings.Key.timeout)
        defaults.set(0.4, forKey: PostProcessSettings.Key.temperature)
        defaults.set("my prompt", forKey: PostProcessSettings.Key.systemPrompt)

        let settings = PostProcessSettings.current(from: defaults)

        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.baseURL, "http://127.0.0.1:8080")
        XCTAssertEqual(settings.model, "another-model")
        XCTAssertEqual(settings.timeout, 3.0)
        XCTAssertEqual(settings.temperature, 0.4)
        XCTAssertEqual(settings.systemPrompt, "my prompt")
    }

    func testEmptyAndInvalidStoredValuesFallBackToDefaults() {
        // A cleared text field must not produce a request with no model or a
        // zero timeout.
        defaults.set("   ", forKey: PostProcessSettings.Key.baseURL)
        defaults.set("", forKey: PostProcessSettings.Key.model)
        defaults.set(0.0, forKey: PostProcessSettings.Key.timeout)
        defaults.set("", forKey: PostProcessSettings.Key.systemPrompt)

        let settings = PostProcessSettings.current(from: defaults)

        XCTAssertEqual(settings.baseURL, PostProcessSettings.Default.baseURL)
        XCTAssertEqual(settings.model, PostProcessSettings.Default.model)
        XCTAssertEqual(settings.timeout, PostProcessSettings.Default.timeout)
        XCTAssertEqual(settings.systemPrompt, Prompts.cleanTranscriptSystemPrompt)
    }

    func testKeysUseThePostProcessNamespace() {
        for key in [
            PostProcessSettings.Key.enabled,
            PostProcessSettings.Key.baseURL,
            PostProcessSettings.Key.model,
            PostProcessSettings.Key.timeout,
            PostProcessSettings.Key.temperature,
            PostProcessSettings.Key.systemPrompt
        ] {
            XCTAssertTrue(key.hasPrefix("vocamac.postProcess."), "\(key) breaks the AD-9 key convention")
        }
    }
}
