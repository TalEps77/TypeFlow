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
    @AppStorage("vocamac.history.retentionLimit") var retentionLimit: Int = 0 {
        didSet {
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
    func search(_ query: String) -> [HistoryRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return records }
        return records.filter {
            $0.rawTranscript.localizedCaseInsensitiveContains(trimmed) ||
            $0.finalText.localizedCaseInsensitiveContains(trimmed)
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
