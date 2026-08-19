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
    ///
    /// - Parameter fallbackApplication: what to treat as the target when
    ///   VocaMac itself is frontmost — the hotkey can be pressed while our
    ///   own settings or History window has key status, and resolving a
    ///   Profile for *us* (and AX-reading our own text fields) is never what
    ///   the user meant (MINOR 9). `nil` means "no fallback known", in which
    ///   case a self-frontmost capture yields no bundle identifier and no
    ///   Cursor Context rather than our own.
    func capture(
        fallbackApplication: NSRunningApplication?,
        shouldReadCursorContext: (String?) -> Bool
    ) -> CapturedContext

    /// Reads the focused element's current full text value via the same
    /// Accessibility path `capture` uses — but, unlike `capture`, at
    /// whatever later moment the caller asks, not tied to recording start.
    ///
    /// This carries no AD-5 obligation of its own; it exists for Story 5.6's
    /// correction-learning re-read, and it is that caller's responsibility
    /// (upheld by `CorrectionLearner`) to treat the returned text as
    /// transient — used for one local, in-memory diff and never logged or
    /// persisted.
    func readFocusedElementText(processIdentifier: pid_t?) -> String?
}

@MainActor
final class AXContextReader: ContextReading {

    /// Characters kept on each side of the caret. Bounded so a request never
    /// grows with document size (NFR-4) — this runs on the main thread at
    /// recording start and must add negligible latency.
    static let contextCharacterBudget = 500

    /// Hard ceiling on a whole-value read, used only on the fallback path
    /// where the parameterized range attribute is unsupported. A text view
    /// holding a multi-megabyte document would otherwise copy all of it
    /// across the process boundary, synchronously, on the main thread
    /// (MAJOR 3) — and then keep it alive for as long as the caller does.
    static let maximumWholeValueCharacters = 200_000

    /// Roles whose `AXValue` is ordinary editable text the user is typing
    /// into. An allow-list rather than a deny-list on purpose (MAJOR 2): a
    /// role we have never heard of gets no read at all, which is the safe
    /// default for a capability whose whole cost is what it might see.
    static let readableRoles: Set<String> = [
        kAXTextAreaRole as String,
        kAXTextFieldRole as String
    ]

    /// Roles/subroles that mask their contents in the UI and must never be
    /// read even though they are text fields. AppKit usually refuses to hand
    /// out a secure field's value, but "usually" is not a guarantee, and
    /// non-AppKit toolkits make no such promise at all (MAJOR 2).
    static let secureRoleIdentifiers: Set<String> = [
        kAXSecureTextFieldSubrole as String,
        "AXSecureTextField"
    ]

    func capture(
        fallbackApplication: NSRunningApplication?,
        shouldReadCursorContext: (String?) -> Bool
    ) -> CapturedContext {
        // MINOR 9: when we are frontmost — the hotkey pressed from our own
        // settings or History window — the app the user is actually
        // dictating into is the last one *other* than us to hold focus.
        let frontmost = NSWorkspace.shared.frontmostApplication
        let isSelf = frontmost?.processIdentifier == NSRunningApplication.current.processIdentifier
        let targetApp = isSelf ? fallbackApplication : frontmost
        let bundleIdentifier = targetApp?.bundleIdentifier

        guard shouldReadCursorContext(bundleIdentifier) else {
            return CapturedContext(bundleIdentifier: bundleIdentifier, cursorContextBefore: nil, cursorContextAfter: nil)
        }

        // "AX read returns nothing" (Failure table): no focused element, no
        // readable text, no caret range — proceed without context, silently.
        // Nothing here is ever passed to `VocaLogger`, not even to note that
        // it failed, since even that could hint at what was in the field.
        guard let element = focusedTextElement(processIdentifier: targetApp?.processIdentifier),
              let (before, after) = cursorContext(around: element, budget: Self.contextCharacterBudget) else {
            return CapturedContext(bundleIdentifier: bundleIdentifier, cursorContextBefore: nil, cursorContextAfter: nil)
        }

        return CapturedContext(bundleIdentifier: bundleIdentifier, cursorContextBefore: before, cursorContextAfter: after)
    }

