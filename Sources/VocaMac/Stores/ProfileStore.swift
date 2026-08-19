// ProfileStore.swift
// VocaMac
//
// Persists Profiles via JSONFileStore (AD-10). Owns CRUD and reordering
// for the Profiles settings tab (Story 4.3); ProfileManager
// (Services/ProfileManager.swift) is what resolves a bundle identifier to
// one of these at dictation time (Story 4.2). Modeled on HistoryStore.

import Foundation
import Combine
import SwiftUI

@MainActor
final class ProfileStore: ObservableObject {

    /// In list order — Story 4.3's reorder AC operates on this array
    /// directly. The Default Profile can sit anywhere the user puts it: the
    /// *fallback* is found by `isDefault`, never by position.
    ///
    /// Order does matter in one case, though (MINOR 3): `ProfileManager`
    /// matches with `.first`, so when two Profiles claim the same bundle
    /// identifier the one earlier in this array wins. That is what makes
    /// reordering a meaningful action rather than cosmetic, and the Profiles
    /// tab says so.
    @Published private(set) var profiles: [Profile]

    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    private let store: JSONFileStore<[Profile]>

    init(store: JSONFileStore<[Profile]>? = nil) {
        self.store = store ?? JSONFileStore(fileName: "profiles.json", defaultValue: [], logCategory: .profiles)
        let loaded = self.store.load()

        if loaded.isEmpty {
            // Fresh install (Story 4.3 AC): seed the Default Profile plus the
            // starter set illustrating casual, formal, and identifier-shaped
            // output.
            self.profiles = [Profile.makeDefault()] + Profile.starterProfiles()
            self.store.save(self.profiles)
        } else if loaded.contains(where: { $0.isDefault }) {
            self.profiles = loaded
        } else {
            // A profiles file that somehow lost its Default Profile (hand
            // edited, or restored from a malformed export) must not leave
            // dictation with nothing to fall back on (Story 4.2 AC).
            self.profiles = [Profile.makeDefault()] + loaded
            VocaLogger.warning(.profiles, "profiles.json had no Default Profile — one was re-added")
            self.store.save(self.profiles)
        }
    }

    func add(_ profile: Profile) {
        profiles.append(profile)
        persist()
    }

    func update(_ profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        persist()
    }

    /// Refuses to delete the Default Profile (Story 4.2/4.3 AC): it is the
    /// fallback every dictation resolves to, and deleting it would leave a
    /// disabled or non-matching dictation with nowhere to fall back.
    @discardableResult
    func delete(_ id: UUID) -> Bool {
        guard let profile = profiles.first(where: { $0.id == id }), !profile.isDefault else {
            return false
        }
        profiles.removeAll { $0.id == id }
        persist()
        return true
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        profiles.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    /// Used by import (Story 4.3 AC): replaces the whole set with a sanitized
    /// version of it.
    ///
    /// Sanitizing here rather than only in the settings tab is deliberate
    /// (MAJOR 5): this is the single door every import goes through, so the
    /// invariants — exactly one unbound Default Profile, unique ids, Cursor
    /// Context never armed by a file — hold no matter which caller opened it.
    /// `Profile.sanitizedForImport` is idempotent, so a caller that already
    /// sanitized in order to show the user what changed loses nothing by
    /// passing the result back through.
    @discardableResult
    func replaceAll(with newProfiles: [Profile]) -> Profile.SanitizedImport {
        let sanitized = Profile.sanitizedForImport(newProfiles)
        profiles = sanitized.profiles
        persist()
        return sanitized
    }

    private func persist() {
        store.save(profiles)
    }
}
