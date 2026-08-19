// HotKeyManager.swift
// VocaMac
//
// Listens for global hotkey events using CGEventTap.
// Supports push-to-talk (hold key) and double-tap toggle modes.
//
// Story 6.1 added a second binding for Command Mode. It shares this one tap —
// no second `CGEvent.tapCreate` exists anywhere in the app — and is exposed
// through its own `onCommand*` callbacks rather than by teaching the existing
// state machine to serve two masters (R-5). That state machine now lives in
// `HotKeyBinding`, instantiated twice; this type is the tap, the permission
// check, and the dispatcher.

import Foundation
import AppKit
import Carbon.HIToolbox

final class HotKeyManager {

    // MARK: - Properties

    /// Event tap Mach port
    private(set) var eventTap: CFMachPort?

    /// Run loop source for the event tap
    private var runLoopSource: CFRunLoopSource?

    /// Whether the event tap is currently active
    private(set) var isListening = false

    /// The dictation binding — the one that existed before Story 6.1. Every
    /// pre-existing entry point on this type (`startListening`,
    /// `updateConfiguration`, `resetKeyState`, `onRecordingStart/Stop`) drives
    /// this and only this, so dictation behaves exactly as it did.
    private let dictationBinding = HotKeyBinding(label: "dictation", keyCode: 61)  // Right Option

    /// The Command Mode binding (Story 6.1). Disabled until
    /// `updateCommandConfiguration(...)` turns it on, so an app that never
    /// enables Command Mode dispatches exactly as it did before.
    private let commandBinding = HotKeyBinding(
        label: "command",
        keyCode: CommandModeSettings.Default.hotKeyCode,
        isEnabled: false
    )

    // MARK: - Callbacks

    /// Called when recording should start
    var onRecordingStart: (() -> Void)? {
        get { dictationBinding.onStart }
        set { dictationBinding.onStart = newValue }
    }

    /// Called when recording should stop
    var onRecordingStop: (() -> Void)? {
        get { dictationBinding.onStop }
        set { dictationBinding.onStop = newValue }
    }

    /// Called when the Command Mode gesture begins (Story 6.1).
    var onCommandStart: (() -> Void)? {
        get { commandBinding.onStart }
        set { commandBinding.onStart = newValue }
    }

    /// Called when the Command Mode gesture ends (Story 6.1).
    var onCommandStop: (() -> Void)? {
        get { commandBinding.onStop }
        set { commandBinding.onStop = newValue }
    }

    // MARK: - Accessibility Permission

    /// Check if the app has Accessibility permission
    /// - Parameter prompt: Whether to show the system prompt if not trusted
    /// - Returns: true if the app is trusted for Accessibility
    static func checkAccessibilityPermission(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Lifecycle

    /// Start listening for global hotkey events
    /// - Parameters:
    ///   - keyCode: The virtual key code to listen for (default: 61 = Right Option)
    ///   - mode: The activation mode (push-to-talk or double-tap toggle)
    ///   - doubleTapThreshold: Time window for double-tap detection (seconds)
    ///   - safetyTimeout: Maximum seconds before the safety timer forces a key-up
    ///     in push-to-talk mode. Should be slightly longer than the app's max
    ///     recording duration so AudioEngine's own limit fires first. The safety
    ///     timer is a last-resort backstop for when a key-up event is lost entirely.
    func startListening(
        keyCode: Int = 61,
        mode: ActivationMode = .pushToTalk,
        doubleTapThreshold: Double = 0.4,
        safetyTimeout: Double = 65.0
    ) {
        guard !isListening else {
            VocaLogger.debug(.hotKeyManager, "Already listening")
            return
        }

        dictationBinding.configure(
            keyCode: keyCode,
            mode: mode,
            doubleTapThreshold: doubleTapThreshold,
            safetyTimeout: safetyTimeout
        )

        // Create event tap for key events and flags changed (modifier keys)
        let eventMask: CGEventMask = (
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        )

        // We need to pass `self` as a raw pointer to the C callback
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: HotKeyManager.eventTapCallback,
            userInfo: userInfo
        ) else {
            VocaLogger.error(.hotKeyManager, "FAILED to create event tap! Check Accessibility & Input Monitoring permissions.")
            return
        }

        self.eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        isListening = true
        VocaLogger.info(.hotKeyManager, "Event tap created successfully. Listening for keyCode \(keyCode) in \(mode.rawValue) mode")
    }

    /// Stop listening for global hotkey events
    func stopListening() {
        guard isListening else { return }

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil
        isListening = false
        dictationBinding.resetState()
        commandBinding.resetState()

        VocaLogger.info(.hotKeyManager, "Stopped listening")
    }

    /// Reset internal key tracking state without stopping the listener.
    /// Used when the app forcibly recovers from a stuck recording state
    /// (e.g., after an audio device change) so that the next keypress
    /// is treated as a fresh key-down rather than a recovery key-down.
    func resetKeyState() {
        dictationBinding.resetState()
        commandBinding.resetState()
        VocaLogger.debug(.hotKeyManager, "Key state reset")
    }

