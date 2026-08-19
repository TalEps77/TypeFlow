// HistoryStoreTests.swift
// VocaMac Tests
//
// Covers Story 3.1 (FR-8): HistoryRecord encode/decode and the AD-5 privacy
// assertion, HistoryStore persistence/search/retention, and the AppState seam
// that writes a record after every completed dictation.

import XCTest
@testable import VocaMac

// MARK: - HistoryRecord

final class HistoryRecordTests: XCTestCase {

    func testEncodeDecodeRoundTrips() throws {
        let record = HistoryRecord(
            rawTranscript: "שלום עולם",
            finalText: "שלום עולם.",
            targetBundleId: "com.apple.TextEdit",
            profileName: "Default",
            modelName: "Tiny",
            recordingMillis: 1200,
            asrMillis: 340,
            postProcessMillis: 90,
            didFallback: true,
            mode: .dictation
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(HistoryRecord.self, from: data)

        XCTAssertEqual(decoded, record)
    }

    func testDefaultsWhenOptionalFieldsAreOmitted() {
        let record = HistoryRecord(rawTranscript: "raw", finalText: "final", modelName: "Tiny")

        XCTAssertNil(record.targetBundleId)
        XCTAssertNil(record.profileName)
        XCTAssertEqual(record.recordingMillis, 0)
        XCTAssertEqual(record.asrMillis, 0)
        XCTAssertEqual(record.postProcessMillis, 0)
        XCTAssertFalse(record.didFallback)
        XCTAssertEqual(record.mode, .dictation)
    }

    /// AD-5, as a schema constraint: no field on HistoryRecord may hold Cursor
    /// Context, and a serialized record must carry no context payload at all.
    func testSerializedRecordContainsNoContextPayload() throws {
        let record = HistoryRecord(
            rawTranscript: "raw",
            finalText: "final",
            targetBundleId: "com.apple.TextEdit",
            profileName: "Default",
            modelName: "Tiny"
        )

        let data = try JSONEncoder().encode(record)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = Set(object?.keys ?? [])

        let expectedKeys: Set<String> = [
            "id", "timestamp", "rawTranscript", "finalText", "targetBundleId",
            "profileName", "modelName", "recordingMillis", "asrMillis",
            "postProcessMillis", "didFallback", "mode"
        ]
        XCTAssertEqual(keys, expectedKeys, "HistoryRecord must not gain undocumented fields")

        for key in keys {
            XCTAssertFalse(key.localizedCaseInsensitiveContains("context"),
                            "No key on HistoryRecord may reference Cursor Context (AD-5)")
        }

        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(json.localizedCaseInsensitiveContains("context"))
    }

    func testPreviewCollapsesNewlines() {
        let record = HistoryRecord(rawTranscript: "raw", finalText: "  line one\nline two  ", modelName: "Tiny")
        XCTAssertEqual(record.preview, "line one line two")
    }
}

// MARK: - HistoryStore

@MainActor
final class HistoryStoreTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("history_store_test_\(UUID().uuidString)", isDirectory: true)
        UserDefaults.standard.removeObject(forKey: "vocamac.history.retentionLimit")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        UserDefaults.standard.removeObject(forKey: "vocamac.history.retentionLimit")
        super.tearDown()
    }

    private func makeStore() -> (HistoryStore, JSONFileStore<[HistoryRecord]>) {
        let fileStore = JSONFileStore<[HistoryRecord]>(fileName: "history.json", defaultValue: [], directoryURL: tempDirectory)
        return (HistoryStore(store: fileStore), fileStore)
    }

    private func record(_ text: String, at date: Date = Date()) -> HistoryRecord {
        HistoryRecord(timestamp: date, rawTranscript: text, finalText: text, modelName: "Tiny")
    }

    func testStartsEmpty() {
        let (store, _) = makeStore()
        XCTAssertTrue(store.records.isEmpty)
    }

    func testRecordInsertsNewestFirst() {
        let (store, _) = makeStore()
        let first = record("one", at: Date(timeIntervalSince1970: 1))
        let second = record("two", at: Date(timeIntervalSince1970: 2))

        store.record(first)
        store.record(second)

        XCTAssertEqual(store.records.map(\.rawTranscript), ["two", "one"])
    }

    func testRecordsSurviveAFreshInstanceAtTheSameFile() {
        let fileStore = JSONFileStore<[HistoryRecord]>(fileName: "history.json", defaultValue: [], directoryURL: tempDirectory)
        let first = HistoryStore(store: fileStore)

        first.record(record("dictation one"))
        first.record(record("dictation two"))
        first.record(record("dictation three"))
        fileStore.synchronizeForTesting()

        // Simulate "quit and relaunch": a brand new HistoryStore reading the
        // same underlying file.
        let restartedFileStore = JSONFileStore<[HistoryRecord]>(fileName: "history.json", defaultValue: [], directoryURL: tempDirectory)
        let relaunched = HistoryStore(store: restartedFileStore)

        XCTAssertEqual(relaunched.records.count, 3)
        XCTAssertEqual(Set(relaunched.records.map(\.rawTranscript)),
                        Set(["dictation one", "dictation two", "dictation three"]))
    }

    func testDeleteRemovesOnlyTheMatchingRecord() {
        let (store, _) = makeStore()
        let keep = record("keep me")
        let remove = record("remove me")
        store.record(keep)
        store.record(remove)

        store.delete(remove.id)

        XCTAssertEqual(store.records.map(\.id), [keep.id])
    }

    func testDeleteAllClearsEverything() {
        let (store, _) = makeStore()
        store.record(record("one"))
        store.record(record("two"))

        store.deleteAll()

        XCTAssertTrue(store.records.isEmpty)
    }

    // MARK: - Search

    func testSearchFiltersByRawOrFinalText() {
        let (store, _) = makeStore()
        store.record(HistoryRecord(rawTranscript: "call the plumber", finalText: "Call the plumber.", modelName: "Tiny"))
        store.record(HistoryRecord(rawTranscript: "buy groceries", finalText: "Buy groceries.", modelName: "Tiny"))

        let results = store.search("plumber")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.rawTranscript, "call the plumber")
    }

    func testSearchIsCaseInsensitive() {
        let (store, _) = makeStore()
        store.record(HistoryRecord(rawTranscript: "Hello World", finalText: "Hello World.", modelName: "Tiny"))

        XCTAssertEqual(store.search("hello world").count, 1)
        XCTAssertEqual(store.search("HELLO WORLD").count, 1)
    }

    func testSearchSupportsHebrewQueries() {
        let (store, _) = makeStore()
        store.record(HistoryRecord(rawTranscript: "נפגש מחר בבוקר", finalText: "נפגש מחר בבוקר.", modelName: "Tiny"))
        store.record(HistoryRecord(rawTranscript: "קניתי חלב", finalText: "קניתי חלב.", modelName: "Tiny"))

        let results = store.search("מחר")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.rawTranscript, "נפגש מחר בבוקר")
    }

    func testEmptyQueryReturnsEverything() {
        let (store, _) = makeStore()
        store.record(record("one"))
        store.record(record("two"))

        XCTAssertEqual(store.search("   ").count, 2)
    }

    // MARK: - Retention

    func testRetentionLimitPrunesOldestRecordsAsNewOnesArrive() {
        let (store, _) = makeStore()
        store.retentionLimit = 2

        store.record(record("first", at: Date(timeIntervalSince1970: 1)))
        store.record(record("second", at: Date(timeIntervalSince1970: 2)))
        store.record(record("third", at: Date(timeIntervalSince1970: 3)))

        XCTAssertEqual(store.records.count, 2)
        // Newest-first insertion means the oldest ("first") is the one pruned.
        XCTAssertEqual(store.records.map(\.rawTranscript), ["third", "second"])
    }

    func testRetentionLimitExactlyAtBoundaryDoesNotPrune() {
        let (store, _) = makeStore()
        store.retentionLimit = 3

        store.record(record("first", at: Date(timeIntervalSince1970: 1)))
        store.record(record("second", at: Date(timeIntervalSince1970: 2)))
        store.record(record("third", at: Date(timeIntervalSince1970: 3)))

        XCTAssertEqual(store.records.count, 3, "Exactly at the limit must not prune")
    }

    func testZeroRetentionLimitMeansUnlimited() {
        let (store, _) = makeStore()
        store.retentionLimit = 0

        for i in 0..<10 {
            store.record(record("item \(i)"))
        }

        XCTAssertEqual(store.records.count, 10)
    }

    func testLoweringRetentionLimitTrimsExistingRecords() {
        let (store, _) = makeStore()
        store.record(record("first", at: Date(timeIntervalSince1970: 1)))
        store.record(record("second", at: Date(timeIntervalSince1970: 2)))
        store.record(record("third", at: Date(timeIntervalSince1970: 3)))
        XCTAssertEqual(store.records.count, 3)

        store.retentionLimit = 1

        XCTAssertEqual(store.records.map(\.rawTranscript), ["third"])
    }
}

