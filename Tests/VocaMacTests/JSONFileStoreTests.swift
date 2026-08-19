// JSONFileStoreTests.swift
// VocaMac Tests
//
// JSONFileStore is the one persistence primitive every collection store
// builds on (AD-10). These tests cover the guarantees every caller relies on:
// round-trip fidelity, atomic writes surviving process restart, corrupt-file
// recovery, and safe concurrent saves.

import XCTest
@testable import VocaMac

final class JSONFileStoreTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonfilestore_test_\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeStore<T: Codable & Sendable>(fileName: String = "data.json", defaultValue: T) -> JSONFileStore<T> {
        JSONFileStore(fileName: fileName, defaultValue: defaultValue, directoryURL: tempDirectory)
    }

    // MARK: - Round trip

    func testLoadReturnsDefaultValueWhenFileIsAbsent() {
        let store = makeStore(defaultValue: ["a", "b"])
        XCTAssertEqual(store.load(), ["a", "b"])
    }

    func testSaveThenLoadRoundTripsOnTheSameInstance() {
        let store = makeStore(defaultValue: [String]())
        store.save(["one", "two", "three"])
        store.flush()

        XCTAssertEqual(store.load(), ["one", "two", "three"])
    }

    func testSaveThenLoadRoundTripsAcrossFreshInstances() {
        // Simulates "quit and relaunch": a second store instance pointed at
        // the same directory/file must see what the first one wrote.
        let writer = makeStore(defaultValue: [Int]())
        writer.save([1, 2, 3])
        writer.flush()

        let reader = makeStore(defaultValue: [Int]())
        XCTAssertEqual(reader.load(), [1, 2, 3])
    }

    // MARK: - Atomic write

    func testSaveWritesTheFileToDisk() {
        let store = makeStore(fileName: "atomic.json", defaultValue: [String]())
        store.save(["x"])
        store.flush()

        let fileURL = tempDirectory.appendingPathComponent("atomic.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// `save()` must hand the work off rather than doing it inline. Timing the
    /// call is a throughput assertion and flakes on a loaded machine (MINOR
    /// 11); the ordering property is what actually distinguishes "enqueued"
    /// from "done synchronously", and it holds regardless of how slow the
    /// machine is.
    func testSaveEnqueuesTheWriteRatherThanPerformingItInline() {
        let store = makeStore(fileName: "ordering.json", defaultValue: [String]())
        let fileURL = tempDirectory.appendingPathComponent("ordering.json")

        store.save(Array(repeating: "x", count: 10_000))

        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path),
                        "save() must return before the write has happened")

        store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                       "…and the write must have landed once the queue drains")
    }

    // MARK: - Corrupt file quarantine (MAJOR 2)

    func testCorruptFileIsPreservedInsteadOfBeingOverwritten() throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let fileURL = tempDirectory.appendingPathComponent("data.json")
        let corruptContents = #"[{"partially":"recoverable"} "#
        try Data(corruptContents.utf8).write(to: fileURL)

        let store = makeStore(defaultValue: ["fallback"])
        XCTAssertEqual(store.load(), ["fallback"])

        let quarantined = try XCTUnwrap(store.quarantinedFileURL,
                                        "An undecodable file must be set aside, not left to be overwritten")
        XCTAssertTrue(quarantined.lastPathComponent.contains("corrupt-"))
        XCTAssertEqual(try String(contentsOf: quarantined, encoding: .utf8), corruptContents,
                        "The quarantined copy must be byte-for-byte what was on disk")

        // And the next save() writes a fresh file without touching it.
        store.save(["new"])
        store.flush()
        XCTAssertEqual(store.load(), ["new"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.path))
    }

    func testLoadingAValidFileQuarantinesNothing() {
        let store = makeStore(defaultValue: [String]())
        store.save(["fine"])
        store.flush()

        XCTAssertEqual(store.load(), ["fine"])
        XCTAssertNil(store.quarantinedFileURL)
    }

    // MARK: - Permissions (MAJOR 3)

    /// These files are verbatim transcripts of everything the user has ever
    /// dictated. At the default 0644 any other local account can read them.
    func testWrittenFileIsReadableOnlyByItsOwner() throws {
        let store = makeStore(fileName: "private.json", defaultValue: [String]())
        store.save(["secret dictation"])
        store.flush()

        let fileURL = tempDirectory.appendingPathComponent("private.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)

        XCTAssertEqual(permissions.int16Value & 0o777, 0o600)
    }

    func testStoreDirectoryIsAccessibleOnlyByItsOwner() throws {
        // A directory the store creates itself, not one the test pre-made.
        let nested = tempDirectory.appendingPathComponent("nested", isDirectory: true)
        let store = JSONFileStore<[String]>(fileName: "d.json", defaultValue: [], directoryURL: nested)
        store.save(["x"])
        store.flush()

        let attributes = try FileManager.default.attributesOfItem(atPath: nested.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)

        XCTAssertEqual(permissions.int16Value & 0o777, 0o700)
    }

    // MARK: - Corrupt file recovery

    func testLoadRecoversFromCorruptFile() throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let fileURL = tempDirectory.appendingPathComponent("data.json")
        try Data("{ this is not valid json ".utf8).write(to: fileURL)

        let store = makeStore(defaultValue: ["fallback"])
        XCTAssertEqual(store.load(), ["fallback"],
                        "A corrupt file must yield the default value, never crash or throw")
    }

    func testLoadRecoversFromWrongShapeJSON() throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let fileURL = tempDirectory.appendingPathComponent("data.json")
        // Valid JSON, but not the shape T expects (array of strings vs. object).
        try Data(#"{"unexpected": "shape"}"#.utf8).write(to: fileURL)

        let store = makeStore(defaultValue: ["fallback"])
        XCTAssertEqual(store.load(), ["fallback"])
    }

    // MARK: - Concurrent saves

    func testConcurrentSavesDoNotCrashAndLastWriteWins() {
        let store = makeStore(defaultValue: [Int]())
        let iterations = 50

        for i in 0..<iterations {
            store.save([i])
        }
        store.flush()

        // The serial save queue preserves enqueue order, so the last call's
        // payload must be what's on disk.
        XCTAssertEqual(store.load(), [iterations - 1])
    }

    func testSavesFromMultipleThreadsAreSerializedSafely() {
        let store = makeStore(defaultValue: [Int]())
        let group = DispatchGroup()

        for i in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                store.save([i])
                group.leave()
            }
        }
        group.wait()
        store.flush()

        // No crash, and the result is one of the values that was actually
        // written (never a torn/partial write).
        let result = store.load()
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue((0..<20).contains(result[0]))
    }
}
