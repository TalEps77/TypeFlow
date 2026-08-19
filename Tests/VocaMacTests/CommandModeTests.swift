// CommandModeTests.swift
// VocaMac Tests
//
// Epic 6, Story 6.3. Command Mode inverts the fallback rule (AD-4), so almost
// every test here is a variation on one assertion: when anything goes wrong,
// **nothing was written**. `MockTextInjector` counts both the injection path
// and the replace path, so "nothing was written" is checkable directly rather
// than inferred.

import XCTest
@testable import VocaMac

// MARK: - Command Mode acceptance rules (pure, no network)

final class PostProcessCommandValidatorTests: XCTestCase {

    private let selection = "הפגישה נדחתה למחר בעשר ואני לא בטוח שכולם יודעים על זה"
    private let instruction = "תקצר את זה למשפט אחד"

    private func responseBody(_ content: String, finishReason: String = "stop") -> Data {
        let payload: [String: Any] = [
            "choices": [["message": ["content": content], "finish_reason": finishReason]]
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    private func validate(_ content: String, finishReason: String = "stop", status: Int = 200) -> Result<String, PostProcessError> {
        PostProcessCommandValidator.validate(
            data: responseBody(content, finishReason: finishReason),
            statusCode: status,
            selection: selection,
            instruction: instruction
        )
    }

    func testAcceptsARewriteThatDivergesFromTheSelection() {
        // The whole point of the separate validator: this rewrite is 40% of
        // the selection's length and shares little of its wording, which the
        // *cleanup* validator would reject outright.
        let rewritten = "הפגישה נדחתה למחר בעשר."
        guard case .success(let text) = validate(rewritten) else {
            return XCTFail("A legitimate shortening must be accepted — that is what Command Mode is for")
        }
        XCTAssertEqual(text, rewritten)
    }

    func testRejectsAnEchoOfTheInstruction() {
        // The destructive failure: the model hands back the spoken command,
        // which would then be pasted over the user's paragraph.
        guard case .failure(let error) = validate(instruction) else {
            return XCTFail("An echoed instruction must never be written back")
        }
        XCTAssertEqual(error, .commandEchoedInstruction)
    }

    func testRejectsAnEchoOfTheInstructionEvenWhenReworded() {
        guard case .failure = validate("תקצר את זה למשפט אחד.") else {
            return XCTFail("A near-identical echo must be rejected too")
        }
    }

    func testRejectsALeakedReasoningBlock() {
        guard case .failure(let error) = validate("<think>they want it shorter</think> הפגישה נדחתה למחר.") else {
            return XCTFail("A leaked reasoning block is not a rewrite")
        }
        XCTAssertEqual(error, .commandLeakedReasoning)
    }

    func testRejectsARunawayRewrite() {
        guard case .failure(let error) = validate(String(repeating: "א ", count: 2000)) else {
            return XCTFail("A runaway completion must be refused")
        }
        guard case .commandOutputTooLong = error else {
            return XCTFail("Expected a length rejection, got \(error)")
        }
    }

    func testRejectsATruncatedRewrite() {
        // A rewrite cut off at the token cap would replace the selection with
        // half a sentence — worse than not running.
        guard case .failure = validate("הפגישה נדחתה", finishReason: "length") else {
            return XCTFail("An answer that stopped early must be refused")
        }
    }

    func testRejectsEmptyAndNonSuccessResponses() {
        guard case .failure(let empty) = validate("   \n ") else {
            return XCTFail("Empty content must be refused")
        }
        XCTAssertEqual(empty, .emptyContent)

        guard case .failure(let http) = validate("fine", status: 503) else {
            return XCTFail("A non-2xx status must be refused")
        }
        XCTAssertEqual(http, .httpStatus(503))

        guard case .failure = PostProcessCommandValidator.validate(
            data: Data("not json".utf8), statusCode: 200, selection: selection, instruction: instruction
        ) else {
            return XCTFail("Undecodable JSON must be refused")
        }
    }

    func testLengthCeilingAllowsALegitimateExpansion() {
        // "expand this into a paragraph" is a real instruction, so the ceiling
        // is a runaway guard, not a similarity guard.
        let short = "בדוק"
        XCTAssertTrue(PostProcessCommandValidator.isWithinLengthCeiling(
            selection: short,
            output: String(repeating: "א", count: 300)
        ), "A short selection must still be allowed to grow into a sentence")
        XCTAssertFalse(PostProcessCommandValidator.isWithinLengthCeiling(
            selection: short,
            output: String(repeating: "א", count: 5000)
        ))
    }

    func testTheCleanupValidatorIsUnchanged() {
        // Story 6.3 must not have loosened cleanup's guards to make room for
        // Command Mode's. These are the constants Epic 2 tuned.
        XCTAssertEqual(PostProcessResponseValidator.minimumLengthRatio, 0.5)
        XCTAssertEqual(PostProcessResponseValidator.maximumLengthRatio, 2.0)
        XCTAssertEqual(PostProcessResponseValidator.minimumSimilarity, 0.5)
        XCTAssertEqual(PostProcessResponseValidator.contextEchoWindowLength, 40)

        // And a shortening that Command Mode accepts is still rejected as a
        // *cleanup*, which is exactly why the two validators are separate.
        let cleanupResult = PostProcessResponseValidator.validate(
            data: responseBody("הפגישה נדחתה."),
            statusCode: 200,
            input: selection
        )
        guard case .failure = cleanupResult else {
            return XCTFail("Cleanup must still reject an answer that rewrote instead of cleaning")
        }
    }
}

// MARK: - The command request

final class PostProcessCommandRequestTests: XCTestCase {

    func testCommandBodyUsesTheCommandPromptAndMessageShape() {
        let body = PostProcessRequestBuilder.commandBody(
            selection: "טקסט",
            instruction: "תקצר",
            systemPrompt: Prompts.commandModeSystemPrompt,
            configuration: PostProcessConfiguration()
        )

        XCTAssertEqual(body.messages.count, 2)
        XCTAssertEqual(body.messages[0].role, "system")
        XCTAssertEqual(body.messages[0].content, Prompts.commandModeSystemPrompt)
        XCTAssertEqual(body.messages[1].content, "Text: טקסט\nInstruction: תקצר\nRewritten:")
        XCTAssertFalse(body.stream)
    }

    func testTheCommandPromptIsNotTheCleanupPrompt() {
        // They give the model opposite instructions; merging them would leave
        // it holding a contradiction.
        XCTAssertNotEqual(Prompts.commandModeSystemPrompt, Prompts.cleanTranscriptSystemPrompt)
        XCTAssertTrue(Prompts.cleanTranscriptSystemPrompt.contains("never carry out an instruction"))
        XCTAssertTrue(Prompts.commandModeSystemPrompt.contains("Apply the Instruction to the Text"))
    }

    func testCommandTokenCapIsBoundedButRoomierThanCleanup() {
        XCTAssertGreaterThanOrEqual(PostProcessRequestBuilder.commandMaxTokens(forSelectionCharacterCount: 0), 512)
        XCTAssertGreaterThan(
            PostProcessRequestBuilder.commandMaxTokens(forSelectionCharacterCount: 1000),
            PostProcessRequestBuilder.maxTokens(forInputCharacterCount: 1000),
            "A rewrite may be asked to expand where a cleanup may not"
        )
    }
}

// MARK: - The coordinator

@MainActor
final class CommandModeCoordinatorTests: XCTestCase {

    private func makeCoordinator() -> (CommandModeCoordinator, MockTextInjector, MockPostProcessService) {
        let injector = MockTextInjector()
        let service = MockPostProcessService()
        return (
            CommandModeCoordinator(textInjector: injector, postProcessService: service),
            injector,
            service
        )
    }

    func testHappyPathReplacesTheSelectionWithTheRewrite() async {
        let (coordinator, injector, service) = makeCoordinator()
        injector.stubSelection("הפגישה נדחתה למחר בעשר ואני לא בטוח שכולם יודעים")
        service.commandResult = .success("הפגישה נדחתה למחר בעשר.")

        XCTAssertTrue(coordinator.captureSelection().isSuccess)

        let result = await coordinator.rewrite(
            instruction: "תקצר את זה",
            systemPrompt: Prompts.commandModeSystemPrompt,
            configuration: PostProcessConfiguration()
        )

        guard case .success(let outcome) = result else {
            return XCTFail("Expected the rewrite to be applied, got \(result)")
        }
        XCTAssertEqual(injector.replaceSelectionCallCount, 1)
        XCTAssertEqual(injector.lastReplacementText, "הפגישה נדחתה למחר בעשר.")
        XCTAssertEqual(outcome.targetBundleIdentifier, "com.apple.TextEdit")
        XCTAssertEqual(injector.injectCallCount, 0, "Command Mode must never inject")

        // The selection and the instruction both reached the LLM.
        XCTAssertEqual(service.commandCallCount, 1)
        XCTAssertEqual(service.lastCommandInstruction, "תקצר את זה")
        XCTAssertEqual(service.cleanCallCount, 0, "Command Mode must not go through the cleanup route")
    }

    func testTheSelectionIsReleasedAfterEveryOperation() async {
        let (coordinator, injector, service) = makeCoordinator()
        injector.stubSelection("טקסט נבחר")
        service.commandResult = .success("טקסט מתוקן")
        coordinator.captureSelection()
        XCTAssertTrue(coordinator.hasSelection)

        _ = await coordinator.rewrite(instruction: "תקן", systemPrompt: "", configuration: PostProcessConfiguration())
        XCTAssertFalse(coordinator.hasSelection, "Document text must not outlive the operation that needed it (AD-5)")

        // And after a failure, too.
        coordinator.captureSelection()
        service.commandResult = .failure(.timedOut(5))
        _ = await coordinator.rewrite(instruction: "תקן", systemPrompt: "", configuration: PostProcessConfiguration())
        XCTAssertFalse(coordinator.hasSelection)
    }

    func testNoSelectionAbortsBeforeAnythingIsWritten() async {
        let (coordinator, injector, service) = makeCoordinator()
        injector.selectionResult = .failure(.noSelection)

        guard case .failure(let captureError) = coordinator.captureSelection() else {
            return XCTFail("A capture with nothing selected must fail")
        }
        XCTAssertEqual(captureError, .noSelection(.noSelection))

        let result = await coordinator.rewrite(instruction: "תקצר", systemPrompt: "", configuration: PostProcessConfiguration())
        guard case .failure = result else { return XCTFail("Expected an abort") }

        XCTAssertEqual(service.commandCallCount, 0, "With nothing selected the LLM must never be contacted")
        XCTAssertEqual(injector.replaceSelectionCallCount, 0)
        XCTAssertEqual(injector.injectCallCount, 0)
    }

    func testAnUnreachableLLMAbortsWithoutWriting() async {
        let (coordinator, injector, service) = makeCoordinator()
        injector.stubSelection("טקסט נבחר")
        service.commandResult = .failure(.transport("Could not connect to the server."))
        coordinator.captureSelection()

        let result = await coordinator.rewrite(instruction: "תקצר", systemPrompt: "", configuration: PostProcessConfiguration())

        guard case .failure(.llm) = result else {
            return XCTFail("An unreachable LLM must abort, got \(result)")
        }
        XCTAssertEqual(injector.replaceSelectionCallCount, 0, "Nothing may be written when the LLM is unreachable")
        XCTAssertEqual(injector.injectCallCount, 0)
    }

    func testATimeoutAbortsWithoutWriting() async {
        let (coordinator, injector, service) = makeCoordinator()
        injector.stubSelection("טקסט נבחר")
        service.commandResult = .failure(.timedOut(20))
        coordinator.captureSelection()

        let result = await coordinator.rewrite(instruction: "תקצר", systemPrompt: "", configuration: PostProcessConfiguration())

        guard case .failure(.llm(.timedOut)) = result else {
            return XCTFail("A timeout must abort, got \(result)")
        }
        XCTAssertEqual(injector.replaceSelectionCallCount, 0)
    }

    func testAnUnwritableTargetIsReportedRatherThanIgnored() async {
        let (coordinator, injector, service) = makeCoordinator()
        injector.stubSelection("טקסט נבחר")
        service.commandResult = .success("טקסט מתוקן")
        injector.replaceSelectionResult = .failure(.writeNotApplied)
        coordinator.captureSelection()

        let result = await coordinator.rewrite(instruction: "תקן", systemPrompt: "", configuration: PostProcessConfiguration())

        guard case .failure(.write(.writeNotApplied)) = result else {
            return XCTFail("A refused write must surface as a failure, got \(result)")
        }
    }

    func testAnEmptyInstructionAbortsBeforeTheLLM() async {
        let (coordinator, injector, service) = makeCoordinator()
        injector.stubSelection("טקסט נבחר")
        coordinator.captureSelection()

        let result = await coordinator.rewrite(instruction: "   ", systemPrompt: "", configuration: PostProcessConfiguration())

        guard case .failure(.emptyInstruction) = result else {
            return XCTFail("An empty instruction must abort, got \(result)")
        }
        XCTAssertEqual(service.commandCallCount, 0)
        XCTAssertEqual(injector.replaceSelectionCallCount, 0)
    }

    func testEveryFailureMessageSaysNothingWasChanged() {
        let errors: [CommandModeError] = [
            .noSelection(.noSelection),
            .noSelection(.notTrusted),
            .noSelection(.noAccessibleElement),
            .emptyInstruction,
            .llm(.timedOut(20)),
            .write(.writeNotApplied),
            .abandoned
        ]
        for error in errors {
            XCTAssertTrue(error.userMessage.contains("nothing was changed"),
                          "\(error) must tell the user their text is untouched")
        }
    }
}

// MARK: - The AppState route

@MainActor
final class AppStateCommandModeTests: XCTestCase {

    /// A state with Command Mode enabled on a key that does not collide, a
    /// selection ready to read, and audio that will produce an instruction.
    private func makeCommandState(
        selection: String = "הפגישה נדחתה למחר בעשר ואני לא בטוח שכולם יודעים על זה",
        instruction: String = "תקצר את זה למשפט אחד"
    ) -> (AppState, TestMocks) {
        let (appState, mocks) = AppState.makeTestState()
        appState.commandModeEnabled = true
        appState.commandHotKeyCode = 54
        appState.hotKeyCode = 61
        mocks.textInjector.stubSelection(selection)
        mocks.audioEngine.stopRecordingResult = [0.1, 0.2, 0.3]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: instruction, duration: 1.0, detectedLanguage: "he", audioLengthSeconds: 2.0, modelUsed: .tiny
        )
        mocks.postProcessService.commandResult = .success("הפגישה נדחתה למחר בעשר.")
        return (appState, mocks)
    }

    private func runCommand(_ appState: AppState) async {
        await appState.startCommandRecording()
        await appState.stopCommandRecordingAndRewrite()
    }

    func testHappyPathRewritesAndRecordsACommandModeHistoryRecord() async {
        let (appState, mocks) = makeCommandState()

        await runCommand(appState)

        XCTAssertEqual(mocks.textInjector.replaceSelectionCallCount, 1)
        XCTAssertEqual(mocks.textInjector.lastReplacementText, "הפגישה נדחתה למחר בעשר.")
        XCTAssertEqual(mocks.textInjector.injectCallCount, 0,
                       "The spoken instruction must never be injected into the document")
        XCTAssertEqual(appState.appStatus, .idle)

        XCTAssertEqual(mocks.historyStore.records.count, 1)
        let record = mocks.historyStore.records[0]
        XCTAssertEqual(record.mode, .command, "A Command Mode record must be distinguishable by its mode field")
        XCTAssertEqual(record.rawTranscript, "תקצר את זה למשפט אחד")
    }

    func testTheHistoryRecordNeverHoldsTheSelectionOrTheRewrite() async {
        let selection = "VOCAMAC_SELECTION_TOKEN_UNIQUE_9c4f"
        let (appState, mocks) = makeCommandState(selection: selection)
        mocks.postProcessService.commandResult = .success("VOCAMAC_REWRITE_TOKEN_UNIQUE_2b7a")

        await runCommand(appState)

        let encoded = try! JSONEncoder().encode(mocks.historyStore.records)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains(selection), "The selection is document text and must never be persisted (AD-5)")
        XCTAssertFalse(json.contains("VOCAMAC_REWRITE_TOKEN_UNIQUE_2b7a"),
                       "The rewrite is derived from document text and must never be persisted (AD-5)")
    }

