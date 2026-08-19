// JSONFileStore.swift
// VocaMac
//
// One generic JSON-file persistence primitive for every collection this app
// keeps locally (AD-10): History, and later Profiles, the Dictionary, and
// Snippets. Modeled directly on StatsManager.swift:24-38 — atomic writes on a
// serial `.utility` queue, so a caller (always @MainActor) is never blocked
// on disk I/O.

import Foundation

final class JSONFileStore<T: Codable & Sendable>: @unchecked Sendable {

    private let fileURL: URL
    private let defaultValue: T
    private let saveQueue: DispatchQueue
    /// Which `LogCategory` this store's own failures are filed under. The
    /// store is shared by History, Profiles, the Dictionary, Snippets, and
    /// dismissed corrections; hard-coding `.history` meant a Profiles file
    /// failing to load, or being quarantined, was logged as a History problem
    /// — misleading in exactly the moment someone is reading the log to find
    /// out what happened (MINOR 17).
    private let logCategory: LogCategory

    /// Owner-only permissions for the directory and every file in it. These
    /// payloads are verbatim transcripts of everything the user has ever
    /// dictated; at the default 0755/0644 any other local account or process
    /// can read them, and backup/sync clients sweep them up as-is (MAJOR 3).
    private static var directoryPermissions: NSNumber { NSNumber(value: Int16(0o700)) }
    private static var filePermissions: NSNumber { NSNumber(value: Int16(0o600)) }

    /// - Parameters:
    ///   - fileName: e.g. "history.json".
    ///   - defaultValue: What `load()` returns when the file is absent, or
    ///     when it exists but fails to decode (corrupt or from an
    ///     incompatible future version).
    ///   - directoryURL: Override for tests; defaults to
    ///     `~/Library/Application Support/VocaMac/`.
    ///   - logCategory: Which category this store's own failures are logged
    ///     under. Defaults to `.history`, the original caller.
    init(
        fileName: String,
        defaultValue: T,
        directoryURL: URL? = nil,
        logCategory: LogCategory = .history
    ) {
        self.logCategory = logCategory
        let baseDirectory = directoryURL ?? JSONFileStore.applicationSupportDirectory()
        if !FileManager.default.fileExists(atPath: baseDirectory.path) {
            try? FileManager.default.createDirectory(
                at: baseDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: JSONFileStore.directoryPermissions]
            )
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
            // Returning the default value alone is not enough: the very next
            // save() would write over the unreadable file and take whatever
            // was recoverable in it with them. Set it aside first so a
            // partially-corrupt history is still there to be salvaged by hand
            // (MAJOR 2). `quarantinedFileURL` is left behind as the record of
            // what happened.
            quarantineCorruptFile()
            VocaLogger.error(logCategory, "JSONFileStore: failed to load \(fileURL.lastPathComponent) — \(error.localizedDescription). Using default value.")
            return defaultValue
        }
    }

    /// Where `load()` moved a file it could not decode, if it ever did. Read
    /// by callers that want to tell the user their history was set aside.
    private(set) var quarantinedFileURL: URL?

    private func quarantineCorruptFile() {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let destination = fileURL.appendingPathExtension("corrupt-\(stamp)")
        do {
            try FileManager.default.moveItem(at: fileURL, to: destination)
            quarantinedFileURL = destination
            VocaLogger.warning(logCategory, "JSONFileStore: preserved the unreadable \(fileURL.lastPathComponent) as \(destination.lastPathComponent)")
        } catch {
            VocaLogger.error(logCategory, "JSONFileStore: could not preserve the unreadable \(fileURL.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    /// Encodes *and* writes off-main, atomically, on the serial save queue, so
    /// writes never race each other and never block the caller.
    ///
    /// The encode used to happen on the caller's thread, which is always the
    /// main actor: with an unbounded history that is a whole-file JSON encode
    /// on the main thread after every single dictation, growing without limit
    /// — hundreds of milliseconds of stall right after the injection the user
    /// is watching for (MAJOR 1, NFR-4). `T: Sendable` is what makes moving it
    /// across the queue boundary safe rather than merely convenient.
    func save(_ value: T) {
        let url = fileURL
        // Copied out alongside `url` rather than captured through `self`,
        // for the same reason `url` is: this closure must not retain the
        // store (MINOR 17).
        let category = logCategory
        saveQueue.async {
            let data: Data
            do {
                data = try JSONEncoder().encode(value)
            } catch {
                VocaLogger.error(category, "JSONFileStore: failed to encode \(url.lastPathComponent) — \(error.localizedDescription)")
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                // An atomic write replaces the file, so the permissions have
                // to be re-applied to the new inode every time (MAJOR 3).
                try? FileManager.default.setAttributes(
                    [.posixPermissions: JSONFileStore.filePermissions],
                    ofItemAtPath: url.path
                )
            } catch {
                VocaLogger.error(category, "JSONFileStore: failed to write \(url.lastPathComponent) — \(error.localizedDescription)")
            }
        }
    }

    /// Blocks until every write enqueued so far has completed.
    ///
    /// Used by tests to assert on what actually landed on disk, and at
    /// termination to make sure the last dictation of the session is not
    /// still sitting in the queue when the process goes away (MINOR 6) — a
    /// SIGTERM from `ensureSingleInstance` arrives with no warning at all.
    func flush() {
        saveQueue.sync {}
    }
}
