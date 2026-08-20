// HistoryStoreTests.swift
// VocaMac Tests
//
// Covers Story 3.1 (FR-8): HistoryRecord encode/decode and the AD-5 privacy
// assertion, HistoryStore persistence/search/retention, and the AppState seam
// that writes a record after every completed dictation.

import XCTest
import Combine
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
        let keys: Set<String> = object.map { Set($0.keys) } ?? []

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
        VocaDefaults.store.removeObject(forKey: "vocamac.history.retentionLimit")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        VocaDefaults.store.removeObject(forKey: "vocamac.history.retentionLimit")
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
        fileStore.flush()

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

    /// MINOR 2: Hebrew is dictated here far more often than it is typed with
    /// niqqud, so an unpointed query has to reach pointed text. Plain
    /// case-insensitive matching treats the marks as distinct characters and
    /// finds nothing.
    func testSearchMatchesHebrewAcrossNiqqud() {
        let (store, _) = makeStore()
        store.record(HistoryRecord(rawTranscript: "שָׁלוֹם עוֹלָם", finalText: "שָׁלוֹם עוֹלָם.", modelName: "Tiny"))

        XCTAssertEqual(store.search("שלום").count, 1, "An unpointed query must find pointed text")
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

    /// MAJOR 1: every record() re-encodes and rewrites the whole file. An
    /// unlimited default makes that work grow without bound for the life of
    /// the install, which is a stall on the main actor right after the
    /// injection the user is watching for (NFR-4).
    func testDefaultRetentionLimitIsBounded() {
        let (store, _) = makeStore()

        XCTAssertGreaterThan(store.retentionLimit, 0,
                              "The default must be bounded; Unlimited stays available as an explicit choice")
        XCTAssertEqual(store.retentionLimit, 500)
    }

    /// MINOR 7: retention was only applied as new records arrived, so a file
    /// restored from backup — or written before the limit was lowered — stayed
    /// over the limit indefinitely.
    func testRetentionIsEnforcedOnLoadNotOnlyOnInsert() {
        let seeded = (1...5).map { index in
            record("item \(index)", at: Date(timeIntervalSince1970: TimeInterval(index)))
        }
        let writer = JSONFileStore<[HistoryRecord]>(fileName: "history.json", defaultValue: [], directoryURL: tempDirectory)
        writer.save(seeded)
        writer.flush()

        VocaDefaults.store.set(3, forKey: "vocamac.history.retentionLimit")

        let reader = JSONFileStore<[HistoryRecord]>(fileName: "history.json", defaultValue: [], directoryURL: tempDirectory)
        let restarted = HistoryStore(store: reader)

        XCTAssertEqual(restarted.records.map(\.rawTranscript), ["item 5", "item 4", "item 3"])
    }

    /// MINOR 1: the retention menu shows the current limit, so it has to
    /// re-render on every change — including the ones that trim nothing.
    func testChangingTheRetentionLimitAlwaysPublishes() {
        let (store, _) = makeStore()
        store.record(record("only one"))

        var publishCount = 0
        let cancellable = store.objectWillChangePublisher.sink { publishCount += 1 }

        // Raising the limit prunes nothing at all.
        store.retentionLimit = 900
        cancellable.cancel()

        XCTAssertGreaterThan(publishCount, 0, "A limit change that trims nothing must still publish")
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

    // MARK: - Per-stage latency (Story 1.3, FR-3)

    func testHistoryRecordCapturesRecordingAndASRDurations() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.isRecording = true
        appState.appStatus = .recording
        mocks.audioEngine.stopRecordingResult = [0.1, 0.2, 0.3]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "hello",
            duration: 0.42,
            detectedLanguage: "en",
            audioLengthSeconds: 3.5,
            modelUsed: .largeV3
        )

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.historyStore.lastRecordedRecord?.recordingMillis ?? .nan, 3500, accuracy: 0.01)
        XCTAssertEqual(mocks.historyStore.lastRecordedRecord?.asrMillis ?? .nan, 420, accuracy: 0.01)
    }

    func testHistoryRecordPostProcessMillisIsZeroWhenTheStageDidNotRun() async {
        // The identity mock pipeline (no `transform`, no `additionalReports`)
        // appends no "PostProcess" report at all — the stage did not run.
        let (appState, mocks) = makeStateThatTranscribes("שלום עולם")

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.historyStore.lastRecordedRecord?.postProcessMillis, 0)
    }

    /// MAJOR 6: the test above passed for the wrong reason — the mock pipeline
    /// simply never files a PostProcess report. The *real* pipeline files one
    /// for every stage it runs, including a disabled one, whose few
    /// microseconds then surfaced in the History detail as "Post-process 0ms".
    /// This drives `TranscriptPipeline.production()` for real.
    func testRealPipelineWithPostProcessingOffReportsNoPostProcessLatency() async {
        VocaDefaults.store.set(false, forKey: PostProcessSettings.Key.enabled)
        defer { VocaDefaults.store.removeObject(forKey: PostProcessSettings.Key.enabled) }

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
        let (appState, mocks) = AppState.makeTestState(
            transcriptPipelineOverride: TranscriptPipeline.production(dictionaryStore: dictionaryStore, snippetStore: snippetStore)
        )
        appState.isRecording = true
        appState.appStatus = .recording
        mocks.audioEngine.stopRecordingResult = [0.1, 0.2, 0.3]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "שלום עולם",
            duration: 1.0,
            detectedLanguage: "he",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny
        )

        await appState.stopRecordingAndTranscribe()

        let recorded = mocks.historyStore.lastRecordedRecord
        XCTAssertEqual(recorded?.finalText, "שלום עולם", "A disabled stage is an identity stage (AD-2)")
        XCTAssertEqual(recorded?.postProcessMillis, 0,
                        "A stage that declined before doing any work has no latency to report")
        XCTAssertFalse(recorded?.didFallback ?? true, "Declining is not failing")
    }

    /// MINOR 12: a dictation that produced words and then ended up with
    /// nothing to paste is exactly the one worth having a record of.
    func testHistoryIsRecordedEvenWhenThereIsNothingLeftToInject() async {
        let (appState, mocks) = makeStateThatTranscribes("שלום עולם")
        mocks.transcriptPipeline.transform = { _ in "" }

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.textInjector.injectCallCount, 0, "There is nothing to inject")
        XCTAssertEqual(mocks.historyStore.recordCallCount, 1, "…but the dictation must not vanish silently")
        XCTAssertEqual(mocks.historyStore.lastRecordedRecord?.rawTranscript, "שלום עולם")
    }

    func testHistoryRecordCapturesThePostProcessStagesOwnDuration() async {
        let (appState, mocks) = makeStateThatTranscribes("שלום עולם")
        mocks.transcriptPipeline.additionalReports = [
            StageReport(stageName: "PostProcess", outcome: .applied, duration: 0.25)
        ]

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.historyStore.lastRecordedRecord?.postProcessMillis ?? .nan, 250, accuracy: 0.01)
    }

    func testHistoryRecordDidFallbackIsTrueWhenAnyStageFailed() async {
        let (appState, mocks) = makeStateThatTranscribes("שלום עולם")
        mocks.transcriptPipeline.additionalReports = [
            StageReport(stageName: "PostProcess", outcome: .failed(reason: "connection refused"), duration: 0.1)
        ]

        await appState.stopRecordingAndTranscribe()

        XCTAssertTrue(mocks.historyStore.lastRecordedRecord?.didFallback ?? false)
    }
}

