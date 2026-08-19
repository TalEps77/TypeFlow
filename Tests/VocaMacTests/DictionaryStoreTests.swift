// DictionaryStoreTests.swift
// VocaMac Tests
//
// Story 5.3: Dictionary Entry persistence and CRUD, modeled on
// ProfileStoreTests. No "always exactly one" invariant to enforce here —
// unlike Profiles, an empty Dictionary is a perfectly normal, supported state
// (AD-2: it makes DictionaryStage an identity operation).

import XCTest
@testable import VocaMac

@MainActor
final class DictionaryStoreTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictionary_store_test_\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeStore() -> (DictionaryStore, JSONFileStore<[DictionaryEntry]>) {
        let fileStore = JSONFileStore<[DictionaryEntry]>(fileName: "dictionary.json", defaultValue: [], directoryURL: tempDirectory)
        return (DictionaryStore(store: fileStore), fileStore)
    }

    // MARK: - Fresh install

    func testFreshInstallStartsWithNoEntries() {
        let (store, _) = makeStore()
        XCTAssertTrue(store.entries.isEmpty)
    }

    // MARK: - CRUD (Story 5.3 AC)

    func testAddAppendsAnEntry() {
        let (store, _) = makeStore()

        store.add(DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קוברנטיס"]))

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.canonicalForm, "Kubernetes")
    }

    func testUpdateReplacesTheMatchingEntry() {
        let (store, _) = makeStore()
        var entry = DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קוברנטיס"])
        store.add(entry)

        entry.canonicalForm = "Kubernetes (K8s)"
        entry.triggers.append("קוברנטס")
        store.update(entry)

        let updated = store.entries.first { $0.id == entry.id }
        XCTAssertEqual(updated?.canonicalForm, "Kubernetes (K8s)")
        XCTAssertEqual(updated?.triggers, ["קוברנטיס", "קוברנטס"])
    }

    func testUpdateOfAnUnknownIDDoesNothing() {
        let (store, _) = makeStore()
        store.add(DictionaryEntry(canonicalForm: "A", triggers: ["a"]))
        let countBefore = store.entries.count

        store.update(DictionaryEntry(canonicalForm: "Ghost", triggers: ["ghost"]))

        XCTAssertEqual(store.entries.count, countBefore)
    }

    func testDeleteRemovesAnEntry() {
        let (store, _) = makeStore()
        let entry = DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קוברנטיס"])
        store.add(entry)

        let result = store.delete(entry.id)

        XCTAssertTrue(result)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testDeleteOfAnUnknownIDReturnsFalse() {
        let (store, _) = makeStore()
        let result = store.delete(UUID())
        XCTAssertFalse(result)
    }

    // MARK: - Persistence round-trip (Story 5.3 AC: "restart the app")

    func testEntriesSurviveAFreshInstanceAtTheSameFile() {
        let fileStore = JSONFileStore<[DictionaryEntry]>(fileName: "dictionary.json", defaultValue: [], directoryURL: tempDirectory)
        let first = DictionaryStore(store: fileStore)
        first.add(DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קוברנטיס", "קווברנטיס"]))
        first.add(DictionaryEntry(canonicalForm: "Docker", triggers: ["דוקר"]))
        fileStore.flush()

        let restartedFileStore = JSONFileStore<[DictionaryEntry]>(fileName: "dictionary.json", defaultValue: [], directoryURL: tempDirectory)
        let second = DictionaryStore(store: restartedFileStore)

        XCTAssertEqual(second.entries.count, 2)
        XCTAssertEqual(second.entries.map(\.canonicalForm).sorted(), ["Docker", "Kubernetes"])
        XCTAssertEqual(second.entries.first { $0.canonicalForm == "Kubernetes" }?.triggers, ["קוברנטיס", "קווברנטיס"])
    }

    // MARK: - Export/import round-trip (Story 5.3 AC)

    func testReplaceAllRoundTripsThroughJSONEncodingAndDecoding() throws {
        let (store, _) = makeStore()
        store.add(DictionaryEntry(canonicalForm: "Kubernetes", triggers: ["קוברנטיס"]))
        store.add(DictionaryEntry(canonicalForm: "Docker", triggers: ["דוקר", "דוקער"]))

        // Mirrors what the settings tab's Export/Import buttons do: encode,
        // then decode back and replace the whole set.
        let encoded = try JSONEncoder().encode(store.entries)
        let decoded = try JSONDecoder().decode([DictionaryEntry].self, from: encoded)

        let (importTarget, _) = makeStore()
        importTarget.replaceAll(with: decoded)

        XCTAssertEqual(importTarget.entries, store.entries)
    }

    func testReplaceAllReplacesTheWholeSet() {
        let (store, _) = makeStore()
        store.add(DictionaryEntry(canonicalForm: "Stale", triggers: ["stale"]))

        let imported = [DictionaryEntry(canonicalForm: "Fresh", triggers: ["fresh"])]
        store.replaceAll(with: imported)

        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.canonicalForm, "Fresh")
    }
}
