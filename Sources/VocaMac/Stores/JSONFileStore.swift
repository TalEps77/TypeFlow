// JSONFileStore.swift
// VocaMac
//
// One generic JSON-file persistence primitive for every collection this app
// keeps locally (AD-10): History, and later Profiles, the Dictionary, and
// Snippets. Modeled directly on StatsManager.swift:24-38 — atomic writes on a
// serial `.utility` queue, so a caller (always @MainActor) is never blocked
// on disk I/O.

import Foundation

final class JSONFileStore<T: Codable>: @unchecked Sendable {

    private let fileURL: URL
    private let defaultValue: T
    private let saveQueue: DispatchQueue

    /// - Parameters:
    ///   - fileName: e.g. "history.json".
    ///   - defaultValue: What `load()` returns when the file is absent, or
    ///     when it exists but fails to decode (corrupt or from an
    ///     incompatible future version).
    ///   - directoryURL: Override for tests; defaults to
    ///     `~/Library/Application Support/VocaMac/`.
    init(
        fileName: String,
        defaultValue: T,
        directoryURL: URL? = nil
    ) {
        let baseDirectory = directoryURL ?? JSONFileStore.applicationSupportDirectory()
        if !FileManager.default.fileExists(atPath: baseDirectory.path) {
            try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }
        self.fileURL = baseDirectory.appendingPathComponent(fileName)
        self.defaultValue = defaultValue
        self.saveQueue = DispatchQueue(label: "com.vocamac.jsonfilestore.\(fileName)", qos: .utility)
    }

    static func applicationSupportDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("VocaMac", isDirectory: true)
    }

    /// Synchronous read. Called once, at startup — the payloads this store
    /// carries are small (StatsManager precedent), so this never runs on a
    /// hot path. A corrupt or unreadable file never crashes and never blocks
    /// startup: it logs and yields `defaultValue` instead.
    func load() -> T {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return defaultValue
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            VocaLogger.error(.general, "JSONFileStore: failed to load \(fileURL.lastPathComponent) — \(error.localizedDescription). Using default value.")
            return defaultValue
        }
    }

    /// Encodes on the caller's thread (cheap — these payloads are small) then
    /// writes off-main, atomically, on the serial save queue so writes never
    /// race each other and never block the caller.
    func save(_ value: T) {
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            VocaLogger.error(.general, "JSONFileStore: failed to encode \(fileURL.lastPathComponent) — \(error.localizedDescription)")
            return
        }
        let url = fileURL
        saveQueue.async {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                VocaLogger.error(.general, "JSONFileStore: failed to write \(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }
    }

    /// Test-only escape hatch: blocks until every write enqueued so far has
    /// completed, so a test can assert on what actually landed on disk.
    func synchronizeForTesting() {
        saveQueue.sync {}
    }
}