    func testNoSelectionAbortsWithoutEverRecording() async {
        let (appState, mocks) = makeCommandState()
        mocks.textInjector.selectionResult = .failure(.noSelection)

        await appState.startCommandRecording()

        XCTAssertEqual(mocks.audioEngine.lastMaxDuration, nil,
                       "With nothing selected the microphone must never be opened")
        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(appState.appStatus, .error)
        XCTAssertNotNil(appState.errorMessage)
        XCTAssertEqual(mocks.soundManager.errorSoundCallCount, 0,
                       "Sound effects are off by default in tests, so no cue is expected")
        XCTAssertEqual(mocks.textInjector.replaceSelectionCallCount, 0)
        XCTAssertEqual(mocks.historyStore.records.count, 0)
    }

    func testTheErrorCuePlaysOnAbortWhenSoundIsOn() async {
        let (appState, mocks) = makeCommandState()
        appState.soundEffectsEnabled = true
        mocks.textInjector.selectionResult = .failure(.noSelection)

        await appState.startCommandRecording()

        XCTAssertEqual(mocks.soundManager.errorSoundCallCount, 1)
    }

    func testAnUnreachableLLMLeavesTheSelectionUntouched() async {
        let (appState, mocks) = makeCommandState()
        mocks.postProcessService.commandResult = .failure(.transport("Could not connect to the server."))

        await runCommand(appState)

        XCTAssertEqual(mocks.textInjector.replaceSelectionCallCount, 0, "Nothing may be written")
        XCTAssertEqual(mocks.textInjector.injectCallCount, 0, "And nothing may be injected either")
        XCTAssertEqual(mocks.historyStore.records.count, 0, "An aborted operation writes no record")
        XCTAssertEqual(appState.appStatus, .error)
        XCTAssertTrue(appState.errorMessage?.contains("nothing was changed") == true)
    }

