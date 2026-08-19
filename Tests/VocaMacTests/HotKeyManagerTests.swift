// HotKeyManagerTests.swift
// VocaMac
//
// Tests for HotKeyManager configuration and state logic.

import XCTest
@testable import VocaMac

// MARK: - HotKeyManager Configuration Tests

final class HotKeyManagerConfigurationTests: XCTestCase {

    func testDefaultState() {
        let manager = HotKeyManager()

        XCTAssertFalse(manager.isListening, "Should not be listening initially")
        XCTAssertNil(manager.eventTap, "Should have no event tap initially")
    }

    func testUpdateConfigurationKeyCode() {
        let manager = HotKeyManager()

        manager.updateConfiguration(keyCode: 58) // Left Option
        // Configuration should be accepted without crashing
        // (keyCode is private, but the method should not throw)
    }

    func testUpdateConfigurationMode() {
        let manager = HotKeyManager()

        manager.updateConfiguration(mode: .doubleTapToggle)
        manager.updateConfiguration(mode: .pushToTalk)
        // Both modes should be accepted without issues
    }

    func testUpdateConfigurationDoubleTapThreshold() {
        let manager = HotKeyManager()

        manager.updateConfiguration(doubleTapThreshold: 0.3)
        manager.updateConfiguration(doubleTapThreshold: 0.5)
        manager.updateConfiguration(doubleTapThreshold: 1.0)
    }

    func testUpdateConfigurationSafetyTimeout() {
        let manager = HotKeyManager()

        manager.updateConfiguration(safetyTimeout: 30.0)
        manager.updateConfiguration(safetyTimeout: 65.0)
    }

    func testUpdateConfigurationMultipleParams() {
        let manager = HotKeyManager()

        // Should accept multiple parameters at once
        manager.updateConfiguration(
            keyCode: 55,
            mode: .doubleTapToggle,
            doubleTapThreshold: 0.5,
            safetyTimeout: 120.0
        )
    }

    func testUpdateConfigurationNilParams() {
        let manager = HotKeyManager()

        // Nil parameters should leave existing values unchanged
        manager.updateConfiguration(keyCode: nil, mode: nil, doubleTapThreshold: nil, safetyTimeout: nil)
        // Should not crash
    }

    func testCallbacksInitiallyNil() {
        let manager = HotKeyManager()

        XCTAssertNil(manager.onRecordingStart, "onRecordingStart should be nil initially")
        XCTAssertNil(manager.onRecordingStop, "onRecordingStop should be nil initially")
    }

    func testCallbacksCanBeSet() {
        let manager = HotKeyManager()
        var startCalled = false
        var stopCalled = false

        manager.onRecordingStart = { startCalled = true }
        manager.onRecordingStop = { stopCalled = true }

        manager.onRecordingStart?()
        manager.onRecordingStop?()

        XCTAssertTrue(startCalled, "Start callback should be invokable")
        XCTAssertTrue(stopCalled, "Stop callback should be invokable")
    }

    func testStopListeningWithoutStarting() {
        let manager = HotKeyManager()

        // Should not crash when stopping without having started
        manager.stopListening()
        XCTAssertFalse(manager.isListening)
    }

    func testStopListeningIdempotent() {
        let manager = HotKeyManager()

        manager.stopListening()
        manager.stopListening()
        manager.stopListening()
        XCTAssertFalse(manager.isListening)
    }