    func readFocusedElementText(processIdentifier: pid_t?) -> String? {
        guard let element = focusedTextElement(processIdentifier: processIdentifier) else { return nil }
        return wholeValue(of: element)
    }

    // MARK: - Pure slicing (no AX — unit-testable without permission)

    /// Slices out up to `budget` UTF-16 units on each side of the caret.
    /// Pure and side-effect free on purpose — the part of context capture
    /// that doesn't touch the Accessibility API, so the budget/truncation
    /// behavior is unit-testable without AX permission (Story 4.4 AC).
    ///
    /// - Parameter selectionLength: how much text is currently *selected* at
    ///   the caret. That selection is what a dictation is about to replace,
    ///   so it belongs to neither side of the context: the "after" side
    ///   starts past it, not at the selection's start (MINOR 8).
    static func slice(
        fullText: String,
        caretUTF16Location: Int,
        selectionLength: Int = 0,
        budget: Int
    ) -> (before: String?, after: String?) {
        let utf16 = Array(fullText.utf16)
        let caretLocation = min(max(caretUTF16Location, 0), utf16.count)
        let selectionEnd = min(caretLocation + max(selectionLength, 0), utf16.count)

        let beforeStart = max(0, caretLocation - budget)
        let before = string(fromUTF16: utf16, in: beforeStart..<caretLocation)

        let afterEnd = min(utf16.count, selectionEnd + budget)
        let after = string(fromUTF16: utf16, in: selectionEnd..<afterEnd)

        return (before, after)
    }

    /// Builds a `String` from a UTF-16 range, dropping a surrogate half left
    /// orphaned at either end. A budget boundary can land between the two
    /// halves of an astral character (emoji, and every Hebrew cantillation
    /// mark's neighbors in some fonts); `String(utf16CodeUnits:)` turns an
    /// orphaned half into U+FFFD, so the LLM would be shown a corrupted
    /// character that isn't in the user's document at all (MINOR 7).
    private static func string(fromUTF16 utf16: [UInt16], in range: Range<Int>) -> String? {
        guard range.lowerBound < range.upperBound else { return nil }
        var units = Array(utf16[range])
        if let first = units.first, UTF16.isTrailSurrogate(first) {
            units.removeFirst()
        }
        if let last = units.last, UTF16.isLeadSurrogate(last) {
            units.removeLast()
        }
        guard !units.isEmpty else { return nil }
        return String(utf16CodeUnits: units, count: units.count)
    }

    // MARK: - Accessibility

    /// The focused element of `processIdentifier`'s application, if it is one
    /// this reader is willing to read.
    ///
    /// Anchoring on the target application's own `AXUIElement` was
    /// live-verified during Story 4.4: querying `AXUIElementCreateSystemWide()`
    /// failed with `kAXErrorCannotComplete` (-25204) from a process with no
    /// active `NSApplication` run loop of its own, while
    /// `AXUIElementCreateApplication` succeeded reliably against the same
    /// target. The system-wide fallback that used to sit behind it has been
    /// dropped: its focused element may belong to a *different* process than
    /// the one the caller's Profile gate was answered for — a 1Password or
    /// Keychain panel, say — so a read that fell back to it read something
    /// the user never opted in for (MAJOR 1).
    private func focusedTextElement(processIdentifier: pid_t?) -> AXUIElement? {
        guard let processIdentifier else { return nil }

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

        // Belt and braces for MAJOR 1: even anchored on one application's
        // element, confirm what came back really belongs to that process
        // before reading a single character out of it.
        var elementProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &elementProcessIdentifier) == .success,
              elementProcessIdentifier == processIdentifier else {
            return nil
        }

