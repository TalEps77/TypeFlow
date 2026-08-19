// CursorContextTests.swift
// VocaMac Tests
//
// Story 4.4: budget truncation (pure logic, no AX permission needed), the
// privacy assertion AD-5 requires — Cursor Context must never reach a log
// line or a persisted History Record — and the other half of that AC, which
// the original tests did not cover: it must not survive in memory either, on
// any of the ways a dictation can end without producing a transcript.

import XCTest
@testable import VocaMac

// MARK: - Budget truncation (AXContextReader.slice — pure, no AX call)

@MainActor
final class AXContextReaderSliceTests: XCTestCase {

    func testSlicesUpToTheBudgetOnEachSide() {
        let text = String(repeating: "a", count: 10) + String(repeating: "b", count: 10)
        // Caret sits exactly at the boundary between the a's and b's.
        let (before, after) = AXContextReader.slice(fullText: text, caretUTF16Location: 10, budget: 4)

        XCTAssertEqual(before, "aaaa")
        XCTAssertEqual(after, "bbbb")
    }

    func testDoesNotOverrunWhenTextIsShorterThanTheBudget() {
        let text = "short"
        let (before, after) = AXContextReader.slice(fullText: text, caretUTF16Location: 3, budget: 500)

        XCTAssertEqual(before, "sho")
        XCTAssertEqual(after, "rt")
    }

    func testCaretAtTheStartYieldsNoBeforeContext() {
        let (before, after) = AXContextReader.slice(fullText: "hello world", caretUTF16Location: 0, budget: 500)

        XCTAssertNil(before)
        XCTAssertEqual(after, "hello world")
    }

    func testCaretAtTheEndYieldsNoAfterContext() {
        let text = "hello world"
        let (before, after) = AXContextReader.slice(fullText: text, caretUTF16Location: text.utf16.count, budget: 500)

        XCTAssertEqual(before, "hello world")
        XCTAssertNil(after)
    }

    func testEmptyTextYieldsNoContextEitherSide() {
        let (before, after) = AXContextReader.slice(fullText: "", caretUTF16Location: 0, budget: 500)

        XCTAssertNil(before)
        XCTAssertNil(after)
    }

    /// A caret location outside the text's actual bounds (stale/racing AX
    /// read) must not crash — it's clamped into range instead.
    func testOutOfBoundsCaretLocationIsClamped() {
        let text = "hello"

        let beforeStart = AXContextReader.slice(fullText: text, caretUTF16Location: -5, budget: 500)
        XCTAssertNil(beforeStart.before)
        XCTAssertEqual(beforeStart.after, "hello")

        let beforeEnd = AXContextReader.slice(fullText: text, caretUTF16Location: 999, budget: 500)
        XCTAssertEqual(beforeEnd.before, "hello")
        XCTAssertNil(beforeEnd.after)
    }

    // MARK: - Selection (MINOR 8)

    /// With text selected, that selection is what the dictation is about to
    /// replace. It belongs to neither side: "after" starts past it.
    func testSelectedTextIsExcludedFromTheAfterSide() {
        let text = "before[SELECTED]after"
        let caret = "before".utf16.count
        let selectionLength = "[SELECTED]".utf16.count

        let (before, after) = AXContextReader.slice(
            fullText: text,
            caretUTF16Location: caret,
            selectionLength: selectionLength,
            budget: 500
        )

        XCTAssertEqual(before, "before")
        XCTAssertEqual(after, "after", "the text about to be replaced must not be handed to the LLM as context")
    }

    func testASelectionRunningToTheEndLeavesNoAfterContext() {
        let text = "keep this selected"
        let caret = "keep this ".utf16.count

        let (before, after) = AXContextReader.slice(
            fullText: text,
            caretUTF16Location: caret,
            selectionLength: "selected".utf16.count,
            budget: 500
        )

        XCTAssertEqual(before, "keep this ")
        XCTAssertNil(after)
    }

    /// A selection longer than what is actually left in the text (a stale AX
    /// range) is clamped rather than trapping.
    func testOverlongSelectionIsClamped() {
        let (before, after) = AXContextReader.slice(
            fullText: "hello",
            caretUTF16Location: 2,
            selectionLength: 999,
            budget: 500
        )

        XCTAssertEqual(before, "he")
        XCTAssertNil(after)
    }

