// HotKeyBinding.swift
// VocaMac
//
// One hotkey's state machine: which key it watches, whether it is held or
// toggled, its double-tap window, its stuck-key safety timer, and the two
// callbacks it fires. Extracted verbatim from HotKeyManager so a second
// binding (Story 6.1, Command Mode) can exist without a second CGEventTap and
// without the existing state machine growing a "which binding is this?" branch
// through every method (R-5).
//
// The extraction is deliberately a *move*, not a rewrite: the press/release
// derivation, the recovery key-down, the double-tap window arithmetic, and the
// safety timer are the same code they were when they lived in HotKeyManager,
// so the dictation binding behaves byte-identically to before. What changed is
// only where the state lives — one instance per binding rather than one set of
// fields per manager.

import Foundation
import AppKit

/// The per-binding half of `HotKeyManager`. Owns no tap and no run loop
/// source: `HotKeyManager` owns the single tap (Story 6.1 AC) and feeds every
/// event to each binding in turn.
final class HotKeyBinding {

    // MARK: - Configuration

    /// The key code this binding watches.
    private(set) var targetKeyCode: Int

    /// Current activation mode.
    private(set) var mode: ActivationMode

    /// Double-tap threshold in seconds.
    private(set) var doubleTapThreshold: Double

    /// Maximum duration (seconds) before the safety timer forces a key-up.
    private(set) var safetyTimeoutSeconds: Double

    /// When false the binding ignores every event and fires no callbacks.
    /// Always true for dictation; the Command Mode binding is off until the
    /// user turns it on.
    var isEnabled: Bool

    /// Names this binding in log lines, so the two are distinguishable.
    private let label: String

    // MARK: - State

    /// Timestamp of the last key down event for the target key
    private var lastKeyDownTime: CFAbsoluteTime = 0

    /// Whether the key is currently held down (for push-to-talk)
    private var isKeyHeld = false

    /// Whether we are currently in a "recording" toggle state (for double-tap mode)
    private var isToggled = false

    /// Whether the configured modifier key is physically held.
    /// This is tracked separately from recording state so modifier double-tap
    /// mode can distinguish press/release even when another same-group modifier
    /// keeps the shared modifier flag set.
    private var isModifierKeyHeld = false

    /// Safety timer that auto-fires key-up if a real key-up event is missed.
    /// macOS can drop flagsChanged events when multiple modifiers interact,
    /// leaving push-to-talk stuck in the "recording" state.
    private var keyHeldSafetyTimer: DispatchWorkItem?

    // MARK: - Callbacks

    /// Called when this binding's gesture begins.
    var onStart: (() -> Void)?

    /// Called when this binding's gesture ends.
    var onStop: (() -> Void)?

    // MARK: - Lifecycle

    init(
        label: String,
        keyCode: Int,
        mode: ActivationMode = .pushToTalk,
        doubleTapThreshold: Double = 0.4,
        safetyTimeout: Double = 65.0,
        isEnabled: Bool = true
    ) {
        self.label = label
        self.targetKeyCode = keyCode
        self.mode = mode
        self.doubleTapThreshold = doubleTapThreshold
        self.safetyTimeoutSeconds = safetyTimeout
        self.isEnabled = isEnabled
    }

    /// Apply a fresh configuration and clear any half-finished gesture, the
    /// way `startListening` used to.
    func configure(
        keyCode: Int,
        mode: ActivationMode,
        doubleTapThreshold: Double,
        safetyTimeout: Double,
        isEnabled: Bool = true
    ) {
        self.targetKeyCode = keyCode
        self.mode = mode
        self.doubleTapThreshold = doubleTapThreshold
        self.safetyTimeoutSeconds = safetyTimeout
        self.isEnabled = isEnabled
        resetState()
        lastKeyDownTime = 0
    }

