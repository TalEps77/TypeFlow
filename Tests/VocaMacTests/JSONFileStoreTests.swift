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

    private func makeStore<T: Codable>(fileName: String = "data.json", defaultValue: T) -> JSONFileStore<T> {
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
        store.synchronizeForTesting()

        XCTAssertEqual(store.load(), ["one", "two", "three"])
    }

    func testSaveThenLoadRoundTripsAcrossFreshInstances() {
        // Simulates "quit and relaunch": a second store instance pointed at
        // the same directory/file must see what the first one wrote.
        let writer = makeStore(defaultValue: [Int]())
        writer.save([1, 2, 3])
        writer.synchronizeForTesting()

        let reader = makeStore(defaultValue: [Int]())
        XCTAssertEqual(reader.load(), [1, 2, 3])
    }

    // MARK: - Atomic write

    func testSaveWritesTheFileToDisk() {
        let store = makeStore(fileName: "atomic.json", defaultValue: [String]())
        store.save(["x"])
        store.synchronizeForTesting()

        let fileURL = tempDirectory.appendingPathComponent("atomic.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSaveDoesNotBlockTheCallingThread() {
        let store = makeStore(defaultValue: [String]())
        let start = Date()
        store.save(Array(repeating: "x", count: 10_000))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.05,
                           "save() must enqueue the write and return immediately")
        store.synchronizeForTesting()
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
        store.synchronizeForTesting()

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
        store.synchronizeForTesting()

        // No crash, and the result is one of the values that was actually
        // written (never a torn/partial write).
        let result = store.load()
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue((0..<20).contains(result[0]))
    }
}
