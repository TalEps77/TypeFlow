// DictionaryEntry.swift
// VocaMac
//
// A recurring mis-transcription and its fix (Story 5.2/5.3): one canonical
// form plus every trigger variant Whisper is known to produce for it.
// Persisted via DictionaryStore (AD-9, AD-10). Distinct from the existing
// Vocabulary (`AppState.customVocabulary`, "Glossary: "), which biases the
// decoder *before* transcription — this operates on the transcript after
// the fact (NFR-5, Story 5.3 AC).

import Foundation

struct DictionaryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID

    /// What a matched trigger is replaced with.
    var canonicalForm: String

    /// Variant spellings/mis-transcriptions of `canonicalForm` that
    /// `DictionaryService` matches against — exactly, or by edit distance
    /// over `HebrewNormalizer`-normalized forms.
    var triggers: [String]

    /// True for an entry that originated from a confirmed correction-learning
    /// candidate (Story 5.6) rather than being typed in by hand — lets the
    /// settings UI show which entries the user authored versus which ones
    /// VocaMac proposed and they approved.
    var learned: Bool

    init(id: UUID = UUID(), canonicalForm: String, triggers: [String] = [], learned: Bool = false) {
        self.id = id
        self.canonicalForm = canonicalForm
        self.triggers = triggers
        self.learned = learned
    }

    private enum CodingKeys: String, CodingKey {
        case id, canonicalForm, triggers, learned
    }

    /// Custom so a `dictionary.json` written before Story 5.6 (no `learned`
    /// key) still decodes — absent means "typed in by hand", never a
    /// decode failure that would quarantine an otherwise-valid file.
    ///
    /// `id` is optional for the same reason (MINOR 10). The Dictionary is
    /// documented as importable JSON, and a file written by hand or generated
    /// from a term list has no reason to carry UUIDs — yet a single missing
    /// `id` used to fail the decode of the *whole array*, rejecting every entry
    /// in the file with a message about a key. Minting one is always the right
    /// answer: nothing outside this file references it.
    ///
    /// Duplicate triggers are dropped here rather than at every use site
    /// (MINOR 11): the editor lists them with `id: \.self` and removes by
    /// value, so two identical triggers give SwiftUI two rows with the same
    /// identity and make the minus button delete both.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        canonicalForm = try container.decode(String.self, forKey: .canonicalForm)
        triggers = Self.deduplicated(try container.decode([String].self, forKey: .triggers))
        learned = try container.decodeIfPresent(Bool.self, forKey: .learned) ?? false
    }

    /// First occurrence wins, order otherwise preserved.
    static func deduplicated(_ triggers: [String]) -> [String] {
        var seen: Set<String> = []
        return triggers.filter { seen.insert($0).inserted }
    }
}
