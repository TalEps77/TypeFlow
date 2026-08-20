// VocaMacApp.swift
// VocaMac
//
// Main entry point for the VocaMac application.
// Configures the app as a menu bar-only application (no Dock icon).

import SwiftUI

/// Drops the Dock icon and menu bar again once the last ordinary window has
/// closed — and only then.
///
/// Each window manager used to demote unconditionally half a second after
/// *its* window closed, which yanked the Dock icon and menu out from under
/// whatever other window was still open (MINOR 4). Closing Settings while
/// Onboarding is up is enough to reproduce it.
private func demoteToAccessoryIfNoWindowsRemain() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let hasOrdinaryWindow = NSApp.windows.contains { window in
            window.isVisible && window.canBecomeMain && !(window is NSPanel)
        }
        guard !hasOrdinaryWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

/// True when this window should be reused rather than replaced: a window the
/// user merely minimized is still ours to bring back. `isVisible` is false for
/// a miniaturized window, so testing it created a second window every time and
/// orphaned the first in the Dock (MINOR 3).
private func reuse(_ window: NSWindow?) -> Bool {
    guard let window else { return false }
    if window.isMiniaturized {
        window.deminiaturize(nil)
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    return true
}

/// Manages the settings window for menu-bar-only apps
final class SettingsWindowManager: ObservableObject {
    private var settingsWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func open(appState: AppState) {
        // If window already exists, just bring it to front
        if reuse(settingsWindow) {
            return
        }

        // Create the settings view
        let settingsView = SettingsView()
            .environmentObject(appState)

        // Create a new window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TypeFlow Settings"
        window.contentView = NSHostingView(rootView: settingsView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.settingsWindow = window

        // Temporarily show in dock so the window can receive focus
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Watch for window close to hide from dock again. The token is kept
        // and removed on fire, so reopening the window doesn't stack up a new
        // observer every time (MINOR 4).
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            if let token = self?.closeObserver {
                NotificationCenter.default.removeObserver(token)
            }
            self?.closeObserver = nil
            self?.settingsWindow = nil
            demoteToAccessoryIfNoWindowsRemain()
        }
    }
}

/// Manages the history window
final class HistoryWindowManager: ObservableObject {
    private var historyWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func open(appState: AppState) {
        if reuse(historyWindow) {
            return
        }

        let historyView = HistoryView()
            .environmentObject(appState)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 440),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TypeFlow History"
        window.contentView = NSHostingView(rootView: historyView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.historyWindow = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            if let token = self?.closeObserver {
                NotificationCenter.default.removeObserver(token)
            }
            self?.closeObserver = nil
            self?.historyWindow = nil
            demoteToAccessoryIfNoWindowsRemain()
        }
    }
}

/// Manages the onboarding window
@MainActor
final class OnboardingWindowManager: ObservableObject {
    private var onboardingWindow: NSWindow?
    private var closeObserver: NSObjectProtocol?
    var onCompletion: (() -> Void)?

    func open(appState: AppState, force: Bool = false) {
        // If window already exists, just bring it to front
        if reuse(onboardingWindow) {
            return
        }

        // When manually re-triggered, reset completion flag so the
        // monitor doesn't immediately close the window
        if force {
            appState.hasCompletedOnboarding = false
        }

        // Create the onboarding view
        let onboardingView = OnboardingView()
            .environmentObject(appState)

        // Create a new window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to TypeFlow"
        window.contentView = NSHostingView(rootView: onboardingView)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)

        self.onboardingWindow = window

        // Show in dock
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Watch for window close
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                if let token = self?.closeObserver {
                    NotificationCenter.default.removeObserver(token)
                }
                self?.closeObserver = nil
                self?.onboardingWindow = nil
                // Hide from dock when onboarding closes — but not while
                // Settings or History is still open (MINOR 4).
                demoteToAccessoryIfNoWindowsRemain()
            }
        }

        // Monitor app state for onboarding completion on main thread
        DispatchQueue.main.async {
            self.monitorOnboardingCompletion(appState: appState)
        }
    }

    private func monitorOnboardingCompletion(appState: AppState) {
        Task {
            while self.onboardingWindow?.isVisible == true {
                await MainActor.run {
                    if appState.hasCompletedOnboarding {
                        self.onboardingWindow?.close()
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)  // Check every 100ms
            }
        }
    }
}