    func testATimeoutLeavesTheSelectionUntouched() async {
        let (appState, mocks) = makeCommandState()
        mocks.postProcessService.commandResult = .failure(.timedOut(20))

        await runCommand(appState)

        XCTAssertEqual(mocks.textInjector.replaceSelectionCallCount, 0)
        XCTAssertEqual(mocks.historyStore.records.count, 0)
    }

    func testAnInvalidRewriteLeavesTheSelectionUntouched() async {
        let (appState, mocks) = makeCommandState()
        mocks.postProcessService.commandResult = .failure(.commandEchoedInstruction)

        await runCommand(appState)

        XCTAssertEqual(mocks.textInjector.replaceSelectionCallCount, 0,
                       "An echoed instruction must never reach the document")
        XCTAssertEqual(mocks.historyStore.records.count, 0)
    }

    func testAnUnwritableTargetAbortsAndRecordsNothing() async {
        let (appState, mocks) = makeCommandState()
        mocks.textInjector.replaceSelectionResult = .failure(.writeNotApplied)

        await runCommand(appState)

        XCTAssertEqual(mocks.textInjector.replaceSelectionCallCount, 1, "The write was attempted")
        XCTAssertEqual(mocks.historyStore.records.count, 0, "…but it did not apply, so nothing is recorded")
        XCTAssertEqual(appState.appStatus, .error)
    }

