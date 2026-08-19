// DictionaryStageTests.swift
// VocaMac Tests
//
// Story 5.2: the stage's own gates (disabled, empty Dictionary, nothing to
// correct) all degrade to identity (AD-2); an applied replacement is
// reported as such; a no-op replacement is reported as skipped, not applied.

import XCTest
@testable import VocaMac

@MainActor
final class DictionaryStageTests: XCTestCase {

    private func makeStage(
        service: MockDictionaryService,
        entries: [DictionaryEntry],
        isEnabled: Bool = true
    ) -> DictionaryStage {
        DictionaryStage(
            service: service,
            entriesProvider: { entries },
            settingsProvider: { DictionarySettings(isEnabled: isEnabled) }
        )
    }

    // MARK: - Success

    func testReplacedTextIsApplied() async {
        let service = MockDictionaryService()
        service.replaceResult = DictionaryReplacementResult(text: "Kubernetes here", replacementCount: 1)
        let entry = DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קוברנטיס"])
        let stage = makeStage(service: service, entries: [entry])

        let result = await stage.run(TranscriptContext(rawTranscript: "קוברנטיס here"))

        XCTAssertEqual(result.text, "Kubernetes here")
        XCTAssertEqual(result.outcome, .applied)
        XCTAssertEqual(service.lastText, "קוברנטיס here")
        XCTAssertEqual(service.lastEntries?.count, 1)
    }

    func testStageSeesTheTextTheStageBeforeItProduced() async {
        let service = MockDictionaryService()
        let entry = DictionaryEntry(canonicalForm: "X", triggers: ["y"])
        let stage = makeStage(service: service, entries: [entry])
        var context = TranscriptContext(rawTranscript: "raw")
        context.currentText = "text from an earlier stage"

        _ = await stage.run(context)

        XCTAssertEqual(service.lastText, "text from an earlier stage")
    }

    func testUnchangedOutputIsReportedAsSkippedRatherThanApplied() async {
        let service = MockDictionaryService()
        service.replaceResult = DictionaryReplacementResult(text: "שלום עולם", replacementCount: 0)
        let entry = DictionaryEntry(canonicalForm: "X", triggers: ["y"])
        let stage = makeStage(service: service, entries: [entry])

        let result = await stage.run(TranscriptContext(rawTranscript: "שלום עולם"))

        XCTAssertEqual(result.text, "שלום עולם")
        XCTAssertEqual(result.outcome, .skipped(reason: "no matches"))
    }

    // MARK: - The master toggle

    func testDisabledStageMakesNoCallAtAll() async {
        let service = MockDictionaryService()
        let entry = DictionaryEntry(canonicalForm: "X", triggers: ["y"])
        let stage = makeStage(service: service, entries: [entry], isEnabled: false)

        let result = await stage.run(TranscriptContext(rawTranscript: "שלום עולם"))

        XCTAssertEqual(service.replaceCallCount, 0)
        XCTAssertEqual(result.text, "שלום עולם")
        XCTAssertEqual(result.outcome, .skipped(reason: "dictionary disabled"))
        XCTAssertFalse(result.didRun)
    }

    // MARK: - Empty dictionary (AD-2)

    func testEmptyDictionaryMakesNoCallAtAll() async {
        let service = MockDictionaryService()
        let stage = makeStage(service: service, entries: [])

        let result = await stage.run(TranscriptContext(rawTranscript: "שלום עולם"))

        XCTAssertEqual(service.replaceCallCount, 0)
        XCTAssertEqual(result.text, "שלום עולם")
        XCTAssertEqual(result.outcome, .skipped(reason: "dictionary is empty"))
        XCTAssertFalse(result.didRun)
    }

    // MARK: - Nothing to correct

    func testBlankTextMakesNoCallAtAll() async {
        let service = MockDictionaryService()
        let entry = DictionaryEntry(canonicalForm: "X", triggers: ["y"])
        let stage = makeStage(service: service, entries: [entry])

        let result = await stage.run(TranscriptContext(rawTranscript: "   "))

        XCTAssertEqual(service.replaceCallCount, 0)
        XCTAssertEqual(result.outcome, .skipped(reason: "nothing to correct"))
        XCTAssertFalse(result.didRun)
    }

    // MARK: - Identity across the corpus (AD-13-style check for this stage alone)

    func testDisabledStageIsIdentityAcrossTheCorpus() async {
        let service = MockDictionaryService()
        service.replaceResult = DictionaryReplacementResult(text: "THIS MUST NEVER APPEAR", replacementCount: 1)
        let entry = DictionaryEntry(canonicalForm: "X", triggers: ["y"])
        let stage = makeStage(service: service, entries: [entry], isEnabled: false)
        let pipeline = TranscriptPipeline(stages: [stage])

        let corpus = ["שָׁלוֹם עוֹלָם", "Hello Kubernetes", "", "   ", "מחשב ניידMacBook"]
        for input in corpus {
            let result = await pipeline.run(TranscriptContext(rawTranscript: input))
            XCTAssertEqual(result.currentText, input)
            XCTAssertTrue(result.isUnchanged)
        }
    }
}