    /// Partial update, matching `HotKeyManager.updateConfiguration`'s shape:
    /// every argument is optional and only the supplied ones change. State is
    /// deliberately *not* reset — this runs while the user is settling a
    /// slider in Settings, and resetting mid-gesture is what the separate
    /// `resetState()` is for.
    func updateConfiguration(
        keyCode: Int? = nil,
        mode: ActivationMode? = nil,
        doubleTapThreshold: Double? = nil,
        safetyTimeout: Double? = nil,
        isEnabled: Bool? = nil
    ) {
        if let keyCode { self.targetKeyCode = keyCode }
        if let mode { self.mode = mode }
        if let doubleTapThreshold { self.doubleTapThreshold = doubleTapThreshold }
        if let safetyTimeout { self.safetyTimeoutSeconds = safetyTimeout }
        if let isEnabled { self.isEnabled = isEnabled }
    }

    /// Reset key tracking without touching configuration or callbacks.
    func resetState() {
        isKeyHeld = false
        isToggled = false
        isModifierKeyHeld = false
        cancelSafetyTimer()
    }

    // MARK: - Event Handling

    /// - Returns: `true` when the event belongs to this binding's key and
    ///   should be consumed so it doesn't also affect the frontmost app.
    func handle(type: CGEventType, keyCode: Int, event: CGEvent) -> Bool {
        guard isEnabled else { return false }

        if type == .flagsChanged {
            return handleModifierKeyEvent(keyCode: keyCode, event: event)
        } else if type == .keyDown || type == .keyUp {
            return handleRegularKeyEvent(keyCode: keyCode, isKeyDown: type == .keyDown, event: event)
        }

        return false
    }

    /// Handle modifier key events (Option, Command, Control, Shift, Fn)
    /// Modifier keys generate flagsChanged events, not keyDown/keyUp.
    ///
    /// **Key insight:** Modifier flags like `.maskAlternate` are shared between
    /// left and right variants (e.g., Left Option and Right Option both set
    /// `.maskAlternate`). A `flagsChanged` event fires whenever *any* modifier
    /// changes, so we can't simply check the flag — pressing Left Option while
    /// Right Option is already held would still show `.maskAlternate` as set,
    /// and releasing Right Option while Left Option is held would *not* clear
    /// the flag, causing the key-up to be missed.
    ///
    /// **Fix:** We track the target modifier's physical held state. When a
    /// `flagsChanged` event arrives for the target key code, a transition from
    /// not-held to set flags is a press; any later target-key event while held
    /// is a release, even if another same-group modifier keeps the shared flag set.
    private func handleModifierKeyEvent(keyCode: Int, event: CGEvent) -> Bool {
        guard keyCode == targetKeyCode else { return false }

        VocaLogger.debug(.hotKeyManager, "[\(label)] flagsChanged event for target keyCode \(keyCode)")

        let flags = event.flags

        // The flag mask that corresponds to this key's modifier group
        let relevantMask: CGEventFlags
        switch keyCode {
        case 61, 58:  // Right Option (61) or Left Option (58)
            relevantMask = .maskAlternate
        case 54, 55:  // Right Command (54) or Left Command (55)
            relevantMask = .maskCommand
        case 60, 56:  // Right Shift (60) or Left Shift (56)
            relevantMask = .maskShift
        case 62, 59:  // Right Control (62) or Left Control (59)
            relevantMask = .maskControl
        case 63:      // Fn key
            relevantMask = .maskSecondaryFn
        default:
            return false
        }

        // A flagsChanged event for this keyCode means the key was either
        // pressed or released. Modifier flags are shared by left/right pairs,
        // so we cannot rely on the flag being cleared to detect release.
        let flagIsSet = flags.contains(relevantMask)

        let isPressed: Bool
        if flagIsSet && !isModifierKeyHeld {
            isPressed = true
            isModifierKeyHeld = true
        } else if isModifierKeyHeld {
            isPressed = false
            isModifierKeyHeld = false
        } else {
            return true
        }

        if isPressed {
            handleKeyDown()
        } else {
            handleKeyUp()
        }

        return true
    }

