// CorrectionDiffingTests.swift
// VocaMac Tests
//
// Story 5.6: the bounded word-level diff at the heart of correction
// learning. A single-word edit is a candidate; anything else — identical
// text, a different word count, more than one differing word, or nothing
// at all — must produce no candidate (R-6: a conservative miss over noise).

import XCTest
@testable import VocaMac

final class CorrectionDiffingTests: XCTestCase {

    // MARK: - Single-word edit -> a candidate

    func testSingleWordSubstitutionIsACandidate() {
        let candidate = CorrectionDiffing.detectCandidate(
            injected: "please add Kuberentes here",
            current: "please add Kubernetes here"
        )
        XCTAssertEqual(candidate, CorrectionCandidate(original: "Kuberentes", corrected: "Kubernetes"))
    }

    func testSingleWordEditInHebrewIsACandidate() {
        // MINOR 15: the shared bound prefix ב is dropped from both sides. The
        // correction is of קוברנטיס, not of the prefixed form — learning the
        // prefixed pair yields an entry that only ever fires after ב.
        let candidate = CorrectionDiffing.detectCandidate(
            injected: "אני משתמש בקוברנטיס כאן",
            current: "אני משתמש בקוברנטס כאן"
        )
        XCTAssertEqual(candidate, CorrectionCandidate(original: "קוברנטיס", corrected: "קוברנטס"))
    }

    func testABoundPrefixOnOnlyOneSideIsNotStripped() {
        // The prefix is part of what changed, so it stays.
        let candidate = CorrectionDiffing.detectCandidate(
            injected: "אני משתמש קוברנטיס כאן",
            current: "אני משתמש בקוברנטיס כאן"
        )
        XCTAssertEqual(candidate, CorrectionCandidate(original: "קוברנטיס", corrected: "בקוברנטיס"))
    }

    // MARK: - The injected text located inside a larger field (MAJOR 7)

    func testACorrectionIsFoundWhenTheFieldAlsoHoldsOtherText() {
        // The dominant real case: dictating a reply under a quoted thread, or
        // appending to a paragraph that is already there. Diffing against the
        // whole field made every one of these bail on the word count.
        let candidate = CorrectionDiffing.detectCandidate(
            injected: "please add Kuberentes here",
            current: "On Monday you wrote: please add Kubernetes here\n\nThanks"
        )
        XCTAssertEqual(candidate, CorrectionCandidate(original: "Kuberentes", corrected: "Kubernetes"))
    }

    func testTextTypedAroundAnUnchangedDictationProducesNoCandidate() {
        XCTAssertNil(CorrectionDiffing.detectCandidate(
            injected: "please add Kubernetes here",
            current: "hello there, please add Kubernetes here, thanks very much"
        ))
    }

    func testAnAmbiguousLocationProducesNoCandidate() {
        // Two equally good places the dictation could sit; which one the user
        // edited is a guess.
        XCTAssertNil(CorrectionDiffing.detectCandidate(
            injected: "add the thing",
            current: "add the thang add the thong"
        ))
    }

    // MARK: - Magnitude bound (MAJOR 11)

    func testAnOrdinaryWordSwapIsNotACorrection() {
        // Confirming these would install a permanent global find-and-replace.
        XCTAssertNil(CorrectionDiffing.detectCandidate(injected: "see you Monday", current: "see you Tuesday"))
        XCTAssertNil(CorrectionDiffing.detectCandidate(injected: "הוא אמר לי", current: "הוא טען לי"))
        XCTAssertNil(CorrectionDiffing.detectCandidate(injected: "the red car", current: "the blue car"))
    }

    func testATinyWordSwapIsNotACorrectionEither() {
        // Distance 2, but over two characters — the similarity floor is what
        // catches this one.
        XCTAssertNil(CorrectionDiffing.detectCandidate(injected: "get at it", current: "get on it"))
    }

    func testADifferenceOnlyInNiqqudProducesNoCandidate() {
        // Identical once normalized: every comparison in this epic already
        // treats these as the same word, so there is nothing to learn.
        XCTAssertNil(CorrectionDiffing.detectCandidate(injected: "אמרתי שלום לך", current: "אמרתי שָׁלוֹם לך"))
    }

    func testEditAtTheFirstWordIsStillDetected() {
        let candidate = CorrectionDiffing.detectCandidate(injected: "helo world", current: "hello world")
        XCTAssertEqual(candidate, CorrectionCandidate(original: "helo", corrected: "hello"))
    }

    func testEditAtTheLastWordIsStillDetected() {
        let candidate = CorrectionDiffing.detectCandidate(injected: "hello wrold", current: "hello world")
        XCTAssertEqual(candidate, CorrectionCandidate(original: "wrold", corrected: "world"))
    }

    // MARK: - No difference -> no candidate

    func testIdenticalTextProducesNoCandidate() {
        XCTAssertNil(CorrectionDiffing.detectCandidate(injected: "hello world", current: "hello world"))
    }

    func testPunctuationOnlyChangeProducesNoCandidate() {
        // Words unchanged; only a comma was added. Not a word-level edit.
        XCTAssertNil(CorrectionDiffing.detectCandidate(injected: "hello, world", current: "hello world"))
    }

    // MARK: - Large or diffuse differences -> no candidate (R-6)

    func testDifferentWordCountProducesNoCandidate() {
        // The user typed a whole new word in, not a correction.
        XCTAssertNil(CorrectionDiffing.detectCandidate(injected: "hello world", current: "hello there world"))
    }

    func testMultipleDifferingWordsProducesNoCandidate() {
        XCTAssertNil(CorrectionDiffing.detectCandidate(injected: "the cat sat", current: "the dog ran"))
    }

    func testACompleteRewriteWithADifferentWordCountProducesNoCandidate() {
        XCTAssertNil(CorrectionDiffing.detectCandidate(injected: "hi", current: "hi there how are you"))
    }

    // MARK: - Empty input

    func testBothEmptyProducesNoCandidate() {
        XCTAssertNil(CorrectionDiffing.detectCandidate(injected: "", current: ""))
    }

    func testOneEmptyOneNotProducesNoCandidate() {
        XCTAssertNil(CorrectionDiffing.detectCandidate(injected: "", current: "hello"))
        XCTAssertNil(CorrectionDiffing.detectCandidate(injected: "hello", current: ""))
    }
}
