import AppKit
import Foundation

/// Developer-only screenshot capture for the docs.
///
/// Launch with `TYPEFLOW_CAPTURE_DIR=/some/dir` and the app renders its own
/// windows to PNG: the Settings window once per section, the History window,
/// and — on the distributed notification `il.typeflow.capture` — every window
/// currently visible, which is how the menu-bar popover gets captured after
/// something else has opened it. The app draws its own view hierarchy into a
/// bitmap, so this needs no Screen Recording permission and works over SSH.
///
/// Inert unless the environment variable is set. Never triggered from the UI.
@MainActor
enum DebugCapture {
    private static let notification = Notification.Name("il.typeflow.capture")
    private static var token: NSObjectProtocol?

    static func startIfRequested(
        appState: AppState,
        settings: SettingsWindowManager,
        history: HistoryWindowManager
    ) {
        guard let dir = ProcessInfo.processInfo.environment["TYPEFLOW_CAPTURE_DIR"], !dir.isEmpty else {
            return
        }
        let outDir = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        token = DistributedNotificationCenter.default().addObserver(
            forName: notification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                for (index, window) in NSApp.windows.filter({ $0.isVisible && $0.frame.width > 40 }).enumerated() {
                    let name = window.title.isEmpty ? "window-\(index)" : slug(window.title)
                    write(window, to: outDir.appendingPathComponent("\(name).png"))
                }
            }
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let before = Set(NSApp.windows.map { ObjectIdentifier($0) })
            settings.open(appState: appState)
            try? await Task.sleep(for: .seconds(1))
            // `.navigationTitle` renames the window to the section label, so the
            // settings window is identified as the one `open` created, not by title.
            let settingsWindow = NSApp.windows.first { !before.contains(ObjectIdentifier($0)) }
            for section in SettingsSection.allCases {
                VocaDefaults.store.set(section.rawValue, forKey: "vocamac.settings.selectedSection")
                try? await Task.sleep(for: .milliseconds(900))
                if let window = settingsWindow {
                    write(window, to: outDir.appendingPathComponent("settings-\(section.rawValue).png"))
                }
            }
            history.open(appState: appState)
            try? await Task.sleep(for: .seconds(1))
            if let window = NSApp.windows.first(where: { $0.title == "TypeFlow History" }) {
                write(window, to: outDir.appendingPathComponent("history.png"))
            }
            try? "done\n".write(to: outDir.appendingPathComponent("CAPTURE_DONE"), atomically: true, encoding: .utf8)
        }
    }

    /// Draws the window's content view into a bitmap at backing scale, over the
    /// window background colour so visual-effect backdrops (which do not draw
    /// offscreen) come out solid rather than transparent. Content only — the
    /// title bar's toolbar items render as blank shapes offscreen.
    private static func write(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)

        let scale = window.backingScaleFactor
        let size = NSSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        guard let out = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        guard let data = out.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    private static func slug(_ title: String) -> String {
        title.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