    func testBlankAudioAbortsWithoutContactingTheLLM() async {
        let (appState, mocks) = makeCommandState()
        mocks.audioEngine.stopRecordingResult = []

        await runCommand(appState)

        XCTAssertEqual(mocks.postProcessService.commandCallCount, 0)
        XCTAssertEqual(mocks.textInjector.replaceSelectionCallCount, 0)
        XCTAssertEqual(appState.appStatus, .error)
    }

    func testAFailedTranscriptionAbortsWithoutWriting() async {
        let (appState, mocks) = makeCommandState()
        mocks.whisperService.shouldThrow = true

        await runCommand(appState)

        XCTAssertEqual(mocks.postProcessService.commandCallCount, 0)
        XCTAssertEqual(mocks.textInjector.replaceSelectionCallCount, 0)
        XCTAssertEqual(mocks.historyStore.records.count, 0)
    }

    func testCommandModeIsIgnoredWhenTheBindingIsNotUsable() async {
        let (appState, mocks) = makeCommandState()
        appState.commandModeEnabled = false

        await appState.startCommandRecording()

        XCTAssertEqual(mocks.textInjector.readSelectionCallCount, 0)
        XCTAssertFalse(appState.isRecording)
        XCTAssertEqual(appState.appStatus, .idle, "A disabled binding must not even produce an error state")
    }