    // MARK: - Surrogate pairs (MINOR 7)

    /// The budget boundary can land between the two halves of an astral
    /// character. Cutting there and rebuilding the String turns the orphaned
    /// half into U+FFFD — a character that is not in the user's document at
    /// all, handed to the LLM as though it were.
    func testBudgetBoundarySplittingASurrogatePairDropsTheHalfInsteadOfCorruptingIt() {
        // "😀" is two UTF-16 units, so a budget of 3 starts the "before"
        // window one unit inside the middle emoji of three.
        let text = String(repeating: "😀", count: 3)

        let (before, _) = AXContextReader.slice(fullText: text, caretUTF16Location: text.utf16.count, budget: 3)

        XCTAssertEqual(before, "😀", "the split emoji must be dropped, not turned into U+FFFD")
        XCTAssertFalse(before?.unicodeScalars.contains("\u{FFFD}") ?? false)
    }

    func testTrailingSurrogateHalfIsDroppedFromTheAfterSide() {
        let text = String(repeating: "😀", count: 3)

        let (_, after) = AXContextReader.slice(fullText: text, caretUTF16Location: 0, budget: 3)

        XCTAssertEqual(after, "😀")
        XCTAssertFalse(after?.unicodeScalars.contains("\u{FFFD}") ?? false)
    }

    /// A window that is *only* half a surrogate pair has nothing left once
    /// that half is dropped, which reads as "no context" rather than as one
    /// replacement character.
    func testAWindowOfNothingButHalfASurrogatePairYieldsNoContext() {
        let (_, after) = AXContextReader.slice(fullText: "😀", caretUTF16Location: 0, budget: 1)

        XCTAssertNil(after)
    }
}

// MARK: - The decision closure is the gate (MINOR 13)

@MainActor
final class AXContextReaderGateTests: XCTestCase {

    /// Exercises the *real* `AXContextReader`, not the mock: when the
    /// caller's closure answers `false`, `capture` must return before it
    /// touches the Accessibility API at all. Needs no AX permission
    /// precisely because nothing should be attempted — which is what makes
    /// it runnable anywhere and worth having.
    func testAnswerOfFalseSuppressesTheReadEntirely() {
        let reader = AXContextReader()
        var wasAsked = false

        let captured = reader.capture(fallbackApplication: nil) { _ in
            wasAsked = true
            return false
        }

        XCTAssertTrue(wasAsked, "the gate must be consulted, not assumed")
        XCTAssertNil(captured.cursorContextBefore)
        XCTAssertNil(captured.cursorContextAfter)
    }

    /// The bundle identifier is captured unconditionally (Story 4.1), so a
    /// `false` answer must not suppress *that* too — and the gate must be
    /// asked about the same identifier the call ends up reporting.
    func testTheGateIsAskedAboutTheBundleIdentifierItWillReturn() {
        let reader = AXContextReader()
        var askedAbout: String??

        let captured = reader.capture(fallbackApplication: nil) { bundleIdentifier in
            askedAbout = .some(bundleIdentifier)
            return false
        }

        XCTAssertEqual(askedAbout ?? nil, captured.bundleIdentifier)
    }
}

// MARK: - The privacy assertion (AD-5)

@MainActor
final class CursorContextPrivacyTests: XCTestCase {

    /// A token distinctive enough that finding it anywhere it shouldn't be —
    /// a log line, an encoded History Record — is unambiguous.
    private let secretToken = "VOCAMAC_CURSOR_CONTEXT_PRIVACY_TEST_TOKEN_7f3a9c"

    private var previousLogLevel: LogLevel = .info

    override func setUp() {
        super.setUp()
        // MAJOR 6: the AC says Cursor Context is never passed to VocaLogger
        // "at any level", but the logger's default level is `.info`, which
        // drops `.debug` before it ever reaches the file this test reads. A
        // `.debug`-level leak therefore passed green. Lowering the level is
        // what makes this test capable of failing at all.
        previousLogLevel = VocaLogger.logLevel
        VocaLogger.setLogLevel(.debug)
    }

    override func tearDown() {
        VocaLogger.setLogLevel(previousLogLevel)
        super.tearDown()
    }

