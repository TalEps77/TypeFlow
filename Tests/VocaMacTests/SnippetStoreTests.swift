// SnippetStoreTests.swift
// VocaMac Tests
//
// Story 5.5: Snippet persistence and CRUD, modeled on DictionaryStoreTests,
// plus the Cue-collision guard that keeps Cues unambiguous.

import XCTest
@testable import VocaMac

@MainActor
final class SnippetStoreTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("snippet_store_test_\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeStore() -> (SnippetStore, JSONFileStore<[Snippet]>) {
        let fileStore = JSONFileStore<[Snippet]>(fileName: "snippets.json", defaultValue: [], directoryURL: tempDirectory)
        return (SnippetStore(store: fileStore), fileStore)
    }

    // MARK: - Fresh install

    func testFreshInstallStartsWithNoSnippets() {
        let (store, _) = makeStore()
        XCTAssertTrue(store.snippets.isEmpty)
    }

    // MARK: - CRUD (Story 5.5 AC)

    func testAddAppendsASnippet() {
        let (store, _) = makeStore()

        store.add(Snippet(cue: "signature", body: "Best regards,\nJohn"))

        XCTAssertEqual(store.snippets.count, 1)
        XCTAssertEqual(store.snippets.first?.cue, "signature")
    }

    func testUpdateReplacesTheMatchingSnippet() {
        let (store, _) = makeStore()
        var snippet = Snippet(cue: "signature", body: "old body")
        store.add(snippet)

        snippet.body = "new body\nsecond line"
        store.update(snippet)

        let updated = store.snippets.first { $0.id == snippet.id }
        XCTAssertEqual(updated?.body, "new body\nsecond line")
    }

    func testDeleteRemovesASnippet() {
        let (store, _) = makeStore()
        let snippet = Snippet(cue: "signature", body: "body")
        store.add(snippet)

        let result = store.delete(snippet.id)

        XCTAssertTrue(result)
        XCTAssertTrue(store.snippets.isEmpty)
    }

    func testDeleteOfAnUnknownIDReturnsFalse() {
        let (store, _) = makeStore()
        XCTAssertFalse(store.delete(UUID()))
    }

    // MARK: - Persistence round-trip (multi-line body survives exactly)

    func testMultiLineBodySurvivesAFreshInstanceAtTheSameFile() {
        let fileStore = JSONFileStore<[Snippet]>(fileName: "snippets.json", defaultValue: [], directoryURL: tempDirectory)
        let first = SnippetStore(store: fileStore)
        let body = "Line one\nLine two\n\nLine four"
        first.add(Snippet(cue: "signature", body: body))
        fileStore.flush()

        let restartedFileStore = JSONFileStore<[Snippet]>(fileName: "snippets.json", defaultValue: [], directoryURL: tempDirectory)
        let second = SnippetStore(store: restartedFileStore)

        XCTAssertEqual(second.snippets.first?.body, body)
    }

    // MARK: - Export/import round-trip (Story 5.5 AC)

    func testReplaceAllRoundTripsThroughJSONEncodingAndDecoding() throws {
        let (store, _) = makeStore()
        store.add(Snippet(cue: "signature", body: "Best regards,\nJohn"))
        store.add(Snippet(cue: "address", body: "123 Main St"))

        let encoded = try JSONEncoder().encode(store.snippets)
        let decoded = try JSONDecoder().decode([Snippet].self, from: encoded)

        let (importTarget, _) = makeStore()
        importTarget.replaceAll(with: decoded)

        XCTAssertEqual(importTarget.snippets, store.snippets)
    }

    // MARK: - Cue collision (Story 5.5 AC: "Cues must be unambiguous")

    func testHasCollisionDetectsAnExactDuplicateCue() {
        let (store, _) = makeStore()
        store.add(Snippet(cue: "signature", body: "a"))

        XCTAssertTrue(store.hasCollision(withCue: "signature"))
    }

    func testHasCollisionIsCaseAndNormalizationTolerant() {
        let (store, _) = makeStore()
        store.add(Snippet(cue: "חתימה", body: "a"))

        // Same word, fully pointed -- must still be seen as a collision.
        XCTAssertTrue(store.hasCollision(withCue: "חֲתִימָה"))
        XCTAssertFalse(store.hasCollision(withCue: "SIGNATURE"), "unrelated cue is not a collision")
    }

    func testHasCollisionIsFalseForAUniqueCue() {
        let (store, _) = makeStore()
        store.add(Snippet(cue: "signature", body: "a"))

        XCTAssertFalse(store.hasCollision(withCue: "address"))
    }

    func testHasCollisionExcludesTheSnippetBeingEdited() {
        let (store, _) = makeStore()
        let snippet = Snippet(cue: "signature", body: "a")
        store.add(snippet)

        // Renaming a Snippet's Cue to the same value it already has must not
        // reject itself as a collision.
        XCTAssertFalse(store.hasCollision(withCue: "signature", excluding: snippet.id))
    }

    func testHasCollisionStillRejectsAgainstOtherSnippetsWhileExcludingSelf() {
        let (store, _) = makeStore()
        let first = Snippet(cue: "signature", body: "a")
        let second = Snippet(cue: "address", body: "b")
        store.add(first)
        store.add(second)

        XCTAssertTrue(store.hasCollision(withCue: "signature", excluding: second.id))
    }
}
