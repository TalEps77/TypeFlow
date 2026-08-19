// TextInjector.swift
// VocaMac
//
// Injects transcribed text at the cursor position in any application
// using the clipboard (NSPasteboard) + simulated Cmd+V keystroke approach.
//
// Story 6.2 added selection read/replace for Command Mode. It is additive:
// `inject(text:preserveClipboard:)`, its role gate, its pasteboard
// snapshot/restore and its changeCount guard are untouched.

import Foundation
import AppKit
import Carbon.HIToolbox

// MARK: - Selection vocabulary (Story 6.2)

/// What was selected, and in exactly which element, at the moment
/// `readSelection()` ran.
///
/// It exists because Command Mode reads a selection, then suspends for as long
/// as an LLM round trip takes, then writes back. "Write to whatever is focused
/// now" is not good enough across that gap — the user may have clicked into
/// another field, or another document, or edited the selection. The snapshot
/// is what lets the write prove it is replacing the same text in the same
/// place (the pattern `undoViaAccessibility` already uses).
///
/// AD-5: `text` is the user's document content. It is transient — held for the
/// one operation that needs it, never logged (not even truncated), never
/// persisted, and never placed on a `HistoryRecord`.
struct SelectionSnapshot {
    let element: AXUIElement
    let text: String
    let range: CFRange
    let processIdentifier: pid_t
    let bundleIdentifier: String?
}

/// Why a selection could not be read or replaced. Every case is a reason to
/// abort and change nothing (AD-4) — Command Mode has no safe fallback,
/// because its fallback would mean pasting a spoken instruction over the
/// user's text.
enum SelectionError: Error, Equatable {
    /// No accessible focused element, or one this reader will not touch
    /// (wrong role, or a secure field).
    case noAccessibleElement
    /// There is a focused element, but nothing is selected in it.
    case noSelection
    /// Accessibility permission has not been granted.
    case notTrusted
    /// Focus moved to a different element between read and write.
    case focusChanged
    /// The selection is no longer the text that was read.
    case selectionChanged
    /// The Accessibility write itself was refused by the target.
    case writeRejected(Int32)
    /// The write was accepted and did nothing — *proved*, by reading the text
    /// back and finding the original selection still in place. Some multi-line
    /// text views — terminals and code editors especially — return `.success`
    /// for a `kAXSelectedTextAttribute` write and silently discard it, which is
    /// exactly the failure that must not be reported as a rewrite.
    case writeNotApplied
    /// The write was accepted and the result could not be read back, so
    /// whether it landed is genuinely unknown (MAJOR 2). This is *not*
    /// `writeNotApplied`: telling the user "nothing was changed" when the app
    /// may well have applied the edit invites a retry that rewrites it twice.
    case writeUnverified

    var reason: String {
        switch self {
        case .noAccessibleElement: return "no accessible text element is focused"
        case .noSelection:         return "nothing is selected"
        case .notTrusted:          return "Accessibility permission has not been granted"
        case .focusChanged:        return "focus moved to a different field"
        case .selectionChanged:    return "the selection changed"
        case .writeRejected(let code): return "the app refused the edit (AX error \(code))"
        case .writeNotApplied:     return "the app accepted the edit but did not apply it"
        case .writeUnverified:     return "the app accepted the edit but would not confirm it"
        }
    }
}

final class TextInjector {

    // MARK: - Constants

    /// Delay after simulating Cmd+V before restoring the clipboard.
    /// This must be long enough for the target application to read the
    /// pasteboard in response to the paste event. 50 ms is sufficient
    /// for all mainstream macOS apps (most read the pasteboard
    /// synchronously on the main thread).
    private let clipboardRestoreDelay: Double = 0.05

    /// Delay before simulating the Cmd+V keystroke, giving the
    /// pasteboard a moment to settle after we write to it.
    private let prePasteDelay: Double = 0.05

    /// Default virtual key code for the V key on a US-QWERTY layout.
    /// Used as a fallback when the active layout cannot be inspected.
    private static let kVK_ANSI_V_Fallback: CGKeyCode = 9

    /// Default virtual key code for the Z key on a US-QWERTY layout.
    /// Used as a fallback when the active layout cannot be inspected.
    private static let kVK_ANSI_Z_Fallback: CGKeyCode = 6

    /// Undo (FR-10) is offered only within this short window after an
    /// injection, and only while the same application is still frontmost.
    private let undoWindow: TimeInterval = 10.0

    /// How long to wait after handing focus back to the target application
    /// before injecting into it or retracting from it. Application
    /// activation is asynchronous and slower to settle than a pasteboard
    /// write, so this is deliberately longer than `prePasteDelay`.
    static let focusSettleDelay: Double = 0.15

    // MARK: - Types

    /// Deep copy of a single pasteboard item's data across all its types
    private struct PasteboardItemSnapshot {
        /// Map from pasteboard type to raw data
        let dataByType: [(NSPasteboard.PasteboardType, Data)]
    }

    /// Deep copy of the entire pasteboard state
    private struct PasteboardSnapshot {
        let items: [PasteboardItemSnapshot]
    }

