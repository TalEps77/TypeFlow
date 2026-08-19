// CursorContextTests.swift
// VocaMac Tests
//
// Story 4.4: budget truncation (pure logic, no AX permission needed), and
// the privacy assertion AD-5 requires — Cursor Context must never reach a
// log line or a persisted History Record.

import XCTest
@testable import VocaMac

// MARK: - Budget truncation (AXContextReader.slice — pure, no AX call)

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
}

// MARK: - The privacy assertion (AD-5)

@MainActor
final class CursorContextPrivacyTests: XCTestCase {

    /// A token distinctive enough that finding it anywhere it shouldn't be —
    /// a log line, an encoded History Record — is unambiguous.
    private let secretToken = "VOCAMAC_CURSOR_CONTEXT_PRIVACY_TEST_TOKEN_7f3a9c"

    func testCursorContextNeverReachesTheHistoryRecordOrTheLogFile() async throws {
        defer { UserDefaults.standard.removeObject(forKey: "vocamac.contextCapture.enabled") }

        let postProcessService = MockPostProcessService()
        postProcessService.cleanResult = .success("שלום עולם")
        let stage = PostProcessStage(service: postProcessService, settingsProvider: {
            PostProcessSettings(isEnabled: true)
        })
        let pipeline = TranscriptPipeline(stages: [stage])
        let (appState, mocks) = AppState.makeTestState(transcriptPipelineOverride: pipeline)

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

        // 2) Never in the log file, at any level.
        VocaLogger.flush()
        let logLines = VocaLogger.readLastLines(2000)
        XCTAssertFalse(logLines.contains { $0.contains(secretToken) }, "Cursor Context leaked into the log file")
    }
}