    func testCursorContextNeverReachesTheHistoryRecordOrTheLogFile() async throws {
        let profilesDirectory = makeTestStorageDirectory("privacy_profiles")
        let profilesFileStore = JSONFileStore<[Profile]>(
            fileName: "profiles.json",
            defaultValue: [],
            directoryURL: profilesDirectory,
            logCategory: .profiles
        )

        let postProcessService = MockPostProcessService()
        postProcessService.cleanResult = .success("שלום עולם")
        let stage = PostProcessStage(service: postProcessService, settingsProvider: {
            PostProcessSettings(isEnabled: true)
        })
        let pipeline = TranscriptPipeline(stages: [stage])
        let (appState, mocks) = AppState.makeTestState(
            transcriptPipelineOverride: pipeline,
            profileStore: ProfileStore(store: profilesFileStore)
        )

        appState.contextCaptureEnabled = true
        mocks.profileManager.resolvedProfile = Profile(name: "Editor", contextCaptureEnabled: true)
        mocks.contextReader.captureResult = CapturedContext(
            bundleIdentifier: "com.apple.TextEdit",
            cursorContextBefore: "before-\(secretToken)",
            cursorContextAfter: "after-\(secretToken)"
        )
        mocks.audioEngine.stopRecordingResult = [0.1, 0.2, 0.3]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "שלום עולם",
            duration: 1.0,
            detectedLanguage: "he",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny
        )

        await appState.startRecording()
        await appState.stopRecordingAndTranscribe()

        // Sanity check: the context really was captured and really did reach
        // the LLM request — otherwise the assertions below would pass for
        // the wrong reason (nothing to leak in the first place).
        XCTAssertEqual(postProcessService.lastContextBefore, "before-\(secretToken)")

        // 1) Never in the persisted History Record. HistoryRecord has no
        // field that could hold it (a schema constraint, AD-5) — this
        // confirms it holistically by encoding the actual recorded value and
        // searching the JSON text for the token.
        let record = try XCTUnwrap(mocks.historyStore.lastRecordedRecord)
        let recordData = try JSONEncoder().encode(record)
        let recordJSON = String(data: recordData, encoding: .utf8) ?? ""
        XCTAssertFalse(recordJSON.contains(secretToken), "Cursor Context leaked into the persisted History Record")

        // 2) Never in the log file — now genuinely at any level, since
        // `setUp` put the logger in `.debug` (MAJOR 6).
        VocaLogger.flush()
        let logLines = VocaLogger.readLastLines(2000)
        XCTAssertFalse(logLines.contains { $0.contains(secretToken) }, "Cursor Context leaked into the log file")

        // 3) Never in what the user would hand to someone else. `exportLogs`
        // is its own formatting path with its own header, and it is the copy
        // that actually leaves the machine (MAJOR 6).
        XCTAssertFalse(
            VocaLogger.exportLogs(lastLines: 2000).contains(secretToken),
            "Cursor Context leaked into exported logs"
        )

        // 4) Never on disk beside the Profiles. profiles.json is rewritten on
        // every store mutation and is the other file this feature touches.
        profilesFileStore.flush()
        if let profilesData = try? Data(contentsOf: profilesDirectory.appendingPathComponent("profiles.json")) {
            let profilesJSON = String(data: profilesData, encoding: .utf8) ?? ""
            XCTAssertFalse(profilesJSON.contains(secretToken), "Cursor Context leaked into profiles.json")
        }

        // 5) And nothing is still holding it now the run is over (BLOCKER 1).
        XCTAssertNil(appState.capturedContext)
    }
}

// MARK: - Retention on abort paths (BLOCKER 1, Story 4.4 AC)

/// "Released from memory immediately after the request" is an acceptance
/// criterion, not a nicety: what is held is up to 1000 characters read out of
/// whatever document the user was in, and `AppState` lives as long as the
/// process — so anything left there is reachable from a crash report, a
/// memory dump, or swap for the rest of the session.
///
/// The success path always cleared it. Every other way a dictation can end
/// did not, and each of these is an ordinary thing that happens to people: a
/// Bluetooth headset dropping mid-sentence, a laptop waking with a different
/// default input, a mistimed hotkey producing silence, a model that fails.
@MainActor
final class CursorContextRetentionTests: XCTestCase {