    func testACollidingCommandKeyMakesTheBindingUnusable() {
        let (appState, _) = AppState.makeTestState()
        appState.hotKeyCode = 61
        appState.commandModeEnabled = true
        appState.commandHotKeyCode = 61

        XCTAssertFalse(appState.isCommandModeUsable,
                       "Two gestures must never share one key, whatever the stored preference says")
    }

    func testSyncPushesTheCommandBindingConfiguration() {
        let (appState, mocks) = AppState.makeTestState()
        appState.hotKeyCode = 61
        appState.commandModeEnabled = true
        appState.commandHotKeyCode = 54
        appState.commandActivationMode = .doubleTapToggle

        appState.syncCommandHotKeyConfiguration()

        XCTAssertEqual(mocks.hotKeyManager.lastCommandKeyCode, 54)
        XCTAssertEqual(mocks.hotKeyManager.lastCommandMode, .doubleTapToggle)
        XCTAssertEqual(mocks.hotKeyManager.lastCommandIsEnabled, true)
        XCTAssertEqual(mocks.hotKeyManager.lastKeyCode, nil,
                       "Syncing the command binding must not touch the dictation binding")
    }

    // MARK: The two routes must not interfere

    func testTheDictationStopCannotHijackACommandRecording() async {
        let (appState, mocks) = makeCommandState()

        await appState.startCommandRecording()
        XCTAssertTrue(appState.isRecording)

        // The dictation key released (or a silence auto-stop) while the
        // command recording is live: it must do nothing at all. Otherwise the
        // spoken instruction would be transcribed and injected.
        await appState.stopRecordingAndTranscribe()

        XCTAssertTrue(appState.isRecording, "The command recording must still be running")
        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
        XCTAssertEqual(mocks.historyStore.records.count, 0)

        await appState.stopCommandRecordingAndRewrite()
        XCTAssertEqual(mocks.textInjector.replaceSelectionCallCount, 1)
    }

