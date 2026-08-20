// SettingsView.swift
// VocaMac
//
// Settings window for VocaMac configuration.
// Organized into tabs: General, Models, Stats, Audio, Cleanup, Debug, About.

import SwiftUI

extension Notification.Name {
    static let showOnboarding = Notification.Name("com.vocamac.showOnboarding")
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            ModelSettingsTab()
                .tabItem {
                    Label("Models", systemImage: "brain")
                }

            StatsSettingsTab()
                .tabItem {
                    Label("Stats", systemImage: "chart.xyaxis.line")
                }

            AudioSettingsTab()
                .tabItem {
                    Label("Audio", systemImage: "waveform")
                }

            PostProcessSettingsTab()
                .tabItem {
                    Label("Cleanup", systemImage: "wand.and.sparkles")
                }

            ProfilesSettingsTab()
                .tabItem {
                    Label("Profiles", systemImage: "person.crop.rectangle.stack")
                }

            VocabularySettingsTab()
                .tabItem {
                    Label("Vocabulary", systemImage: "character.book.closed")
                }

            DebugTab()
                .tabItem {
                    Label("Debug", systemImage: "ladybug")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(minWidth: 560, minHeight: 520)
    }
}

// MARK: - General Settings

struct GeneralSettingsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            // Activation Mode
            Section("Activation Mode") {
                Picker("Mode", selection: $appState.activationMode) {
                    ForEach(ActivationMode.allCases) { mode in
                        VStack(alignment: .leading) {
                            Text(mode.displayName)
                        }
                        .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: appState.activationMode) { _ in
                    appState.syncHotKeyConfiguration()
                }

                Text(appState.activationMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Hotkey
            Section("Hotkey") {
                HotKeySelectionControl(
                    keyCode: $appState.hotKeyCode,
                    pickerLabel: "Activation Key",
                    footerText: "Choose a preset or record a key. TypeFlow reserves this key while running.",
                    reservedKeyCode: appState.commandModeEnabled ? appState.commandHotKeyCode : nil,
                    reservedKeyOwner: "Command Mode",
                    onCommit: { appState.syncHotKeyConfiguration() }
                )

                if appState.activationMode == .doubleTapToggle {
                    HStack {
                        Text("Double-tap speed")
                        Slider(
                            value: $appState.doubleTapThreshold,
                            in: 0.2...0.8,
                            step: 0.05,
                            onEditingChanged: { isEditing in
                                if !isEditing {
                                    appState.syncHotKeyConfiguration()
                                }
                            }
                        )
                        Text("\(String(format: "%.2f", appState.doubleTapThreshold))s")
                            .monospacedDigit()
                            .frame(width: 40)
                    }

                    Text("Shorter = faster double-tap required. Longer = more forgiving.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Command Mode — the second hotkey binding (Story 6.1)
            Section("Command Mode") {
                Toggle("Enable Command Mode", isOn: $appState.commandModeEnabled)
                    .onChange(of: appState.commandModeEnabled) { _ in
                        appState.syncCommandHotKeyConfiguration()
                    }

                Text("Select text, hold the Command Mode key, and speak an instruction — the selection is rewritten in place. If anything fails, nothing is changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.commandModeEnabled {
                    // The toggle is on and the binding is not usable — the key
                    // collides with dictation's, which can only be reached by a
                    // migrated or hand-edited preference now that both pickers
                    // refuse it. Said here rather than left to a log, because
                    // the toggle reading ON while the feature is inert is
                    // exactly what MAJOR 5 is about.
                    if !appState.isCommandModeUsable {
                        Label(
                            "Command Mode is off: this key is the same as the dictation hotkey. Pick a different key to turn it back on.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }

                    HotKeySelectionControl(
                        keyCode: $appState.commandHotKeyCode,
                        pickerLabel: "Command Key",
                        footerText: "Must be a different key from the dictation hotkey. TypeFlow reserves it while Command Mode is on — other apps will not see this key.",
                        reservedKeyCode: appState.hotKeyCode,
                        reservedKeyOwner: "dictation",
                        onCommit: { appState.syncCommandHotKeyConfiguration() }
                    )

                    Picker("Command Mode Activation", selection: $appState.commandActivationMode) {
                        ForEach(ActivationMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .onChange(of: appState.commandActivationMode) { _ in
                        appState.syncCommandHotKeyConfiguration()
                    }
                }
            }

            // Language
            Section("Transcription Language") {
                // Rows come from `DictationLanguage`, the same list the
                // menu-bar quick toggle checks itself against (MAJOR 2) —
                // hand-written rows here were what let the two drift apart.
                Picker("Language", selection: $appState.selectedLanguage) {
                    Text(DictationLanguage.auto.name).tag(DictationLanguage.auto.code)
                    Divider()
                    Group {
                        ForEach(DictationLanguage.primary) { Text($0.name).tag($0.code) }
                        ForEach(DictationLanguage.secondary) { Text($0.name).tag($0.code) }
                    }
                    Divider()
                    Group {
                        ForEach(DictationLanguage.additional) { Text($0.name).tag($0.code) }
                    }
                }

                Text("Auto-detect works well for most cases. Set a specific language for better accuracy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // MAJOR 2: the menu bar's segmented control only has segments
                // for Hebrew, English, and Auto. Say so where the choice is
                // actually made, so a Spanish selection does not look broken
                // the next time the menu is opened.
                if !DictationLanguage.canQuickToggle(appState.selectedLanguage) {
                    Text("The menu bar's quick toggle covers Hebrew, English, and Auto-detect. Other languages are shown there as a label and can only be changed here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Translation
            Section("Translation") {
                Toggle("Enable translation", isOn: $appState.translationEnabled)

                Text(appState.translationEnabled
                    ? "Speech will be translated to the selected language (or English if Auto-detect)."
                    : "Speech will be transcribed as-is in the spoken language. The language setting is used as a recognition hint only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Custom Vocabulary
            Section("Custom Vocabulary") {
                TextEditor(text: $appState.customVocabulary)
                    .font(.body)
                    .frame(minHeight: 90)
                    .overlay(alignment: .topLeading) {
                        if appState.customVocabulary.isEmpty {
                            Text("kubectl, PostgreSQL, nginx, Grafana")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }

                let count = WhisperService.vocabularyTerms(from: appState.customVocabulary).count
                Text(count == 0
                    ? "Add names, jargon, or proper nouns (one per line, or comma-separated) that get mis-transcribed. TypeFlow hints these to the model so it spells them right."
                    : "\(count) term\(count == 1 ? "" : "s"). Keep the list short, since the model can only use the first 50 to 100 words as a hint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // MAJOR 3: the old wording here sold the Auto-detect nudge as
                // a feature. It was the bug — a Hebrew-leaning glossary
                // prefilled ahead of language detection is the one decoding
                // combination Epic 8 never tested, and it skewed the very
                // detection it preceded. The glossary is now withheld in Auto
                // as well as in English, so say where it applies.
                Text("Enter terms in the language you dictate, and set a matching Transcription Language above. The glossary is only sent when a specific language other than English is selected — Auto-detect and English skip it, so it cannot skew language detection or steer an English recording toward Hebrew spellings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.setLaunchAtLogin($0) }
                ))

                Toggle("Preserve clipboard after text injection", isOn: $appState.preserveClipboard)

                Toggle("Show mic indicator near cursor while recording", isOn: $appState.showCursorIndicator)

                Text("When enabled, your clipboard contents are restored after injecting text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    let name: String
    let icon: String
    let status: PermissionStatus
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .frame(width: 16)
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(name)
            Spacer()
            switch status {
            case .granted:
                Text("Granted")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .notDetermined:
                Button("Grant") { action() }
                    .controlSize(.small)
            case .denied:
                Button("Open Settings") { action() }
                    .controlSize(.small)
            }
        }
    }

    private var statusIcon: String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .notDetermined: return "questionmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .granted: return .green
        case .notDetermined: return .orange
        case .denied: return .red
        }
    }
}

// MARK: - Model Settings

struct ModelSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var processMonitor = ProcessMonitor()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // System info
                if let capabilities = appState.systemCapabilities {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("System Information", systemImage: "cpu")
                                .font(.headline)
                                .padding(.bottom, 4)

                            HStack(spacing: 24) {
                                SystemInfoPill(icon: "cpu", label: "CPU", value: capabilities.processorName)
                                SystemInfoPill(icon: "memorychip", label: "RAM", value: "\(capabilities.physicalMemoryGB) GB")
                                SystemInfoPill(icon: "bolt.fill", label: "Metal", value: capabilities.supportsMetalAcceleration ? "Yes" : "No")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                        }
                        .padding(4)
                    }
                }

                // Resource usage
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Resource Usage", systemImage: "gauge.with.dots.needle.bottom.50percent")
                            .font(.headline)
                            .padding(.bottom, 4)

                        HStack(spacing: 24) {
                            SystemInfoPill(
                                icon: "cpu",
                                label: "CPU",
                                value: String(format: "%.1f%%", processMonitor.cpuUsage)
                            )
                            SystemInfoPill(
                                icon: "memorychip",
                                label: "Memory",
                                value: processMonitor.memoryMB >= 1024
                                    ? String(format: "%.1f GB", processMonitor.memoryMB / 1024)
                                    : String(format: "%.0f MB", processMonitor.memoryMB)
                            )
                            SystemInfoPill(
                                icon: "chart.line.uptrend.xyaxis",
                                label: "Peak",
                                value: processMonitor.memoryPeakMB >= 1024
                                    ? String(format: "%.1f GB", processMonitor.memoryPeakMB / 1024)
                                    : String(format: "%.0f MB", processMonitor.memoryPeakMB)
                            )
                            SystemInfoPill(
                                icon: "arrow.triangle.branch",
                                label: "Threads",
                                value: "\(processMonitor.threadCount)"
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(4)
                }

                // Currently active model
                if let current = appState.currentModel {
                    GroupBox {
                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .font(.title3)
                            VStack(alignment: .leading) {
                                Text("Active Model: \(current.size.displayName)")
                                    .font(.callout)
                                    .fontWeight(.semibold)
                                Text("\(current.size.qualityDescription) quality • \(current.size.fileSizeDescription)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(4)
                    }
                }

                if appState.appStatus == .error, let errorMessage = appState.errorMessage {
                    GroupBox {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button {
                                appState.errorMessage = nil
                                appState.appStatus = .idle
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Dismiss")
                        }
                        .padding(4)
                    }
                }

                // Model list
                GroupBox {
                    VStack(alignment: .leading, spacing: 0) {
                        Label("Available Models", systemImage: "list.bullet")
                            .font(.headline)
                            .padding(.bottom, 8)
                            .padding(.horizontal, 4)

                        ForEach(appState.availableModels) { model in
                            ModelRow(model: model, appState: appState)

                            if model.id != appState.availableModels.last?.id {
                                Divider()
                                    .padding(.horizontal, 4)
                            }
                        }
                    }
                    .padding(4)
                }

                // Info text
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Models are downloaded from HuggingFace and cached locally. Larger models produce better results but are slower and use more memory.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let recommended = appState.deviceRecommendedModel,
                   let recommendedSize = appState.modelManager.modelSize(from: recommended) {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recommended for your device: **\(recommendedSize.displayName)**")
                                .font(.callout)
                            Text("Based on WhisperKit's tuned variants for your chip — not your RAM.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                HStack {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(.secondary)
                    Text("Model storage: \(appState.modelManager.diskUsageDescription())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
    }
}

struct SystemInfoPill: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

struct ModelRow: View {
    let model: WhisperModelInfo
    @ObservedObject var appState: AppState
    @State private var showForceDownloadAlert = false

    var body: some View {
        HStack {
            // Status icon
            Image(systemName: model.statusIconName)
                .foregroundStyle(model.isActive ? .green : .secondary)
                .frame(width: 20)

            // Model info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.size.displayName)
                        .font(.callout)
                        .fontWeight(model.isActive ? .semibold : .regular)

                    if model.size.isSideloadOnly {
                        if !model.isDownloaded {
                            Text("Not Installed")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.2))
                                .foregroundStyle(.secondary)
                                .cornerRadius(4)
                        }
                    } else {
                        if model.isSupported,
                           let recommended = appState.deviceRecommendedModel {
                            if appState.modelManager.modelSize(from: recommended) == model.size {
                                Text("Recommended")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.blue.opacity(0.2))
                                    .foregroundStyle(.blue)
                                    .cornerRadius(4)
                            }
                        }

                        if !model.isSupported {
                            Text("Experimental")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.orange.opacity(0.2))
                                .foregroundStyle(.orange)
                                .cornerRadius(4)
                                .help("WhisperKit hasn't verified this model on your chip family. It may fail to load, or it may run slower than tuned models.")
                        }
                    }
                }

                HStack(spacing: 4) {
                    Text(model.size.fileSizeDescription)
                    Text("•")
                    Text(model.size.qualityDescription)
                    Text("•")
                    Text("~\(String(format: "%.0f", model.size.ramRequiredGB)) GB RAM")
                    Text("•")
                    Text("Speed: \(String(repeating: "⚡", count: max(1, 6 - model.size.relativeSpeed)))")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if model.size.isSideloadOnly && !model.isDownloaded {
                    Text("Place model files at: \(appState.modelManager.expectedModelDirectory(for: model.size).path)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            // Download progress or loading indicator
            if let progress = model.downloadProgress {
                VStack(spacing: 2) {
                    ProgressView(value: progress)
                        .frame(width: 60)
                        .controlSize(.small)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if model.isLoading {
                VStack(spacing: 2) {
                    ProgressView()
                        .frame(width: 60)
                        .controlSize(.small)
                    Text(model.loadingStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Action button
            if model.size.isSideloadOnly && !model.isDownloaded {
                // Side-loaded model with no files on disk: no download to offer.
                // Checked ahead of isActive so a row never shows both "Active"
                // and "Not Installed" at once (e.g. files removed while selected).
                EmptyView()
            } else if model.isActive {
                Label("Active", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if !model.isSupported {
                if model.isLoading || model.downloadProgress != nil {
                    EmptyView()
                } else if model.isDownloaded {
                    Button("Load Anyway") {
                        showForceDownloadAlert = true
                    }
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                } else {
                    Button("Try Anyway") {
                        showForceDownloadAlert = true
                    }
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                }
            } else if model.isLoading || model.downloadProgress != nil {
                // Show nothing - progress indicator handles the feedback
                EmptyView()
            } else if model.isDownloaded {
                Button("Load") {
                    Task { @MainActor in await appState.loadModel(model.size) }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            } else {
                Button("Download & Load") {
                    Task { @MainActor in
                        await appState.downloadModel(model.size)
                        if appState.availableModels.first(where: { $0.size == model.size })?.isDownloaded == true {
                            await appState.loadModel(model.size)
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .alert("Use Experimental Model?", isPresented: $showForceDownloadAlert) {
            Button("Cancel", role: .cancel) {}
            Button(model.isDownloaded ? "Load Anyway" : "Download & Load", role: .destructive) {
                Task { @MainActor in
                    if !model.isDownloaded {
                        await appState.downloadModel(model.size)
                    }
                    if model.isDownloaded || appState.availableModels.first(where: { $0.size == model.size })?.isDownloaded == true {
                        await appState.loadModel(model.size)
                    }
                }
            }
        } message: {
            Text("WhisperKit hasn't verified this model on your chip family. It may fail to load, or it may run slower than tuned models.")
        }
    }
}

// MARK: - Audio Settings

struct AudioSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @State private var audioDevices: [AudioDevice] = []

    var body: some View {
        Form {
            Section("Recording") {
                Picker("Max recording duration", selection: $appState.maxRecordingDuration) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                    Text("120 seconds").tag(120)
                    Text("300 seconds (5 min)").tag(300)
                }
                .onChange(of: appState.maxRecordingDuration) { _ in
                    appState.syncHotKeyConfiguration()
                }

                Text("Recording will automatically stop after this duration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Silence Detection") {
                Picker("Detection method", selection: $appState.vadDetectorKind) {
                    ForEach(VADDetectorKind.allCases, id: \.rawValue) { kind in
                        Text(kind.displayName).tag(kind.rawValue)
                    }
                }
                .onChange(of: appState.vadDetectorKind) { _ in
                    // The migration note below explains a choice made *for*
                    // the user; once they make one themselves it is spent.
                    appState.vadKeptLegacyForTunedThreshold = false
                }

                if appState.vadKeptLegacyForTunedThreshold {
                    HStack(alignment: .top) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                        Text("You had tuned the sensitivity below, so TypeFlow kept your Legacy (RMS threshold) setting and its value instead of switching you to Voice Activity Detection. Switching methods gives VAD its own separate sensitivity — your legacy value stays untouched and applies again if you switch back.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text("Sensitivity")
                    Slider(
                        value: isUsingLegacyDetector ? $appState.silenceThreshold : $appState.vadEnergyThreshold,
                        in: sensitivityRange,
                        step: isUsingLegacyDetector ? 0.001 : 0.0005
                    )
                    Text(sensitivityLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    Text(String(format: "%.4f", sensitivityValue))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }

                Text(isUsingLegacyDetector
                     ? "Sensitivity sets the legacy RMS threshold (this method only)."
                     : "Sensitivity sets the Voice Activity Detection threshold — a separate value from the legacy one, on its own narrower useful range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Auto-stop after silence")
                    Slider(
                        value: $appState.silenceDuration,
                        in: 0.5...5.0,
                        step: 0.5
                    )
                    Text("\(String(format: "%.1f", appState.silenceDuration))s")
                        .monospacedDigit()
                        .frame(width: 35)
                }

                Text("Voice Activity Detection (recommended) recognizes quiet or whispered speech that the legacy RMS threshold could cut off mid-sentence. Switch to Legacy if VAD ever misfires on your voice. In double-tap mode, recording auto-stops after the configured duration of silence; in push-to-talk mode, you control when to stop by releasing the key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sound Effects") {
                Toggle("Enable sound effects", isOn: $appState.soundEffectsEnabled)

                Text("Play subtle audio cues when recording starts and stops.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Input Device") {
                Picker("Microphone", selection: $appState.selectedAudioDeviceID) {
                    Text("System Default").tag("")
                    if selectedAudioDeviceIsUnavailable {
                        Text("\(selectedAudioDeviceDisplayName) (Unavailable)").tag(appState.selectedAudioDeviceID)
                    }
                    ForEach(audioDevices) { device in
                        Text(audioDeviceLabel(for: device)).tag(device.id)
                    }
                }
                .onChange(of: appState.selectedAudioDeviceID) { _ in
                    syncSelectedAudioDeviceName()
                }

                if audioDevices.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("No audio input devices found")
                            .foregroundStyle(.secondary)
                    }
                } else if selectedAudioDeviceIsUnavailable {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text("\(selectedAudioDeviceDisplayName) is unavailable. TypeFlow will use System Default until it reconnects.")
                            .foregroundStyle(.secondary)
                    }
                } else if let selectedAudioDevice {
                    HStack {
                        Image(systemName: "mic.circle.fill")
                            .foregroundStyle(.blue)
                        Text("TypeFlow will record from \(selectedAudioDevice.name) without changing macOS' system default input.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(systemDefaultInputDescription)
                        .foregroundStyle(.secondary)
                }

                Button("Refresh Devices") {
                    refreshAudioDevices()
                }
                .controlSize(.small)

                Text("Choose System Default to follow macOS, or pin TypeFlow to a specific microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshAudioDevices()
        }
    }

    private var selectedAudioDevice: AudioDevice? {
        guard !appState.selectedAudioDeviceID.isEmpty else { return nil }
        return audioDevices.first { $0.id == appState.selectedAudioDeviceID }
    }

    private var selectedAudioDeviceIsUnavailable: Bool {
        !appState.selectedAudioDeviceID.isEmpty && selectedAudioDevice == nil
    }

    private var selectedAudioDeviceDisplayName: String {
        appState.selectedAudioDeviceName.isEmpty ? "Selected microphone" : appState.selectedAudioDeviceName
    }

    private var systemDefaultInputDescription: String {
        if let defaultDevice = audioDevices.first(where: { $0.isDefault }) {
            return "TypeFlow will follow macOS' system default input: \(defaultDevice.name)."
        }
        return "TypeFlow will follow macOS' system default input."
    }

    private func audioDeviceLabel(for device: AudioDevice) -> String {
        device.isDefault ? "\(device.name) (System Default)" : device.name
    }

    private func refreshAudioDevices() {
        audioDevices = AudioEngine.availableInputDevices()
        syncSelectedAudioDeviceName()
    }

    private func syncSelectedAudioDeviceName() {
        guard !appState.selectedAudioDeviceID.isEmpty else {
            appState.selectedAudioDeviceName = ""
            return
        }

        if let selectedAudioDevice {
            appState.selectedAudioDeviceName = selectedAudioDevice.name
        }
    }

    private var isUsingLegacyDetector: Bool {
        appState.vadDetectorKind == VADDetectorKind.rmsThreshold.rawValue
    }

    private var sensitivityValue: Double {
        isUsingLegacyDetector ? appState.silenceThreshold : appState.vadEnergyThreshold
    }

    /// The two detectors are not on the same scale. The legacy RMS threshold
    /// is useful across 0.001–0.05; the VAD threshold's useful band is roughly
    /// 0.001–0.015, so on the legacy range its 0.006 default sat at a tenth of
    /// the travel and most of the slider read "Low".
    private var sensitivityRange: ClosedRange<Double> {
        isUsingLegacyDetector ? 0.001...0.05 : 0.001...0.015
    }

    private var sensitivityLabel: String {
        let range = sensitivityRange
        let travel = (sensitivityValue - range.lowerBound) / (range.upperBound - range.lowerBound)
        if travel < 0.34 { return "High" }
        if travel < 0.67 { return "Medium" }
        return "Low"
    }
}

// MARK: - About Tab

struct AboutTab: View {
    @EnvironmentObject var appState: AppState
    @State private var showingUpdateSheet = false
    @State private var updateInfoForSheet: UpdateInfo?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            // App icon
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            // App name and version
            Text("TypeFlow")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Your voice, your Mac, your privacy.\nOpen-source dictation powered by AI.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Version \(appVersionDisplay) (\(buildChannelLabel))")
                .font(.caption)
                .foregroundStyle(.tertiary)

            // BLOCKER 4: the "Check for Updates..." button is gone rather than
            // disabled. It polled the upstream VocaMac repo and presented
            // upstream's releases as TypeFlow updates — installing one would
            // have replaced this build with an app that has none of its
            // features. See `UpdateChecker.updatesEnabled` for the full
            // reasoning and for what to restore this button alongside.
            if UpdateChecker.updatesEnabled {
                Button {
                    Task { @MainActor in
                        await appState.updateChecker.checkForUpdates()
                        switch appState.updateChecker.updateState {
                        case .updateAvailable(let info), .updateAvailableViaHomebrew(let info, _):
                            updateInfoForSheet = info
                            showingUpdateSheet = true
                        default:
                            break
                        }
                    }
                } label: {
                    if case .checking = appState.updateChecker.updateState {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking for Updates...")
                        }
                        .font(.caption)
                    } else {
                        Label("Check for Updates...", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)

                Text(updateStatusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Automatic updates are off in this build. Rebuild from source to update.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Divider()
                .frame(width: 200)

            // Tech info
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    if let capabilities = appState.systemCapabilities {
                        InfoRow2(label: "Device", value: capabilities.processorName)
                        InfoRow2(label: "Architecture", value: capabilities.isAppleSilicon ? "Apple Silicon (ARM64)" : "Intel (x86_64)")
                        InfoRow2(label: "Neural Engine", value: capabilities.supportsMetalAcceleration ? "Available" : "Not Available")
                    }
                    InfoRow2(label: "Engine", value: "WhisperKit")
                    InfoRow2(label: "Model", value: appState.whisperService.loadedModelName ?? "Not loaded")
                    InfoRow2(label: "Storage", value: appState.modelManager.diskUsageDescription())
                }
                .font(.caption)
                .padding(4)
            }
            .frame(width: 300)

            Divider()
                .frame(width: 200)

            // Links
            HStack(spacing: 16) {
                Link(destination: URL(string: "https://vocamac.com")!) {
                    Label("Website", systemImage: "globe")
                }
                Link(destination: URL(string: "https://github.com/jatinkrmalik/vocamac")!) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/argmaxinc/WhisperKit")!) {
                    Label("WhisperKit", systemImage: "waveform")
                }
            }
            .font(.caption)

            Divider()
                .frame(width: 200)

            Button(action: {
                NotificationCenter.default.post(name: .showOnboarding, object: nil)
            }) {
                Label("Show Setup Wizard…", systemImage: "wand.and.stars")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .help("Re-run the first-launch setup wizard")

            Spacer()

            HStack(spacing: 0) {
                Text("Made with ❤️ by ")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Link("Jatin Kumar Malik", destination: URL(string: "https://x.com/intent/user?screen_name=jatinkrmalik")!)
                    .font(.caption2)
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .sheet(isPresented: $showingUpdateSheet) {
            if let info = updateInfoForSheet {
                UpdateDetailView(info: info)
                    .environmentObject(appState)
            }
        }
    }

    private var appVersionDisplay: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
    }

    private var buildChannelLabel: String {
        appVersionDisplay.contains("nightly") ? "Nightly" : "Beta"
    }

    private var updateStatusText: String {
        switch appState.updateChecker.updateState {
        case .upToDate:
            return "You are on the latest version."
        case .updateAvailable(let info):
            return "Update available: \(info.tagName)"
        case .updateAvailableViaHomebrew(_, let install):
            return "Update available via Homebrew. Run: \(install.upgradeCommand)"
        case .error(let message):
            return message
        case .downloading(let progress, _, _, _):
            return "Downloading update... \(Int(progress * 100))%"
        case .verifying:
            return "Verifying download integrity..."
        case .readyToInstall:
            return "Update downloaded. Open the DMG to install."
        case .checking:
            return "Checking for updates..."
        case .idle:
            return ""
        }
    }
}

// MARK: - Debug Tab

struct DebugTab: View {
    @EnvironmentObject var appState: AppState
    @State private var logEntryCount: Int = VocaLogger.logEntryCount

    // The "denied since" clocks used to live here as @State (MINOR 3). That
    // made the 30-second timer restart every time this tab appeared, so
    // switching tabs — the natural thing to do while waiting on System
    // Settings — reset it and the hint that says "denied for 30+ seconds"
    // could take arbitrarily long to show, or never show at all. They now live
    // on `PermissionManager`, set on the transition *into* `.denied`, where
    // they outlive any view's lifetime. Permission polling still re-renders
    // this tab every few seconds while anything is denied (see
    // `PermissionManager.startPermissionPolling`), so no extra timer is needed
    // just to notice the elapsed time.

    var body: some View {
        Form {
            // Permissions
            Section("Permissions") {
                PermissionRow(
                    name: "Microphone",
                    icon: "mic.fill",
                    status: appState.micPermission,
                    action: { appState.requestMicrophonePermission() }
                )

                PermissionRow(
                    name: "Accessibility",
                    icon: "accessibility",
                    status: appState.accessibilityPermission,
                    action: { appState.requestAccessibilityPermission() }
                )

                PermissionRow(
                    name: "Input Monitoring",
                    icon: "keyboard",
                    status: appState.inputMonitoringPermission,
                    action: { appState.requestInputMonitoringPermission() }
                )

                if appState.micPermission == .denied || appState.accessibilityPermission == .denied || appState.inputMonitoringPermission == .denied {
                    Text("Denied permissions must be enabled manually in System Settings → Privacy & Security.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let hint = longDeniedHint {
                    Label(hint, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button(action: { appState.checkPermissions() }) {
                        Label("Re-check Permissions", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(action: resetPermissions) {
                        Label("Reset All Permissions", systemImage: "arrow.counterclockwise")
                            .foregroundStyle(.red)
                    }
                    .controlSize(.small)
                    .help("Reset all TCC permissions for TypeFlow. The app will quit and you'll need to re-grant permissions on next launch.")
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.caption)
                    Text("**Upgrading?** Permissions now persist across updates since TypeFlow is signed with a Developer ID. If permissions ever appear stuck, use the Reset button above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Debug Logs
            Section("Debug Logs") {
                LabeledContent("Log File") {
                    Text(VocaLogger.logFileURL().lastPathComponent)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Log Entries") {
                    Text("\(logEntryCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button(action: copyDebugLogs) {
                        Label("Copy to Clipboard", systemImage: "doc.on.clipboard")
                    }
                    .help("Copy last 500 lines of logs to clipboard")

                    Spacer()

                    Button(action: exportDebugLogs) {
                        Label("Export to File…", systemImage: "square.and.arrow.up")
                    }
                    .help("Save debug logs to file and reveal in Finder")

                    Spacer()

                    Button(action: {
                        VocaLogger.clearLogs()
                        logEntryCount = VocaLogger.logEntryCount
                    }) {
                        Label("Clear", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                    .help("Clear all log entries")
                }

                Text("Copy or export recent application logs for troubleshooting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Application
            Section("Application") {
                HStack {
                    Button(action: restartApp) {
                        Label("Restart TypeFlow", systemImage: "arrow.trianglehead.clockwise")
                    }
                    .help("Quit and relaunch TypeFlow")

                    Spacer()

                    Button(role: .destructive, action: {
                        NSApplication.shared.terminate(nil)
                    }) {
                        Label("Quit TypeFlow", systemImage: "power")
                    }
                    .help("Quit TypeFlow")
                }

                Text("Restart can help resolve issues with permissions or audio devices.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// One concise hint once *any* permission has read `.denied` for 30+
    /// seconds of polling — long enough that "wait a moment" is no longer good
    /// advice and the remove-and-re-add fix is what actually gets someone
    /// unstuck.
    ///
    /// The advice leads with removing the stale **VocaMac** row (MAJOR 4).
    /// Accessibility and Input Monitoring grants are keyed to the bundle's
    /// path, so renaming the bundle VocaMac.app → TypeFlow.app invalidated
    /// every existing grant and left a row in System Settings pointing at an
    /// app that is no longer there. That row is not harmless: it keeps its
    /// toggle on, so the list *looks* like permission is granted while the app
    /// asking for it is a different bundle.
    ///
    /// `tccutil reset` stays in the hint but is now the second suggestion, not
    /// the first: it reliably clears Microphone, and is unreliable for
    /// Accessibility specifically — it often reports success while the row and
    /// its grant survive, which sends someone off believing they tried the fix.
    private var longDeniedHint: String? {
        guard let deniedFor = appState.longestPermissionDenialDuration, deniedFor >= 30 else { return nil }
        return "Still denied after 30+ seconds? In System Settings → Privacy & Security, remove any \"VocaMac\" row from both Accessibility and Input Monitoring (left over from before the rename — its toggle stays on but grants nothing), then remove and re-add TypeFlow and toggle it on. Failing that, run tccutil reset All com.vocamac.app in Terminal (same as the Reset button below) — note it is unreliable for Accessibility specifically."
    }

    // MARK: - Actions

    private func resetPermissions() {
        let alert = NSAlert()
        alert.messageText = "Reset All Permissions?"
        alert.informativeText = "This will clear all permission grants (Microphone, Accessibility, Input Monitoring) for TypeFlow. The app will quit and you'll need to re-grant permissions on next launch.\n\nThis is useful when permissions appear stuck or aren't being recognized after an update."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset & Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Run tccutil to reset all TCC permissions for this app
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", "All", "com.vocamac.app"]
            try? task.run()
            task.waitUntilExit()

            VocaLogger.info(.general, "TCC permissions reset via tccutil")

            // Quit the app so permissions take effect on next launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func restartApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", bundlePath, "--args", "--restarted"]
        try? task.run()

        // Give the new instance a moment to start
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApplication.shared.terminate(nil)
        }
    }

    // MARK: - Debug Log Actions

    private func copyDebugLogs() {
        let logs = VocaLogger.exportLogs(lastLines: 500)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logs, forType: .string)
    }

    private func exportDebugLogs() {
        let logs = VocaLogger.exportLogs(lastLines: 1000)

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "TypeFlow-Debug-\(ISO8601DateFormatter().string(from: Date()).prefix(19)).log"
        savePanel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        savePanel.begin { response in
            if response == .OK, let fileURL = savePanel.url {
                do {
                    try logs.write(to: fileURL, atomically: true, encoding: .utf8)
                    NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: fileURL.deletingLastPathComponent().path)
                } catch {
                    VocaLogger.error(.general, "Failed to export logs: \(error)")
                }
            }
        }
    }
}

struct InfoRow2: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .trailing)
            Text(value)
                .fontWeight(.medium)
            Spacer()
        }
    }
}
