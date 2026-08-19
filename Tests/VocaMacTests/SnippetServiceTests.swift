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

    // MARK: - A Cue must not reach across a boundary (MINOR 3)

    func testAMultiWordCueDoesNotMatchAcrossAFullStop() {
        // "תודה. רבה" is two sentences. Matching the Cue "תודה רבה" here would
        // also swallow the full stop the speaker put there.
        let service = SnippetService()
        let snippet = Snippet(cue: "תודה רבה", body: "BODY")

        let result = service.protect(in: "תודה. רבה לך", using: [snippet])

        XCTAssertEqual(result.text, "תודה. רבה לך")
        XCTAssertTrue(result.protectedSpans.isEmpty)
    }

    func testAMultiWordCueDoesNotMatchAcrossALineBreak() {
        let service = SnippetService()
        let snippet = Snippet(cue: "תודה רבה", body: "BODY")

        let result = service.protect(in: "תודה\nרבה לך", using: [snippet])

        XCTAssertEqual(result.text, "תודה\nרבה לך")
    }

    func testAMultiWordCueStillMatchesAcrossOrdinaryWhitespace() {
        let service = SnippetService()
        let snippet = Snippet(cue: "תודה רבה", body: "BODY")

        XCTAssertEqual(service.protect(in: "אמרתי תודה רבה לך", using: [snippet]).text, "אמרתי ⟦S0⟧ לך")
        XCTAssertEqual(service.protect(in: "אמרתי תודה  רבה לך", using: [snippet]).text, "אמרתי ⟦S0⟧ לך")
    }

    // MARK: - A blank body never mints a placeholder (BLOCKER 1)

    func testASnippetWithABlankBodyIsSkippedEntirely() {
        let service = SnippetService()

        let result = service.protect(in: "הוסף חתימה כאן", using: [Snippet(cue: "חתימה", body: "   \n")])

        XCTAssertEqual(result.text, "הוסף חתימה כאן")
        XCTAssertTrue(result.protectedSpans.isEmpty)
    }

    func testABlankBodiedSnippetDoesNotShadowALaterUsableOne() {
        let service = SnippetService()
        let snippets = [
            Snippet(cue: "חתימה", body: ""),
            Snippet(cue: "כתובת", body: "ADDRESS")
        ]

        let result = service.protect(in: "חתימה ואז כתובת", using: snippets)

        XCTAssertEqual(result.text, "חתימה ואז ⟦S0⟧")
    }

    // MARK: - Placeholder detection (the pipeline's last line of defence)

    func testContainsPlaceholderRecognizesOurOwnTokensAndNothingElse() {
        XCTAssertTrue(SnippetService.containsPlaceholder("Please add my ⟦S0⟧ here"))
        XCTAssertTrue(SnippetService.containsPlaceholder("⟦S12⟧"))
        XCTAssertFalse(SnippetService.containsPlaceholder("Please add my signature here"))
        XCTAssertFalse(SnippetService.containsPlaceholder("⟦SX⟧"))
    }
}