    func testCommandModeIsRefusedWhileADictationIsRecordingAndLeavesItAlone() async {
        let (appState, mocks) = makeCommandState()

        await appState.startRecording()
        XCTAssertTrue(appState.isRecording)
        let readsBefore = mocks.textInjector.readSelectionCallCount
        let resetsBefore = mocks.hotKeyManager.resetKeyStateCallCount

        await appState.startCommandRecording()

        XCTAssertEqual(mocks.textInjector.readSelectionCallCount, readsBefore,
                       "A busy app must refuse before it reads anything")
        XCTAssertEqual(mocks.textInjector.replaceSelectionCallCount, 0)

        // And the refusal must not damage the dictation it refused for: a
        // hotkey-state reset here would clear *both* bindings mid-gesture.
        XCTAssertTrue(appState.isRecording, "The dictation must still be recording")
        XCTAssertEqual(appState.appStatus, .recording)
        XCTAssertEqual(mocks.hotKeyManager.resetKeyStateCallCount, resetsBefore)
        XCTAssertEqual(mocks.cursorOverlay.hideCallCount, 0)
    }

    func testAnAbandonedOperationDoesNotWriteAfterTheLLMReturns() async {
        // The window that matters: the LLM answers *after* the user has
        // already forced a recovery. The rewrite must be dropped, not applied
        // seconds later into whatever they are doing now.
        let (appState, mocks) = makeCommandState()
        mocks.postProcessService.commandDelay = 0.3

        await appState.startCommandRecording()
        let inFlight = Task { await appState.stopCommandRecordingAndRewrite() }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        appState.forceRecovery()
        await inFlight.value

        XCTAssertEqual(mocks.textInjector.replaceSelectionCallCount, 0,
                       "An abandoned rewrite must never reach the document")
        XCTAssertEqual(mocks.historyStore.records.count, 0)
    }

    func testForceRecoveryReleasesTheSelectionAndInvalidatesTheOperation() async {
        let (appState, mocks) = makeCommandState()
        mocks.postProcessService.commandDelay = 0.3

        await appState.startCommandRecording()
        XCTAssertTrue(appState.commandModeCoordinator.hasSelection)

        let inFlight = Task { await appState.stopCommandRecordingAndRewrite() }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)

        appState.forceRecovery()
        await inFlight.value

        XCTAssertFalse(appState.commandModeCoordinator.hasSelection,
                       "An abandoned operation must not leave document text resident (AD-5)")
        XCTAssertEqual(mocks.textInjector.injectCallCount, 0)
        XCTAssertEqual(mocks.historyStore.records.count, 0,
                       "A recovered-from operation must not write a record")
    }

    func testStartRecordingIsUnaffectedWhenCommandModeIsOff() async {
        // The regression guard for the whole epic: with Command Mode off, the
        // dictation path behaves exactly as it did before Story 6.3.
        let (appState, mocks) = AppState.makeTestState()
        mocks.audioEngine.stopRecordingResult = [0.1, 0.2]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "שלום עולם", duration: 1.0, detectedLanguage: "he", audioLengthSeconds: 1.0, modelUsed: .tiny
        )

        await appState.startRecording()
        XCTAssertEqual(appState.appStatus, .recording)
        await appState.stopRecordingAndTranscribe()

        XCTAssertEqual(mocks.textInjector.injectCallCount, 1)
        XCTAssertEqual(mocks.textInjector.lastInjectedText, "שלום עולם")
        XCTAssertEqual(mocks.historyStore.records.first?.mode, .dictation)
        XCTAssertEqual(appState.appStatus, .idle)
    }
}

// MARK: - Small helper

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
