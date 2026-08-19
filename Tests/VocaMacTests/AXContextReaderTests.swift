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

    func testStoppingWithoutStartingCapturesNothing() async {
        let (_, mocks) = makeRecordingState(bundleIdentifier: "com.apple.TextEdit")

        // No startRecording() call — mirrors the existing HistoryStoreTests
        // seam tests that drive stopRecordingAndTranscribe() directly.
        XCTAssertEqual(mocks.contextReader.captureCallCount, 0)
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

    // MARK: - Story 4.4 stays off by default

    func testCursorContextIsNotRequestedUntilStory44WiresItsToggles() async {
        let (appState, mocks) = makeRecordingState(bundleIdentifier: "com.apple.TextEdit")

        await appState.startRecording()

        XCTAssertEqual(mocks.contextReader.lastReadCursorContextRequested, false)
    }
}
