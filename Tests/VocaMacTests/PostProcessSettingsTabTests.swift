// PostProcessSettingsTabTests.swift
// VocaMac Tests
//
// The settings tab writes through @AppStorage on AppState; the pipeline stage
// reads the same keys through PostProcessSettings. These tests hold the two
// halves together — an edit in the tab has to be what the next dictation uses.

import XCTest
@testable import VocaMac

@MainActor
final class PostProcessSettingsTabTests: XCTestCase {

    private let keys = [
        PostProcessSettings.Key.enabled,
        PostProcessSettings.Key.baseURL,
        PostProcessSettings.Key.model,
        PostProcessSettings.Key.timeout,
        PostProcessSettings.Key.temperature,
        PostProcessSettings.Key.systemPrompt
    ]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    // MARK: - Defaults

    func testDefaultsMatchTheDocumentedValues() {
        let (appState, _) = AppState.makeTestState()

        XCTAssertFalse(appState.postProcessEnabled, "Post-processing must ship off")
        XCTAssertEqual(appState.postProcessBaseURL, "http://localhost:1234")
        XCTAssertEqual(appState.postProcessModel, "qwen3-4b-instruct-2507-mlx")
        XCTAssertEqual(appState.postProcessTimeout, 5.0)
        XCTAssertLessThan(appState.postProcessTimeout, 10.0, "the timeout must stay in low single-digit seconds")
        XCTAssertEqual(appState.postProcessTemperature, 0.0)
        XCTAssertEqual(appState.postProcessSystemPrompt, Prompts.cleanTranscriptSystemPrompt)
    }

    // MARK: - Persistence

    func testEditsPersistAndAreWhatTheStageReads() {
        let (appState, _) = AppState.makeTestState()

        appState.postProcessEnabled = true
        appState.postProcessBaseURL = "http://127.0.0.1:4321"
        appState.postProcessModel = "some-other-model"
        appState.postProcessTimeout = 2.5
        appState.postProcessTemperature = 0.2
        appState.postProcessSystemPrompt = "custom prompt"

        // What the pipeline stage will see on the next dictation.
        let settings = PostProcessSettings.current()

        XCTAssertTrue(settings.isEnabled)
        XCTAssertEqual(settings.baseURL, "http://127.0.0.1:4321")
        XCTAssertEqual(settings.model, "some-other-model")
        XCTAssertEqual(settings.timeout, 2.5)
        XCTAssertEqual(settings.temperature, 0.2)
        XCTAssertEqual(settings.systemPrompt, "custom prompt")
    }

    func testEditsSurviveANewAppState() {
        let (first, _) = AppState.makeTestState()
        first.postProcessEnabled = true
        first.postProcessBaseURL = "http://127.0.0.1:5555"

        // Standing in for a relaunch: a fresh AppState over the same defaults.
        let (second, _) = AppState.makeTestState()

        XCTAssertTrue(second.postProcessEnabled)
        XCTAssertEqual(second.postProcessBaseURL, "http://127.0.0.1:5555")
    }

    // MARK: - Restore default

    func testRestoreDefaultPromptReturnsTheDocumentedPrompt() {
        let (appState, _) = AppState.makeTestState()
        appState.postProcessSystemPrompt = "something I typed"
        XCTAssertNotEqual(appState.postProcessSystemPrompt, Prompts.cleanTranscriptSystemPrompt)

        // What the tab's "Restore Default" button does.
        appState.postProcessSystemPrompt = Prompts.cleanTranscriptSystemPrompt

        XCTAssertEqual(appState.postProcessSystemPrompt, Prompts.cleanTranscriptSystemPrompt)
        XCTAssertEqual(PostProcessSettings.current().systemPrompt, Prompts.cleanTranscriptSystemPrompt)
    }

    // MARK: - Key convention

    func testAppStateKeysAreTheKeysTheStageReads() {
        let (appState, _) = AppState.makeTestState()
        appState.postProcessModel = "written through AppState"

        XCTAssertEqual(
            UserDefaults.standard.string(forKey: PostProcessSettings.Key.model),
            "written through AppState",
            "The tab and the stage must not drift onto different keys"
        )
    }
}
