// AXContextReaderTests.swift
// VocaMac Tests
//
// Story 4.1: the frontmost application is captured once, at the moment
// recording starts (AD-5) — never re-read at recording stop, and never left
// captured after the pipeline run that consumes it.

import XCTest
@testable import VocaMac

@MainActor
final class AXContextReaderTests: XCTestCase {

    private func makeRecordingState(bundleIdentifier: String?) -> (AppState, TestMocks) {
        let (appState, mocks) = AppState.makeTestState()
        mocks.contextReader.captureResult = CapturedContext(
            bundleIdentifier: bundleIdentifier,
            cursorContextBefore: nil,
            cursorContextAfter: nil
        )
        mocks.audioEngine.stopRecordingResult = [0.1, 0.2, 0.3]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "שלום עולם",
            duration: 1.0,
            detectedLanguage: "he",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny
        )
        return (appState, mocks)
    }

    // MARK: - Capture happens exactly once, at start

    func testStartRecordingCapturesContextExactlyOnce() async {
        let (appState, mocks) = makeRecordingState(bundleIdentifier: "com.apple.TextEdit")

        await appState.startRecording()

        XCTAssertEqual(mocks.contextReader.captureCallCount, 1)
    }

    /// AD-5: capture happens at recording *start* and nowhere else. The
    /// original version of this test never called `stopRecordingAndTranscribe`
    /// at all, so it asserted only that constructing an AppState does not
    /// capture — true by inspection, and green no matter what stop did
    /// (MINOR 11). It now actually drives the stop path.
    func testStoppingWithoutHavingStartedNeverCaptures() async {
        let (appState, mocks) = makeRecordingState(bundleIdentifier: "com.apple.TextEdit")

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.contextReader.captureCallCount, 0, "capture belongs to recording start, never to stop")
        XCTAssertEqual(mocks.historyStore.recordCallCount, 0, "a stop with no recording behind it records nothing")
    }

    /// MINOR 9: the hotkey can be pressed while VocaMac's own settings or
    /// History window is frontmost. Resolving a Profile for *us* — and
    /// AX-reading our own text fields — is never what the user meant, so the
    /// last non-self frontmost application is offered as the target instead.
    func testTheLastNonSelfFrontmostApplicationIsOfferedAsTheCaptureTarget() async {
        let (appState, mocks) = makeRecordingState(bundleIdentifier: "com.apple.TextEdit")

        await appState.startRecording()

        XCTAssertEqual(
            mocks.contextReader.lastFallbackApplication?.processIdentifier,
            appState.lastNonSelfFrontmostApp?.processIdentifier
        )
    }

    // MARK: - The captured bundle identifier reaches the History Record

    func testCapturedBundleIdentifierIsPersistedToHistory() async {
        let (appState, mocks) = makeRecordingState(bundleIdentifier: "com.apple.TextEdit")

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.historyStore.lastRecordedRecord?.targetBundleId, "com.apple.TextEdit")
    }

    // MARK: - The nil path (AC: "no frontmost application can be determined")

    func testNilBundleIdentifierProceedsNormally() async {
        let (appState, mocks) = makeRecordingState(bundleIdentifier: nil)

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.historyStore.recordCallCount, 1, "A nil target app must not stop the dictation from being recorded")
        XCTAssertNil(mocks.historyStore.lastRecordedRecord?.targetBundleId)
    }

    // MARK: - Capture-at-start semantics: a mid-dictation app switch must not matter

    func testAppSwitchAfterRecordingStartedDoesNotChangeTheCapturedIdentifier() async {
        let (appState, mocks) = makeRecordingState(bundleIdentifier: "com.apple.TextEdit")

        await appState.startRecording()

        // The user switches to another application while still dictating.
        // A real AXContextReader would answer differently now, but AppState
        // must not call it again — it already has what it captured at start.
        mocks.contextReader.captureResult = CapturedContext(
            bundleIdentifier: "com.apple.Safari",
            cursorContextBefore: nil,
            cursorContextAfter: nil
        )

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.contextReader.captureCallCount, 1, "capture() must not be called again at stop time")
        XCTAssertEqual(mocks.historyStore.lastRecordedRecord?.targetBundleId, "com.apple.TextEdit")
    }

    // MARK: - Story 4.4: both the global and Profile toggles are required

    func testCursorContextStaysOffByDefault() async {
        let (appState, mocks) = makeRecordingState(bundleIdentifier: "com.apple.TextEdit")
        // appState.contextCaptureEnabled and Profile.makeDefault().contextCaptureEnabled
        // both default false/off — nothing overridden here.

        await appState.startRecording()

        XCTAssertEqual(mocks.contextReader.lastShouldReadCursorContextAnswer, false)
    }

    func testCursorContextTurnsOnOnlyWhenBothGlobalAndProfileToggleAreOn() async {
        defer { VocaDefaults.store.removeObject(forKey: "vocamac.contextCapture.enabled") }
        let (appState, mocks) = makeRecordingState(bundleIdentifier: "com.apple.TextEdit")
        appState.contextCaptureEnabled = true
        mocks.profileManager.resolvedProfile = Profile(name: "Editor", contextCaptureEnabled: true)

        await appState.startRecording()

        XCTAssertEqual(mocks.contextReader.lastShouldReadCursorContextAnswer, true)
    }

    func testCursorContextStaysOffWhenOnlyTheGlobalToggleIsOn() async {
        defer { VocaDefaults.store.removeObject(forKey: "vocamac.contextCapture.enabled") }
        let (appState, mocks) = makeRecordingState(bundleIdentifier: "com.apple.TextEdit")
        appState.contextCaptureEnabled = true
        mocks.profileManager.resolvedProfile = Profile(name: "Editor", contextCaptureEnabled: false)

        await appState.startRecording()

        XCTAssertEqual(mocks.contextReader.lastShouldReadCursorContextAnswer, false)
    }

    func testCursorContextStaysOffWhenOnlyTheProfileToggleIsOn() async {
        let (appState, mocks) = makeRecordingState(bundleIdentifier: "com.apple.TextEdit")
        // Global toggle left at its default (off).
        mocks.profileManager.resolvedProfile = Profile(name: "Editor", contextCaptureEnabled: true)

        await appState.startRecording()

        XCTAssertEqual(mocks.contextReader.lastShouldReadCursorContextAnswer, false)
    }

    // MARK: - Story 4.4: captured Cursor Context reaches the LLM request

    func testCapturedCursorContextReachesThePostProcessRequest() async {
        defer { VocaDefaults.store.removeObject(forKey: "vocamac.contextCapture.enabled") }

        let postProcessService = MockPostProcessService()
        let stage = PostProcessStage(service: postProcessService, settingsProvider: {
            PostProcessSettings(isEnabled: true)
        })
        let pipeline = TranscriptPipeline(stages: [stage])
        let (appState, mocks) = AppState.makeTestState(transcriptPipelineOverride: pipeline)

        appState.contextCaptureEnabled = true
        mocks.profileManager.resolvedProfile = Profile(name: "Editor", contextCaptureEnabled: true)
        mocks.contextReader.captureResult = CapturedContext(
            bundleIdentifier: "com.apple.TextEdit",
            cursorContextBefore: "some text before the caret",
            cursorContextAfter: "some text after the caret"
        )
        mocks.audioEngine.stopRecordingResult = [0.1, 0.2, 0.3]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "שלום עולם",
            duration: 1.0,
            detectedLanguage: "he",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny
        )

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(postProcessService.lastContextBefore, "some text before the caret")
        XCTAssertEqual(postProcessService.lastContextAfter, "some text after the caret")
    }

    /// AD-5: once the stage that used Cursor Context has run, the pipeline
    /// itself must have dropped it — proven here by inspecting the
    /// `TranscriptContext` the mock pipeline stage actually saw versus what
    /// a *second*, no-op stage placed after it would see.
    func testCursorContextIsClearedFromTheContextAfterPostProcessRuns() async {
        defer { VocaDefaults.store.removeObject(forKey: "vocamac.contextCapture.enabled") }

        let postProcessService = MockPostProcessService()
        let postProcessStage = PostProcessStage(service: postProcessService, settingsProvider: {
            PostProcessSettings(isEnabled: true)
        })
        let observerStage = StubTranscriptStage(name: "Observer", result: .unchanged("שלום עולם", outcome: .skipped(reason: "just observing")))
        let pipeline = TranscriptPipeline(stages: [postProcessStage, observerStage])
        let (appState, mocks) = AppState.makeTestState(transcriptPipelineOverride: pipeline)

        appState.contextCaptureEnabled = true
        mocks.profileManager.resolvedProfile = Profile(name: "Editor", contextCaptureEnabled: true)
        mocks.contextReader.captureResult = CapturedContext(
            bundleIdentifier: "com.apple.TextEdit",
            cursorContextBefore: "before",
            cursorContextAfter: "after"
        )
        mocks.audioEngine.stopRecordingResult = [0.1, 0.2, 0.3]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "שלום עולם",
            duration: 1.0,
            detectedLanguage: "he",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny
        )

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        // PostProcessStage itself did see it (proven by the service call);
        // by the time the pipeline moved on to the next stage, the context
        // it carries must already be nil (AD-5) — `TranscriptPipeline`
        // clears it right after the PostProcess stage runs.
        XCTAssertEqual(postProcessService.lastContextBefore, "before")
        XCTAssertEqual(observerStage.runCallCount, 1)
        XCTAssertNil(observerStage.lastContext?.cursorContextBefore)
        XCTAssertNil(observerStage.lastContext?.cursorContextAfter)
    }

    // MARK: - Story 4.2: the resolved Profile is passed through and persisted

    func testProfileManagerIsCalledWithTheCapturedBundleIdentifier() async {
        let (appState, mocks) = makeRecordingState(bundleIdentifier: "com.apple.mail")

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.profileManager.lastBundleIdentifier, "com.apple.mail")
    }

    func testResolvedProfileNameIsPersistedToHistory() async {
        let (appState, mocks) = makeRecordingState(bundleIdentifier: "com.apple.mail")
        mocks.profileManager.resolvedProfile = Profile(name: "Mail", bundleIdentifiers: ["com.apple.mail"])

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.historyStore.lastRecordedRecord?.profileName, "Mail")
    }

    func testProfilesEnabledSettingIsPassedThroughToResolution() async {
        defer { VocaDefaults.store.removeObject(forKey: "vocamac.profiles.enabled") }
        let (appState, mocks) = makeRecordingState(bundleIdentifier: "com.apple.mail")
        appState.profilesEnabled = false

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.profileManager.lastProfilesEnabled, false)
    }
}
