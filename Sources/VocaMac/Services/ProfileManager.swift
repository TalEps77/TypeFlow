// ProfileManager.swift
// VocaMac
//
// Resolves the bundle identifier captured at recording start (Story 4.1) to
// one of the user's Profiles (Story 4.2). ProfileStore owns persistence and
// CRUD; this is the one place dictation-time resolution logic lives.

import Foundation
import Combine

/// Declared here rather than in ServiceProtocols.swift, alongside its one
/// method — same precedent as `PostProcessing` and `ContextReading`.
/// Registered there with a pointer comment (AD-7).
@MainActor
protocol ProfileResolving: AnyObject {
    /// - Parameter profilesEnabled: the global master toggle. When `false`,
    ///   no bundle-identifier match is attempted at all — a disabled feature
    ///   must behave exactly like Epic 2's, always the Default Profile
    ///   (Story 4.2 AC), not "everything happens to be unbound".
    func resolve(bundleIdentifier: String?, profilesEnabled: Bool) -> Profile
}

@MainActor
final class ProfileManager: ObservableObject, ProfileResolving {

    let store: ProfileStore

    init(store: ProfileStore) {
        self.store = store
    }

    func resolve(bundleIdentifier: String?, profilesEnabled: Bool) -> Profile {
        guard profilesEnabled, let bundleIdentifier else {
            return defaultProfile()
        }
        return store.profiles.first { $0.bundleIdentifiers.contains(bundleIdentifier) } ?? defaultProfile()
    }

    /// Always resolvable: `ProfileStore.init` guarantees exactly one Profile
    /// with `isDefault == true` exists, and `ProfileStore.delete` refuses to
    /// remove it. The literal fallback here only matters if that invariant
    /// is ever broken by a future change.
    private func defaultProfile() -> Profile {
        store.profiles.first { $0.isDefault } ?? Profile.makeDefault()
    }
}