    /// Update the configuration while listening
    /// - Parameters:
    ///   - keyCode: New key code to listen for
    ///   - mode: New activation mode
    ///   - doubleTapThreshold: New double-tap detection window (seconds)
    ///   - safetyTimeout: New safety timer duration (seconds). Should be
    ///     `maxRecordingDuration + 5` to act as a backstop after AudioEngine's
    ///     own max-duration callback.
    func updateConfiguration(
        keyCode: Int? = nil,
        mode: ActivationMode? = nil,
        doubleTapThreshold: Double? = nil,
        safetyTimeout: Double? = nil
    ) {
        dictationBinding.updateConfiguration(
            keyCode: keyCode,
            mode: mode,
            doubleTapThreshold: doubleTapThreshold,
            safetyTimeout: safetyTimeout
        )
    }

    /// Configure the Command Mode binding (Story 6.1). Separate from
    /// `updateConfiguration` on purpose: the two bindings are configured
    /// independently, and no argument here can reach the dictation binding.
    ///
    /// A command binding sharing the dictation key code is refused rather than
    /// stored. The Settings UI rejects the collision first (Story 6.1 AC), so
    /// reaching this means a hand-edited or migrated preference — and the safe
    /// resolution is the one that leaves dictation, the load-bearing path,
    /// exactly as it was.
    func updateCommandConfiguration(
        keyCode: Int? = nil,
        mode: ActivationMode? = nil,
        doubleTapThreshold: Double? = nil,
        safetyTimeout: Double? = nil,
        isEnabled: Bool? = nil
    ) {
        if let keyCode, keyCode == dictationBinding.targetKeyCode {
            VocaLogger.warning(.hotKeyManager, "Command binding requested the dictation key code (\(keyCode)) — refusing the key and disabling Command Mode")
            // Only the key is refused (MINOR 6). The activation mode, the
            // double-tap threshold and the safety timeout arrive in this same
            // call — the timeout is derived from `maxRecordingDuration`, which
            // has nothing to do with the collision — and dropping them left the
            // binding on stale values that would come back the moment the key
            // was fixed.
            commandBinding.updateConfiguration(
                mode: mode,
                doubleTapThreshold: doubleTapThreshold,
                safetyTimeout: safetyTimeout,
                isEnabled: false
            )
            commandBinding.resetState()
            return
        }

        commandBinding.updateConfiguration(
            keyCode: keyCode,
            mode: mode,
            doubleTapThreshold: doubleTapThreshold,
            safetyTimeout: safetyTimeout,
            isEnabled: isEnabled
        )
        if isEnabled == false {
            commandBinding.resetState()
        }
    }

    // MARK: - Event Tap Callback

    /// Static C callback for CGEventTap — dispatches to the instance method
    private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, userInfo in
        guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }

        let manager = Unmanaged<HotKeyManager>.fromOpaque(userInfo).takeUnretainedValue()

        // Handle tap being disabled (system can disable taps if they're too slow)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = manager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let shouldConsumeEvent = manager.handleEvent(type: type, event: event)
        if shouldConsumeEvent {
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Event Handling

    /// Handle an incoming key event
    /// - Returns: `true` when the event belongs to one of the configured
    ///   hotkeys and should be consumed so it doesn't also affect the
    ///   frontmost app.
    ///
    /// Dictation is offered the event first and the command binding only sees
    /// what dictation did not consume. With distinct key codes — which is what
    /// the settings UI and `updateCommandConfiguration` both enforce — the
    /// order is immaterial, since each binding ignores every key but its own.
    /// It matters only for the one case neither guard can prevent (a key code
    /// changed underneath us mid-gesture), where "dictation wins" is the
    /// behaviour that cannot regress the existing path.
    private func handleEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard !isSelfGeneratedEvent(event) else { return false }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if dictationBinding.handle(type: type, keyCode: keyCode, event: event) {
            return true
        }
        return commandBinding.handle(type: type, keyCode: keyCode, event: event)
    }

    private func isSelfGeneratedEvent(_ event: CGEvent) -> Bool {
        let eventPID = event.getIntegerValueField(.eventSourceUnixProcessID)
        return eventPID == Int64(ProcessInfo.processInfo.processIdentifier)
    }

    // MARK: - Deinit

    deinit {
        stopListening()
    }
}

// MARK: - HotKeyMonitoring Conformance

extension HotKeyManager: HotKeyMonitoring {
    func checkAccessibilityPermission(prompt: Bool) -> Bool {
        Self.checkAccessibilityPermission(prompt: prompt)
    }

    func _updateConfiguration(keyCode: Int?, mode: ActivationMode?, doubleTapThreshold: Double?, safetyTimeout: Double?) {
        updateConfiguration(keyCode: keyCode, mode: mode, doubleTapThreshold: doubleTapThreshold, safetyTimeout: safetyTimeout)
    }

    func _updateCommandConfiguration(keyCode: Int?, mode: ActivationMode?, doubleTapThreshold: Double?, safetyTimeout: Double?, isEnabled: Bool?) {
        updateCommandConfiguration(
            keyCode: keyCode,
            mode: mode,
            doubleTapThreshold: doubleTapThreshold,
            safetyTimeout: safetyTimeout,
            isEnabled: isEnabled
        )
    }
}

