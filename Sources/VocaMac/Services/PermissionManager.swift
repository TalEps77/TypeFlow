// PermissionManager.swift
// VocaMac
//
// Manages system permission checking, requesting, and polling.
// Extracts permission logic from AppState for focused responsibility.

import Foundation
import AppKit
import Combine

/// Manages system permissions: microphone, accessibility, and input monitoring.
///
/// Accessibility and Input Monitoring permissions don't provide callback-based APIs,
/// so this manager polls to detect changes when the user grants access in System Settings.
@MainActor
final class PermissionManager: ObservableObject {

    // MARK: - Published State

    /// Microphone permission status
    @Published var micPermission: PermissionStatus = .notDetermined

    /// Accessibility permission status
    @Published var accessibilityPermission: PermissionStatus = .notDetermined

    /// Input Monitoring permission status
    @Published var inputMonitoringPermission: PermissionStatus = .notDetermined

    // MARK: - Dependencies

    private let audioEngine: AudioRecording
    private let hotKeyManager: HotKeyMonitoring

    // MARK: - Private

    private var permissionPollTimer: Timer?

    /// The cadence `permissionPollTimer` is currently running at, so
    /// re-entrant `startPermissionPolling()` calls are idempotent and a
    /// cadence change actually reschedules.
    private var currentPollInterval: TimeInterval?

    /// When each permission was first observed `.denied`, `nil` once it is not.
    ///
    /// These live here rather than in the Settings view that reads them
    /// (MINOR 3). As `@State` on the Debug tab they were reset by every
    /// `onAppear`, so switching tabs — exactly what a user does while walking
    /// over to System Settings — restarted the 30-second clock and the
    /// stuck-permission hint could be postponed indefinitely. Set on the
    /// transition *into* `.denied`, they now outlive any view.
    private var micDeniedSince: Date?
    private var accessibilityDeniedSince: Date?
    private var inputMonitoringDeniedSince: Date?

    /// Poll cadence while something is still missing — fast, because the user
    /// is standing in System Settings waiting for the app to notice.
    private static let activePollInterval: TimeInterval = 3.0

    /// Poll cadence once everything is granted. Polling slows down but never
    /// stops (MINOR 5): it used to be torn down for good on the first
    /// all-granted tick, so a permission revoked mid-session left a stale
    /// `.granted` on screen forever — and because the stuck-permission hint is
    /// driven by observed `.denied`, the one thing that would have explained
    /// the app's sudden silence was unreachable without a restart.
    private static let idlePollInterval: TimeInterval = 30.0

    var onAllPermissionsGranted: (() -> Void)?

    // MARK: - Initialization

    init(audioEngine: AudioRecording, hotKeyManager: HotKeyMonitoring) {
        self.audioEngine = audioEngine
        self.hotKeyManager = hotKeyManager
    }

    // MARK: - Permission Checking

    /// Whether all required permissions are granted.
    var allPermissionsGranted: Bool {
        micPermission == .granted &&
        accessibilityPermission == .granted &&
        inputMonitoringPermission == .granted
    }

    /// Re-check all permission statuses from the system.
    func checkPermissions() {
        micPermission = audioEngine.checkPermissionStatus()

        let accessibilityGranted = hotKeyManager.checkAccessibilityPermission(prompt: false)
        accessibilityPermission = accessibilityGranted ? .granted : .denied

        let inputMonitoringGranted = checkInputMonitoringPermission()
        inputMonitoringPermission = inputMonitoringGranted ? .granted : .denied

        recordDenial(micPermission, into: &micDeniedSince)
        recordDenial(accessibilityPermission, into: &accessibilityDeniedSince)
        recordDenial(inputMonitoringPermission, into: &inputMonitoringDeniedSince)
    }

    /// Stamps the moment a permission first reads `.denied`, and clears the
    /// stamp the moment it stops being denied — so a granted-then-revoked
    /// cycle restarts the clock rather than firing the hint instantly.
    private func recordDenial(_ status: PermissionStatus, into tracker: inout Date?) {
        guard status == .denied else {
            tracker = nil
            return
        }
        if tracker == nil {
            tracker = Date()
        }
    }