@main
struct VocaMacApp: App {
    @StateObject private var appState = AppState.production()
    @StateObject private var settingsManager = SettingsWindowManager()
    @StateObject private var historyManager = HistoryWindowManager()
    @StateObject private var onboardingManager = OnboardingWindowManager()

    var body: some Scene {
        // Menu bar presence — the primary UI for VocaMac
        MenuBarExtra {
            MenuBarView(settingsManager: settingsManager, historyManager: historyManager)
                .environmentObject(appState)
        } label: {
            MenuBarIcon(appStatus: appState.appStatus, audioLevel: appState.audioLevel)
                .onAppear {
                    // Trigger startup from the SwiftUI lifecycle so it only runs
                    // on the AppState instance that SwiftUI actually retains.
                    // Previously, startup ran in AppState.init() which caused
                    // double initialization (and double event taps) because
                    // SwiftUI may instantiate the App struct more than once.
                    appState.triggerStartupIfNeeded()
                }
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor init() {
        // Ensure only one instance of VocaMac is running
        Self.ensureSingleInstance()

        // For .app bundles, Dock hiding is handled by LSUIElement=true in Info.plist.
        // For direct binary execution, we set it programmatically.
        DispatchQueue.main.async {
            NSApp?.setActivationPolicy(.accessory)
        }

        // Listen for "Show Setup Wizard" requests from Settings / Menu Bar
        NotificationCenter.default.addObserver(
            forName: .showOnboarding,
            object: nil,
            queue: .main
        ) { [self] _ in
            Task { @MainActor [self] in
                self.onboardingManager.open(appState: self.appState, force: true)
            }
        }

        // Show onboarding on first launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            if !self.appState.hasCompletedOnboarding {
                self.onboardingManager.open(appState: self.appState)
            }
        }
    }

    /// Terminate any other running instances of VocaMac
    private static func ensureSingleInstance() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.vocamac.app")

        for app in runningApps where app.processIdentifier != currentPID {
            VocaLogger.info(.general, "Terminating previous instance (PID \(app.processIdentifier))")
            app.terminate()
        }

        // Also kill by process name for direct binary execution (no bundle ID)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "VocaMac"]

        let pipe = Pipe()
        task.standardOutput = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let pids = output.split(separator: "\n").compactMap { Int32($0) }
                for pid in pids where pid != currentPID {
                    VocaLogger.info(.general, "Killing previous VocaMac process (PID \(pid))")
                    kill(pid, SIGTERM)
                }
            }
        } catch {
            // pgrep not found or failed — not critical
        }
    }
}

// MARK: - Menu Bar Icon

/// Renders a mic icon in the menu bar with color changes based on app status.
///
/// Uses NSImage to create properly tinted menu bar icons because MenuBarExtra's
/// label treats SwiftUI `.foregroundStyle()` colors as template images, stripping
/// color. By setting `isTemplate = false` for non-idle states, macOS renders
/// the actual color in the menu bar.
///
/// States:
///   • idle       → system default (template mic, adapts to menu bar appearance)
///   • recording  → red filled mic (non-template, colored)
///   • processing → orange spinner (non-template, colored)
///   • error      → yellow warning (non-template, colored)
struct MenuBarIcon: View {
    let appStatus: AppStatus
    let audioLevel: Float

    var body: some View {
        Image(nsImage: makeMenuBarIcon())
    }

    private func makeMenuBarIcon() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)

        guard let baseImage = NSImage(systemSymbolName: iconName, accessibilityDescription: "TypeFlow")?
            .withSymbolConfiguration(config) else {
            // Fallback to a basic mic if symbol lookup fails
            return NSImage(systemSymbolName: "mic", accessibilityDescription: "TypeFlow") ?? NSImage()
        }

        // Tint the icon with the status color
        let tintColor = nsColor
        let size = baseImage.size

        let tinted = NSImage(size: size, flipped: false) { rect in
            baseImage.draw(in: rect)
            tintColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

    private var iconName: String {
        switch appStatus {
        case .idle:
            return "mic.fill"
        case .recording:
            return "mic.fill"
        case .processing:
            return "ellipsis.circle"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    private var nsColor: NSColor {
        switch appStatus {
        case .idle:       return NSColor(red: 0, green: 0.478, blue: 1.0, alpha: 1.0)
        case .recording:  return .systemRed
        case .processing: return NSColor(red: 0.749, green: 0.353, blue: 0.949, alpha: 1.0) // #BF5AF2
        case .error:      return .systemYellow
        }
    }
}
