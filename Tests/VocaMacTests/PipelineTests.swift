// PipelineTests.swift
// VocaMac Tests
//
// The identity guarantee is load-bearing (AD-2, AD-13): with no stages, or with
// every stage disabled or failing, the pipeline must return its input byte for
// byte. Every new stage has to keep these green.

import XCTest
@testable import VocaMac

@MainActor
final class PipelineTests: XCTestCase {

    /// Inputs the pipeline must never touch. Deliberately awkward: Hebrew with
    /// niqqud, mixed scripts, RTL/LTR boundaries, empty and whitespace-only.
    private let identityCorpus: [String] = [
        "",
        " ",
        "   \n\t  ",
        "\n",
        "שלום עולם",
        "שָׁלוֹם עוֹלָם",                       // niqqud
        "בְּרֵאשִׁית בָּרָא אֱלֹהִים",              // niqqud, multi-word
        "תריץ את ה-build של VocaMac ב-Xcode",  // mixed Hebrew/English
        "Hello עולם 123 !@#",
        "טקסט עם\nשורה שנייה",
        "trailing space ",
        " leading space",
        "emoji 👋🏽 and ZWJ 👨‍👩‍👧‍👦",
        String(repeating: "מילה ", count: 500)
    ]

    // MARK: - Empty pipeline

    func testEmptyPipelineReturnsInputByteForByte() async {
        let pipeline = TranscriptPipeline(stages: [])

        for input in identityCorpus {
            let result = await pipeline.run(TranscriptContext(rawTranscript: input))
            XCTAssertEqual(result.currentText, input, "Pipeline altered input: \(input.debugDescription)")
            XCTAssertEqual(Array(result.currentText.utf8), Array(input.utf8), "Byte mismatch for: \(input.debugDescription)")
            XCTAssertTrue(result.isUnchanged)
            XCTAssertTrue(result.reports.isEmpty)
        }
    }

    func testProductionPipelineIsIdentityWithNoStagesEnabled() async {
        let pipeline = TranscriptPipeline.production()

        for input in identityCorpus {
            let result = await pipeline.run(TranscriptContext(rawTranscript: input))
            XCTAssertEqual(result.currentText, input)
        }
    }

    // MARK: - Failing and skipped stages pass through

    func testFailedStageCannotChangeTheText() async {
        let saboteur = StubTranscriptStage(
            name: "Saboteur",
            result: StageResult(text: "TEXT THE STAGE TRIED TO SMUGGLE THROUGH", outcome: .failed(reason: "boom"))
        )
        let pipeline = TranscriptPipeline(stages: [saboteur])

        for input in identityCorpus {
            let result = await pipeline.run(TranscriptContext(rawTranscript: input))
            XCTAssertEqual(result.currentText, input, "A failed stage changed the text")
        }

        XCTAssertEqual(saboteur.runCallCount, identityCorpus.count)
    }

    func testFailedStageRecordsOutcomeOnTheContext() async {
        let stage = StubTranscriptStage(name: "Flaky", result: StageResult(text: "ignored", outcome: .failed(reason: "connection refused")))
        let pipeline = TranscriptPipeline(stages: [stage])

        let result = await pipeline.run(TranscriptContext(rawTranscript: "שלום"))

        XCTAssertEqual(result.currentText, "שלום")
        XCTAssertEqual(result.reports.count, 1)
        XCTAssertEqual(result.reports.first?.stageName, "Flaky")
        XCTAssertEqual(result.reports.first?.outcome, .failed(reason: "connection refused"))
        XCTAssertEqual(result.reports.first?.outcome.reason, "connection refused")
    }

    func testSkippedStageCannotChangeTheText() async {
        let stage = StubTranscriptStage(result: StageResult(text: "should not appear", outcome: .skipped(reason: "disabled")))
        let pipeline = TranscriptPipeline(stages: [stage])

        let result = await pipeline.run(TranscriptContext(rawTranscript: "נפגש מחר"))

        XCTAssertEqual(result.currentText, "נפגש מחר")
        XCTAssertEqual(result.reports.first?.outcome, .skipped(reason: "disabled"))
    }

    // MARK: - Applied stages

