// ProfileManagerTests.swift
// VocaMac Tests
//
// Story 4.2: resolving a captured bundle identifier to a Profile — a
// matching id, a non-matching id, an empty Profile set, and Profiles
// disabled entirely.

import XCTest
@testable import VocaMac

@MainActor
final class ProfileManagerTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile_manager_test_\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeManager(profiles: [Profile]? = nil) -> (ProfileManager, ProfileStore) {
        let fileStore = JSONFileStore<[Profile]>(fileName: "profiles.json", defaultValue: [], directoryURL: tempDirectory)
        if let profiles {
            fileStore.save(profiles)
            fileStore.flush()
        }
        let store = ProfileStore(store: fileStore)
        return (ProfileManager(store: store), store)
    }

    func testMatchingBundleIdentifierResolvesToItsProfile() {
        let bound = Profile(name: "Code Editor", bundleIdentifiers: ["com.apple.dt.Xcode"])
        let (manager, _) = makeManager(profiles: [Profile.makeDefault(), bound])

        let resolved = manager.resolve(bundleIdentifier: "com.apple.dt.Xcode", profilesEnabled: true)

        XCTAssertEqual(resolved.id, bound.id)
    }

    func testNonMatchingBundleIdentifierResolvesToDefault() {
        let bound = Profile(name: "Code Editor", bundleIdentifiers: ["com.apple.dt.Xcode"])
        let defaultProfile = Profile.makeDefault()
        let (manager, _) = makeManager(profiles: [defaultProfile, bound])

        let resolved = manager.resolve(bundleIdentifier: "com.apple.Safari", profilesEnabled: true)

        XCTAssertEqual(resolved.id, defaultProfile.id)
    }

    func testNilBundleIdentifierResolvesToDefault() {
        let defaultProfile = Profile.makeDefault()
        let (manager, _) = makeManager(profiles: [defaultProfile])

        let resolved = manager.resolve(bundleIdentifier: nil, profilesEnabled: true)

        XCTAssertEqual(resolved.id, defaultProfile.id)
    }

    /// "an empty profile set" — only the seeded Default exists, nothing else
    /// to match against.
    func testEmptyProfileSetResolvesToDefault() {
        // No `profiles:` argument — a fresh store seeds Default + starters,
        // none of which is bound to this bundle id.
        let (manager, _) = makeManager()

        let resolved = manager.resolve(bundleIdentifier: "com.something.unbound", profilesEnabled: true)

        XCTAssertTrue(resolved.isDefault)
    }

    /// Story 4.2 AC: "Given Profiles are disabled entirely... the Default
    /// Profile always applies" — even when a Profile is bound to this exact
    /// bundle identifier.
    func testProfilesDisabledAlwaysResolvesToDefaultEvenWithAMatchingProfile() {
        let bound = Profile(name: "Code Editor", bundleIdentifiers: ["com.apple.dt.Xcode"])
        let defaultProfile = Profile.makeDefault()
        let (manager, _) = makeManager(profiles: [defaultProfile, bound])

        let resolved = manager.resolve(bundleIdentifier: "com.apple.dt.Xcode", profilesEnabled: false)

        XCTAssertEqual(resolved.id, defaultProfile.id)
    }

    /// The one case where order genuinely decides the answer (MINOR 4):
    /// `resolve` matches with `.first`, so two Profiles bound to the same
    /// bundle identifier are resolved by list position. Nothing stops a user
    /// from creating that — the editor does not check other Profiles' bindings
    /// — so the behavior is pinned here and stated in the Profiles tab rather
    /// than left to be discovered.
    func testTheFirstOfTwoProfilesClaimingTheSameBundleIdentifierWins() {
        let first = Profile(name: "Mail (work)", bundleIdentifiers: ["com.apple.mail"], promptOverride: "formal")
        let second = Profile(name: "Mail (personal)", bundleIdentifiers: ["com.apple.mail"], promptOverride: "casual")
        let (manager, store) = makeManager(profiles: [Profile.makeDefault(), first, second])

        XCTAssertEqual(manager.resolve(bundleIdentifier: "com.apple.mail", profilesEnabled: true).id, first.id)

        // And reordering is what changes it — which is what makes drag-to-
        // reorder in the Profiles tab a meaningful action rather than cosmetic.
        store.move(fromOffsets: IndexSet(integer: 2), toOffset: 1)
        XCTAssertEqual(store.profiles[1].id, second.id, "sanity check: the move landed where the assertion assumes")
        XCTAssertEqual(manager.resolve(bundleIdentifier: "com.apple.mail", profilesEnabled: true).id, second.id)
    }

    func testResolutionIsIndependentOfProfileOrder() {
        let bound = Profile(name: "Mail", bundleIdentifiers: ["com.apple.mail"])
        let (manager, store) = makeManager(profiles: [bound, Profile.makeDefault()])
        XCTAssertFalse(store.profiles.first!.isDefault, "sanity check: Default is not first in this fixture")

        let resolved = manager.resolve(bundleIdentifier: "com.apple.mail", profilesEnabled: true)

        XCTAssertEqual(resolved.id, bound.id)
    }
}