        guard isReadableTextElement(element) else { return nil }
        return element
    }

    /// MAJOR 2: role and subrole are inspected *before* any value is copied,
    /// so a password field's contents never cross the process boundary at all.
    private func isReadableTextElement(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute, of: element) else { return false }
        let subrole = stringAttribute(kAXSubroleAttribute, of: element)

        if Self.secureRoleIdentifiers.contains(role) { return false }
        if let subrole, Self.secureRoleIdentifiers.contains(subrole) { return false }

        return Self.readableRoles.contains(role)
    }

    /// The bounded window around the caret, fetched with as little copied
    /// across the process boundary as the element allows (MAJOR 3).
    private func cursorContext(around element: AXUIElement, budget: Int) -> (before: String?, after: String?)? {
        guard let selection = selectedTextRange(of: element) else { return nil }

        let caretLocation = max(Int(selection.location), 0)
        let selectionLength = max(Int(selection.length), 0)

        // Preferred path: ask only for the two windows we actually want.
        // `AXUIElementCopyAttributeValue(kAXValueAttribute)` copies the
        // *entire* value — a 10MB text view is a 10MB IPC copy on the main
        // thread at hotkey press, and then 10MB held for the length of the
        // dictation (MAJOR 3, NFR-4, AD-5).
        if let characterCount = intAttribute(kAXNumberOfCharactersAttribute, of: element) {
            let clampedCaret = min(caretLocation, characterCount)
            let selectionEnd = min(clampedCaret + selectionLength, characterCount)

            let beforeStart = max(0, clampedCaret - budget)
            let afterLength = min(budget, characterCount - selectionEnd)

            if let before = stringForRange(element, location: beforeStart, length: clampedCaret - beforeStart),
               let after = stringForRange(element, location: selectionEnd, length: afterLength) {
                return (
                    Self.trimmedContextEdge(before, trimLeading: true),
                    Self.trimmedContextEdge(after, trimLeading: false)
                )
            }
        }

        // Fallback for elements that do not implement the parameterized
        // attribute: the whole value, but never an unbounded amount of it.
        guard let fullText = wholeValue(of: element) else { return nil }
        return Self.slice(
            fullText: fullText,
            caretUTF16Location: caretLocation,
            selectionLength: selectionLength,
            budget: budget
        )
    }

    /// Whole-value read, capped. Used by the fallback context path and by
    /// Story 5.6's correction-learning re-read.
    private func wholeValue(of element: AXUIElement) -> String? {
        if let characterCount = intAttribute(kAXNumberOfCharactersAttribute, of: element),
           characterCount > Self.maximumWholeValueCharacters {
            return nil
        }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let text = valueRef as? String,
              !text.isEmpty,
              text.utf16.count <= Self.maximumWholeValueCharacters else {
            return nil
        }
        return text
    }

    /// A window the parameterized attribute cut mid-surrogate arrives here
    /// already carrying U+FFFD in place of the split character — the same
    /// corruption `string(fromUTF16:in:)` prevents on the slicing path
    /// (MINOR 7). Drop it from the cut edge only: the other edge is the
    /// caret, which the user's own text cursor never splits.
    private static func trimmedContextEdge(_ text: String, trimLeading: Bool) -> String? {
        var trimmed = Substring(text)
        if trimLeading, trimmed.first == "\u{FFFD}" {
            trimmed = trimmed.dropFirst()
        }
        if !trimLeading, trimmed.last == "\u{FFFD}" {
            trimmed = trimmed.dropLast()
        }
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    // MARK: - Attribute helpers

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

    /// `kAXStringForRangeParameterizedAttribute` — the one call that copies a
    /// window instead of a document. An empty window is answered locally
    /// rather than asked for, since a zero-length range is rejected outright
    /// by some implementations.
    private func stringForRange(_ element: AXUIElement, location: Int, length: Int) -> String? {
        guard length > 0 else { return "" }

        var range = CFRange(location: location, length: length)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }

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
}
