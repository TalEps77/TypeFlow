// DismissedCorrectionsStore.swift
// VocaMac
//
// Remembers which correction candidates the user has dismissed, so the same
// pair is never proposed again (Story 5.6 AC). Persisted via JSONFileStore
// (AD-10) — dismissal must survive a restart, not just the current session.
//
// Nothing readable is stored. A dismissal is recorded as a salted hash of the
// normalized pair (MAJOR 9): the *rejected* half of a candidate is a word the
// user typed themselves, read out of their focused text field via
// Accessibility, and writing it to a plaintext file on the reject path put
// arbitrary document words on disk, unbounded, with nothing in the UI even
// listing them — the one place in this epic where declining a feature cost
// more privacy than accepting it. Comparison here is equality-only, so a hash
// answers every question the readable pair could.

import Foundation
import CryptoKit
import Combine

struct DismissedCorrection: Codable, Equatable, Sendable {
    /// Salted SHA-256 of the normalized `original` + `corrected` pair.
    let fingerprint: String

    init(fingerprint: String) {
        self.fingerprint = fingerprint
    }

    init(candidate: CorrectionCandidate) {
        self.fingerprint = Self.fingerprint(for: candidate)
    }

    /// Compared the same normalization-tolerant, case-insensitive way every
    /// other match in this epic is: a pair differing only by niqqud or spelling
    /// variance from one the user already dismissed is just as dismissed as an
    /// identical one. Normalizing *before* hashing is what preserves that —
    /// a hash of the raw words would only ever match byte-identical input.
    static func fingerprint(for candidate: CorrectionCandidate) -> String {
        let original = HebrewNormalizer.normalize(candidate.original).lowercased()
        let corrected = HebrewNormalizer.normalize(candidate.corrected).lowercased()
        // The separator is a character `WordTokenizer` can never produce inside
        // a word, so no two distinct pairs can share a pre-image.
        let payload = Data("\(salt)\u{0000}\(original)\u{0000}\(corrected)".utf8)
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    /// Per-installation, generated on first use and kept in the same defaults
    /// domain as every other setting (AD-9). Without it the file would be a
    /// plain dictionary attack away from being readable again.
    private static let saltKey = "vocamac.dismissedCorrectionsSalt"

    private static var salt: String = {
        if let existing = VocaDefaults.store.string(forKey: saltKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        VocaDefaults.store.set(generated, forKey: saltKey)
        return generated
    }()

    // MARK: - Legacy decoding

    private enum CodingKeys: String, CodingKey {
        case fingerprint, original, corrected
    }

    /// Accepts a `dismissed-corrections.json` written before this fix — the
    /// readable `original`/`corrected` shape — and fingerprints it on the way
    /// in, so the user's existing dismissals keep working and the readable
    /// copy is gone the next time the file is written.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let fingerprint = try container.decodeIfPresent(String.self, forKey: .fingerprint) {
            self.fingerprint = fingerprint
            return
        }
        let original = try container.decode(String.self, forKey: .original)
        let corrected = try container.decode(String.self, forKey: .corrected)
        self.fingerprint = Self.fingerprint(for: CorrectionCandidate(original: original, corrected: corrected))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fingerprint, forKey: .fingerprint)
    }
}

@MainActor
final class DismissedCorrectionsStore: ObservableObject {

    /// Oldest dismissals are dropped past this (MAJOR 9). A list that only
    /// ever grows is a retention problem regardless of what it holds, and a
    /// user with five hundred dismissals behind them is not being re-asked
    /// about the first one.
    static let maximumDismissals = 500

    @Published private(set) var dismissed: [DismissedCorrection]

    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    private let store: JSONFileStore<[DismissedCorrection]>

    init(store: JSONFileStore<[DismissedCorrection]>? = nil) {
        self.store = store ?? JSONFileStore(fileName: "dismissed-corrections.json", defaultValue: [])
        self.dismissed = self.store.load()
    }

    func isDismissed(_ candidate: CorrectionCandidate) -> Bool {
        let fingerprint = DismissedCorrection.fingerprint(for: candidate)
        return dismissed.contains { $0.fingerprint == fingerprint }
    }

    func dismiss(_ candidate: CorrectionCandidate) {
        guard !isDismissed(candidate) else { return }
        dismissed.append(DismissedCorrection(candidate: candidate))
        if dismissed.count > Self.maximumDismissals {
            dismissed.removeFirst(dismissed.count - Self.maximumDismissals)
        }
        persist()
    }

    /// Forgets every dismissal (MAJOR 9). Surfaced in the Vocabulary settings
    /// tab, which is the only way the user can see this list exists at all —
    /// data VocaMac keeps on their behalf must be something they can get rid
    /// of without deleting the whole application's support directory.
    func clear() {
        guard !dismissed.isEmpty else { return }
        dismissed = []
        persist()
    }

    private func persist() {
        store.save(dismissed)
    }
}