    /// Which strategy actually performed the last injection, and what it
    /// takes to retract it safely (FR-10).
    ///
    /// Internal rather than `private`: `TextInjectorTests` seeds this via
    /// `@testable import` to exercise the safety-window and frontmost-app
    /// guards without needing real Accessibility permission in CI.
    enum InjectionStrategy {
        case accessibility
        case clipboard
    }

    struct InjectionRecord {
        let text: String
        let strategy: InjectionStrategy
        let timestamp: Date
        let frontmostBundleId: String?

        /// The application the text actually landed in. Undo and re-paste are
        /// triggered from VocaMac's own menu-bar panel or History window,
        /// which hold key status at that moment — so the target has to be
        /// re-activated before anything is aimed at it (BLOCKER 2).
        let targetApp: NSRunningApplication?

        /// The exact element the Accessibility path wrote into. Retraction
        /// refuses to touch any other element, even inside the same
        /// application: "same app" is not "same text field" (BLOCKER 1).
        let element: AXUIElement?

        init(
            text: String,
            strategy: InjectionStrategy,
            timestamp: Date,
            frontmostBundleId: String?,
            targetApp: NSRunningApplication? = nil,
            element: AXUIElement? = nil
        ) {
            self.text = text
            self.strategy = strategy
            self.timestamp = timestamp
            self.frontmostBundleId = frontmostBundleId
            self.targetApp = targetApp
            self.element = element
        }
    }

    /// What the last `inject(text:preserveClipboard:)` call actually did.
    /// `nil` until the first injection, and also `nil` for the
    /// no-accessibility-permission fallback (clipboard-only, no keystroke
    /// dispatched — there is nothing in the target application to retract).
    var lastInjection: InjectionRecord?

    /// True from the start of a clipboard injection until its clipboard
    /// restore has completed. A second `inject()` inside that window would
    /// snapshot the transcript the first one just wrote and later "restore"
    /// it over the user's real clipboard, which is unrecoverable (MAJOR 4).
    private var isInjecting = false

    /// `changeCount` of the last pasteboard write we made ourselves, so we
    /// never snapshot our own transcript as if it were the user's clipboard.
    private var lastWrittenChangeCount: Int = -1

    // MARK: - Keystroke seams
    //
    // Posting a CGEvent is a system-wide side effect: it lands in whatever
    // application is frontmost, including the developer's editor during
    // `make test`. These two seams are the only places a keystroke is
    // actually posted, and `TextInjectorTests` replaces them (via
    // `@testable import`) so the unit suite never types into anything
    // (BLOCKER 3). Both report whether the keystroke went out (MAJOR 5).

    var pasteKeystrokeDispatcher: () -> Bool = TextInjector.postPasteKeystroke
    var undoKeystrokeDispatcher: () -> Bool = TextInjector.postUndoKeystroke

    // MARK: - Public API

    /// Inject text at the current cursor position in any application.
    ///
    /// Strategy (in order):
    /// 1. **Accessibility API** — sets `kAXSelectedTextAttribute` on the
    ///    focused element. This inserts text directly without going through
    ///    any paste handler, which makes it compatible with apps like Raycast
    ///    whose search bar intercepts Cmd+V before it reaches the text field.
    /// 2. **Clipboard + Cmd+V** — the legacy approach used as a fallback for
    ///    apps whose text fields are not writable via the Accessibility API.
    ///
    /// - Parameters:
    ///   - text: The text to inject
    ///   - preserveClipboard: Whether to save and restore the clipboard contents
    ///                        (only relevant when the clipboard path is taken)
    func inject(text: String, preserveClipboard: Bool = true) {
        guard !text.isEmpty else { return }

        // Two injections overlapping in the ~100 ms clipboard window destroy
        // the user's clipboard permanently: #2 snapshots #1's transcript and
        // later writes it back as if it were the user's own content. Rejecting
        // the overlap is the only outcome that cannot lose data (MAJOR 4).
        guard !isInjecting else {
            VocaLogger.warning(.textInjector, "inject() called while a previous injection is still in flight — ignoring")
            return
        }

        // Check accessibility permission
        let trusted = AXIsProcessTrusted()
        VocaLogger.debug(.textInjector, "AXIsProcessTrusted = \(trusted ? "YES" : "NO")")

        if !trusted {
            VocaLogger.warning(.textInjector, "No accessibility permission. Copying to clipboard only.")
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return
        }

        // Strategy 1: Accessibility API direct insertion.
        // Works with Raycast, Spotlight, and any app whose focused text field
        // is writable via the AX API. Preferred because it does not touch the
        // clipboard and does not require dispatching a keyboard shortcut.
        if let element = injectViaAccessibility(text: text) {
            VocaLogger.info(.textInjector, "Text injected via Accessibility API")
            recordInjection(text: text, strategy: .accessibility, element: element)
            return
        }

        // Strategy 2: Clipboard + Cmd+V (legacy fallback). The injection is
        // recorded inside this call, once the paste keystroke has actually
        // been dispatched — see `injectViaClipboard` (MAJOR 5).
        VocaLogger.info(.textInjector, "AX injection unavailable — falling back to clipboard + Cmd+V")
        injectViaClipboard(text: text, preserveClipboard: preserveClipboard)
    }

