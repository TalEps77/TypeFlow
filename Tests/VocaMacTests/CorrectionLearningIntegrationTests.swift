// CorrectionLearningIntegrationTests.swift
// VocaMac Tests
//
// Story 5.6: the AppState seam — `stopRecordingAndTranscribe` calls
// `correctionLearner.observeInjection` with the injected text only when the
// (off-by-default) toggle is on, and `confirmCorrectionCandidate`/
// `dismissCorrectionCandidate` do the right thing with the Dictionary and
// the dismissed-pairs store while clearing the pending list.

import XCTest
@testable import VocaMac

@MainActor
final class CorrectionLearningIntegrationTests: XCTestCase {

    // MINOR 8-style precaution (see PostProcessStageTests): these tests
    // write `appState.correctionLearningEnabled`, which is backed by
    // VocaDefaults.store directly (AD-9) — save/restore so a mutation
    // here can't bleed into a different test file's assumptions about the
    // default.
    private var previousEnabledValue: Any?

    override func setUp() {
        super.setUp()
        previousEnabledValue = VocaDefaults.store.object(forKey: CorrectionLearningSettings.Key.enabled)
        VocaDefaults.store.removeObject(forKey: CorrectionLearningSettings.Key.enabled)
    }

    override func tearDown() {
        if let previousEnabledValue {
            VocaDefaults.store.set(previousEnabledValue, forKey: CorrectionLearningSettings.Key.enabled)
        } else {
            VocaDefaults.store.removeObject(forKey: CorrectionLearningSettings.Key.enabled)
        }
        super.tearDown()
    }

    private func makeStateThatTranscribes(_ text: String) -> (AppState, TestMocks) {
        let (appState, mocks) = AppState.makeTestState()
        appState.isRecording = true
        appState.appStatus = .recording
        mocks.audioEngine.stopRecordingResult = [0.1, 0.2, 0.3]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: text,
            duration: 1.0,
            detectedLanguage: "he",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny
        )
        return (appState, mocks)
    }

    // MARK: - Off by default (Story 5.6 AC)

    func testCorrectionLearningIsOffByDefault() {
        let (appState, _) = AppState.makeTestState()
        XCTAssertFalse(appState.correctionLearningEnabled)
    }

    func testDisabledLearningNeverObservesAnInjection() async {
        let (appState, mocks) = makeStateThatTranscribes("שלום עולם")
        appState.correctionLearningEnabled = false

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.correctionLearner.observeInjectionCallCount, 0)
    }

    // MARK: - Enabled: observes exactly the injected text

    func testEnabledLearningObservesTheInjectedText() async {
        let (appState, mocks) = makeStateThatTranscribes("שלום עולם")
        appState.correctionLearningEnabled = true

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.correctionLearner.observeInjectionCallCount, 1)
        XCTAssertEqual(mocks.correctionLearner.lastText, "שלום עולם")
    }

    func testNothingInjectedMeansNothingObserved() async {
        let (appState, mocks) = makeStateThatTranscribes("שלום עולם")
        appState.correctionLearningEnabled = true
        mocks.transcriptPipeline.transform = { _ in "" }

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.correctionLearner.observeInjectionCallCount, 0)
    }

    // MARK: - Confirm (Story 5.6 AC: proposed for confirmation, never silent)

    func testConfirmingACandidateAddsALearnedDictionaryEntry() {
        let (appState, _) = AppState.makeTestState()
        let candidate = CorrectionCandidate(original: "Kuberentes", corrected: "Kubernetes")
        appState.pendingCorrectionCandidates = [candidate]

        appState.confirmCorrectionCandidate(candidate)

        let added = appState.dictionaryStore.entries.first
        XCTAssertEqual(added?.canonicalForm, "Kubernetes")
        XCTAssertEqual(added?.triggers, ["Kuberentes"])
        XCTAssertTrue(added?.learned ?? false)
        XCTAssertTrue(appState.pendingCorrectionCandidates.isEmpty)
    }

    // MARK: - Dismiss (Story 5.6 AC: dismissed pairs are not proposed again)

    func testDismissingACandidateRecordsItAndClearsPending() {
        let (appState, _) = AppState.makeTestState()
        let candidate = CorrectionCandidate(original: "Kuberentes", corrected: "Kubernetes")
        appState.pendingCorrectionCandidates = [candidate]

        appState.dismissCorrectionCandidate(candidate)

        XCTAssertTrue(appState.dismissedCorrectionsStore.isDismissed(candidate))
        XCTAssertTrue(appState.pendingCorrectionCandidates.isEmpty)
        XCTAssertTrue(appState.dictionaryStore.entries.isEmpty, "dismissing must never add a Dictionary Entry")
    }
}
