// DictionaryServiceTests.swift
// VocaMac Tests
//
// Story 5.2: exact and near-match replacement, the guards that keep a
// conservative miss preferred to a wrong replacement (SM-C2), whitespace and
// punctuation preservation, the no-substring-match guard, and deterministic
// resolution when entries overlap.

import XCTest
@testable import VocaMac

final class DictionaryServiceTests: XCTestCase {

    // MARK: - Empty dictionary (AD-2)

    func testEmptyDictionaryIsIdentity() {
        let service = DictionaryService()
        let result = service.replace(in: "שלום עולם", using: [])
        XCTAssertEqual(result.text, "שלום עולם")
        XCTAssertEqual(result.replacementCount, 0)
    }

    // MARK: - Exact match

    func testExactTriggerIsReplacedWithCanonicalForm() {
        let service = DictionaryService()
        let entry = DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קוברנטיס"])

        let result = service.replace(in: "אני משתמש בקוברנטיס היום", using: [entry])

        XCTAssertEqual(result.text, "אני משתמש בקוברנטיס היום",
                        "the trigger is inside the longer word 'בקוברנטיס' and must NOT match as a substring")
        XCTAssertEqual(result.replacementCount, 0)
    }

    func testExactTriggerAsAWholeWordIsReplaced() {
        let service = DictionaryService()
        let entry = DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קוברנטיס"])

        let result = service.replace(in: "אני עובד עם קוברנטיס בעבודה", using: [entry])

        XCTAssertEqual(result.text, "אני עובד עם Kubernetes בעבודה")
        XCTAssertEqual(result.replacementCount, 1)
    }

    func testExactMatchIsNormalizationTolerant() {
        // Trigger and spoken word differ only by niqqud + a doubled vav --
        // HebrewNormalizer.normalize brings both to the same form, so this
        // is an *exact* match, not merely a near one.
        let service = DictionaryService()
        let entry = DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קווברנטיס"])

        let result = service.replace(in: "קָוברנטיס זה כלי נהדר", using: [entry])

        XCTAssertEqual(result.text, "Kubernetes זה כלי נהדר")
    }

    // MARK: - Near-match at, above, and below threshold

    func testNearMatchAboveThresholdIsReplaced() {
        // "קוברנטס" vs trigger "קוברנטיס": one character short (missing י),
        // 1 edit over 7 characters -> similarity ~0.857, above an 0.8 threshold.
        let service = DictionaryService(similarityThreshold: 0.8)
        let entry = DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קוברנטיס"])

        let result = service.replace(in: "קוברנטס הותקן בהצלחה", using: [entry])

        XCTAssertEqual(result.text, "Kubernetes הותקן בהצלחה")
    }

    func testNearMatchExactlyAtThresholdIsReplaced() {
        // Construct a pair whose similarity lands exactly on the threshold
        // and assert the boundary is inclusive ("within" the threshold).
        let service = DictionaryService(similarityThreshold: 0.75)
        // "abcd" vs "abcx": distance 1, length 4 -> similarity 0.75 exactly.
        let entry = DictionaryEntry(canonicalForm: "CANON", triggers: ["abcd"])

        let result = service.replace(in: "the word abcx here", using: [entry])

        XCTAssertEqual(result.text, "the word CANON here")
    }

    func testNearMatchBelowThresholdIsNotReplaced() {
        // A conservative miss is preferred to a wrong replacement (SM-C2).
        let service = DictionaryService(similarityThreshold: 0.8)
        let entry = DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קוברנטיס"])

        // "קב" is wildly different from "קוברנטיס" (distance 6 over 8 chars,
        // similarity 0.25) -- far below threshold.
        let result = service.replace(in: "קב זה כלי", using: [entry])

        XCTAssertEqual(result.text, "קב זה כלי")
        XCTAssertEqual(result.replacementCount, 0)
    }

    // MARK: - Whitespace and punctuation preservation

    func testSurroundingWhitespaceAndPunctuationArePreserved() {
        let service = DictionaryService()
        let entry = DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קוברנטיס"])

        let result = service.replace(in: "  קוברנטיס, זה נהדר!  ", using: [entry])

        XCTAssertEqual(result.text, "  Kubernetes, זה נהדר!  ")
    }

    func testMultipleWhitespaceSeparatedWordsAreEachConsidered() {
        let service = DictionaryService()
        let entries = [
            DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קוברנטיס"]),
            DictionaryEntry(canonicalForm: "Docker", triggers: ["דוקר"])
        ]

        let result = service.replace(in: "קוברנטיס ו-דוקר", using: entries)

        XCTAssertEqual(result.text, "Kubernetes ו-Docker")
    }

    // MARK: - No-substring-match guard

    func testTriggerDoesNotMatchInsideALongerUnrelatedWord() {
        let service = DictionaryService()
        // "לך" ("to you") must not fire inside "מלך" ("king").
        let entry = DictionaryEntry(canonicalForm: "CANON", triggers: ["לך"])

        let result = service.replace(in: "המלך יושב על כסאו", using: [entry])

        XCTAssertEqual(result.text, "המלך יושב על כסאו")
    }

    // MARK: - Overlapping entries: deterministic order

    func testOverlappingEntriesResolveByArrayOrderExactMatchFirst() {
        let service = DictionaryService()
        let entries = [
            DictionaryEntry(canonicalForm: "FIRST", triggers: ["term"]),
            DictionaryEntry(canonicalForm: "SECOND", triggers: ["term"])
        ]

        let result = service.replace(in: "the term here", using: entries)

        XCTAssertEqual(result.text, "the FIRST here")
    }

    func testExactMatchInALaterEntryOutranksAFuzzyMatchInAnEarlierEntry() {
        let service = DictionaryService(similarityThreshold: 0.8)
        let entries = [
            // A fuzzy near-neighbor of "term" that would match first if entry
            // order alone decided things.
            DictionaryEntry(canonicalForm: "FUZZY", triggers: ["tern"]),
            DictionaryEntry(canonicalForm: "EXACT", triggers: ["term"])
        ]

        let result = service.replace(in: "the term here", using: entries)

        XCTAssertEqual(result.text, "the EXACT here",
                        "an exact match anywhere in the Dictionary must outrank a fuzzier one")
    }

    // MARK: - Levenshtein distance (the primitive the matcher is built on)

    func testLevenshteinDistanceOfIdenticalStringsIsZero() {
        XCTAssertEqual(levenshteinDistance("abc", "abc"), 0)
    }

    func testLevenshteinDistanceAgainstEmptyStringIsTheOthersLength() {
        XCTAssertEqual(levenshteinDistance("", "abc"), 3)
        XCTAssertEqual(levenshteinDistance("abc", ""), 3)
    }

    func testLevenshteinDistanceOfASingleSubstitution() {
        XCTAssertEqual(levenshteinDistance("abcd", "abcx"), 1)
    }

    func testLevenshteinDistanceOfASingleInsertionOrDeletion() {
        XCTAssertEqual(levenshteinDistance("abc", "abcd"), 1)
        XCTAssertEqual(levenshteinDistance("abcd", "abc"), 1)
    }
}
