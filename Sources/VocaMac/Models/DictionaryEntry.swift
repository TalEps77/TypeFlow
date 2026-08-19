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
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        canonicalForm = try container.decode(String.self, forKey: .canonicalForm)
        triggers = try container.decode([String].self, forKey: .triggers)
        learned = try container.decodeIfPresent(Bool.self, forKey: .learned) ?? false
    }
}