    func testAppliedStageInstallsItsText() async {
        let stage = StubTranscriptStage(result: StageResult(text: "cleaned", outcome: .applied))
        let pipeline = TranscriptPipeline(stages: [stage])

        let result = await pipeline.run(TranscriptContext(rawTranscript: "raw"))

        XCTAssertEqual(result.currentText, "cleaned")
        XCTAssertEqual(result.rawTranscript, "raw", "The raw transcript must survive for the History Record")
        XCTAssertFalse(result.isUnchanged)
    }

    func testStagesRunInOrderAndEachSeesThePreviousText() async {
        let first = StubTranscriptStage(name: "First", result: StageResult(text: "one", outcome: .applied))
        let second = StubTranscriptStage(name: "Second", result: StageResult(text: "two", outcome: .applied))
        let pipeline = TranscriptPipeline(stages: [first, second])

        let result = await pipeline.run(TranscriptContext(rawTranscript: "zero"))

        XCTAssertEqual(result.currentText, "two")
        XCTAssertEqual(result.reports.map(\.stageName), ["First", "Second"])
    }

    func testFailedStageDoesNotStopLaterStages() async {
        let broken = StubTranscriptStage(name: "Broken", result: StageResult(text: "junk", outcome: .failed(reason: "nope")))
        let good = StubTranscriptStage(name: "Good", result: StageResult(text: "final", outcome: .applied))
        let pipeline = TranscriptPipeline(stages: [broken, good])

        let result = await pipeline.run(TranscriptContext(rawTranscript: "raw"))

        XCTAssertEqual(result.currentText, "final")
        XCTAssertEqual(result.reports.count, 2)
    }

    // MARK: - Context bookkeeping

    func testContextStartsWithCurrentTextEqualToRaw() {
        let context = TranscriptContext(rawTranscript: "שלום")
        XCTAssertEqual(context.currentText, context.rawTranscript)
        XCTAssertNil(context.targetBundleIdentifier)
        XCTAssertTrue(context.protectedSpans.isEmpty)
        XCTAssertTrue(context.reports.isEmpty)
        XCTAssertEqual(context.totalStageDuration, 0)
    }

    func testPerStageTimingsAreRecorded() async {
        let stage = StubTranscriptStage(result: StageResult(text: "x", outcome: .applied))
        let pipeline = TranscriptPipeline(stages: [stage, stage])

        let result = await pipeline.run(TranscriptContext(rawTranscript: "raw"))

        XCTAssertEqual(result.reports.count, 2)
        for report in result.reports {
            XCTAssertGreaterThanOrEqual(report.duration, 0)
        }
        XCTAssertEqual(result.totalStageDuration, result.reports.reduce(0) { $0 + $1.duration }, accuracy: 0.0001)
    }
}

// MARK: - The AppState seam (AD-1)

@MainActor
final class AppStatePipelineSeamTests: XCTestCase {

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

    func testTranscriptionIsRoutedThroughThePipeline() async {
        let (appState, mocks) = makeStateThatTranscribes("שלום עולם")

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.transcriptPipeline.runCallCount, 1, "The pipeline must be the seam, and be called exactly once")
        XCTAssertEqual(mocks.transcriptPipeline.lastContext?.rawTranscript, "שלום עולם")
    }

    func testIdentityPipelineInjectsTheRawTranscriptUnchanged() async {
        let (appState, mocks) = makeStateThatTranscribes("  שָׁלוֹם עוֹלָם  ")

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.textInjector.lastInjectedText, "שָׁלוֹם עוֹלָם",
                       "With an identity pipeline the injected text must match the pre-epic behavior byte for byte")
        XCTAssertEqual(mocks.textInjector.injectCallCount, 1)
    }

    func testPipelineOutputIsWhatGetsInjected() async {
        let (appState, mocks) = makeStateThatTranscribes("נפגש בשתיים בעצם בשלוש")
        mocks.transcriptPipeline.transform = { _ in "נפגש בשלוש." }

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.textInjector.lastInjectedText, "נפגש בשלוש.")
    }

    func testEmptyTranscriptStillSkipsInjection() async {
        let (appState, mocks) = makeStateThatTranscribes("   ")

        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.textInjector.injectCallCount, 0,
                       "An empty transcript must not be injected, exactly as before the pipeline existed")
        XCTAssertEqual(appState.appStatus, .idle)
    }
}
