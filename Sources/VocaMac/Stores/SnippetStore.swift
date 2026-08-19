// SnippetStore.swift
// VocaMac
//
// Persists Snippets via JSONFileStore (AD-10). Owns CRUD for the Snippets
// settings UI (Story 5.5); SnippetService (Services/SnippetService.swift) is
// what matches transcript text against these Cues at dictation time
// (Story 5.4). Modeled on DictionaryStore.

import Foundation
import Combine

@MainActor
final class SnippetStore: ObservableObject {

    @Published private(set) var snippets: [Snippet]

    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    private let store: JSONFileStore<[Snippet]>

    init(store: JSONFileStore<[Snippet]>? = nil) {
        self.store = store ?? JSONFileStore(fileName: "snippets.json", defaultValue: [])
        self.snippets = self.store.load()
    }

    func add(_ snippet: Snippet) {
        snippets.append(snippet)
        persist()
    }

    func update(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        snippets[index] = snippet
        persist()
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        guard snippets.contains(where: { $0.id == id }) else { return false }
        snippets.removeAll { $0.id == id }
        persist()
        return true
    }

    /// Adds `snippet` if this is the first time it has been seen, updates it
    /// otherwise. Same reason as `DictionaryStore.upsert` (MAJOR 10): "Add
    /// Snippet" used to persist an empty-cue, empty-body row before the editor
    /// ever opened, and cancelling left it behind.
    func upsert(_ snippet: Snippet) {
        if snippets.contains(where: { $0.id == snippet.id }) {
            update(snippet)
        } else {
            add(snippet)
        }
    }

    /// Used by import (Story 5.5 AC): replaces the whole set.
    func replaceAll(with newSnippets: [Snippet]) {
        snippets = newSnippets
        persist()
    }

    /// The form two Cues have to share to be indistinguishable at match time —
    /// the normalized word sequence *and* the separators between those words,
    /// exactly what `SnippetService` compares (MAJOR 6).
    ///
    /// Comparing whole normalized strings, as this used to, disagreed with the
    /// matcher: "שלום עולם" and "שלום, עולם" are different strings, so both
    /// were accepted as distinct Snippets — and then tokenize identically, so
    /// which one expands is decided by array order, with nothing telling the
    /// user the second Cue is dead.
    static func collisionKey(for cue: String) -> String? {
        guard let phrase = WordTokenizer.phrase(cue, normalizing: HebrewNormalizer.normalize),
              !phrase.words.contains(where: { $0.isEmpty }) else {
            return nil
        }
        var key = phrase.words[0].lowercased()
        for index in phrase.gaps.indices {
            key += "\u{0000}\(phrase.gaps[index])\u{0000}\(phrase.words[index + 1])"
        }
        return key
    }

    /// Whether `cue` collides with an existing Snippet's Cue (Story 5.5 AC:
    /// "Cues must be unambiguous"), compared the same normalization-tolerant,
    /// case-insensitive way `SnippetService` matches — a Cue differing only
    /// by niqqud or spelling variance is just as ambiguous as an identical
    /// one. `excluding` lets the editor check a Cue being renamed against
    /// every *other* Snippet without rejecting it against itself.
    func hasCollision(withCue cue: String, excluding excludedID: UUID? = nil) -> Bool {
        guard let key = Self.collisionKey(for: cue) else { return false }
        return snippets.contains {
            $0.id != excludedID && Self.collisionKey(for: $0.cue) == key
        }
    }

    /// What an imported file is allowed to become (MAJOR 5), the Snippets half.
    ///
    /// A blank body is rejected outright — its placeholder rehydrates to
    /// nothing and the AD-2 blank guard then leaves the raw `⟦S0⟧` to be
    /// injected (BLOCKER 1) — as is a Cue that collides with one already
    /// accepted from the same file, which `hasCollision` never got a chance to
    /// see because import goes straight to `replaceAll`.
    static func sanitizedForImport(_ imported: [Snippet]) -> (snippets: [Snippet], dropped: Int) {
        var seenIDs: Set<UUID> = []
        var seenCues: Set<String> = []
        var sanitized: [Snippet] = []
        var dropped = 0

        for snippet in imported {
            guard let key = collisionKey(for: snippet.cue),
                  !snippet.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seenCues.insert(key).inserted else {
                dropped += 1
                continue
            }
            let id = seenIDs.contains(snippet.id) ? UUID() : snippet.id
            seenIDs.insert(id)
            sanitized.append(Snippet(id: id, cue: snippet.cue, body: snippet.body))
        }

        return (sanitized, dropped)
    }

    private func persist() {
        store.save(snippets)
    }
}
