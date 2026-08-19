// HebrewNormalizerTests.swift
// VocaMac Tests
//
// Story 5.1: HebrewNormalizer is the foundation every fuzzy match in Epic 5
// stands on (NFR-6), so it is tested densely — each transformation alone,
// combinations, idempotence, Latin pass-through, and empty/whitespace input.

import XCTest
@testable import VocaMac

final class HebrewNormalizerTests: XCTestCase {

    // MARK: - Niqqud and cantillation stripping

    func testStripsNiqqudVowelPoints() {
        // "שָׁלוֹם" (shalom) fully pointed, with sheva/kamatz/holam and the
        // shin dot -> "שלום" bare.
        XCTAssertEqual(HebrewNormalizer.stripNiqqud("שָׁלוֹם"), "שלום")
    }

    func testStripsCantillationMarks() {
        // Etnahta (U+0591) and a few common trope marks on "בְּרֵאשִׁית".
        let cantillated = "בְּרֵאשִׁ֖ית"
        XCTAssertEqual(HebrewNormalizer.stripNiqqud(cantillated), "בראשית")
    }

    func testDoesNotStripMaqafOrSofPasuq() {
        // Maqaf (U+05BE) and sof pasuq (U+05C3) are punctuation, not
        // diacritics -- stripping them would corrupt word boundaries.
        XCTAssertEqual(HebrewNormalizer.stripNiqqud("כל\u{05BE}טוב"), "כל\u{05BE}טוב")
        XCTAssertEqual(HebrewNormalizer.stripNiqqud("שלום\u{05C3}"), "שלום\u{05C3}")
    }

    // MARK: - Matres lectionis (ו/וו, י/יי)

    func testCollapsesDoubledVav() {
        XCTAssertEqual(HebrewNormalizer.normalizeMatresLectionis("קווברנטיס"), "קוברנטיס")
    }

    func testCollapsesDoubledYod() {
        XCTAssertEqual(HebrewNormalizer.normalizeMatresLectionis("דיינות"), "דינות")
    }

    func testCollapsesARunOfThreeIdenticalLetters() {
        // A run longer than 2 must still fully collapse to a single letter --
        // this is the case a naive single-pass string replace gets wrong.
        XCTAssertEqual(HebrewNormalizer.normalizeMatresLectionis("וווהלך"), "והלך")
    }

    func testLeavesASingleVavOrYodAlone() {
        XCTAssertEqual(HebrewNormalizer.normalizeMatresLectionis("דוד"), "דוד")
    }

    // MARK: - Final-letter forms

    func testNormalizesAllFiveFinalForms() {
        XCTAssertEqual(HebrewNormalizer.normalizeFinalForms("ך"), "כ")
        XCTAssertEqual(HebrewNormalizer.normalizeFinalForms("ם"), "מ")
        XCTAssertEqual(HebrewNormalizer.normalizeFinalForms("ן"), "נ")
        XCTAssertEqual(HebrewNormalizer.normalizeFinalForms("ף"), "פ")
        XCTAssertEqual(HebrewNormalizer.normalizeFinalForms("ץ"), "צ")
    }

    func testNormalizesFinalFormsInsideAWord() {
        XCTAssertEqual(HebrewNormalizer.normalizeFinalForms("מלך"), "מלכ")
    }

    func testLeavesBaseFormsAlone() {
        XCTAssertEqual(HebrewNormalizer.normalizeFinalForms("מלכה"), "מלכה")
    }

    // MARK: - Geresh and gershayim

    func testConvertsApostropheAfterHebrewLetterToGeresh() {
        // ג' for the /dʒ/ sound, as in "ג'ירפה" (giraffe).
        XCTAssertEqual(HebrewNormalizer.normalizeGereshGershayim("ג'ירפה"), "ג\u{05F3}ירפה")
    }

    func testConvertsTypographicApostropheAfterHebrewLetterToGeresh() {
        XCTAssertEqual(HebrewNormalizer.normalizeGereshGershayim("ג\u{2019}ירפה"), "ג\u{05F3}ירפה")
    }

    func testConvertsQuoteAfterHebrewLetterToGershayim() {
        // A Hebrew acronym, e.g. "מזכ"ל" (secretary-general).
        XCTAssertEqual(HebrewNormalizer.normalizeGereshGershayim("מזכ\"ל"), "מזכ\u{05F4}ל")
    }

    func testLeavesEnglishApostropheUnchanged() {
        // "don't" -- the apostrophe follows Latin "n", not a Hebrew letter.
        XCTAssertEqual(HebrewNormalizer.normalizeGereshGershayim("don't"), "don't")
    }

    func testLeavesEnglishQuoteUnchanged() {
        XCTAssertEqual(HebrewNormalizer.normalizeGereshGershayim("a 12\" screen"), "a 12\" screen")
    }

