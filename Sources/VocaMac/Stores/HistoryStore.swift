// HistoryStore.swift
// VocaMac
//
// Persists every dictation locally via JSONFileStore (AD-10). UI-observable
// list; writes go through the store's off-main serial queue. Modeled on
// StatsManager.swift, per the architecture's threading table.

import Foundation
import Combine
import SwiftUI

@MainActor
final class HistoryStore: ObservableObject, HistoryRecording {

    /// Newest-first, matching how the history view presents them.
    @Published private(set) var records: [HistoryRecord] = []

    /// Maximum number of records to keep. 0 means unlimited. Persisted like
    /// any other scalar setting (AD-9).
    ///
    /// The default is bounded rather than unlimited: every record is re-encoded
    /// and rewritten in full on every dictation, so an unbounded default meant
    /// a file that grows forever and a write that gets slower forever with it
    /// (MAJOR 1). 500 is the largest value the retention picker already offers
    /// short of "Unlimited", which stays available for anyone who wants it.
    @AppStorage("vocamac.history.retentionLimit", store: VocaDefaults.store) var retentionLimit: Int = 500 {
        didSet {
            // Published unconditionally: the menu shows the current limit, so
            // it has to re-render even when the new limit trims nothing
            // (MINOR 1).
            objectWillChange.send()
            if enforceRetentionIfNeeded() {
                persist()
            }
        }
    }

    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    private let store: JSONFileStore<[HistoryRecord]>

    init(store: JSONFileStore<[HistoryRecord]>? = nil) {
        self.store = store ?? JSONFileStore(fileName: "history.json", defaultValue: [])
        self.records = self.store.load().sorted { $0.timestamp > $1.timestamp }

        // Retention was only ever applied as records arrived, so a file
        // restored from backup — or written before the limit was lowered —
        // stayed over the limit indefinitely (MINOR 7).
        if enforceRetentionIfNeeded() {
            persist()
        }

        // The save queue is asynchronous, so the last dictation of a session
        // can still be in flight when the process ends — and `VocaMacApp`
        // SIGTERMs previous instances outright (MINOR 6).
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [store = self.store] _ in
            store.flush()
        }
    }

    func record(_ newRecord: HistoryRecord) {
        records.insert(newRecord, at: 0)
        _ = enforceRetentionIfNeeded()
        persist()
    }

    func delete(_ id: UUID) {
        records.removeAll { $0.id == id }
        persist()
    }

    func deleteAll() {
        records.removeAll()
        persist()
    }

    /// Case-insensitive substring match over both the raw transcript and the
    /// final text, so a search finds a record whether the query matches what
    /// was said or what the pipeline produced. An empty/whitespace-only query
    /// returns everything.
    ///
    /// `localizedStandardContains` rather than `localizedCaseInsensitiveContains`:
    /// it folds diacritics and width as the Finder does, which is what makes
    /// typing שלום find a pointed שָׁלוֹם (MINOR 2). Hebrew is dictated here
    /// far more often than it is typed with niqqud.
    func search(_ query: String) -> [HistoryRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return records }
        return records.filter {
            $0.rawTranscript.localizedStandardContains(trimmed) ||
            $0.finalText.localizedStandardContains(trimmed)
        }
    }

    /// Trims `records` down to `retentionLimit` if it's exceeded.
    /// - Returns: `true` if trimming actually happened, so callers that don't
    ///   otherwise persist (the `retentionLimit` setter) know to.
    @discardableResult
    private func enforceRetentionIfNeeded() -> Bool {
        guard retentionLimit > 0, records.count > retentionLimit else { return false }
        records = Array(records.prefix(retentionLimit))
        return true
    }

    private func persist() {
        store.save(records)
    }
}