// MARK: - Re-paste (Story 3.3, FR-9)

@MainActor
final class AppStateRePasteTests: XCTestCase {

    func testRePasteInjectsTheGivenRecordsFinalText() {
        let (appState, mocks) = AppState.makeTestState()
        let record = HistoryRecord(rawTranscript: "raw", finalText: "final text", modelName: "Tiny")

        appState.rePaste(record)

        XCTAssertEqual(mocks.textInjector.injectCallCount, 1)
        XCTAssertEqual(mocks.textInjector.lastInjectedText, "final text")
    }

    func testRePasteDoesNotCreateANewHistoryRecord() {
        let (appState, mocks) = AppState.makeTestState()
        let record = HistoryRecord(rawTranscript: "raw", finalText: "final text", modelName: "Tiny")

        appState.rePaste(record)

        XCTAssertEqual(mocks.historyStore.recordCallCount, 0, "Re-paste must not duplicate the History Record")
    }

    func testRePastePassesThroughThePreserveClipboardSetting() {
        let (appState, mocks) = AppState.makeTestState()
        appState.preserveClipboard = false
        // preserveClipboard is @AppStorage-backed by the one process-wide
        // VocaDefaults scratch suite (no per-test isolation) — restore the
        // default so this doesn't leak `false` into a later test.
        defer { appState.preserveClipboard = true }
        let record = HistoryRecord(rawTranscript: "raw", finalText: "final", modelName: "Tiny")

        appState.rePaste(record)

        XCTAssertEqual(mocks.textInjector.lastPreserveClipboard, false)
    }