    func testRegularKeyAutoRepeatDoesNotStopPushToTalk() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 0, mode: .pushToTalk, safetyTimeout: 5.0)

        let startExpectation = expectation(description: "Recording starts once")
        let stopExpectation = expectation(description: "Auto-repeat should not stop recording")
        stopExpectation.isInverted = true

        var startCount = 0
        manager.onRecordingStart = {
            startCount += 1
            startExpectation.fulfill()
        }
        manager.onRecordingStop = {
            stopExpectation.fulfill()
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let repeatedKeyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        else {
            throw XCTSkip("Could not create keyboard events")
        }
        markAsExternal(keyDown)
        markAsExternal(repeatedKeyDown)
        repeatedKeyDown.setIntegerValueField(.keyboardEventAutorepeat, value: 1)

        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: keyDown))
        wait(for: [startExpectation], timeout: 1.0)

        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: repeatedKeyDown))
        wait(for: [stopExpectation], timeout: 0.1)
        XCTAssertEqual(startCount, 1)
        manager.resetKeyState()
    }

    func testTargetRegularKeyEventsAreConsumed() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 0, mode: .pushToTalk, safetyTimeout: 5.0)

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else {
            throw XCTSkip("Could not create keyboard events")
        }
        markAsExternal(keyDown)
        markAsExternal(keyUp)

        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: keyDown))
        XCTAssertTrue(manager._handleTestEvent(type: .keyUp, event: keyUp))
        manager.resetKeyState()
    }

    func testNonTargetRegularKeyEventsPassThrough() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 0, mode: .pushToTalk)

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 1, keyDown: true) else {
            throw XCTSkip("Could not create keyboard event")
        }
        markAsExternal(keyDown)

        XCTAssertFalse(manager._handleTestEvent(type: .keyDown, event: keyDown))
    }

    func testTargetModifierEventIsConsumed() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 61, mode: .pushToTalk, safetyTimeout: 5.0)

        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: true) else {
            throw XCTSkip("Could not create keyboard event")
        }
        markAsExternal(event)
        event.flags = .maskAlternate

        XCTAssertTrue(manager._handleTestEvent(type: .flagsChanged, event: event))
        manager.resetKeyState()
    }

    func testModifierReleaseStopsWhenSiblingModifierStillHeld() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 61, mode: .pushToTalk, safetyTimeout: 5.0)

        let startExpectation = expectation(description: "Recording starts")
        let stopExpectation = expectation(description: "Recording stops")

        manager.onRecordingStart = {
            startExpectation.fulfill()
        }
        manager.onRecordingStop = {
            stopExpectation.fulfill()
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: false)
        else {
            throw XCTSkip("Could not create modifier events")
        }
        markAsExternal(keyDown)
        markAsExternal(keyUp)
        keyDown.flags = .maskAlternate
        keyUp.flags = .maskAlternate

        XCTAssertTrue(manager._handleTestEvent(type: .flagsChanged, event: keyDown))
        wait(for: [startExpectation], timeout: 1.0)

        XCTAssertTrue(manager._handleTestEvent(type: .flagsChanged, event: keyUp))
        wait(for: [stopExpectation], timeout: 1.0)
        manager.resetKeyState()
    }

    func testModifierReleaseWithSiblingModifierHeldDoesNotCountAsDoubleTap() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 61, mode: .doubleTapToggle, doubleTapThreshold: 1.0)

        let startExpectation = expectation(description: "Modifier release should not start recording")
        startExpectation.isInverted = true
        manager.onRecordingStart = {
            startExpectation.fulfill()
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: false)
        else {
            throw XCTSkip("Could not create modifier events")
        }
        markAsExternal(keyDown)
        markAsExternal(keyUp)
        keyDown.flags = .maskAlternate
        keyUp.flags = .maskAlternate

        XCTAssertTrue(manager._handleTestEvent(type: .flagsChanged, event: keyDown))

        let releaseDelay = expectation(description: "Release after double-tap minimum interval")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            releaseDelay.fulfill()
        }
        wait(for: [releaseDelay], timeout: 1.0)

        XCTAssertTrue(manager._handleTestEvent(type: .flagsChanged, event: keyUp))
        wait(for: [startExpectation], timeout: 0.15)
        manager.resetKeyState()
    }

    func testSelfGeneratedEventsPassThrough() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 9, mode: .pushToTalk)

        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true) else {
            throw XCTSkip("Could not create keyboard event")
        }

        XCTAssertFalse(manager._handleTestEvent(type: .keyDown, event: event))
    }

    private func markAsExternal(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
    }
}

// MARK: - Second Binding (Story 6.1)
//
// The dictation binding's behaviour is pinned by the tests above and must not
// change; everything here is about the *second* binding existing alongside it
// on the same tap, with its own callbacks and its own state (R-5).

final class HotKeyManagerCommandBindingTests: XCTestCase {

