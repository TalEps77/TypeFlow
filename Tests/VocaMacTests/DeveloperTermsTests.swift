// DeveloperTermsTests.swift
// VocaMac Tests
//
// The built-in Hebrew → English developer term pack: internal consistency of
// the list, end-to-end replacement through DictionaryService including bound
// prefixes, and the merge/seed rules that keep it from trampling a user's own
// Dictionary.

import XCTest
@testable import VocaMac

final class DeveloperTermsTests: XCTestCase {

    private let hebrewLetters = CharacterSet(charactersIn: "אבגדהוזחטיךכלםמןנסעףפץצקרשת")

    // MARK: - The list itself

    func testPackIsSubstantial() {
        XCTAssertGreaterThanOrEqual(DeveloperTerms.hebrewToEnglish.count, 200)
    }

    func testNoDuplicateCanonicalForms() {
        let canonicals = DeveloperTerms.hebrewToEnglish.map { $0.canonicalForm.lowercased() }
        let duplicates = Dictionary(grouping: canonicals, by: { $0 }).filter { $1.count > 1 }.keys
        XCTAssertTrue(duplicates.isEmpty, "duplicate canonical forms: \(duplicates.sorted())")
    }

    func testNoTriggerIsClaimedTwice() {
        var seen: [String: String] = [:]
        var collisions: [String] = []
        for entry in DeveloperTerms.hebrewToEnglish {
            for trigger in entry.triggers {
                let key = HebrewNormalizer.normalize(trigger).lowercased()
                if let owner = seen[key], owner != entry.canonicalForm {
                    collisions.append("\(trigger): \(owner) vs \(entry.canonicalForm)")
                }
                seen[key] = entry.canonicalForm
            }
        }
        XCTAssertTrue(collisions.isEmpty, collisions.joined(separator: "\n"))
    }

    func testEveryTriggerIsHebrewAndEveryEntryHasOne() {
        for entry in DeveloperTerms.hebrewToEnglish {
            XCTAssertFalse(entry.triggers.isEmpty, "\(entry.canonicalForm) has no triggers")
            XCTAssertFalse(entry.canonicalForm.trimmingCharacters(in: .whitespaces).isEmpty)
            for trigger in entry.triggers {
                XCTAssertNotNil(trigger.unicodeScalars.first(where: { hebrewLetters.contains($0) }),
                                "\(trigger) (for \(entry.canonicalForm)) has no Hebrew letter")
                XCTAssertNotNil(WordTokenizer.phrase(trigger, normalizing: HebrewNormalizer.normalize),
                                "\(trigger) does not tokenize into a matchable phrase")
            }
        }
    }

    // MARK: - End to end

    func testTheSentenceEveryoneSays() {
        let service = DictionaryService()
        let result = service.replace(
            in: "קלוד, תפתח פול ריקווסט אחרי הקומיט, תעדכן את קלוד אמדי ותפרוס לורסל.",
            using: DeveloperTerms.hebrewToEnglish
        )
        XCTAssertEqual(
            result.text,
            "Claude, תפתח pull request אחרי ה\u{05BE}commit, תעדכן את CLAUDE.md ותפרוס ל\u{05BE}Vercel."
        )
    }

    func testMixedPrefixesAndPlurals() {
        let service = DictionaryService()
        let result = service.replace(
            in: "עשיתי פוש לברנץ' ובדקתי את הלוגים בפרודקשן",
            using: DeveloperTerms.hebrewToEnglish
        )
        XCTAssertEqual(result.text, "עשיתי push ל\u{05BE}branch ובדקתי את ה\u{05BE}logs ב\u{05BE}production")
    }

    func testOrdinaryHebrewIsLeftAlone() {
        let service = DictionaryService()
        let sentence = "אכלתי פול עם פיתה ואחר כך פורקתי את הארגזים בבית"
        let result = service.replace(in: sentence, using: DeveloperTerms.hebrewToEnglish)
        XCTAssertEqual(result.text, sentence, "פול the bean and פורק the verb are deliberately not in the pack")
    }

    // MARK: - Merge and seed

    @MainActor
    func testMergeSkipsEntriesTheUserAlreadyOwns() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DictionaryStore(store: JSONFileStore(fileName: "dictionary.json", defaultValue: [], directoryURL: dir))
        store.add(DictionaryEntry(canonicalForm: "Commit", triggers: ["קומיט"]))      // same canonical, different case
        store.add(DictionaryEntry(canonicalForm: "Flow", triggers: ["פוש"]))           // user reuses a pack trigger

        let outcome = store.merge(DeveloperTerms.hebrewToEnglish)

        XCTAssertEqual(outcome.skipped, 2)
        XCTAssertEqual(outcome.added, DeveloperTerms.hebrewToEnglish.count - 2)
        XCTAssertEqual(store.entries.first { $0.triggers.contains("פוש") }?.canonicalForm, "Flow",
                       "the user's mapping of פוש must survive")
        let second = store.merge(DeveloperTerms.hebrewToEnglish)
        XCTAssertEqual(second.added, 0, "merging again is a no-op")
    }

    @MainActor
    func testSeedRunsOnceAndOnlyIntoAnEmptyDictionary() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = UserDefaults(suiteName: "developer-terms-tests-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }

        let fresh = DictionaryStore(store: JSONFileStore(fileName: "dictionary.json", defaultValue: [], directoryURL: dir))
        DeveloperTerms.seedIfFresh(into: fresh, defaults: defaults)
        XCTAssertEqual(fresh.entries.count, DeveloperTerms.hebrewToEnglish.count)

        fresh.replaceAll(with: [])
        DeveloperTerms.seedIfFresh(into: fresh, defaults: defaults)
        XCTAssertTrue(fresh.entries.isEmpty, "a pruned Dictionary is never re-seeded")

        let existing = DictionaryStore(store: JSONFileStore(fileName: "other.json", defaultValue: [], directoryURL: dir))
        existing.add(DictionaryEntry(canonicalForm: "Mine", triggers: ["שלי"]))
        let otherDefaults = UserDefaults(suiteName: "developer-terms-tests-\(UUID().uuidString)")!
        DeveloperTerms.seedIfFresh(into: existing, defaults: otherDefaults)
        XCTAssertEqual(existing.entries.count, 1, "an established Dictionary is left for the Settings button")
    }
}
