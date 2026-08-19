// AXContextReader.swift
// VocaMac
//
// Captures, in one call at the moment recording starts, everything the
// pipeline may need to know about where the user was aiming (AD-5):
// the frontmost application's bundle identifier (Story 4.1), and — only
// when the caller's decision closure says so — the text immediately around
// the caret via the Accessibility API (Story 4.4).
//
// AD-5 is a hard rule: the caller captures once, at recording start, never
// at recording stop — the user may switch applications mid-dictation, and
// only what was true when they started speaking is meaningful. Whatever
// this returns lives only as long as the one pipeline run that consumes it;
// nothing here is ever logged or persisted by this type itself.

import Foundation
import AppKit

/// Everything captured in one `capture()` call. `cursorContextBefore` and
/// `cursorContextAfter` are `nil` unless the caller's decision closure
/// answered `true` for this bundle identifier, and the focused element
/// actually exposed readable text (AD-5, FR-14).
struct CapturedContext: Equatable {
    let bundleIdentifier: String?
    let cursorContextBefore: String?
    let cursorContextAfter: String?

    static let empty = CapturedContext(bundleIdentifier: nil, cursorContextBefore: nil, cursorContextAfter: nil)
}

/// Declared here rather than in ServiceProtocols.swift, alongside its
/// vocabulary (`CapturedContext`) — same precedent as `PostProcessing` in
/// PostProcessService.swift. Registered with a pointer comment there (AD-7).
@MainActor
protocol ContextReading: AnyObject {
    /// The frontmost application's bundle identifier is captured first and
    /// handed to `shouldReadCursorContext`, so the caller can decide — using
    /// it to resolve a Profile — whether Cursor Context should be read for
    /// *this* bundle identifier. Whichever way that answers, it happens
    /// within this one call, at this one moment (AD-5): there is no second,
    /// separate capture the caller could make at a different time.
    ///
    /// The bundle identifier itself is always captured, unconditionally — it
    /// is not privacy-sensitive, and Story 4.1 needs it regardless of any
    /// Cursor Context toggle.
    func capture(shouldReadCursorContext: (String?) -> Bool) -> CapturedContext
}

@MainActor
final class AXContextReader: ContextReading {

    /// Characters kept on each side of the caret. Bounded so a request never
    /// grows with document size (NFR-4) — this runs on the main thread at
    /// recording start and must add negligible latency.
    static let contextCharacterBudget = 500

    func capture(shouldReadCursorContext: (String?) -> Bool) -> CapturedContext {
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let bundleIdentifier = frontmostApp?.bundleIdentifier

        guard shouldReadCursorContext(bundleIdentifier) else {
            return CapturedContext(bundleIdentifier: bundleIdentifier, cursorContextBefore: nil, cursorContextAfter: nil)
        }

        // "AX read returns nothing" (Failure table): no focused element, no
        // readable text, no caret range — proceed without context, silently.
        // Nothing here is ever passed to `VocaLogger`, not even to note that
        // it failed, since even that could hint at what was in the field.
        guard let (fullText, caretLocation) = focusedElementTextAndCaretLocation(
            frontmostProcessIdentifier: frontmostApp?.processIdentifier
        ) else {
            return CapturedContext(bundleIdentifier: bundleIdentifier, cursorContextBefore: nil, cursorContextAfter: nil)
        }

        let (before, after) = AXContextReader.slice(
            fullText: fullText,
            caretUTF16Location: caretLocation,
            budget: Self.contextCharacterBudget
        )
        return CapturedContext(bundleIdentifier: bundleIdentifier, cursorContextBefore: before, cursorContextAfter: after)
    }

    /// Slices out up to `budget` UTF-16 units on each side of the caret.
    /// Pure and side-effect free on purpose — the part of context capture
    /// that doesn't touch the Accessibility API, so the budget/truncation
    /// behavior is unit-testable without AX permission (Story 4.4 AC).
    static func slice(fullText: String, caretUTF16Location: Int, budget: Int) -> (before: String?, after: String?) {
        let utf16 = Array(fullText.utf16)
        let caretLocation = min(max(caretUTF16Location, 0), utf16.count)

        let beforeStart = max(0, caretLocation - budget)
        let beforeUnits = Array(utf16[beforeStart..<caretLocation])
        let before = beforeUnits.isEmpty ? nil : String(utf16CodeUnits: beforeUnits, count: beforeUnits.count)

        let afterEnd = min(utf16.count, caretLocation + budget)
        let afterUnits = caretLocation < afterEnd ? Array(utf16[caretLocation..<afterEnd]) : []
        let after = afterUnits.isEmpty ? nil : String(utf16CodeUnits: afterUnits, count: afterUnits.count)

        return (before, after)
    }

    /// Reads the focused element's full text value and caret position via
    /// the Accessibility API. `nil` on any failure — no AX element, an
    /// element with an unreadable value, or no selection range.
    ///
    /// Tries the frontmost application's own AXUIElement first, falling back
    /// to the system-wide element. Live-verified during Story 4.4: querying
    /// `AXUIElementCreateSystemWide()`'s focused element failed with
    /// `kAXErrorCannotComplete` (-25204) from a process with no active
    /// `NSApplication` run loop of its own, while anchoring on the already-
    /// identified frontmost app's own element (`AXUIElementCreateApplication`)
    /// succeeded reliably against the same target. The system-wide fallback
    /// stays in place for the rare case where the truly-focused element
    /// belongs to a process `NSWorkspace` doesn't report as frontmost.
    private func focusedElementTextAndCaretLocation(frontmostProcessIdentifier: pid_t?) -> (text: String, caretLocation: Int)? {
        if let frontmostProcessIdentifier,
           let result = focusedElementTextAndCaretLocation(in: AXUIElementCreateApplication(frontmostProcessIdentifier)) {
            return result
        }
        return focusedElementTextAndCaretLocation(in: AXUIElementCreateSystemWide())
    }

    private func focusedElementTextAndCaretLocation(in root: AXUIElement) -> (text: String, caretLocation: Int)? {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }

        // swiftlint:disable force_cast
        let element = focusedRef as! AXUIElement
        // swiftlint:enable force_cast

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let fullText = valueRef as? String, !fullText.isEmpty else {
            return nil
        }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef else {
            return nil
        }

        // swiftlint:disable force_cast
        let rangeValue = rangeRef as! AXValue
        // swiftlint:enable force_cast

        var caretRange = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &caretRange) else {
            return nil
        }

        return (fullText, caretRange.location)
    }
}