// MARK: - Test Support

extension HotKeyManager {
    /// Exercise event handling without installing a process-wide event tap.
    func _handleTestEvent(type: CGEventType, event: CGEvent) -> Bool {
        handleEvent(type: type, event: event)
    }
}

// MARK: - Common Key Codes Reference

/// Reference for common macOS virtual key codes
/// Used for hotkey configuration UI
enum KeyCodeReference {
    static let escapeKeyCode = 53

    static let commonHotKeys: [(name: String, keyCode: Int)] = [
        ("Right Option (⌥)", 61),
        ("Left Option (⌥)", 58),
        ("Right Command (⌘)", 54),
        ("Right Shift (⇧)", 60),
        ("Right Control (⌃)", 62),
        ("Fn", 63),
        ("F5", 96),
        ("F6", 97),
        ("F7", 98),
        ("F8", 100),
        ("F9", 101),
        ("F10", 109),
        ("F11", 103),
        ("F12", 111),
    ]

    private static let namedKeyCodes: [Int: String] = [
        36: "Return",
        48: "Tab",
        49: "Space",
        51: "Delete",
        53: "Escape",
        54: "Right Command (⌘)",
        55: "Left Command (⌘)",
        56: "Left Shift (⇧)",
        57: "Caps Lock",
        58: "Left Option (⌥)",
        59: "Left Control (⌃)",
        60: "Right Shift (⇧)",
        61: "Right Option (⌥)",
        62: "Right Control (⌃)",
        63: "Fn",
        64: "F17",
        65: "Keypad .",
        67: "Keypad *",
        69: "Keypad +",
        71: "Clear",
        75: "Keypad /",
        76: "Keypad Enter",
        78: "Keypad -",
        79: "F18",
        80: "F19",
        81: "Keypad =",
        82: "Keypad 0",
        83: "Keypad 1",
        84: "Keypad 2",
        85: "Keypad 3",
        86: "Keypad 4",
        87: "Keypad 5",
        88: "Keypad 6",
        89: "Keypad 7",
        90: "F20",
        91: "Keypad 8",
        92: "Keypad 9",
        96: "F5",
        97: "F6",
        98: "F7",
        99: "F3",
        100: "F8",
        101: "F9",
        103: "F11",
        105: "F13",
        106: "F16",
        107: "F14",
        109: "F10",
        111: "F12",
        113: "F15",
        114: "Help",
        115: "Home",
        116: "Page Up",
        117: "Forward Delete",
        118: "F4",
        119: "End",
        120: "F2",
        121: "Page Down",
        122: "F1",
        123: "Left Arrow",
        124: "Right Arrow",
        125: "Down Arrow",
        126: "Up Arrow",
    ]

    /// Get the display name for a key code
    static func displayName(for keyCode: Int) -> String {
        commonHotKeys.first(where: { $0.keyCode == keyCode })?.name
            ?? namedKeyCodes[keyCode]
            ?? displayCharacter(for: keyCode)
            ?? "Key \(keyCode)"
    }

    /// Whether this key code is included in the curated preset list.
    static func isCommonHotKey(_ keyCode: Int) -> Bool {
        commonHotKeys.contains(where: { $0.keyCode == keyCode })
    }

    /// Whether this key code represents a modifier key that emits flagsChanged events.
    static func isModifierKeyCode(_ keyCode: Int) -> Bool {
        switch keyCode {
        case 54, 55, 56, 58, 59, 60, 61, 62, 63:
            return true
        default:
            return false
        }
    }

    private static func displayCharacter(for keyCode: Int) -> String? {
        let inputSource: TISInputSource? = {
            if let asciiSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
                return asciiSource
            }
            return TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        }()

        guard let source = inputSource,
              let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else {
            return fallbackDisplayCharacter(for: keyCode)
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> String? in
            guard let baseAddress = rawBuffer.baseAddress else {
                return fallbackDisplayCharacter(for: keyCode)
            }

            let keyboardLayout = baseAddress.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            let maxStringLength = 4
            var actualStringLength = 0
            var unicodeString = [UniChar](repeating: 0, count: maxStringLength)

            let status = UCKeyTranslate(
                keyboardLayout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                maxStringLength,
                &actualStringLength,
                &unicodeString
            )

            guard status == noErr, actualStringLength > 0 else {
                return fallbackDisplayCharacter(for: keyCode)
            }

            let produced = String(utf16CodeUnits: unicodeString, count: actualStringLength)
            guard produced.rangeOfCharacter(from: .controlCharacters) == nil else {
                return fallbackDisplayCharacter(for: keyCode)
            }

            return produced.count == 1 ? produced.uppercased() : produced
        }
    }

    private static func fallbackDisplayCharacter(for keyCode: Int) -> String? {
        let qwertyNames: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G",
            6: "Z", 7: "X", 8: "C", 9: "V", 11: "B",
            12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
            24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
            37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
            43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
        ]

        return qwertyNames[keyCode]
    }
}
