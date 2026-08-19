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

    // MARK: - Nothing readable on disk (MAJOR 9)

    func testTheDismissedWordsAreNotWrittenToDiskInTheClear() throws {
        let fileStore = JSONFileStore<[DismissedCorrection]>(fileName: "dismissed-corrections.json", defaultValue: [], directoryURL: tempDirectory)
        let store = DismissedCorrectionsStore(store: fileStore)
        // The `corrected` half is a word read out of the user's own focused
        // text field. It must not end up in a plaintext file.
        store.dismiss(CorrectionCandidate(original: "Kuberentes", corrected: "Nightingale"))
        fileStore.flush()

        let contents = try String(contentsOf: tempDirectory.appendingPathComponent("dismissed-corrections.json"), encoding: .utf8)

        XCTAssertFalse(contents.contains("Nightingale"))
        XCTAssertFalse(contents.contains("Kuberentes"))
        XCTAssertTrue(contents.contains("fingerprint"))
    }

    func testALegacyReadablePairStillCountsAsDismissedAndIsRewrittenAsAHash() throws {
        // A `dismissed-corrections.json` written before this fix.
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let url = tempDirectory.appendingPathComponent("dismissed-corrections.json")
        try #"[{"original":"Kuberentes","corrected":"Kubernetes"}]"#.write(to: url, atomically: true, encoding: .utf8)

        let fileStore = JSONFileStore<[DismissedCorrection]>(fileName: "dismissed-corrections.json", defaultValue: [], directoryURL: tempDirectory)
        let store = DismissedCorrectionsStore(store: fileStore)

        XCTAssertTrue(store.isDismissed(CorrectionCandidate(original: "Kuberentes", corrected: "Kubernetes")),
                       "an existing dismissal must survive the change of storage format")

        // And the readable copy is gone the next time the file is written.
        store.dismiss(CorrectionCandidate(original: "helo", corrected: "hello"))
        fileStore.flush()
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(contents.contains("Kuberentes"))
    }

    func testTheListIsCapped() {
        let store = makeStore()
        for index in 0..<(DismissedCorrectionsStore.maximumDismissals + 25) {
            store.dismiss(CorrectionCandidate(original: "original\(index)", corrected: "corrected\(index)"))
        }

        XCTAssertEqual(store.dismissed.count, DismissedCorrectionsStore.maximumDismissals)
        // The oldest fell off; the newest is still there.
        XCTAssertFalse(store.isDismissed(CorrectionCandidate(original: "original0", corrected: "corrected0")))
        XCTAssertTrue(store.isDismissed(CorrectionCandidate(original: "original500", corrected: "corrected500")))
    }

    func testClearForgetsEverything() {
        let store = makeStore()
        let candidate = CorrectionCandidate(original: "Kuberentes", corrected: "Kubernetes")
        store.dismiss(candidate)

        store.clear()

        XCTAssertTrue(store.dismissed.isEmpty)
        XCTAssertFalse(store.isDismissed(candidate))
    }
}