    /// Dictation on key 0, Command Mode on key 1, both push-to-talk, both
    /// with a safety timeout long enough not to fire during a test.
    private func makeManager() -> HotKeyManager {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 0, mode: .pushToTalk, safetyTimeout: 5.0)
        manager.updateCommandConfiguration(keyCode: 1, mode: .pushToTalk, safetyTimeout: 5.0, isEnabled: true)
        return manager
    }

    private func makeEvent(keyCode: Int, keyDown: Bool) throws -> CGEvent {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: keyDown) else {
            throw XCTSkip("Could not create keyboard event")
        }
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return event
    }

    func testCommandBindingIsDisabledUntilConfigured() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 0, mode: .pushToTalk, safetyTimeout: 5.0)

        let commandStart = expectation(description: "A disabled command binding fires nothing")
        commandStart.isInverted = true
        manager.onCommandStart = { commandStart.fulfill() }

        // Key 54 is the shipped Command Mode default — with the binding off it
        // must be an ordinary key that passes straight through to the app.
        let event = try makeEvent(keyCode: 54, keyDown: true)
        XCTAssertFalse(manager._handleTestEvent(type: .keyDown, event: event))
        wait(for: [commandStart], timeout: 0.15)
    }

    func testEachBindingFiresOnlyItsOwnCallbacks() throws {
        let manager = makeManager()

        let dictationStart = expectation(description: "Dictation starts")
        let commandStart = expectation(description: "Command starts")
        let dictationStartedByCommandKey = expectation(description: "The command key must not start dictation")
        dictationStartedByCommandKey.isInverted = true
        let commandStartedByDictationKey = expectation(description: "The dictation key must not start a command")
        commandStartedByDictationKey.isInverted = true

        var sawDictationKey = false
        manager.onRecordingStart = {
            if sawDictationKey {
                dictationStart.fulfill()
            } else {
                dictationStartedByCommandKey.fulfill()
            }
        }
        var sawCommandKey = false
        manager.onCommandStart = {
            if sawCommandKey {
                commandStart.fulfill()
            } else {
                commandStartedByDictationKey.fulfill()
            }
        }

        sawDictationKey = true
        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: try makeEvent(keyCode: 0, keyDown: true)))
        wait(for: [dictationStart], timeout: 1.0)
        XCTAssertTrue(manager._handleTestEvent(type: .keyUp, event: try makeEvent(keyCode: 0, keyDown: false)))
        sawDictationKey = false

        sawCommandKey = true
        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: try makeEvent(keyCode: 1, keyDown: true)))
        wait(for: [commandStart], timeout: 1.0)
        XCTAssertTrue(manager._handleTestEvent(type: .keyUp, event: try makeEvent(keyCode: 1, keyDown: false)))

        wait(for: [dictationStartedByCommandKey, commandStartedByDictationKey], timeout: 0.15)
        manager.resetKeyState()
    }

    /// Interleaved: the command key goes down while dictation is still held,
    /// and each release must stop its own binding, not the other.
    func testInterleavedPressesKeepSeparateState() throws {
        let manager = makeManager()

        let dictationStart = expectation(description: "Dictation starts")
        let dictationStop = expectation(description: "Dictation stops")
        let commandStart = expectation(description: "Command starts")
        let commandStop = expectation(description: "Command stops")

        manager.onRecordingStart = { dictationStart.fulfill() }
        manager.onRecordingStop = { dictationStop.fulfill() }
        manager.onCommandStart = { commandStart.fulfill() }
        manager.onCommandStop = { commandStop.fulfill() }

        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: try makeEvent(keyCode: 0, keyDown: true)))
        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: try makeEvent(keyCode: 1, keyDown: true)))
        wait(for: [dictationStart, commandStart], timeout: 1.0)

        XCTAssertTrue(manager._handleTestEvent(type: .keyUp, event: try makeEvent(keyCode: 1, keyDown: false)))
        wait(for: [commandStop], timeout: 1.0)

        XCTAssertTrue(manager._handleTestEvent(type: .keyUp, event: try makeEvent(keyCode: 0, keyDown: false)))
        wait(for: [dictationStop], timeout: 1.0)
        manager.resetKeyState()
    }

    /// The recovery key-down (a key-up that macOS dropped) has to work on the
    /// command binding exactly as it does on dictation, and must not disturb
    /// the other binding's held state.
    func testStuckKeyRecoveryIsPerBinding() throws {
        let manager = makeManager()

        let commandStart = expectation(description: "Command starts")
        let commandStop = expectation(description: "Second command key-down forces a stop")
        let dictationStop = expectation(description: "Dictation must not be stopped by the command key")
        dictationStop.isInverted = true

        manager.onCommandStart = { commandStart.fulfill() }
        manager.onCommandStop = { commandStop.fulfill() }
        manager.onRecordingStop = { dictationStop.fulfill() }

        // Dictation held down throughout.
        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: try makeEvent(keyCode: 0, keyDown: true)))

        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: try makeEvent(keyCode: 1, keyDown: true)))
        wait(for: [commandStart], timeout: 1.0)

        // No key-up in between: this is the dropped-event recovery path.
        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: try makeEvent(keyCode: 1, keyDown: true)))
        wait(for: [commandStop], timeout: 1.0)
        wait(for: [dictationStop], timeout: 0.15)
        manager.resetKeyState()
    }

    func testCommandBindingRefusesTheDictationKeyCode() throws {
        let manager = makeManager()

        let commandStart = expectation(description: "A colliding command binding fires nothing")
        commandStart.isInverted = true
        let dictationStart = expectation(description: "Dictation still owns its key")
        manager.onCommandStart = { commandStart.fulfill() }
        manager.onRecordingStart = { dictationStart.fulfill() }

        manager.updateCommandConfiguration(keyCode: 0, isEnabled: true)

        XCTAssertTrue(manager._handleTestEvent(type: .keyDown, event: try makeEvent(keyCode: 0, keyDown: true)))
        wait(for: [dictationStart], timeout: 1.0)
        wait(for: [commandStart], timeout: 0.15)
        manager.resetKeyState()
    }

    func testDisablingTheCommandBindingStopsItFiring() throws {
        let manager = makeManager()

        let commandStart = expectation(description: "A disabled binding fires nothing")
        commandStart.isInverted = true
        manager.onCommandStart = { commandStart.fulfill() }

        manager.updateCommandConfiguration(isEnabled: false)

        XCTAssertFalse(manager._handleTestEvent(type: .keyDown, event: try makeEvent(keyCode: 1, keyDown: true)))
        wait(for: [commandStart], timeout: 0.15)
    }

    /// Modifier bindings are the realistic configuration (Right Option for
    /// dictation, Right Command for Command Mode) and take a different path
    /// through the state machine than regular keys.
    func testModifierKeysDriveTheTwoBindingsIndependently() throws {
        let manager = HotKeyManager()
        manager.updateConfiguration(keyCode: 61, mode: .pushToTalk, safetyTimeout: 5.0)  // Right Option
        manager.updateCommandConfiguration(keyCode: 54, mode: .pushToTalk, safetyTimeout: 5.0, isEnabled: true)  // Right Command

        let commandStart = expectation(description: "Command starts on Right Command")
        let commandStop = expectation(description: "Command stops on Right Command release")
        let dictationStart = expectation(description: "Right Command must not start dictation")
        dictationStart.isInverted = true

        manager.onCommandStart = { commandStart.fulfill() }
        manager.onCommandStop = { commandStop.fulfill() }
        manager.onRecordingStart = { dictationStart.fulfill() }

        let down = try makeEvent(keyCode: 54, keyDown: true)
        down.flags = .maskCommand
        let up = try makeEvent(keyCode: 54, keyDown: false)
        up.flags = .maskCommand

        XCTAssertTrue(manager._handleTestEvent(type: .flagsChanged, event: down))
        wait(for: [commandStart], timeout: 1.0)

        XCTAssertTrue(manager._handleTestEvent(type: .flagsChanged, event: up))
        wait(for: [commandStop], timeout: 1.0)
        wait(for: [dictationStart], timeout: 0.15)
        manager.resetKeyState()
    }
}

// MARK: - HotKeyManager Reset State Tests

final class HotKeyManagerResetStateTests: XCTestCase {

    func testResetKeyStateDoesNotCrash() {
        // resetKeyState should be safe to call in any state
        let manager = HotKeyManager()
        manager.resetKeyState()
        // No crash = pass
    }

    func testResetKeyStateMultipleTimes() {
        // Calling resetKeyState multiple times should be safe
        let manager = HotKeyManager()
        manager.resetKeyState()
        manager.resetKeyState()
        manager.resetKeyState()
        // No crash = pass
    }

}
