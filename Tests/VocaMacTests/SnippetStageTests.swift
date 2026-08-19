// SnippetStageTests.swift
// VocaMac Tests
//
// Story 5.4: the stage's own gates (disabled, no Snippets, nothing to
// expand) all degrade to identity (AD-2); an applied protection is reported
// as such and carries its placeholder mapping; a no-match pass is reported
// as skipped, not applied.

import XCTest
@testable import VocaMac

@MainActor
final class SnippetStageTests: XCTestCase {

    private func makeStage(
        service: MockSnippetService,
        snippets: [Snippet],
        isEnabled: Bool = true
    ) -> SnippetStage {
        SnippetStage(
            service: service,
            snippetsProvider: { snippets },
            settingsProvider: { SnippetSettings(isEnabled: isEnabled) }
        )
    }

    // MARK: - Success

    func testProtectedTextIsAppliedWithItsSpans() async {
        let service = MockSnippetService()
        service.protectResult = SnippetProtectionResult(text: "hello ⟦S0⟧", protectedSpans: ["⟦S0⟧": "SIG"])
        let snippet = Snippet(cue: "signature", body: "SIG")
        let stage = makeStage(service: service, snippets: [snippet])

        let result = await stage.run(TranscriptContext(rawTranscript: "hello signature"))

        XCTAssertEqual(result.text, "hello ⟦S0⟧")
        XCTAssertEqual(result.outcome, .applied)
        XCTAssertEqual(result.protectedSpans, ["⟦S0⟧": "SIG"])
        XCTAssertEqual(service.lastText, "hello signature")
        XCTAssertEqual(service.lastSnippets?.count, 1)
    }

    func testStageSeesTheTextTheStageBeforeItProduced() async {
        let service = MockSnippetService()
        let snippet = Snippet(cue: "x", body: "y")
        let stage = makeStage(service: service, snippets: [snippet])
        var context = TranscriptContext(rawTranscript: "raw")
        context.currentText = "text from an earlier stage"

        _ = await stage.run(context)

        XCTAssertEqual(service.lastText, "text from an earlier stage")
    }

    func testNoMatchIsReportedAsSkippedRatherThanApplied() async {
        let service = MockSnippetService()
        service.protectResult = SnippetProtectionResult(text: "שלום עולם", protectedSpans: [:])
        let snippet = Snippet(cue: "x", body: "y")
        let stage = makeStage(service: service, snippets: [snippet])

        let result = await stage.run(TranscriptContext(rawTranscript: "שלום עולם"))

        XCTAssertEqual(result.text, "שלום עולם")
        XCTAssertEqual(result.outcome, .skipped(reason: "no cues matched"))
        XCTAssertTrue(result.protectedSpans.isEmpty)
    }

    // MARK: - The master toggle

    func testDisabledStageMakesNoCallAtAll() async {
        let service = MockSnippetService()
        let snippet = Snippet(cue: "x", body: "y")
        let stage = makeStage(service: service, snippets: [snippet], isEnabled: false)

        let result = await stage.run(TranscriptContext(rawTranscript: "שלום עולם"))

        XCTAssertEqual(service.protectCallCount, 0)
        XCTAssertEqual(result.text, "שלום עולם")
        XCTAssertEqual(result.outcome, .skipped(reason: "snippets disabled"))
        XCTAssertFalse(result.didRun)
    }

    // MARK: - No Snippets defined (AD-2)

    func testNoSnippetsMakesNoCallAtAll() async {
        let service = MockSnippetService()
        let stage = makeStage(service: service, snippets: [])

        let result = await stage.run(TranscriptContext(rawTranscript: "שלום עולם"))

        XCTAssertEqual(service.protectCallCount, 0)
        XCTAssertEqual(result.outcome, .skipped(reason: "no snippets defined"))
        XCTAssertFalse(result.didRun)
    }

    // MARK: - Nothing to expand

    func testBlankTextMakesNoCallAtAll() async {
        let service = MockSnippetService()
        let snippet = Snippet(cue: "x", body: "y")
        let stage = makeStage(service: service, snippets: [snippet])

        let result = await stage.run(TranscriptContext(rawTranscript: "   "))

        XCTAssertEqual(service.protectCallCount, 0)
        XCTAssertEqual(result.outcome, .skipped(reason: "nothing to expand"))
        XCTAssertFalse(result.didRun)
    }

    // MARK: - Identity across the corpus

    func testDisabledStageIsIdentityAcrossTheCorpus() async {
        let service = MockSnippetService()
        service.protectResult = SnippetProtectionResult(text: "⟦S0⟧ THIS MUST NEVER APPEAR", protectedSpans: ["⟦S0⟧": "x"])
        let snippet = Snippet(cue: "x", body: "y")
        let stage = makeStage(service: service, snippets: [snippet], isEnabled: false)
        let pipeline = TranscriptPipeline(stages: [stage])

        let corpus = ["שָׁלוֹם עוֹלָם", "Hello there", "", "   "]
        for input in corpus {
            let result = await pipeline.run(TranscriptContext(rawTranscript: input))
            XCTAssertEqual(result.currentText, input)
            XCTAssertTrue(result.isUnchanged)
            XCTAssertTrue(result.protectedSpans.isEmpty)
        }
    }
}