    func testGereshAtStringStartIsUnchanged() {
        XCTAssertEqual(HebrewNormalizer.normalizeGereshGershayim("'sup"), "'sup")
    }

    // MARK: - Latin pass-through (mixed transcripts)

    func testLatinTextPassesThroughUnchanged() {
        // The Latin identifiers themselves must survive verbatim; the Hebrew
        // portion around them is still subject to its own normalization
        // rules (e.g. "הזמן" ends in a final nun, which normalizes to base
        // nun regardless of what surrounds it) -- it is the Latin substrings
        // that must be byte-identical, not the string as a whole.
        let mixed = "אני משתמש ב-Kubernetes ו-Docker כל הזמן"
        let normalized = HebrewNormalizer.normalize(mixed)
        XCTAssertTrue(normalized.contains("Kubernetes"))
        XCTAssertTrue(normalized.contains("Docker"))
    }

    func testPureLatinTextIsUntouchedByTheFullPipeline() {
        let latin = "The quick brown fox jumps over the lazy dog: don't stop, it's 12\" long."
        XCTAssertEqual(HebrewNormalizer.normalize(latin), latin)
    }

    // MARK: - Full pipeline: variant pairs that must normalize identically

    func testVariantPairsNormalizeIdentically() {
        let pairs: [(String, String)] = [
            ("שָׁלוֹם", "שלום"),                    // niqqud vs bare
            ("מלך", "מלכ"),                         // final vs base form (post-normalization form)
            ("ג'ירפה", "ג\u{05F3}ירפה"),            // ASCII apostrophe vs canonical geresh, post-pipeline
            ("\u{05F0}אס", "וואס"),                 // Yiddish double-vav ligature vs the letter pair (MINOR 6)
            ("\u{05F2}ד", "ייד"),                   // Yiddish double-yod ligature vs the letter pair
        ]
        for (variant, canonical) in pairs {
            XCTAssertEqual(
                HebrewNormalizer.normalize(variant),
                HebrewNormalizer.normalize(canonical),
                "expected '\(variant)' and '\(canonical)' to normalize identically"
            )
        }
    }

    // MARK: - Matres lectionis is NOT part of normalize (MAJOR 1)

    func testNormalizeDoesNotMergeDistinctWordsThatDifferOnlyByAMatresLectionis() {
        // These are four different Hebrew words, not four spellings of one.
        // `normalize` feeds exact-match tiers that bypass every threshold and
        // anchor, so merging them there rewrites text the user really said.
        let distinctPairs: [(String, String)] = [
            ("מוות", "מות"),
            ("עוול", "עול"),
            ("ראייה", "ראיה"),
            ("חייב", "חיב"),
        ]
        for (first, second) in distinctPairs {
            XCTAssertNotEqual(
                HebrewNormalizer.normalize(first),
                HebrewNormalizer.normalize(second),
                "'\(first)' and '\(second)' are different words and must not normalize the same"
            )
        }
    }

    func testTheStandaloneCollapseStillUnifiesSpellingVariants() {
        // Story 5.1's AC still holds for the transform itself — it is only no
        // longer wired into `normalize` or into any matcher.
        XCTAssertEqual(
            HebrewNormalizer.normalizeMatresLectionis("קווברנטיס"),
            HebrewNormalizer.normalizeMatresLectionis("קוברנטיס")
        )
    }

    func testCombinedTransformationsAllApplyTogether() {
        // Niqqud + final form + ASCII apostrophe, all in one string. The
        // doubled vav is deliberately preserved (MAJOR 1).
        let input = "קָווברנטיס' מלך"
        let expected = "קווברנטיס\u{05F3} מלכ"
        XCTAssertEqual(HebrewNormalizer.normalize(input), expected)
    }

    // MARK: - Idempotence

    func testNormalizeIsIdempotent() {
        let samples = [
            "שָׁלוֹם",
            "קווברנטיס",
            "וווהלך",
            "ג'ירפה",
            "מזכ\"ל",
            "אני משתמש ב-Kubernetes",
            "",
            "   ",
        ]
        for sample in samples {
            let once = HebrewNormalizer.normalize(sample)
            let twice = HebrewNormalizer.normalize(once)
            XCTAssertEqual(once, twice, "normalize should be idempotent for '\(sample)'")
        }
    }

    // MARK: - Empty and whitespace input

    func testEmptyStringNormalizesToEmptyString() {
        XCTAssertEqual(HebrewNormalizer.normalize(""), "")
    }

    func testWhitespaceOnlyInputPassesThroughUnchanged() {
        XCTAssertEqual(HebrewNormalizer.normalize("   \n\t "), "   \n\t ")
    }
}
