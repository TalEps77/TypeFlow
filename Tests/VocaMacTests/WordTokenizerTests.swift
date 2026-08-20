// WordTokenizerTests.swift
// VocaMac Tests
//
// `WordTokenizer.phrase(_:normalizing:)` is what VocabularySettingsTab's
// Dictionary Entry editor calls (as `isTriggerUsable`) to decide whether the
// "Add" button next to a typed-or-dictated trigger is enabled — `nil` means
// disabled. These tests pin that exact condition down, using the same
// `HebrewNormalizer.normalize` closure the editor passes, so a future change
// to either side can't silently re-disable Add for ordinary input again.

import XCTest
@testable import VocaMac

final class WordTokenizerTests: XCTestCase {

    // MARK: - Trigger-add enablement (VocabularySettingsTab.isTriggerUsable)

    func testPlainAlphanumericTriggerIsUsable() {
        // The ordinary case: typing or dictating a plain mis-transcribed
        // variant must enable Add, not leave it disabled.
        XCTAssertNotNil(WordTokenizer.phrase("testtrigger", normalizing: HebrewNormalizer.normalize))
    }

    func testHebrewTriggerIsUsable() {
        XCTAssertNotNil(WordTokenizer.phrase("שלום", normalizing: HebrewNormalizer.normalize))
    }

    func testMultiWordTriggerWithASpaceGapIsUsable() {
        XCTAssertNotNil(WordTokenizer.phrase("node js", normalizing: HebrewNormalizer.normalize))
    }

    func testTriggerWithAnInPhraseDotIsUsable() {
        // node.js: a legal in-phrase separator (no whitespace) between words.
        XCTAssertNotNil(WordTokenizer.phrase("node.js", normalizing: HebrewNormalizer.normalize))
    }

    func testEmptyTriggerIsNotUsable() {
        // The field's initial/cleared state — Add must stay disabled here.
        XCTAssertNil(WordTokenizer.phrase("", normalizing: HebrewNormalizer.normalize))
    }

    func testWhitespaceOnlyTriggerIsNotUsable() {
        XCTAssertNil(WordTokenizer.phrase("   ", normalizing: HebrewNormalizer.normalize))
    }

    func testPunctuationOnlyTriggerIsNotUsable() {
        // MAJOR 3 in VocabularySettingsTab: no letters or digits at all can
        // never match anything, so Add correctly stays disabled.
        XCTAssertNil(WordTokenizer.phrase("...", normalizing: HebrewNormalizer.normalize))
    }

    func testSentenceGapTriggerIsNotUsable() {
        // A ". " gap (period + space) is a sentence boundary, not a legal
        // in-phrase separator — MINOR 3's mixed-gap rule.
        XCTAssertNil(WordTokenizer.phrase("hello. world", normalizing: HebrewNormalizer.normalize))
    }
}