    func testRePasteMostRecentInjectsTheNewestRecord() {
        let (appState, mocks) = AppState.makeTestState()
        mocks.historyStore.records = [
            HistoryRecord(timestamp: Date(timeIntervalSince1970: 2), rawTranscript: "newer", finalText: "newer final", modelName: "Tiny"),
            HistoryRecord(timestamp: Date(timeIntervalSince1970: 1), rawTranscript: "older", finalText: "older final", modelName: "Tiny")
        ]

        appState.rePasteMostRecent()

        XCTAssertEqual(mocks.textInjector.lastInjectedText, "newer final",
                       "Records are newest-first, so the most recent is at index 0")
    }

    func testRePasteMostRecentDoesNothingWhenHistoryIsEmpty() {
        let (appState, mocks) = AppState.makeTestState()

        appState.rePasteMostRecent()

        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
    }

    // MARK: - Idle gate (MAJOR 7)
    //
    // "Re-paste Last" is a menu row the user can hit at any moment, including
    // mid-dictation. Doing so overlaps the live injection on the clipboard and
    // overwrites `lastInjection`, so a subsequent undo retracts the wrong text.

    func testRePasteIsIgnoredWhileRecording() {
        let (appState, mocks) = AppState.makeTestState()
        appState.appStatus = .recording

        appState.rePaste(HistoryRecord(rawTranscript: "raw", finalText: "final", modelName: "Tiny"))

        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
    }

    func testRePasteIsIgnoredWhileProcessing() {
        let (appState, mocks) = AppState.makeTestState()
        appState.appStatus = .processing

        appState.rePaste(HistoryRecord(rawTranscript: "raw", finalText: "final", modelName: "Tiny"))

        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
    }

    func testRePasteMostRecentIsAlsoGatedOnIdle() {
        let (appState, mocks) = AppState.makeTestState()
        mocks.historyStore.records = [
            HistoryRecord(rawTranscript: "newer", finalText: "newer final", modelName: "Tiny")
        ]
        appState.appStatus = .recording

        appState.rePasteMostRecent()

        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
    }

    func testRePasteResumesOnceIdleAgain() {
        let (appState, mocks) = AppState.makeTestState()
        let record = HistoryRecord(rawTranscript: "raw", finalText: "final", modelName: "Tiny")

        appState.appStatus = .recording
        appState.rePaste(record)
        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)

        appState.appStatus = .idle
        appState.rePaste(record)
        XCTAssertEqual(mocks.textInjector.injectCallCount, 1, "The gate must not be sticky")
    }
}
