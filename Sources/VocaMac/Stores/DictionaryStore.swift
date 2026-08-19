// DictionaryStore.swift
// VocaMac
//
// Persists Dictionary Entries via JSONFileStore (AD-10). Owns CRUD for the
// Dictionary settings tab (Story 5.3); DictionaryService (in
// Services/DictionaryService.swift) is what matches transcript text against
// these entries at dictation time (Story 5.2). Modeled on ProfileStore —
// simpler, since the Dictionary has no "always exactly one" invariant to
// enforce the way the Default Profile does.

import Foundation
import Combine

@MainActor
final class DictionaryStore: ObservableObject {

    @Published private(set) var entries: [DictionaryEntry]

    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    private let store: JSONFileStore<[DictionaryEntry]>

    init(store: JSONFileStore<[DictionaryEntry]>? = nil) {
        self.store = store ?? JSONFileStore(fileName: "dictionary.json", defaultValue: [])
        self.entries = self.store.load()
    }

    func add(_ entry: DictionaryEntry) {
        entries.append(entry)
        persist()
    }

    func update(_ entry: DictionaryEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        persist()
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        guard entries.contains(where: { $0.id == id }) else { return false }
        entries.removeAll { $0.id == id }
        persist()
        return true
    }

    /// Used by import (Story 5.3 AC): replaces the whole set.
    func replaceAll(with newEntries: [DictionaryEntry]) {
        entries = newEntries
        persist()
    }

    private func persist() {
        store.save(entries)
    }
}