    private func recordInjection(text: String, strategy: InjectionStrategy, element: AXUIElement?) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        lastInjection = InjectionRecord(
            text: text,
            strategy: strategy,
            timestamp: Date(),
            frontmostBundleId: frontmost?.bundleIdentifier,
            targetApp: frontmost,
            element: element
        )
    }

    // MARK: - Undo (FR-10)

    /// True when the last injection can still be retracted safely: within a
    /// short window, and with the same application still frontmost. Undo is
    /// **unavailable** rather than destructive whenever either condition
    /// fails (R-9) — there is no attempt to guess or force it.
    var canUndoLastInjection: Bool {
        guard let last = lastInjection else { return false }
        return isWithinUndoWindow(last) && isSameFrontmostApp(last)
    }

    /// Best-effort retraction of the last injection (FR-10). Returns `false`
    /// — changing nothing — when it cannot be performed safely, or when the
    /// retraction itself fails.
    ///
    /// When the target application has to be re-activated first (BLOCKER 2)
    /// the retraction is dispatched after a short settle delay and `true`
    /// means "accepted and dispatched"; the retraction itself still refuses
    /// to delete anything it cannot prove is ours.
    @discardableResult
    func undoLastInjection() -> Bool {
        guard let last = lastInjection, canUndoLastInjection else { return false }

        // Consume the record up front. A retraction that is merely *dispatched*
        // must still be unrepeatable — otherwise a second click while the
        // target application is coming forward fires a second retraction at
        // text that is already gone. A refused retraction stays refused, too:
        // for destructive work, unavailable beats retried (R-9).
        lastInjection = nil

        guard let target = last.targetApp, !target.isActive else {
            return performUndo(last)
        }

        // The user reached Undo from VocaMac's own menu-bar panel or History
        // window, so *we* hold key status right now. Retracting here would
        // aim ⌘Z — or an AX delete — at our own UI (BLOCKER 2). Hand focus
        // back to the application the text went into, then retract.
        VocaLogger.info(.textInjector, "Undo: re-activating the target application before retracting")
        NSApp.deactivate()
        target.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + TextInjector.focusSettleDelay) { [self] in
            _ = performUndo(last)
        }
        return true
    }

    private func performUndo(_ record: InjectionRecord) -> Bool {
        switch record.strategy {
        case .accessibility:
            // Precise: select exactly the span we inserted and delete it —
            // but only after proving the span really is ours.
            return undoViaAccessibility(record)
        case .clipboard:
            // Best-effort: synthesize ⌘Z. Behavior is app-dependent and that
            // is an accepted, documented limitation (AC, Story 3.4). Reports
            // failure rather than claiming success when the keystroke could
            // not be dispatched at all (MAJOR 5).
            return simulateUndo()
        }
    }

    private func isWithinUndoWindow(_ record: InjectionRecord) -> Bool {
        Date().timeIntervalSince(record.timestamp) <= undoWindow
    }

    private func isSameFrontmostApp(_ record: InjectionRecord) -> Bool {
        let frontmost = NSWorkspace.shared.frontmostApplication
        return isSameFrontmostApp(
            record,
            frontmostPid: frontmost?.processIdentifier,
            frontmostBundleId: frontmost?.bundleIdentifier
        )
    }

    /// The frontmost-app half of the undo guard, taking the frontmost app's
    /// identity as arguments.
    ///
    /// Internal rather than `private` so `TextInjectorTests` can exercise the
    /// VocaMac-is-frontmost case, which a test runner cannot actually put on
    /// screen — and which is precisely the case that was broken (BLOCKER 2).
    func isSameFrontmostApp(
        _ record: InjectionRecord,
        frontmostPid: pid_t?,
        frontmostBundleId: String?
    ) -> Bool {
        guard let frontmostPid else { return false }

        // VocaMac itself is transparent here. Reaching the Undo row means
        // clicking our own menu-bar panel, which makes *us* frontmost —
        // comparing bundle identifiers naively made undo permanently
        // unavailable, i.e. the feature simply never appeared. Compared by pid
        // so a dev binary with no bundle identifier cannot accidentally match
        // some other unbundled app.
        if frontmostPid == NSRunningApplication.current.processIdentifier {
            return true
        }
        return frontmostBundleId == record.frontmostBundleId
    }

    /// Selects the exact span of characters we inserted via the Accessibility
    /// API, immediately before the current caret, and deletes it.
    ///
    /// The caret arithmetic alone is not enough to make this safe. "N units
    /// before the caret" is our text only if nothing has happened since —
    /// type "!!!" after an 11-unit injection and that span becomes 3 of the
    /// user's own characters plus 8 of ours (BLOCKER 1). So the retraction
    /// only proceeds once it has proved two things: focus is still on the
    /// very element we wrote into, and the span it is about to delete reads
    /// back as exactly the text we inserted. Anything else refuses, and puts
    /// the caret back where it found it.
    private func undoViaAccessibility(_ record: InjectionRecord) -> Bool {
        guard let injectedElement = record.element else {
            VocaLogger.debug(.textInjector, "Undo: the AX injection has no recorded element — refusing")
            return false
        }

        let text = record.text
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            VocaLogger.debug(.textInjector, "Undo: no focused element")
            return false
        }

        // swiftlint:disable force_cast
        let element = focusedRef as! AXUIElement
        // swiftlint:enable force_cast

        // The bundle-identifier check upstream only proves the same *app*.
        // A second text field in that app — or a different document — would
        // sail straight through it (BLOCKER 1).
        guard CFEqual(element, injectedElement) else {
            VocaLogger.debug(.textInjector, "Undo: focus has moved to a different element — refusing")
            return false
        }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef else {
            VocaLogger.debug(.textInjector, "Undo: could not read current selection range")
            return false
        }

        // swiftlint:disable force_cast
        let rangeValue = rangeRef as! AXValue
        // swiftlint:enable force_cast

        var currentRange = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &currentRange) else {
            return false
        }

        let injectedLength = text.utf16.count
        let undoStart = currentRange.location - injectedLength
        guard undoStart >= 0 else {
            VocaLogger.debug(.textInjector, "Undo: caret has moved before the injected span — refusing")
            return false
        }

        var undoRange = CFRange(location: undoStart, length: injectedLength)
        guard let undoRangeValue = AXValueCreate(.cfRange, &undoRange) else { return false }

        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, undoRangeValue) == .success else {
            VocaLogger.debug(.textInjector, "Undo: could not select the injected span")
            return false
        }

        // Read the span back and require it to be, character for character,
        // what we inserted. This is the check that stops the user's own typing
        // from being swept away with ours, and it is also what makes the
        // UTF-16-vs-code-point range mismatch on Chromium/Electron fields
        // harmless: an overshooting range simply fails to match and refuses.
        //
        // AD-5: this read is transient. `selectedText` is compared and dropped
        // on this stack frame — it is never logged, never handed to
        // VocaLogger, and never reaches a HistoryRecord.
        var selectedRef: CFTypeRef?
        let readResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef)
        guard readResult == .success, (selectedRef as? String) == text else {
            VocaLogger.debug(.textInjector, "Undo: the span before the caret is not the text we injected — refusing")
            restoreSelection(currentRange, on: element)
            return false
        }

        let deleteResult = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, "" as CFTypeRef)
        guard deleteResult == .success else {
            VocaLogger.debug(.textInjector, "Undo: could not delete the injected span (\(deleteResult.rawValue))")
            restoreSelection(currentRange, on: element)
            return false
        }

        VocaLogger.info(.textInjector, "Undo: retracted \(injectedLength) UTF-16 units via Accessibility API")
        return true
    }

    /// Puts the caret (or selection) back exactly where the retraction found
    /// it. A refused undo must leave no trace — least of all a selection the
    /// user never made, one keystroke away from being overwritten.
    private func restoreSelection(_ range: CFRange, on element: AXUIElement) {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return }
        _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
    }

    /// Simulate ⌘Z. Mirrors `simulatePaste()`'s layout-aware keycode
    /// resolution — see its documentation for why this cannot just post the
    /// US-QWERTY keycode for "z" directly.
    private func simulateUndo() -> Bool {
        undoKeystrokeDispatcher()
    }

    private static func postUndoKeystroke() -> Bool {
        let keyCode = TextInjector.keyCode(forCharacter: "z") ?? TextInjector.kVK_ANSI_Z_Fallback
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            VocaLogger.error(.textInjector, "ERROR: Failed to create Cmd+Z key down event")
            return false
        }
        keyDown.flags = [.maskCommand]
        keyDown.post(tap: .cgAnnotatedSessionEventTap)

        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            VocaLogger.error(.textInjector, "ERROR: Failed to create Cmd+Z key up event")
            return false
        }
        keyUp.flags = [.maskCommand]
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        VocaLogger.info(.textInjector, "Cmd+Z posted (keycode \(keyCode))")
        return true
    }

    // MARK: - Strategy 1: Accessibility API

    /// Roles the injection path is willing to write into: single-line inputs
    /// only. Hoisted out of `injectViaAccessibility` so a test can pin the
    /// actual gate rather than a constant that merely resembles it (MINOR 7) —
    /// the values and the guard below are unchanged.
    static let injectableRoles: Set<String> = ["AXTextField", "AXSearchField", "AXComboBox"]

    /// Attempt to insert `text` at the cursor position by writing directly to
    /// the `kAXSelectedTextAttribute` of the currently focused UI element.
    ///
    /// This replaces any active selection with `text`, or inserts at the caret
    /// when no text is selected — identical to what the user would experience
    /// when typing.
    ///
    /// **Scope:** This strategy is intentionally limited to single-line input
    /// roles (`AXTextField`, `AXSearchField`, `AXComboBox`). Multi-line
    /// `AXTextArea` elements — which covers terminal emulators (Terminal.app,
    /// Ghostty, iTerm2) and code editors — accept the AX attribute write and
    /// return `.success`, but silently discard or mishandle the text because
    /// those views process input as a stream of key events, not as a direct
    /// value mutation. Limiting scope to single-line fields makes AX injection
    /// reliable for apps like Raycast while letting terminal/editor traffic
    /// fall through to the clipboard+Cmd+V path that has always worked there.
    ///
    /// - Returns: The element the text was written into, or `nil` if the
    ///            focused element is unreachable, has an unsupported role, or
    ///            the write was rejected. The element is kept on the
    ///            `InjectionRecord` so an undo can prove it is retracting from
    ///            the same field it wrote to (BLOCKER 1).
    private func injectViaAccessibility(text: String) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?

        let fetchResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard fetchResult == .success, let focusedRef else {
            VocaLogger.debug(.textInjector, "AX: no focused element (\(fetchResult.rawValue))")
            return nil
        }

        // The returned CFTypeRef must be an AXUIElement.
        guard CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            VocaLogger.debug(.textInjector, "AX: focused element is not an AXUIElement")
            return nil
        }

        // swiftlint:disable force_cast
        let element = focusedRef as! AXUIElement
        // swiftlint:enable force_cast

        // Gate on element role. Only single-line input fields reliably handle
        // a direct kAXSelectedTextAttribute write as "insert text at cursor".
        // AXTextArea (terminals, editors) must use clipboard+Cmd+V instead.
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""

        guard Self.injectableRoles.contains(role) else {
            VocaLogger.debug(.textInjector, "AX: skipping role '\(role)' — not a single-line input field")
            return nil
        }

        let setResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        if setResult == .success {
            VocaLogger.debug(.textInjector, "AX: inserted \(text.count) chars via kAXSelectedTextAttribute (role: \(role))")
            return element
        }

        VocaLogger.debug(.textInjector, "AX: kAXSelectedTextAttribute write failed (\(setResult.rawValue)) — element may be read-only")
        return nil
    }

    // MARK: - Selection read/replace (Story 6.2)
    //
    // Deliberately separate from the injection path above. Injection inserts
    // text the user just spoke; this replaces text the user already has, which
    // is destructive, so every step here refuses rather than guesses.

    /// Roles whose selection Command Mode is willing to read and rewrite.
    ///
    /// Wider than `injectViaAccessibility`'s single-line allow-list, because
    /// the text people select to rewrite is overwhelmingly in an `AXTextArea`
    /// — a mail body, a document, a comment box. Still an allow-list rather
    /// than a deny-list, for the same reason `AXContextReader` uses one: a
    /// role we have never heard of gets no read at all (MAJOR 2 there).
    static let selectableRoles: Set<String> = [
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
        "AXSearchField",
        "AXComboBox"
    ]

    /// Role/subrole identifiers that mask their contents and must never be
    /// read, mirroring `AXContextReader.secureRoleIdentifiers`.
    static let secureRoleIdentifiers: Set<String> = [
        kAXSecureTextFieldSubrole as String,
        "AXSecureTextField"
    ]

    /// Read the current selection in the frontmost application, with the
    /// reason it could not be read. `readSelection()` — the `nil`-returning
    /// shape Story 6.2's AC names — is the protocol extension over this.
    ///
    /// The selected text is returned to the caller and never logged (AD-5);
    /// only its length and the failure reasons reach the log.
    func readSelectionResult() -> Result<SelectionSnapshot, SelectionError> {
        let result = computeSelectionResult()
        if case .failure(let error) = result {
            VocaLogger.debug(.textInjector, "Selection read unavailable — \(error.reason)")
        }
        return result
    }

    private func computeSelectionResult() -> Result<SelectionSnapshot, SelectionError> {
        guard AXIsProcessTrusted() else { return .failure(.notTrusted) }

        // Command Mode is invoked by a global hotkey, so the app the user
        // selected text in is the frontmost one. If that is us — the hotkey
        // pressed with our own settings or History window key — there is
        // nothing meaningful to rewrite (the same reasoning as MINOR 9 in
        // AXContextReader).
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != NSRunningApplication.current.processIdentifier else {
            return .failure(.noAccessibleElement)
        }
        let processIdentifier = frontmost.processIdentifier

        guard let element = focusedSelectableElement(processIdentifier: processIdentifier) else {
            return .failure(.noAccessibleElement)
        }
        guard let range = selectedTextRange(of: element) else {
            return .failure(.noSelection)
        }
        guard range.length > 0 else {
            return .failure(.noSelection)
        }

        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
              let text = selectedRef as? String,
              !text.isEmpty else {
            return .failure(.noSelection)
        }

        VocaLogger.debug(.textInjector, "Read a selection of \(text.utf16.count) UTF-16 units for Command Mode")
        return .success(SelectionSnapshot(
            element: element,
            text: text,
            range: range,
            processIdentifier: processIdentifier,
            bundleIdentifier: frontmost.bundleIdentifier
        ))
    }

    /// Replace the snapshot's selection with `text`.
    ///
    /// Refuses — changing nothing — unless focus is still on the very element
    /// the snapshot came from, the selection still occupies the very range it
    /// was read from, and it still reads back as exactly the text that was
    /// read. That is the same proof `undoViaAccessibility` demands before it
    /// deletes anything, and here it is what stops a rewrite landing in a field
    /// the user moved to while the LLM was thinking.
    ///
    /// Failure is returned, never swallowed (Story 6.2 AC).
    @discardableResult
    func replaceSelection(_ text: String, replacing snapshot: SelectionSnapshot) -> Result<Void, SelectionError> {
        guard AXIsProcessTrusted() else { return .failure(.notTrusted) }

        guard let focused = focusedElement(processIdentifier: snapshot.processIdentifier),
              CFEqual(focused, snapshot.element) else {
            return .failure(.focusChanged)
        }

        // The range, not just the text (MAJOR 3). Element identity plus string
        // equality is satisfied by a *different* occurrence of the same phrase:
        // the user selects "the meeting" on line 2 while the LLM is rewriting
        // the "the meeting" they selected on line 9, and both guards pass while
        // the write lands on the wrong one. The snapshot only exists because a
        // read and a write are separated by seconds; the location it was read
        // from is part of what it recorded.
        //
        // An unreadable range refuses too. `computeSelectionResult` could not
        // have produced this snapshot without reading one from this same
        // element, so "unreadable now" is an anomaly, and the safe way to
        // resolve an anomaly here is to change nothing.
        guard let currentRange = selectedTextRange(of: focused),
              currentRange.location == snapshot.range.location,
              currentRange.length == snapshot.range.length else {
            return .failure(.selectionChanged)
        }

        // AD-5: read back, compare, drop. The comparison happens on this stack
        // frame and neither string is logged.
        var currentRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXSelectedTextAttribute as CFString, &currentRef) == .success,
              let current = currentRef as? String,
              current == snapshot.text else {
            return .failure(.selectionChanged)
        }

        let countBefore = intAttribute(kAXNumberOfCharactersAttribute, of: focused)

        let result = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard result == .success else {
            VocaLogger.warning(.commandMode, "Selection replace refused by the target (AX error \(result.rawValue))")
            return .failure(.writeRejected(result.rawValue))
        }

        return verifyWrite(of: text, into: focused, replacing: snapshot, countBefore: countBefore)
    }

    /// Decide whether the accepted write actually landed.
    ///
    /// A `.success` that changed nothing is the failure mode that matters:
    /// multi-line text views in terminals and editors accept this write and
    /// discard it (the same behaviour that keeps them off
    /// `injectViaAccessibility`'s allow-list).
    ///
    /// Content, not length (MAJOR 1). The character count cannot see an
    /// equal-length rewrite — "make this uppercase", "swap these two words" —
    /// being dropped, because a dropped write and a perfect one produce exactly
    /// the same count. Reading the text back at the range the rewrite should
    /// now occupy answers the question directly, and it also removes MAJOR 2's
    /// false alarms: an app that normalizes what it stores (smart quotes,
    /// autocorrect, RTL marks) changes the count without dropping anything.
    private func verifyWrite(
        of text: String,
        into element: AXUIElement,
        replacing snapshot: SelectionSnapshot,
        countBefore: Int?
    ) -> Result<Void, SelectionError> {
        let writtenRange = CFRange(location: snapshot.range.location, length: text.utf16.count)

        if let written = string(in: writtenRange, of: element) {
            if written == text {
                VocaLogger.info(.commandMode, "Replaced a \(snapshot.text.utf16.count)-unit selection with \(text.utf16.count) units")
                return .success(())
            }
            // Not what we wrote. If the original selection is still sitting
            // there, the write was discarded and nothing was changed — the one
            // case that may say so.
            if let original = string(in: snapshot.range, of: element), original == snapshot.text {
                VocaLogger.warning(.commandMode, "Selection replace was accepted but the original text is still in place — the app discarded it")
                return .failure(.writeNotApplied)
            }
            VocaLogger.warning(.commandMode, "Selection replace was accepted but read back as neither the rewrite nor the original")
            return .failure(.writeUnverified)
        }

        // The target does not answer AXStringForRange. Fall back to the count,
        // which can prove a *length-changing* rewrite was dropped and can prove
        // nothing at all about an equal-length one.
        guard let countBefore,
              let countAfter = intAttribute(kAXNumberOfCharactersAttribute, of: element) else {
            VocaLogger.debug(.commandMode, "Selection replace could not be verified — the target reports neither text ranges nor a character count")
            return .success(())
        }

        let expected = countBefore - snapshot.text.utf16.count + text.utf16.count
        if countAfter == expected {
            VocaLogger.info(.commandMode, "Replaced a \(snapshot.text.utf16.count)-unit selection with \(text.utf16.count) units")
            return .success(())
        }
        if countAfter == countBefore, text.utf16.count != snapshot.text.utf16.count {
            VocaLogger.warning(.commandMode, "Selection replace was accepted but the document length did not move at all (\(countAfter))")
            return .failure(.writeNotApplied)
        }
        VocaLogger.warning(.commandMode, "Selection replace was accepted but the document length is unexpected (\(countAfter) vs \(expected)) and cannot be read back")
        return .failure(.writeUnverified)
    }

    /// The text occupying `range`, or `nil` if the element does not support
    /// parameterized range reads (or the range is out of bounds).
    ///
    /// AD-5: the string is returned to the comparison on the caller's stack
    /// frame and never logged.
    private func string(in range: CFRange, of element: AXUIElement) -> String? {
        guard range.location >= 0, range.length >= 0 else { return nil }
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange) else { return nil }

        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeValue,
            &result
        ) == .success else {
            return nil
        }
        return result as? String
    }

    /// The focused element of `processIdentifier`'s application, pid-verified,
    /// with no role gate — the identity check `replaceSelection` needs.
    ///
    /// Anchored on the application's own element rather than
    /// `AXUIElementCreateSystemWide()`, and re-checked with `AXUIElementGetPid`
    /// afterwards, for the reason AXContextReader documents (MAJOR 1): a
    /// system-wide focused element may belong to some other process entirely.
    private func focusedElement(processIdentifier: pid_t) -> AXUIElement? {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(processIdentifier),
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        ) == .success,
            let focusedRef,
            CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }

        // swiftlint:disable force_cast
        let element = focusedRef as! AXUIElement
        // swiftlint:enable force_cast

        var elementProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &elementProcessIdentifier) == .success,
              elementProcessIdentifier == processIdentifier else {
            return nil
        }
        return element
    }

    /// Same, plus the role allow-list and the secure-field refusal. Role is
    /// inspected before any value is copied, so a password field's contents
    /// never cross the process boundary.
    private func focusedSelectableElement(processIdentifier: pid_t) -> AXUIElement? {
        guard let element = focusedElement(processIdentifier: processIdentifier) else { return nil }

        guard let role = stringAttribute(kAXRoleAttribute, of: element) else { return nil }
        let subrole = stringAttribute(kAXSubroleAttribute, of: element)

        if Self.secureRoleIdentifiers.contains(role) { return nil }
        if let subrole, Self.secureRoleIdentifiers.contains(subrole) { return nil }
        guard Self.selectableRoles.contains(role) else {
            VocaLogger.debug(.textInjector, "Selection read: skipping role '\(role)'")
            return nil
        }
        return element
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private func intAttribute(_ attribute: String, of element: AXUIElement) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let number = ref as? NSNumber else {
            return nil
        }
        return number.intValue
    }

    private func selectedTextRange(of element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef,
              CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return nil
        }

        // swiftlint:disable force_cast
        let rangeValue = rangeRef as! AXValue
        // swiftlint:enable force_cast

        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return range
    }

    // MARK: - Strategy 2: Clipboard + Cmd+V

    /// Inject text via the system clipboard followed by a simulated Cmd+V.
    /// This is the original injection strategy and acts as a fallback for
    /// apps whose focused element is not writable via the Accessibility API.
    private func injectViaClipboard(text: String, preserveClipboard: Bool) {
        let pasteboard = NSPasteboard.general
        isInjecting = true

        // Deep-copy current clipboard state before we overwrite it.
        // NSPasteboardItem objects are invalidated when the pasteboard is cleared,
        // so we must extract the raw data eagerly.
        //
        // Never snapshot content we put there ourselves: when a previous
        // restore was skipped (or `preserveClipboard` was off) the last
        // transcript is still sitting on the pasteboard, and snapshotting it
        // would arm a later "restore" that overwrites the user's real
        // clipboard with our text (MAJOR 4).
        let isOurOwnContent = pasteboard.changeCount == lastWrittenChangeCount
        if preserveClipboard && isOurOwnContent {
            VocaLogger.debug(.textInjector, "Clipboard still holds our previous transcript — not snapshotting it")
        }
        let snapshot = (preserveClipboard && !isOurOwnContent) ? captureSnapshot(pasteboard) : nil

        // Set transcribed text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        VocaLogger.debug(.textInjector, "Set clipboard: '\(String(text.prefix(80)))'")

        // Record the changeCount right after we write the transcribed text.
        // We check this before restoring so we don't clobber a newer clipboard
        // entry if the user (or another app) copies something in the meantime.
        let changeCountAfterWrite = pasteboard.changeCount
        lastWrittenChangeCount = changeCountAfterWrite

        // Delay to let clipboard settle, then simulate Cmd+V
        DispatchQueue.main.asyncAfter(deadline: .now() + prePasteDelay) { [self] in
            VocaLogger.debug(.textInjector, "Simulating Cmd+V...")
            let didPaste = simulatePaste()

            // The injection is recorded only now, once the paste keystroke has
            // actually gone out. Recording it before meant that a paste which
            // never reached the target still armed an undo — and that undo's
            // ⌘Z would have retracted an edit of the user's own (MAJOR 5).
            if didPaste {
                recordInjection(text: text, strategy: .clipboard, element: nil)
            } else {
                VocaLogger.error(.textInjector, "Paste keystroke was not dispatched — no undoable injection recorded")
            }

            // Restore clipboard as soon as the paste event has been dispatched.
            // The short delay gives the target app time to read the pasteboard.
            guard preserveClipboard else {
                isInjecting = false
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
                defer { self.isInjecting = false }

                // Guard: only restore if the pasteboard hasn't been modified
                // by the user or another app since we wrote the transcribed text.
                guard pasteboard.changeCount == changeCountAfterWrite else {
                    VocaLogger.debug(.textInjector, "Clipboard was modified externally — skipping restore")
                    return
                }

                if let snapshot = snapshot {
                    self.restoreSnapshot(snapshot, to: pasteboard)
                } else {
                    // Previous clipboard was empty; clear the transcribed text
                    pasteboard.clearContents()
                }
                VocaLogger.debug(.textInjector, "Clipboard restored")
            }
        }
    }

    // MARK: - Clipboard Snapshot Management

    /// Deep-copy every item and type from the pasteboard into plain `Data` values.
    /// This must be called *before* `clearContents()` because NSPasteboardItem
    /// objects are invalidated when the pasteboard changes.
    private func captureSnapshot(_ pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else {
            return nil
        }

        var itemSnapshots: [PasteboardItemSnapshot] = []

        for item in pasteboardItems {
            var dataByType: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    dataByType.append((type, data))
                }
            }
            if !dataByType.isEmpty {
                itemSnapshots.append(PasteboardItemSnapshot(dataByType: dataByType))
            }
        }

        guard !itemSnapshots.isEmpty else { return nil }
        return PasteboardSnapshot(items: itemSnapshots)
    }

    /// Write a previously captured snapshot back to the pasteboard.
    private func restoreSnapshot(_ snapshot: PasteboardSnapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        var newItems: [NSPasteboardItem] = []
        for itemSnapshot in snapshot.items {
            let newItem = NSPasteboardItem()
            for (type, data) in itemSnapshot.dataByType {
                newItem.setData(data, forType: type)
            }
            newItems.append(newItem)
        }

        pasteboard.writeObjects(newItems)
        VocaLogger.debug(.textInjector, "Restored clipboard with \(newItems.count) items")
    }

    // MARK: - Paste Simulation

    /// Simulate Cmd+V keystroke to paste from clipboard.
    ///
    /// On non-QWERTY layouts (e.g. Dvorak, Colemak, AZERTY), the hardware
    /// virtual keycode for "V" on a US-QWERTY keyboard (9) maps to a
    /// different character. Posting `kVK_ANSI_V` directly therefore triggers
    /// the wrong shortcut — for example, on Dvorak keycode 9 produces ".",
    /// so the system fires Cmd+. (which most apps interpret as "cancel")
    /// instead of Cmd+V (paste). See GitHub issue #123.
    ///
    /// To fix this, we resolve the keycode that produces the character "v"
    /// on the *currently active* keyboard layout and post that keycode
    /// instead. If the active layout cannot be inspected (e.g. in tests
    /// with no input source available) we fall back to the QWERTY keycode.
    private func simulatePaste() -> Bool {
        pasteKeystrokeDispatcher()
    }

    private static func postPasteKeystroke() -> Bool {
        let keyCode = TextInjector.keyCode(forCharacter: "v") ?? TextInjector.kVK_ANSI_V_Fallback
        VocaLogger.debug(.textInjector, "Resolved keycode for 'v' on active layout: \(keyCode)")

        let source = CGEventSource(stateID: .combinedSessionState)

        // Cmd+V key down
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            VocaLogger.error(.textInjector, "ERROR: Failed to create key down event")
            return false
        }
        keyDown.flags = [.maskCommand]
        keyDown.post(tap: .cgAnnotatedSessionEventTap)

        // Cmd+V key up
        guard let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            VocaLogger.error(.textInjector, "ERROR: Failed to create key up event")
            return false
        }
        keyUp.flags = [.maskCommand]
        keyUp.post(tap: .cgAnnotatedSessionEventTap)

        VocaLogger.info(.textInjector, "Cmd+V posted (keycode \(keyCode))")
        return true
    }

    // MARK: - Keyboard Layout Resolution

    /// Find the virtual keycode that produces the given character on the
    /// currently active keyboard layout.
    ///
    /// This walks all keycodes in the standard ANSI range (0...127) and
    /// translates each one through the active Unicode key layout using
    /// `UCKeyTranslate`, returning the first keycode whose unmodified
    /// output matches the requested character.
    ///
    /// - Parameter character: The character to look up (e.g. "v")
    /// - Returns: The virtual keycode that produces the character on the
    ///            active layout, or `nil` if the character is unreachable
    ///            or the input source cannot be inspected.
    static func keyCode(forCharacter character: Character) -> CGKeyCode? {
        // Prefer the active ASCII-capable input source; this skips over
        // non-Latin layouts like Hiragana where "v" is not directly
        // typable, and falls back to the underlying ASCII layout that
        // macOS uses for shortcut interpretation.
        let inputSource: TISInputSource? = {
            if let asciiSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() {
                return asciiSource
            }
            return TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        }()

        guard let source = inputSource else { return nil }

        guard let layoutDataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPointer).takeUnretainedValue() as Data

        let target = String(character)

        return layoutData.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> CGKeyCode? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            let keyboardLayout = baseAddress.assumingMemoryBound(to: UCKeyboardLayout.self)

            var deadKeyState: UInt32 = 0
            let maxStringLength = 4
            var actualStringLength = 0
            var unicodeString = [UniChar](repeating: 0, count: maxStringLength)

            for keyCode in 0..<128 {
                deadKeyState = 0
                let status = UCKeyTranslate(
                    keyboardLayout,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDisplay),
                    0, // no modifiers — match the bare key
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    maxStringLength,
                    &actualStringLength,
                    &unicodeString
                )

                guard status == noErr, actualStringLength > 0 else { continue }

                let produced = String(utf16CodeUnits: unicodeString, count: actualStringLength)
                if produced == target {
                    return CGKeyCode(keyCode)
                }
            }

            return nil
        }
    }
}

// MARK: - TextInjecting Conformance

extension TextInjector: TextInjecting {}
