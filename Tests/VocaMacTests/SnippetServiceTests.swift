// SnippetServiceTests.swift
// VocaMac Tests
//
// Story 5.4: single and multiple Cues, multi-line body preservation,
// normalization/case-insensitive matching, whitespace and punctuation
// preservation, and the empty/no-match identity paths.

import XCTest
@testable import VocaMac

final class SnippetServiceTests: XCTestCase {

    // MARK: - Empty Snippets (AD-2)

    func testEmptySnippetsIsIdentity() {
        let service = SnippetService()
        let result = service.protect(in: "שלום עולם", using: [])
        XCTAssertEqual(result.text, "שלום עולם")
        XCTAssertTrue(result.protectedSpans.isEmpty)
    }

    func testNoMatchLeavesTextAndSpansEmpty() {
        let service = SnippetService()
        let result = service.protect(in: "nothing to see here", using: [Snippet(cue: "signature", body: "SIG")])
        XCTAssertEqual(result.text, "nothing to see here")
        XCTAssertTrue(result.protectedSpans.isEmpty)
    }

    // MARK: - Single cue

    func testSingleWordCueIsReplacedWithAPlaceholder() {
        let service = SnippetService()
        let snippet = Snippet(cue: "חתימה", body: "בברכה,\nישראל ישראלי")

        let result = service.protect(in: "בבקשה הוסף חתימה כאן", using: [snippet])

        XCTAssertEqual(result.text, "בבקשה הוסף ⟦S0⟧ כאן")
        XCTAssertEqual(result.protectedSpans["⟦S0⟧"], "בברכה,\nישראל ישראלי")
    }

    func testMultiWordCueMatchesAsAContiguousPhrase() {
        let service = SnippetService()
        let snippet = Snippet(cue: "הוסף כתובת מגורים", body: "רחוב הרצל 1, תל אביב")

        let result = service.protect(in: "אנא הוסף כתובת מגורים בסוף", using: [snippet])

        XCTAssertEqual(result.text, "אנא ⟦S0⟧ בסוף")
    }

    // MARK: - Multiple distinct cues

    func testMultipleDistinctCuesAllExpand() {
        let service = SnippetService()
        let snippets = [
            Snippet(cue: "חתימה", body: "SIGNATURE"),
            Snippet(cue: "כתובת", body: "ADDRESS")
        ]

        let result = service.protect(in: "חתימה ואז כתובת בבקשה", using: snippets)

        XCTAssertEqual(result.text, "⟦S0⟧ ואז ⟦S1⟧ בבקשה")
        XCTAssertEqual(result.protectedSpans["⟦S0⟧"], "SIGNATURE")
        XCTAssertEqual(result.protectedSpans["⟦S1⟧"], "ADDRESS")
    }

    // MARK: - Multi-line body preservation

    func testMultiLineBodyIsPreservedVerbatim() {
        let service = SnippetService()
        let body = "Line1\nLine2\n\nLine4"
        let snippet = Snippet(cue: "חתימה", body: body)

        let result = service.protect(in: "הוסף חתימה", using: [snippet])

        XCTAssertEqual(result.protectedSpans["⟦S0⟧"], body)
    }

    // MARK: - Normalization-tolerant and case-insensitive matching

    func testMatchIsToleratesNiqqud() {
        let service = SnippetService()
        let snippet = Snippet(cue: "חתימה", body: "SIG")

        // "חֲתִימָה" -- the same word, fully pointed.
        let result = service.protect(in: "please add my חֲתִימָה here", using: [snippet])

        XCTAssertEqual(result.text, "please add my ⟦S0⟧ here")
    }

    func testMatchIsCaseInsensitiveForLatinCues() {
        let service = SnippetService()
        let snippet = Snippet(cue: "signature", body: "SIG")

        let result = service.protect(in: "ADD MY SIGNATURE NOW", using: [snippet])

        XCTAssertEqual(result.text, "ADD MY ⟦S0⟧ NOW")
    }

    // MARK: - Whitespace and punctuation preservation

    func testSurroundingWhitespaceAndPunctuationArePreserved() {
        let service = SnippetService()
        let snippet = Snippet(cue: "חתימה", body: "SIG")

        let result = service.protect(in: "  please, חתימה!  ", using: [snippet])

        XCTAssertEqual(result.text, "  please, ⟦S0⟧!  ")
    }
}
