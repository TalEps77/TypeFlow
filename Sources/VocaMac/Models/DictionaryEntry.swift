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

    init(id: UUID = UUID(), canonicalForm: String, triggers: [String] = []) {
        self.id = id
        self.canonicalForm = canonicalForm
        self.triggers = triggers
    }
}
