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

    /// Adds `entry` if this is the first time it has been seen, updates it
    /// otherwise.
    ///
    /// What the settings tab's editor calls (MAJOR 10). "Add Entry" used to
    /// persist a blank row *before* opening the editor, so cancelling left a
    /// permanent "(untitled)" entry behind — and, worse, a non-empty Dictionary
    /// flips `DictionaryStage` from declining outright to running a full
    /// tokenize pass on every dictation, forever, for a row the user never
    /// finished creating.
    func upsert(_ entry: DictionaryEntry) {
        if entries.contains(where: { $0.id == entry.id }) {
            update(entry)
        } else {
            add(entry)
        }
    }

    /// Used by import (Story 5.3 AC): replaces the whole set.
    func replaceAll(with newEntries: [DictionaryEntry]) {
        entries = newEntries
        persist()
    }

    /// What an imported file is allowed to become (MAJOR 5).
    ///
    /// The file is arbitrary JSON off the user's disk, and `replaceAll` writes
    /// it straight into the matcher: a blank `canonicalForm` *deletes* every
    /// matching token from future transcripts, and duplicate `id`s leave
    /// SwiftUI with two rows it cannot tell apart. Returns what survived
    /// alongside how many entries were dropped, so the UI can say so rather
    /// than silently importing less than the file contained.
    static func sanitizedForImport(_ imported: [DictionaryEntry]) -> (entries: [DictionaryEntry], dropped: Int) {
        var seenIDs: Set<UUID> = []
        var sanitized: [DictionaryEntry] = []
        var dropped = 0

        for entry in imported {
            let canonicalForm = entry.canonicalForm.trimmingCharacters(in: .whitespacesAndNewlines)
            let triggers = DictionaryEntry.deduplicated(
                entry.triggers
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            guard !canonicalForm.isEmpty, !triggers.isEmpty else {
                dropped += 1
                continue
            }
            // A repeated id is regenerated rather than dropped: the entry
            // itself is perfectly good, it just cannot keep an identity that
            // is already taken.
            let id = seenIDs.contains(entry.id) ? UUID() : entry.id
            seenIDs.insert(id)
            sanitized.append(DictionaryEntry(
                id: id,
                canonicalForm: canonicalForm,
                triggers: triggers,
                learned: entry.learned
            ))
        }

        return (sanitized, dropped)
    }

    private func persist() {
        store.save(entries)
    }
}