    private func makeStateMidRecording() async -> (AppState, TestMocks) {
        let (appState, mocks) = AppState.makeTestState()
        appState.contextCaptureEnabled = true
        mocks.profileManager.resolvedProfile = Profile(name: "Editor", contextCaptureEnabled: true)
        mocks.contextReader.captureResult = CapturedContext(
            bundleIdentifier: "com.apple.TextEdit",
            cursorContextBefore: "confidential paragraph before the caret",
            cursorContextAfter: "confidential paragraph after the caret"
        )
        mocks.audioEngine.stopRecordingResult = [0.1, 0.2, 0.3]
        mocks.whisperService.mockTranscriptionResult = VocaTranscription(
            text: "שלום עולם",
            duration: 1.0,
            detectedLanguage: "he",
            audioLengthSeconds: 1.0,
            modelUsed: .tiny
        )
        await appState.startRecording()
        return (appState, mocks)
    }

    /// Guards the guard: if capture ever stopped happening, every assertion
    /// below would pass for the wrong reason.
    func testTheFixtureReallyDoesCaptureContext() async {
        let (appState, _) = await makeStateMidRecording()

        XCTAssertNotNil(appState.capturedContext?.cursorContextBefore)
        XCTAssertNotNil(appState.capturedProfile)
    }

    func testForceRecoveryDiscardsCapturedContext() async {
        let (appState, mocks) = await makeStateMidRecording()

        appState.forceRecovery()

        XCTAssertNil(appState.capturedContext)
        XCTAssertNil(appState.capturedProfile)
        XCTAssertEqual(mocks.correctionLearner.cancelPendingObservationCallCount, 1)
    }

    /// The mic unplugged, the Bluetooth headset dropped, or the machine woke
    /// with a different default input. `AudioEngine` has already stopped and
    /// reset itself; `AppState` recovers — and must let go of what it read.
    func testAudioDeviceChangeDiscardsCapturedContext() async throws {
        let (appState, mocks) = await makeStateMidRecording()

        mocks.audioEngine.onAudioDeviceChanged?()
        await Task.yield()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(appState.capturedContext)
        XCTAssertNil(appState.capturedProfile)
        XCTAssertEqual(appState.appStatus, .idle)
    }

    /// The audio engine refused to start: nothing was ever recorded, so
    /// nothing will ever consume the capture made a few lines earlier.
    func testFailedAudioEngineStartDiscardsCapturedContext() async {
        let (appState, mocks) = AppState.makeTestState()
        appState.contextCaptureEnabled = true
        mocks.profileManager.resolvedProfile = Profile(name: "Editor", contextCaptureEnabled: true)
        mocks.contextReader.captureResult = CapturedContext(
            bundleIdentifier: "com.apple.TextEdit",
            cursorContextBefore: "confidential paragraph before the caret",
            cursorContextAfter: nil
        )
        mocks.audioEngine.startRecordingResult = false

        await appState.startRecording()

        XCTAssertNil(appState.capturedContext)
        XCTAssertNil(appState.capturedProfile)
        XCTAssertEqual(appState.appStatus, .idle)
    }

    /// Recording started and stopped, but the buffer came back empty — the
    /// pipeline never runs, so the success path's clear never happens.
    func testEmptyAudioDiscardsCapturedContext() async {
        let (appState, mocks) = await makeStateMidRecording()
        mocks.audioEngine.stopRecordingResult = []

        await appState.stopRecordingAndTranscribe()

        XCTAssertNil(appState.capturedContext)
        XCTAssertNil(appState.capturedProfile)
    }

    /// ASR threw. The capture is consumed *after* transcription on the happy
    /// path, so a throw skips the clear entirely.
    func testTranscriptionFailureDiscardsCapturedContext() async {
        let (appState, mocks) = await makeStateMidRecording()
        mocks.whisperService.shouldThrow = true

        await appState.stopRecordingAndTranscribe()

        XCTAssertNil(appState.capturedContext)
        XCTAssertNil(appState.capturedProfile)
    }

    /// The path that always worked, asserted here too so a future change
    /// cannot quietly move the clear off it.
    func testSuccessfulDictationStillDiscardsCapturedContext() async {
        let (appState, _) = await makeStateMidRecording()

        await appState.stopRecordingAndTranscribe()

        XCTAssertNil(appState.capturedContext)
        XCTAssertNil(appState.capturedProfile)
    }
}
