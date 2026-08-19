// DismissedCorrectionsStore.swift
// VocaMac
//
// Remembers which correction candidates the user has dismissed, so the same
// pair is never proposed again (Story 5.6 AC). Persisted via JSONFileStore
// (AD-10) — dismissal must survive a restart, not just the current session.
//
// Only the two words involved are ever stored here — never the surrounding
// sentence or field contents a candidate was detected from (AD-5 still
// holds for the transient AX re-read that produced it).

import Foundation
import Combine

struct DismissedCorrection: Codable, Equatable, Sendable {
    let original: String
    let corrected: String
}

@MainActor
final class DismissedCorrectionsStore: ObservableObject {

    @Published private(set) var dismissed: [DismissedCorrection]

    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    private let store: JSONFileStore<[DismissedCorrection]>

    init(store: JSONFileStore<[DismissedCorrection]>? = nil) {
        self.store = store ?? JSONFileStore(fileName: "dismissed-corrections.json", defaultValue: [])
        self.dismissed = self.store.load()
    }

    /// Compared the same normalization-tolerant, case-insensitive way every
    /// other match in this epic is: a pair differing only by niqqud or
    /// spelling variance from one the user already dismissed is just as
    /// dismissed as an identical one.
    func isDismissed(_ candidate: CorrectionCandidate) -> Bool {
        let normalizedOriginal = HebrewNormalizer.normalize(candidate.original).lowercased()
        let normalizedCorrected = HebrewNormalizer.normalize(candidate.corrected).lowercased()
        return dismissed.contains {
            HebrewNormalizer.normalize($0.original).lowercased() == normalizedOriginal
                && HebrewNormalizer.normalize($0.corrected).lowercased() == normalizedCorrected
        }
    }

    func dismiss(_ candidate: CorrectionCandidate) {
        guard !isDismissed(candidate) else { return }
        dismissed.append(DismissedCorrection(original: candidate.original, corrected: candidate.corrected))
        persist()
    }

    private func persist() {
        store.save(dismissed)
    }
}
