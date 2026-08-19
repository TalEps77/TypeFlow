// AXContextReader.swift
// VocaMac
//
// Captures, in one call at the moment recording starts, everything the
// pipeline may need to know about where the user was aiming (AD-5):
// the frontmost application's bundle identifier (Story 4.1), and — only
// when the caller asks for it — the text immediately around the caret via
// the Accessibility API (Story 4.4).
//
// AD-5 is a hard rule: the caller captures once, at recording start, never
// at recording stop — the user may switch applications mid-dictation, and
// only what was true when they started speaking is meaningful. Whatever
// this returns lives only as long as the one pipeline run that consumes it;
// nothing here is ever logged or persisted by this type itself.

import Foundation
import AppKit

/// Everything captured in one `capture()` call. `cursorContextBefore` and
/// `cursorContextAfter` are `nil` unless `readCursorContext` was `true` and
/// the focused element actually exposed readable text (AD-5, FR-14).
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
    /// - Parameter readCursorContext: When `false`, no Accessibility read of
    ///   the caret's surrounding text is attempted at all — the feature is
    ///   off by default (FR-14), and the cheapest way to guarantee nothing is
    ///   ever read is to not call the API. The bundle identifier is always
    ///   captured; it is not privacy-sensitive and Story 4.1 needs it
    ///   unconditionally.
    func capture(readCursorContext: Bool) -> CapturedContext
}

@MainActor
final class AXContextReader: ContextReading {

    /// Characters kept on each side of the caret. Bounded so a request never
    /// grows with document size (NFR-4) — this runs on the main thread at
    /// recording start and must add negligible latency.
    static let contextCharacterBudget = 500

    func capture(readCursorContext: Bool) -> CapturedContext {
        let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        guard readCursorContext else {
            return CapturedContext(bundleIdentifier: bundleIdentifier, cursorContextBefore: nil, cursorContextAfter: nil)
        }

        let (before, after) = readCursorContextViaAccessibility()
        return CapturedContext(bundleIdentifier: bundleIdentifier, cursorContextBefore: before, cursorContextAfter: after)
    }

    /// Reads the focused element's full text value and caret position, then
    /// slices out up to `contextCharacterBudget` characters on each side.
    ///
    /// Deliberately silent on every failure path (AD-5's "AX read returns
    /// nothing" row): a target app that exposes no readable text, no caret
    /// range, or no AX element at all just yields `(nil, nil)` — the pipeline
    /// proceeds without context, same as a disabled toggle. Nothing here is
    /// ever passed to `VocaLogger` — not the text, not its length — since
    /// even a length can hint at what was in the field.
    private func readCursorContextViaAccessibility() -> (before: String?, after: String?) {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return (nil, nil)
        }

        // swiftlint:disable force_cast
        let element = focusedRef as! AXUIElement
        // swiftlint:enable force_cast

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let fullText = valueRef as? String, !fullText.isEmpty else {
            return (nil, nil)
        }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef else {
            return (nil, nil)
        }

        // swiftlint:disable force_cast
        let rangeValue = rangeRef as! AXValue
        // swiftlint:enable force_cast

        var caretRange = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &caretRange) else {
            return (nil, nil)
        }

        let utf16 = Array(fullText.utf16)
        let caretLocation = min(max(caretRange.location, 0), utf16.count)
        let budget = Self.contextCharacterBudget

        let beforeStart = max(0, caretLocation - budget)
        let beforeUnits = Array(utf16[beforeStart..<caretLocation])
        let before = beforeUnits.isEmpty ? nil : String(utf16CodeUnits: beforeUnits, count: beforeUnits.count)

        let afterEnd = min(utf16.count, caretLocation + budget)
        let afterUnits = caretLocation < afterEnd ? Array(utf16[caretLocation..<afterEnd]) : []
        let after = afterUnits.isEmpty ? nil : String(utf16CodeUnits: afterUnits, count: afterUnits.count)

        return (before, after)
    }
}
