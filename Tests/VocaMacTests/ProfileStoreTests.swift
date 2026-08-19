// ProfileStoreTests.swift
// VocaMac Tests
//
// Story 4.2/4.3: Profile persistence, CRUD, reordering, and the invariant
// every resolution depends on — exactly one Default Profile always exists
// and cannot be deleted.

import XCTest
@testable import VocaMac

@MainActor
final class ProfileStoreTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile_store_test_\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeStore() -> (ProfileStore, JSONFileStore<[Profile]>) {
        let fileStore = JSONFileStore<[Profile]>(fileName: "profiles.json", defaultValue: [], directoryURL: tempDirectory)
        return (ProfileStore(store: fileStore), fileStore)
    }

    // MARK: - Fresh install (Story 4.3 AC)

    func testFreshInstallSeedsDefaultPlusStarterProfiles() {
        let (store, _) = makeStore()

        XCTAssertTrue(store.profiles.contains { $0.isDefault && $0.name == "Default" })
        XCTAssertEqual(store.profiles.count, 1 + Profile.starterProfiles().count)
        XCTAssertTrue(store.profiles.contains { $0.name == "Chat" })
        XCTAssertTrue(store.profiles.contains { $0.name == "Mail" })
        XCTAssertTrue(store.profiles.contains { $0.name == "Code Editor" })
    }

    func testSeededProfilesSurviveAFreshInstanceAtTheSameFile() {
        let fileStore = JSONFileStore<[Profile]>(fileName: "profiles.json", defaultValue: [], directoryURL: tempDirectory)
        let first = ProfileStore(store: fileStore)
        fileStore.flush()

        let restartedFileStore = JSONFileStore<[Profile]>(fileName: "profiles.json", defaultValue: [], directoryURL: tempDirectory)
        let second = ProfileStore(store: restartedFileStore)

        XCTAssertEqual(second.profiles.map(\.id).sorted(), first.profiles.map(\.id).sorted())
    }

    // MARK: - Loading a file with no Default Profile

    func testFileWithoutADefaultProfileGetsOneAddedBack() {
        let fileStore = JSONFileStore<[Profile]>(fileName: "profiles.json", defaultValue: [], directoryURL: tempDirectory)
        fileStore.save([Profile(name: "Only Custom", bundleIdentifiers: ["com.example.app"])])
        fileStore.flush()

        let store = ProfileStore(store: fileStore)

        XCTAssertTrue(store.profiles.contains { $0.isDefault })
        XCTAssertTrue(store.profiles.contains { $0.name == "Only Custom" })
    }

    // MARK: - CRUD

    func testAddAppendsAProfile() {
        let (store, _) = makeStore()
        let countBefore = store.profiles.count

        store.add(Profile(name: "Terminal", bundleIdentifiers: ["com.apple.Terminal"]))

        XCTAssertEqual(store.profiles.count, countBefore + 1)
        XCTAssertTrue(store.profiles.contains { $0.name == "Terminal" })
    }

    func testUpdateReplacesTheMatchingProfile() {
        let (store, _) = makeStore()
        var custom = Profile(name: "Terminal", bundleIdentifiers: ["com.apple.Terminal"])
        store.add(custom)

        custom.name = "Terminal (renamed)"
        custom.promptOverride = "new prompt"
        store.update(custom)

        let updated = store.profiles.first { $0.id == custom.id }
        XCTAssertEqual(updated?.name, "Terminal (renamed)")
        XCTAssertEqual(updated?.promptOverride, "new prompt")
    }

    func testDeleteRemovesANonDefaultProfile() {
        let (store, _) = makeStore()
        let custom = Profile(name: "Terminal", bundleIdentifiers: ["com.apple.Terminal"])
        store.add(custom)

        let result = store.delete(custom.id)

        XCTAssertTrue(result)
        XCTAssertFalse(store.profiles.contains { $0.id == custom.id })
    }

    /// Story 4.2 AC: "the Default Profile... can be edited but not deleted."
    func testDeleteRefusesToRemoveTheDefaultProfile() {
        let (store, _) = makeStore()
        let defaultProfile = store.profiles.first { $0.isDefault }!

        let result = store.delete(defaultProfile.id)

        XCTAssertFalse(result)
        XCTAssertTrue(store.profiles.contains { $0.id == defaultProfile.id })
    }

    func testMoveReordersProfiles() {
        let (store, _) = makeStore()
        let namesBefore = store.profiles.map(\.name)
        guard namesBefore.count >= 2 else { return XCTFail("expected at least two seeded profiles") }

        store.move(fromOffsets: IndexSet(integer: namesBefore.count - 1), toOffset: 0)

        XCTAssertEqual(store.profiles.first?.name, namesBefore.last)
    }

    // MARK: - Import (Story 4.3 AC)

    func testReplaceAllKeepsExactlyOneDefaultProfileWhenImportHasOne() {
        let (store, _) = makeStore()
        let imported = [
            Profile(id: Profile.defaultProfileID, name: "Default", isDefault: true),
            Profile(name: "Imported Custom", bundleIdentifiers: ["com.example.app"])
        ]

        store.replaceAll(with: imported)

        XCTAssertEqual(store.profiles.filter(\.isDefault).count, 1)
        XCTAssertEqual(store.profiles.count, 2)
    }

    func testReplaceAllAddsADefaultProfileWhenImportHasNone() {
        let (store, _) = makeStore()
        let imported = [Profile(name: "Imported Custom", bundleIdentifiers: ["com.example.app"])]

        store.replaceAll(with: imported)

        XCTAssertEqual(store.profiles.filter(\.isDefault).count, 1)
        XCTAssertEqual(store.profiles.count, 2)
    }
}
