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

    func testPipelineIsIdentityWithPostProcessDisabled() async {
        // Was `TranscriptPipeline.production()`, which builds a real
        // PostProcessStage reading VocaDefaults.store through
        // PostProcessSettings.current(). If a crashed test run elsewhere
        // leaves vocamac.postProcess.enabled=true persisted, that turned this
        // identity test into a live network test against localhost:1234 for
        // every entry in the corpus (MAJOR 5). Built explicitly here instead,
        // so this test can never read process-global state or reach a
        // socket.
        let service = MockPostProcessService()
        let stage = PostProcessStage(service: service, settingsProvider: { PostProcessSettings(isEnabled: false) })
        let pipeline = TranscriptPipeline(stages: [stage])

        for input in identityCorpus {
            let result = await pipeline.run(TranscriptContext(rawTranscript: input))
            XCTAssertEqual(result.currentText, input)
        }
        XCTAssertEqual(service.cleanCallCount, 0, "disabled post-processing must never reach the service, real or mock")
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

    func testAppliedStageWithBlankTextCannotClobberTheContext() async {
        // MINOR 7: a stage's own contract says `.applied` never carries blank
        // text, but the runner is the sole AD-2 enforcer and must not trust
        // that — a stage that violates its contract must still not blank out
        // whatever the pipeline already had.
        let stage = StubTranscriptStage(result: StageResult(text: "   ", outcome: .applied))
        let pipeline = TranscriptPipeline(stages: [stage])

        let result = await pipeline.run(TranscriptContext(rawTranscript: "raw text"))

        XCTAssertEqual(result.currentText, "raw text")
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

    // MARK: - AD-5: the runner never hands Cursor Context back (MINOR 1)

    /// The clear inside the loop is keyed on `PostProcessStage` having run.
    /// A pipeline that does not contain one — a test's stage list, or any
    /// future assembly that drops it — therefore returned the context to
    /// `AppState` still populated, which is the one place AD-5 said it would
    /// never be. The runner now clears unconditionally after the loop too.
    func testCursorContextIsClearedEvenWhenNoPostProcessStageExists() async {
        let observer = StubTranscriptStage(name: "Observer", result: .unchanged("raw", outcome: .skipped(reason: "observing")))
        let pipeline = TranscriptPipeline(stages: [observer])

        let result = await pipeline.run(TranscriptContext(
            rawTranscript: "raw",
            cursorContextBefore: "document text before",
            cursorContextAfter: "document text after"
        ))

        // The stage that ran did see it — the pipeline is not simply
        // dropping context on the floor before anything can use it.
        XCTAssertEqual(observer.lastContext?.cursorContextBefore, "document text before")
        XCTAssertNil(result.cursorContextBefore)
        XCTAssertNil(result.cursorContextAfter)
    }

    /// An empty stage list is the identity pipeline (AD-2/AD-13) — and must
    /// still not carry context out the other side.
    func testCursorContextIsClearedByAnEmptyPipeline() async {
        let result = await TranscriptPipeline(stages: []).run(TranscriptContext(
            rawTranscript: "raw",
            cursorContextBefore: "document text before",
            cursorContextAfter: "document text after"
        ))

        XCTAssertEqual(result.currentText, "raw")
        XCTAssertNil(result.cursorContextBefore)
        XCTAssertNil(result.cursorContextAfter)
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

    // MARK: - Re-entrancy at the seam (MAJOR 2)

    /// Builds an AppState wired with a *real* `TranscriptPipeline` running a
    /// *real* `PostProcessStage` against a slow `MockPostProcessService`, so
    /// these tests exercise the actual production seam code path — not just
    /// a generic pipeline stub — under a genuine multi-hundred-millisecond
    /// suspension.
    private func makeStateThatTranscribesSlowly(
        _ text: String,
        cleanDelay: TimeInterval
    ) -> (AppState, TestMocks, MockPostProcessService) {
        let postProcessService = MockPostProcessService()
        postProcessService.cleanDelay = cleanDelay
        postProcessService.cleanResult = .success("cleaned: \(text)")
        let pipeline = TranscriptPipeline(stages: [
            PostProcessStage(service: postProcessService, settingsProvider: { PostProcessSettings(isEnabled: true) })
        ])

        let (appState, mocks) = AppState.makeTestState(
            postProcessService: postProcessService,
            transcriptPipelineOverride: pipeline
        )
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
        return (appState, mocks, postProcessService)
    }

    func testStaleDictationDoesNotInjectIntoANewRecording() async throws {
        let (appState, mocks, _) = makeStateThatTranscribesSlowly("stale dictation", cleanDelay: 0.3)

        // Release the hotkey: this suspends inside the slow post-process stage.
        let staleDictation = Task {
            await appState.stopRecordingAndTranscribe()
        }
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(appState.appStatus, .processing, "must be suspended mid-pipeline before the race is simulated")

        // A second hotkey press while stuck in .processing force-recovers...
        appState.forceRecovery()
        // ...and a third genuinely starts a new recording.
        await appState.startRecording()
        XCTAssertEqual(appState.appStatus, .recording, "the new recording must be live")
        let hideCallCountBeforeStaleResult = mocks.cursorOverlay.hideCallCount

        // The stale pipeline call now resolves into a world with a different
        // recording live. It must change nothing.
        await staleDictation.value

        XCTAssertEqual(mocks.textInjector.injectCallCount, 0, "the stale dictation must never be injected")
        XCTAssertEqual(mocks.historyStore.recordCallCount, 0, "the stale dictation must never be recorded in history")
        XCTAssertEqual(appState.appStatus, .recording, "the new recording's status must survive the stale one resuming")
        XCTAssertTrue(appState.isRecording, "the new recording must still be marked as recording")
        XCTAssertEqual(mocks.cursorOverlay.hideCallCount, hideCallCountBeforeStaleResult,
                       "the stale dictation must not hide the new recording's overlay")
    }

    // MARK: - Main-actor liveness during post-processing (MINOR 10)

    /// Mirrors `testStartRecordingDoesNotBlockMainActorDuringAudioStart`
    /// (AppStateRecordingTests.swift): the post-process seam is the app's
    /// longest main-actor suspension (up to the configured timeout), and had
    /// no regression test proving it actually suspends rather than blocks.
    func testStopRecordingDoesNotBlockMainActorDuringPostProcessing() async throws {
        let (appState, _, _) = makeStateThatTranscribesSlowly("שלום עולם", cleanDelay: 0.3)

        let start = Date()
        let task = Task {
            await appState.stopRecordingAndTranscribe()
        }

        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3,
                          "the main actor should stay free while post-processing is in flight")
        XCTAssertEqual(appState.appStatus, .processing, "still suspended in the post-process stage")

        await task.value
        XCTAssertEqual(appState.appStatus, .idle)
    }
}