    /// Handle regular (non-modifier) key events
    private func handleRegularKeyEvent(keyCode: Int, isKeyDown: Bool, event: CGEvent) -> Bool {
        guard keyCode == targetKeyCode else { return false }

        if isKeyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return true
        }

        if isKeyDown {
            handleKeyDown()
        } else {
            handleKeyUp()
        }

        return true
    }

    /// Process a key-down event for the target hotkey
    private func handleKeyDown() {
        let currentTime = CFAbsoluteTimeGetCurrent()
        VocaLogger.debug(.hotKeyManager, "[\(label)] Key DOWN detected (mode=\(mode.rawValue))")

        switch mode {
        case .pushToTalk:
            if !isKeyHeld {
                // Normal case: start recording on key down
                isKeyHeld = true
                VocaLogger.debug(.hotKeyManager, "[\(label)] Push-to-talk: START")
                startSafetyTimer()
                DispatchQueue.main.async { [weak self] in
                    self?.onStart?()
                }
            } else {
                // Recovery: key-down while already held means the previous
                // key-up was missed (macOS dropped the flagsChanged event).
                // Treat this as a stop → the user is pressing the key again
                // because recording is stuck.
                VocaLogger.warning(.hotKeyManager, "[\(label)] Push-to-talk: key DOWN while already held — forcing STOP (recovery)")
                isKeyHeld = false
                cancelSafetyTimer()
                DispatchQueue.main.async { [weak self] in
                    self?.onStop?()
                }
            }

        case .doubleTapToggle:
            // Double-tap: check if this is the second tap within threshold
            let timeSinceLastTap = currentTime - lastKeyDownTime

            if timeSinceLastTap < doubleTapThreshold && timeSinceLastTap > 0.05 {
                // This is a double-tap!
                isToggled.toggle()
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    if self.isToggled {
                        self.onStart?()
                    } else {
                        self.onStop?()
                    }
                }
                // Reset to avoid triple-tap triggering
                lastKeyDownTime = 0
            } else {
                lastKeyDownTime = currentTime
            }
        }
    }

    /// Process a key-up event for the target hotkey
    private func handleKeyUp() {
        VocaLogger.debug(.hotKeyManager, "[\(label)] Key UP detected (mode=\(mode.rawValue))")

        switch mode {
        case .pushToTalk:
            // Push-to-talk: stop recording on key release
            if isKeyHeld {
                isKeyHeld = false
                cancelSafetyTimer()
                VocaLogger.debug(.hotKeyManager, "[\(label)] Push-to-talk: STOP")
                DispatchQueue.main.async { [weak self] in
                    self?.onStop?()
                }
            }

        case .doubleTapToggle:
            // No action on key up for toggle mode
            break
        }
    }

    // MARK: - Safety Timer

    /// Start a safety timer that forces a key-up if the real event is never received.
    /// This prevents the app from getting stuck in a "recording" state indefinitely.
    ///
    /// The timeout should be slightly longer than `maxRecordingDuration` so that
    /// AudioEngine's own max-duration callback fires first under normal
    /// conditions. The safety timer only kicks in when a key-up event is
    /// completely lost.
    private func startSafetyTimer() {
        cancelSafetyTimer()

        let timeout = safetyTimeoutSeconds
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isKeyHeld else { return }
            VocaLogger.warning(.hotKeyManager, "[\(self.label)] Safety timer fired — forcing key-up (key held for >\(timeout)s)")
            self.isKeyHeld = false
            DispatchQueue.main.async { [weak self] in
                self?.onStop?()
            }
        }
        keyHeldSafetyTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    /// Cancel the safety timer (called on normal key-up)
    private func cancelSafetyTimer() {
        keyHeldSafetyTimer?.cancel()
        keyHeldSafetyTimer = nil
    }

    deinit {
        keyHeldSafetyTimer?.cancel()
    }
}
