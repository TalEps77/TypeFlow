// CorrectionLearnerTests.swift
// VocaMac Tests
//
// Story 5.6: CorrectionLearner's own orchestration — the disabled path does
// nothing at all, a detected candidate reaches `onCandidateProposed` exactly
// once, and a dismissed pair is never proposed again. `scheduleReRead` is
// overridden to run synchronously so these tests don't wait on a real timer.

import XCTest
@testable import VocaMac

@MainActor
final class CorrectionLearnerTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("correction_learner_test_\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeDismissedStore() -> DismissedCorrectionsStore {
        DismissedCorrectionsStore(store: JSONFileStore(fileName: "dismissed-corrections.json", defaultValue: [], directoryURL: tempDirectory))
    }

    private func makeLearner(
        contextReader: MockContextReader,
        dismissedStore: DismissedCorrectionsStore,
        isEnabled: Bool
    ) -> CorrectionLearner {
        CorrectionLearner(
            contextReader: contextReader,
            dismissedStore: dismissedStore,
            isEnabledProvider: { isEnabled },
            scheduleReRead: { workItem in workItem.perform() } // synchronous for tests
        )
    }

    /// A learner whose scheduled work item is captured rather than run, so a
    /// test can decide when — or whether — it fires.
    private func makeDeferredLearner(
        contextReader: MockContextReader,
        dismissedStore: DismissedCorrectionsStore,
        isEnabled: @escaping () -> Bool,
        scheduled: @escaping (DispatchWorkItem) -> Void
    ) -> CorrectionLearner {
        CorrectionLearner(
            contextReader: contextReader,
            dismissedStore: dismissedStore,
            isEnabledProvider: isEnabled,
            scheduleReRead: scheduled
        )
    }

    // MARK: - Disabled path (AD-2-style: off produces nothing)

    func testDisabledLearnerNeverReadsOrProposesAnything() {
        let contextReader = MockContextReader()
        contextReader.readFocusedElementTextResult = "please add Kubernetes here"
        let learner = makeLearner(contextReader: contextReader, dismissedStore: makeDismissedStore(), isEnabled: false)
        var proposed: CorrectionCandidate?
        learner.onCandidateProposed = { proposed = $0 }

        learner.observeInjection("please add Kuberentes here", targetProcessIdentifier: 42)

        XCTAssertEqual(contextReader.readFocusedElementTextCallCount, 0)
        XCTAssertNil(proposed)
    }

    func testEmptyInjectedTextProposesNothing() {
        let contextReader = MockContextReader()
        let learner = makeLearner(contextReader: contextReader, dismissedStore: makeDismissedStore(), isEnabled: true)
        var proposed: CorrectionCandidate?
        learner.onCandidateProposed = { proposed = $0 }

        learner.observeInjection("   ", targetProcessIdentifier: 42)

        XCTAssertEqual(contextReader.readFocusedElementTextCallCount, 0)
        XCTAssertNil(proposed)
    }

    // MARK: - Candidate detection

    func testASingleWordEditProposesExactlyOneCandidate() {
        let contextReader = MockContextReader()
        contextReader.readFocusedElementTextResult = "please add Kubernetes here"
        let learner = makeLearner(contextReader: contextReader, dismissedStore: makeDismissedStore(), isEnabled: true)
        var proposedCandidates: [CorrectionCandidate] = []
        learner.onCandidateProposed = { proposedCandidates.append($0) }

        learner.observeInjection("please add Kuberentes here", targetProcessIdentifier: 42)

        XCTAssertEqual(proposedCandidates, [CorrectionCandidate(original: "Kuberentes", corrected: "Kubernetes")])
        XCTAssertEqual(contextReader.lastReadProcessIdentifier, 42)
    }

    func testNoAXTextAvailableProposesNothing() {
        let contextReader = MockContextReader()
        contextReader.readFocusedElementTextResult = nil
        let learner = makeLearner(contextReader: contextReader, dismissedStore: makeDismissedStore(), isEnabled: true)
        var proposed: CorrectionCandidate?
        learner.onCandidateProposed = { proposed = $0 }

        learner.observeInjection("please add Kuberentes here", targetProcessIdentifier: 42)

        XCTAssertNil(proposed)
    }

    func testALargeDiffuseDifferenceProposesNothing() {
        let contextReader = MockContextReader()
        contextReader.readFocusedElementTextResult = "a completely different sentence entirely"
        let learner = makeLearner(contextReader: contextReader, dismissedStore: makeDismissedStore(), isEnabled: true)
        var proposed: CorrectionCandidate?
        learner.onCandidateProposed = { proposed = $0 }

        learner.observeInjection("please add Kuberentes here", targetProcessIdentifier: 42)

        XCTAssertNil(proposed)
    }

    // MARK: - Dismissal (Story 5.6 AC)

    func testADismissedPairIsNeverProposedAgain() {
        let contextReader = MockContextReader()
        contextReader.readFocusedElementTextResult = "please add Kubernetes here"
        let dismissedStore = makeDismissedStore()
        dismissedStore.dismiss(CorrectionCandidate(original: "Kuberentes", corrected: "Kubernetes"))
        let learner = makeLearner(contextReader: contextReader, dismissedStore: dismissedStore, isEnabled: true)
        var proposed: CorrectionCandidate?
        learner.onCandidateProposed = { proposed = $0 }

        learner.observeInjection("please add Kuberentes here", targetProcessIdentifier: 42)

        XCTAssertNil(proposed)
    }

    // MARK: - No target process, no read (BLOCKER 3)

    func testAnUnknownTargetProcessNeverReadsAnything() {
        // Without a process identifier there is nothing to anchor the read to,
        // and 1.5 seconds after an injection whatever holds focus may be an
        // entirely different application's field.
        let contextReader = MockContextReader()
        contextReader.readFocusedElementTextResult = "please add Kubernetes here"
        let learner = makeLearner(contextReader: contextReader, dismissedStore: makeDismissedStore(), isEnabled: true)
        var proposed: CorrectionCandidate?
        learner.onCandidateProposed = { proposed = $0 }

        learner.observeInjection("please add Kuberentes here", targetProcessIdentifier: nil)

        XCTAssertEqual(contextReader.readFocusedElementTextCallCount, 0)
        XCTAssertNil(proposed)
    }

    // MARK: - Cancellation and re-checking (MAJOR 8)

    func testCancellingBeforeTheReReadFiresPreventsIt() {
        let contextReader = MockContextReader()
        contextReader.readFocusedElementTextResult = "please add Kubernetes here"
        var scheduled: DispatchWorkItem?
        let learner = makeDeferredLearner(
            contextReader: contextReader,
            dismissedStore: makeDismissedStore(),
            isEnabled: { true },
            scheduled: { scheduled = $0 }
        )
        var proposed: CorrectionCandidate?
        learner.onCandidateProposed = { proposed = $0 }

        learner.observeInjection("please add Kuberentes here", targetProcessIdentifier: 42)
        learner.cancelPendingObservation()
        scheduled?.perform()

        XCTAssertTrue(scheduled?.isCancelled ?? false, "the work item itself must be cancelled, not merely skipped")
        XCTAssertEqual(contextReader.readFocusedElementTextCallCount, 0)
        XCTAssertNil(proposed)
    }

    func testANewerInjectionCancelsThePreviousPendingReRead() {
        let contextReader = MockContextReader()
        contextReader.readFocusedElementTextResult = "please add Kubernetes here"
        var scheduled: [DispatchWorkItem] = []
        let learner = makeDeferredLearner(
            contextReader: contextReader,
            dismissedStore: makeDismissedStore(),
            isEnabled: { true },
            scheduled: { scheduled.append($0) }
        )
        learner.onCandidateProposed = { _ in }

        learner.observeInjection("first dictation text", targetProcessIdentifier: 42)
        learner.observeInjection("please add Kuberentes here", targetProcessIdentifier: 42)

        XCTAssertEqual(scheduled.count, 2)
        XCTAssertTrue(scheduled[0].isCancelled, "the superseded re-read must not still be live")
        XCTAssertFalse(scheduled[1].isCancelled)
    }

    func testTurningTheToggleOffInsideTheDelayStopsTheRead() {
        let contextReader = MockContextReader()
        contextReader.readFocusedElementTextResult = "please add Kubernetes here"
        var isEnabled = true
        var scheduled: DispatchWorkItem?
        let learner = makeDeferredLearner(
            contextReader: contextReader,
            dismissedStore: makeDismissedStore(),
            isEnabled: { isEnabled },
            scheduled: { scheduled = $0 }
        )
        var proposed: CorrectionCandidate?
        learner.onCandidateProposed = { proposed = $0 }

        learner.observeInjection("please add Kuberentes here", targetProcessIdentifier: 42)
        isEnabled = false
        scheduled?.perform()

        XCTAssertEqual(contextReader.readFocusedElementTextCallCount, 0,
                        "a feature the user has just switched off must not perform one last read of their screen")
        XCTAssertNil(proposed)
    }
}
