// TextInjector.swift
// VocaMac
//
// Injects transcribed text at the cursor position in any application
// using the clipboard (NSPasteboard) + simulated Cmd+V keystroke approach.

import Foundation
import AppKit
import Carbon.HIToolbox

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

        let supportedRoles: Set<String> = ["AXTextField", "AXSearchField", "AXComboBox"]
        guard supportedRoles.contains(role) else {
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
