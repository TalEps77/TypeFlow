// HotKeySelectionControl.swift
// VocaMac
//
// Reusable hotkey picker with direct key recording for settings and onboarding.

import AppKit
import SwiftUI

struct HotKeySelectionControl: View {
    @EnvironmentObject private var appState: AppState
    @State private var isRecording = false
    @State private var wasListeningBeforeRecording = false
    @State private var rejectionMessage: String?

    /// The key code this control edits. Story 6.1 made this a binding so the
    /// same control can drive either hotkey; it defaults to nothing and every
    /// call site passes one explicitly.
    @Binding private var keyCode: Int

    let pickerLabel: String
    let footerText: String?

    /// A key code this control must refuse, because the *other* binding
    /// already owns it, and what to call it in the rejection message
    /// (Story 6.1 AC). `nil` disables the check.
    let reservedKeyCode: Int?
    let reservedKeyOwner: String

    /// Applied after a value is accepted — each call site pushes its own
    /// binding's configuration to the listener.
    let onCommit: () -> Void

    init(
        keyCode: Binding<Int>,
        pickerLabel: String = "Preset",
        footerText: String? = nil,
        reservedKeyCode: Int? = nil,
        reservedKeyOwner: String = "the other hotkey",
        onCommit: @escaping () -> Void
    ) {
        self._keyCode = keyCode
        self.pickerLabel = pickerLabel
        self.footerText = footerText
        self.reservedKeyCode = reservedKeyCode
        self.reservedKeyOwner = reservedKeyOwner
        self.onCommit = onCommit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker(pickerLabel, selection: pickerSelection) {
                    ForEach(KeyCodeReference.commonHotKeys, id: \.keyCode) { hotKey in
                        Text(hotKey.name).tag(hotKey.keyCode)
                    }

                    if !KeyCodeReference.isCommonHotKey(keyCode) {
                        Divider()
                        Text("Custom: \(KeyCodeReference.displayName(for: keyCode))")
                            .tag(keyCode)
                    }
                }
                .disabled(isRecording)

                HotKeyRecorderButton(
                    isRecording: $isRecording,
                    onStart: beginRecording,
                    onCancel: finishRecording,
                    onKeyRecorded: recordKey
                )
            }

