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

    // MINOR 12: this was named `testExactTriggerIsReplacedWithCanonicalForm`
    // while asserting the exact opposite — the one test whose name a reader
    // scanning for exact-match coverage would stop at. The real exact-match
    // case is `testExactTriggerAsAWholeWordIsReplaced` below.
    // The bound-prefix tier (DeveloperTerms) changed this from "never touch a
    // prefixed word" to "peel the prefix, require an exact remainder, keep the
    // prefix with a maqaf". The substring guard it used to assert still holds
    // for anything that is not exactly prefix + trigger — see
    // testPrefixedWordWithInexactRemainderIsNotReplaced.
    func testTriggerCarryingABoundPrefixKeepsThePrefixWithAMaqaf() {
        let service = DictionaryService()
        let entry = DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קוברנטיס"])

        let result = service.replace(in: "אני משתמש בקוברנטיס היום", using: [entry])

        XCTAssertEqual(result.text, "אני משתמש ב\u{05BE}Kubernetes היום")
        XCTAssertEqual(result.replacementCount, 1)
    }

    func testPrefixedWordWithInexactRemainderIsNotReplaced() {
        let service = DictionaryService()
        let entry = DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קוברנטיס"])

        // One letter off after the prefix: the prefix tier is exact-only and the
        // fuzzy tier's first-character anchor refuses the prefixed form.
        let result = service.replace(in: "אני משתמש בקוברנטס היום", using: [entry])

        XCTAssertEqual(result.text, "אני משתמש בקוברנטס היום")
        XCTAssertEqual(result.replacementCount, 0)
    }

    func testTwoLetterPrefixIsPeeledWhole() {
        let service = DictionaryService()
        let entry = DictionaryEntry(canonicalForm: "commit", triggers: ["קומיט"])

        let result = service.replace(in: "תבדוק והקומיט יעבור", using: [entry])

        XCTAssertEqual(result.text, "תבדוק וה\u{05BE}commit יעבור")
    }

    func testShortRemainderIsNotTreatedAsPrefixed() {
        let service = DictionaryService()
        // "בית" must not become ב + a two-letter trigger.
        let entry = DictionaryEntry(canonicalForm: "IT", triggers: ["ית"])

        let result = service.replace(in: "הלכתי הבית", using: [entry])

        XCTAssertEqual(result.text, "הלכתי הבית")
    }

    func testExactTriggerAsAWholeWordIsReplaced() {
        let service = DictionaryService()
        let entry = DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קוברנטיס"])

        let result = service.replace(in: "אני עובד עם קוברנטיס בעבודה", using: [entry])

        XCTAssertEqual(result.text, "אני עובד עם Kubernetes בעבודה")
        XCTAssertEqual(result.replacementCount, 1)
    }

    func testNiqqudAndSpellingVarianceStillCorrects() {
        // Trigger and spoken word differ by niqqud (which `normalize` removes,
        // so it costs nothing) and by a doubled vav — which `normalize`
        // deliberately preserves (MAJOR 1), leaving the near-match tier to
        // clear it at 1 edit over 9 characters, similarity 0.889.
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

    func testNearMatchExactlyAtThresholdIsNotReplaced() {
        // MAJOR 2: the boundary is exclusive. It has to be — at the shipped
        // 0.8 it lands exactly on Hebrew's feminine -ת inflection (see below),
        // and every four-letter stem in the Dictionary would rewrite its own
        // five-letter inflected form.
        let service = DictionaryService(similarityThreshold: 0.75)
        // "abcd" vs "abcx": distance 1, length 4 -> similarity 0.75 exactly.
        let entry = DictionaryEntry(canonicalForm: "CANON", triggers: ["abcd"])

        let result = service.replace(in: "the word abcx here", using: [entry])

        XCTAssertEqual(result.text, "the word abcx here")
    }

    // MARK: - The shipped threshold against real Hebrew inflections (MAJOR 2)

    func testTheShippedThresholdDoesNotFireOnTheFeminineInflection() {
        // 4-letter stem -> 5-letter feminine form is distance 1 over 5, which
        // is similarity 0.800 exactly — the value the shipped default is set
        // to. Every one of these used to be replaced.
        let service = DictionaryService(similarityThreshold: 0.8)
        let pairs: [(stem: String, inflected: String, canonical: String)] = [
            ("עובד", "עובדת", "WORKER"),
            ("מנהל", "מנהלת", "MANAGER"),
            ("דוקר", "דוקרת", "Docker"),
        ]
        for pair in pairs {
            let entry = DictionaryEntry(canonicalForm: pair.canonical, triggers: [pair.stem])
            XCTAssertEqual(
                service.replace(in: pair.inflected, using: [entry]).text,
                pair.inflected,
                "'\(pair.stem)' must not rewrite its own inflected form '\(pair.inflected)'"
            )
        }
    }

    func testTheShippedThresholdLeavesAnOrdinarySentenceAlone() {
        let service = DictionaryService(similarityThreshold: 0.8)
        let entry = DictionaryEntry(canonicalForm: "Docker", triggers: ["דוקר"])

        // "she is stabbing me" -- nothing to do with containers.
        XCTAssertEqual(service.replace(in: "היא דוקרת אותי", using: [entry]).text, "היא דוקרת אותי")
        // ...and the word the entry actually exists for still corrects.
        XCTAssertEqual(service.replace(in: "התקנתי דוקר אתמול", using: [entry]).text, "התקנתי Docker אתמול")
    }

    func testTheShippedThresholdDoesNotMergeDistinctMatresLectionisWords(){
        // MAJOR 1 seen from the matcher's side: with the collapse gone from
        // `normalize`, מות is 1 edit over 4 characters from מוות — similarity
        // 0.75, correctly below the bar.
        let service = DictionaryService(similarityThreshold: 0.8)
        let entry = DictionaryEntry(canonicalForm: "DEATH", triggers: ["מות"])

        XCTAssertEqual(service.replace(in: "מוות הוא סוף", using: [entry]).text, "מוות הוא סוף")
    }

    // MARK: - Triggers containing a non-letter (MAJOR 3)

    func testATriggerWithGershayimMatches() {
        let service = DictionaryService()
        let entry = DictionaryEntry(canonicalForm: "CEO", triggers: ["מנכ״ל"])

        XCTAssertEqual(service.replace(in: "מנכ״ל החברה הגיע", using: [entry]).text, "CEO החברה הגיע")
        // The ASCII double quote an ASR or a keyboard substitutes for the
        // gershayim is the same trigger.
        XCTAssertEqual(service.replace(in: "מנכ\"ל החברה הגיע", using: [entry]).text, "CEO החברה הגיע")
        // ...and so is the run-together spelling, via the near-match tier.
        XCTAssertEqual(service.replace(in: "מנכל החברה הגיע", using: [entry]).text, "CEO החברה הגיע")
    }

    func testATriggerWithATrailingGereshTakesItWithIt() {
        let service = DictionaryService()
        let entry = DictionaryEntry(canonicalForm: "George", triggers: ["ג׳ורג׳"])

        XCTAssertEqual(service.replace(in: "ג׳ורג׳ הגיע", using: [entry]).text, "George הגיע")
    }

    func testATriggerWithAFullStopMatches() {
        let service = DictionaryService()
        let entry = DictionaryEntry(canonicalForm: "Node.js", triggers: ["node.js"])

        XCTAssertEqual(service.replace(in: "I wrote it in node.js yesterday", using: [entry]).text,
                       "I wrote it in Node.js yesterday")
    }

    func testAMultiWordTriggerMatchesAsAPhrase() {
        let service = DictionaryService()
        let entry = DictionaryEntry(canonicalForm: "ML", triggers: ["machine learning"])

        XCTAssertEqual(service.replace(in: "we do machine learning here", using: [entry]).text, "we do ML here")
    }

    func testAMultiWordTriggerDoesNotReachAcrossASentenceBoundary() {
        let service = DictionaryService()
        let entry = DictionaryEntry(canonicalForm: "ML", triggers: ["machine learning"])

        XCTAssertEqual(service.replace(in: "we do machine. learning here", using: [entry]).text,
                       "we do machine. learning here")
    }

    func testALongerTriggerOutranksAShorterOneAtTheSamePosition() {
        let service = DictionaryService()
        let entries = [
            DictionaryEntry(canonicalForm: "SHORT", triggers: ["node"]),
            DictionaryEntry(canonicalForm: "Node.js", triggers: ["node.js"])
        ]

        XCTAssertEqual(service.replace(in: "it runs on node.js today", using: entries).text,
                       "it runs on Node.js today")
    }

    // MARK: - Literal placeholder-shaped text in a dictation (MINOR 12)

    func testLiteralPlaceholderTextIsNotTreatedSpecially() {
        let service = DictionaryService()
        let entry = DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קוברנטיס"])

        // The user genuinely dictated the bracket characters. The Dictionary
        // has no opinion about them and must leave them exactly as they are.
        let text = "⟦S0⟧ קוברנטיס ⟦S1⟧"
        XCTAssertEqual(service.replace(in: text, using: [entry]).text, "⟦S0⟧ Kubernetes ⟦S1⟧")
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
