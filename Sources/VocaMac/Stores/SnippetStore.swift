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

    /// Used by import (Story 5.5 AC): replaces the whole set.
    func replaceAll(with newSnippets: [Snippet]) {
        snippets = newSnippets
        persist()
    }

    /// Whether `cue` collides with an existing Snippet's Cue (Story 5.5 AC:
    /// "Cues must be unambiguous"), compared the same normalization-tolerant,
    /// case-insensitive way `SnippetService` matches — a Cue differing only
    /// by niqqud or spelling variance is just as ambiguous as an identical
    /// one. `excluding` lets the editor check a Cue being renamed against
    /// every *other* Snippet without rejecting it against itself.
    func hasCollision(withCue cue: String, excluding excludedID: UUID? = nil) -> Bool {
        let normalizedCue = HebrewNormalizer.normalize(cue).lowercased()
        guard !normalizedCue.isEmpty else { return false }
        return snippets.contains {
            $0.id != excludedID && HebrewNormalizer.normalize($0.cue).lowercased() == normalizedCue
        }
    }

    private func persist() {
        store.save(snippets)
    }
}