            if isRecording {
                Label("Press a key, or press Escape to cancel", systemImage: "keyboard")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            } else if let rejectionMessage {
                Label(rejectionMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let footerText {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // A rejection is about one specific clash, so it dies with it (MINOR 2).
        // Without this, refusing a key here and then moving the *other* binding
        // off it leaves the warning on screen — and suppressing `footerText` —
        // until the next successful pick.
        .onChange(of: reservedKeyCode) { _ in
            rejectionMessage = nil
        }
        .onDisappear {
            guard isRecording else { return }
            isRecording = false
            finishRecording()
        }
    }

    /// The Picker writes through this rather than straight to `keyCode`, so a
    /// collision is refused before it is ever stored — a rejection that wrote
    /// the value and then reverted it would briefly leave two bindings on one
    /// key, and would flicker in the UI.
    private var pickerSelection: Binding<Int> {
        Binding(
            get: { keyCode },
            set: { newValue in
                guard !isRecording else { return }
                apply(newValue)
            }
        )
    }

    /// Accepts and commits `newKeyCode`, or refuses it with a message and
    /// changes nothing.
    ///
    /// This is the only place either key code is written — the Picker and the
    /// recorder both route through it, and nothing outside this control writes
    /// `hotKeyCode` or `commandHotKeyCode`. That is why Story 6.1 could drop
    /// the old `.onChange(of: appState.hotKeyCode)` listener sync (MINOR 1):
    /// every write already ends in the call site's own `onCommit`, and re-adding
    /// the observer would only push the same configuration a second time.
    private func apply(_ newKeyCode: Int) {
        guard newKeyCode != reservedKeyCode else {
            rejectionMessage = "\(KeyCodeReference.displayName(for: newKeyCode)) is already assigned to \(reservedKeyOwner). Pick a different key."
            return
        }
        rejectionMessage = nil
        guard newKeyCode != keyCode else { return }
        keyCode = newKeyCode
        onCommit()
    }

    private func beginRecording() {
        wasListeningBeforeRecording = appState.hotKeyManager.isListening
        if wasListeningBeforeRecording {
            appState.hotKeyManager.stopListening()
        }
    }

    private func finishRecording() {
        if wasListeningBeforeRecording {
            restartHotKeyListener()
        }
        wasListeningBeforeRecording = false
    }

    private func recordKey(_ recordedKeyCode: Int) {
        apply(recordedKeyCode)
        finishRecording()
    }

    private func restartHotKeyListener() {
        appState.hotKeyManager.startListening(
            keyCode: appState.hotKeyCode,
            mode: appState.activationMode,
            doubleTapThreshold: appState.doubleTapThreshold,
            safetyTimeout: Double(appState.maxRecordingDuration) + 5.0
        )
    }
}

private struct HotKeyRecorderButton: View {
    @Binding var isRecording: Bool

    let onStart: () -> Void
    let onCancel: () -> Void
    let onKeyRecorded: (Int) -> Void

    var body: some View {
        ZStack {
            Button {
                if isRecording {
                    isRecording = false
                    onCancel()
                } else {
                    onStart()
                    isRecording = true
                }
            } label: {
                Label(isRecording ? "Cancel" : "Record", systemImage: isRecording ? "xmark.circle" : "record.circle")
            }
            .controlSize(.small)

            if isRecording {
                HotKeyCaptureView(
                    onCapture: { keyCode in
                        isRecording = false
                        onKeyRecorded(keyCode)
                    },
                    onCancel: {
                        isRecording = false
                        onCancel()
                    }
                )
                .frame(width: 1, height: 1)
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
    }
}

private struct HotKeyCaptureView: NSViewRepresentable {
    let onCapture: (Int) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> HotKeyCaptureNSView {
        let view = HotKeyCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: HotKeyCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        nsView.focus()
    }

    static func dismantleNSView(_ nsView: HotKeyCaptureNSView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

private final class HotKeyCaptureNSView: NSView {
    var onCapture: ((Int) -> Void)?
    var onCancel: (() -> Void)?

    private var localMonitor: Any?
    private var windowResignObserver: NSObjectProtocol?
    private var didCapture = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installMonitor()
        installWindowObserver()
        focus()
    }

    override func keyDown(with event: NSEvent) {
        _ = capture(event)
    }

    override func flagsChanged(with event: NSEvent) {
        _ = capture(event)
    }

    func focus() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    func stopMonitoring() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        if let windowResignObserver {
            NotificationCenter.default.removeObserver(windowResignObserver)
            self.windowResignObserver = nil
        }
    }

    private func installMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            return self.capture(event) ? nil : event
        }
    }

    private func installWindowObserver() {
        guard windowResignObserver == nil, let window else { return }
        windowResignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.cancelCapture()
        }
    }

    private func capture(_ event: NSEvent) -> Bool {
        guard !didCapture else { return false }

        if shouldCancel(event) {
            cancelCapture()
            return true
        }

        guard shouldCapture(event) else { return false }

        didCapture = true
        stopMonitoring()

        let keyCode = Int(event.keyCode)
        DispatchQueue.main.async { [weak self] in
            self?.onCapture?(keyCode)
        }
        return true
    }

    private func cancelCapture() {
        guard !didCapture else { return }
        didCapture = true
        stopMonitoring()
        DispatchQueue.main.async { [weak self] in
            self?.onCancel?()
        }
    }

    private func shouldCapture(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            return !event.isARepeat
        case .flagsChanged:
            let keyCode = Int(event.keyCode)
            guard KeyCodeReference.isModifierKeyCode(keyCode),
                  let modifierFlag = modifierFlag(for: keyCode)
            else {
                return false
            }
            return event.modifierFlags.contains(modifierFlag)
        default:
            return false
        }
    }

    private func shouldCancel(_ event: NSEvent) -> Bool {
        event.type == .keyDown && Int(event.keyCode) == KeyCodeReference.escapeKeyCode
    }

    private func modifierFlag(for keyCode: Int) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55:
            return .command
        case 56, 60:
            return .shift
        case 58, 61:
            return .option
        case 59, 62:
            return .control
        case 63:
            return .function
        default:
            return nil
        }
    }

    deinit {
        stopMonitoring()
    }
}
