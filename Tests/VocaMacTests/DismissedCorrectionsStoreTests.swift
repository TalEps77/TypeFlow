// DismissedCorrectionsStoreTests.swift
// VocaMac Tests
//
// Story 5.6 AC: "if I dismiss a candidate... the same pair is not proposed
// again" — persisted across a restart, and tolerant of the same
// niqqud/case variance every other match in this epic is.

import XCTest
@testable import VocaMac

@MainActor
final class DismissedCorrectionsStoreTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dismissed_corrections_test_\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeStore() -> DismissedCorrectionsStore {
        DismissedCorrectionsStore(store: JSONFileStore(fileName: "dismissed-corrections.json", defaultValue: [], directoryURL: tempDirectory))
    }

    func testFreshInstallHasNoDismissals() {
        XCTAssertTrue(makeStore().dismissed.isEmpty)
    }

    func testDismissRecordsThePair() {
        let store = makeStore()
        let candidate = CorrectionCandidate(original: "Kuberentes", corrected: "Kubernetes")

        store.dismiss(candidate)

        XCTAssertTrue(store.isDismissed(candidate))
    }

    func testDismissingTwiceDoesNotDuplicate() {
        let store = makeStore()
        let candidate = CorrectionCandidate(original: "Kuberentes", corrected: "Kubernetes")

        store.dismiss(candidate)
        store.dismiss(candidate)

        XCTAssertEqual(store.dismissed.count, 1)
    }

    func testAnUndismissedPairIsNotDismissed() {
        let store = makeStore()
        store.dismiss(CorrectionCandidate(original: "Kuberentes", corrected: "Kubernetes"))

        XCTAssertFalse(store.isDismissed(CorrectionCandidate(original: "helo", corrected: "hello")))
    }

    func testIsDismissedIsNormalizationAndCaseTolerant() {
        let store = makeStore()
        store.dismiss(CorrectionCandidate(original: "בקוברנטיס", corrected: "בקוברנטס"))

        // Same words, fully pointed and different case-folding for the
        // Latin comparison path.
        XCTAssertTrue(store.isDismissed(CorrectionCandidate(original: "בְּקוברנטיס", corrected: "בקוברנטס")))
    }

    func testDismissalsPersistAcrossAFreshInstanceAtTheSameFile() {
        let fileStore = JSONFileStore<[DismissedCorrection]>(fileName: "dismissed-corrections.json", defaultValue: [], directoryURL: tempDirectory)
        let first = DismissedCorrectionsStore(store: fileStore)
        let candidate = CorrectionCandidate(original: "Kuberentes", corrected: "Kubernetes")
        first.dismiss(candidate)
        fileStore.flush()

        let restartedFileStore = JSONFileStore<[DismissedCorrection]>(fileName: "dismissed-corrections.json", defaultValue: [], directoryURL: tempDirectory)
        let second = DismissedCorrectionsStore(store: restartedFileStore)

        XCTAssertTrue(second.isDismissed(candidate))
    }
}