// MARK: - AppState seam

@MainActor
final class AppStateHistoryTests: XCTestCase {

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

    func testCompletedDictationWritesOneHistoryRecord() async {
        let (appState, mocks) = makeStateThatTranscribes("שלום עולם")

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.historyStore.recordCallCount, 1)
        XCTAssertEqual(mocks.historyStore.lastRecordedRecord?.rawTranscript, "שלום עולם")
        XCTAssertEqual(mocks.historyStore.lastRecordedRecord?.finalText, "שלום עולם")
        XCTAssertEqual(mocks.historyStore.lastRecordedRecord?.modelName, ModelSize.tiny.displayName)
        XCTAssertFalse(mocks.historyStore.lastRecordedRecord?.didFallback ?? true)
    }

    func testHistoryRecordCapturesThePipelineOutputNotTheRawTranscript() async {
        let (appState, mocks) = makeStateThatTranscribes("נפגש בשתיים בעצם בשלוש")
        mocks.transcriptPipeline.transform = { _ in "נפגש בשלוש." }

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.historyStore.lastRecordedRecord?.rawTranscript, "נפגש בשתיים בעצם בשלוש")
        XCTAssertEqual(mocks.historyStore.lastRecordedRecord?.finalText, "נפגש בשלוש.")
    }

    func testEmptyTranscriptWritesNoHistoryRecord() async {
        let (appState, mocks) = makeStateThatTranscribes("   ")

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.historyStore.recordCallCount, 0)
    }
}
