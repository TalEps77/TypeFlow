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
        let candidate = CorrectionDiffing.detectCandidate(
            injected: "אני משתמש בקוברנטיס כאן",
            current: "אני משתמש בקוברנטס כאן"
        )
        XCTAssertEqual(candidate, CorrectionCandidate(original: "בקוברנטיס", corrected: "בקוברנטס"))
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