    /// How long the longest-standing currently-denied permission has been
    /// denied, or `nil` when nothing is denied. The Settings hint asks this one
    /// question, so this is the one thing exposed rather than three dates.
    var longestPermissionDenialDuration: TimeInterval? {
        let now = Date()
        return [micDeniedSince, accessibilityDeniedSince, inputMonitoringDeniedSince]
            .compactMap { $0 }
            .map { now.timeIntervalSince($0) }
            .max()
    }

    /// Check Input Monitoring permission using multiple strategies since no
    /// single approach is 100% reliable:
    /// 1. If HotKeyManager created a tap, check if macOS has disabled it (revocation)
    /// 2. Try creating a fresh `.cghidEventTap` to trigger/check Input Monitoring
    private func checkInputMonitoringPermission() -> Bool {
        // Strategy 1: If HotKeyManager has an active tap, check if macOS disabled it.
        if hotKeyManager.isListening, let tap = hotKeyManager.eventTap {
            return CGEvent.tapIsEnabled(tap: tap)
        }

        // Strategy 2: Try creating a fresh .cghidEventTap. This probes Input
        // Monitoring more accurately than .cgSessionEventTap, which may inherit
        // Terminal's permissions when launched from CLI.
        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passRetained(event) },
            userInfo: nil
        )
        if let tap = tap {
            CFMachPortInvalidate(tap)
            return true
        }
        return false
    }

    // MARK: - Permission Requests

    /// Request microphone permission. Opens System Settings if already denied.
    func requestMicrophonePermission() {
        if micPermission == .denied {
            openMicrophoneSettings()
            return
        }

        audioEngine.requestPermission { [weak self] granted in
            Task { @MainActor in
                self?.micPermission = granted ? .granted : .denied
            }
        }
    }

    /// Open the Microphone privacy pane in System Settings.
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.checkPermissions()
        }
    }

    /// Prompt the user to grant Accessibility permission.
    func requestAccessibilityPermission() {
        let _ = HotKeyManager.checkAccessibilityPermission(prompt: true)
        startPermissionPolling()
    }

    /// Trigger Input Monitoring permission dialog and open System Settings.
    func requestInputMonitoringPermission() {
        // Attempting to create an event tap triggers macOS to auto-add
        // the app to the Input Monitoring list in System Settings.
        let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, _, event, _ in Unmanaged.passRetained(event) },
            userInfo: nil
        )
        if let tap = tap {
            CFMachPortInvalidate(tap)
        }

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }

        startPermissionPolling()
    }

    // MARK: - Permission Polling

    /// Start polling permissions — every 3 seconds while anything is missing,
    /// every 30 once everything is granted. It does not stop on its own
    /// (MINOR 5): a mid-session revoke has to be noticed too.
    func startPermissionPolling() {
        schedulePolling(interval: allPermissionsGranted ? Self.idlePollInterval : Self.activePollInterval)
    }

    /// Idempotent: asking for the cadence that is already running is a no-op,
    /// so the several places that call `startPermissionPolling()` cannot stack
    /// up timers.
    private func schedulePolling(interval: TimeInterval) {
        guard currentPollInterval != interval else { return }

        permissionPollTimer?.invalidate()
        currentPollInterval = interval
        VocaLogger.debug(.appState, "Permission polling every \(Int(interval))s")

        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollTick()
            }
        }
    }

    private func pollTick() {
        checkPermissions()

        // Notify when all permissions granted and hotkey can start
        if accessibilityPermission == .granted &&
            inputMonitoringPermission == .granted &&
            !hotKeyManager.isListening {
            onAllPermissionsGranted?()
        }

        // Slow down rather than stop, and speed back up if something was
        // revoked while we were idling.
        schedulePolling(interval: allPermissionsGranted ? Self.idlePollInterval : Self.activePollInterval)
    }

    /// Stop polling entirely. Nothing in the normal lifecycle calls this any
    /// more — it exists for teardown.
    func stopPermissionPolling() {
        VocaLogger.debug(.appState, "Stopping permission polling")
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        currentPollInterval = nil
    }
}

// MARK: - PermissionManaging Conformance

extension PermissionManager: PermissionManaging {
    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }
}
