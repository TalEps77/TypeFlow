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

    private func persist() {
        store.save(snippets)
    }
}
