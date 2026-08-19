// AppState.swift
// VocaMac
//
// Central observable state for the entire application.
// All UI and services react to changes in AppState.

import Foundation
import SwiftUI
import Combine
import ServiceManagement

// MARK: - Enums

/// Application status representing the current state of the transcription pipeline
enum AppStatus: String {
    case idle          // Ready for input, not recording
    case recording     // Actively capturing microphone audio
    case processing    // Transcribing audio via WhisperKit
    case error         // Something went wrong
}

/// How recording is activated by the user
enum ActivationMode: String, CaseIterable, Codable, Identifiable {
    case pushToTalk       // Hold key to record, release to stop
    case doubleTapToggle  // Double-tap key to start/stop

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pushToTalk:      return "Push to Talk (Hold)"
        case .doubleTapToggle: return "Double-Tap Toggle"
        }
    }

    var description: String {
        switch self {
        case .pushToTalk:
            return "Hold the hotkey to record. Release to stop and transcribe."
        case .doubleTapToggle:
            return "Double-tap the hotkey to start recording. Double-tap again to stop."
        }
    }
}

/// Permission status for system permissions
enum PermissionStatus: String {
    case notDetermined
    case granted
    case denied
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {

    // MARK: - Published State

    /// Current application status
    @Published var appStatus: AppStatus = .idle

    /// Whether the app is actively recording audio
    @Published var isRecording: Bool = false

    /// Current audio input level (0.0 - 1.0) for visual feedback
    @Published var audioLevel: Float = 0.0

    /// The most recent transcription result
    @Published var lastTranscription: VocaTranscription?

    /// Error message to display, if any
    @Published var errorMessage: String?

    /// Currently loaded/active whisper model info
    @Published var currentModel: WhisperModelInfo?

    /// All available models and their statuses
    @Published var availableModels: [WhisperModelInfo] = []

    // Permissions are managed by PermissionManager.
    // These computed properties maintain backward compatibility for views.
    var micPermission: PermissionStatus { permissionManager.micPermission }
    var accessibilityPermission: PermissionStatus { permissionManager.accessibilityPermission }
    var inputMonitoringPermission: PermissionStatus { permissionManager.inputMonitoringPermission }

    /// Detected system capabilities
    @Published var systemCapabilities: SystemCapabilities?

    /// WhisperKit's recommended model for this device
    @Published var deviceRecommendedModel: String?

    // MARK: - User Settings (persisted via UserDefaults)

    @AppStorage("vocamac.hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @AppStorage("vocamac.activationMode") var activationMode: ActivationMode = .pushToTalk
    @AppStorage("vocamac.hotKeyCode") var hotKeyCode: Int = 61  // Right Option
    @AppStorage("vocamac.doubleTapThreshold") var doubleTapThreshold: Double = 0.4
    @AppStorage("vocamac.silenceThreshold") var silenceThreshold: Double = 0.01
    @AppStorage("vocamac.silenceDuration") var silenceDuration: Double = 1.2
    @AppStorage("vocamac.maxRecordingDuration") var maxRecordingDuration: Int = 180
    @AppStorage("vocamac.selectedAudioDeviceID") var selectedAudioDeviceID: String = ""
    @AppStorage("vocamac.selectedAudioDeviceName") var selectedAudioDeviceName: String = ""
    @AppStorage("vocamac.selectedModelSize") var selectedModelSize: String = ModelSize.largeV3LatestCompact.rawValue
    @AppStorage("vocamac.selectedLanguage") var selectedLanguage: String = "he"
    @AppStorage("vocamac.launchAtLogin") var launchAtLogin: Bool = false
    @AppStorage("vocamac.preserveClipboard") var preserveClipboard: Bool = true
    @AppStorage("vocamac.soundEffectsEnabled") var soundEffectsEnabled: Bool = false
    @AppStorage("vocamac.showCursorIndicator") var showCursorIndicator: Bool = true
    @AppStorage("vocamac.translationEnabled") var translationEnabled: Bool = false
    @AppStorage("vocamac.customVocabulary") var customVocabulary: String = "WhisperKit, CoreML, Apple Silicon, macOS, Swift, SwiftUI, Xcode, Homebrew, GitHub, API, JSON, TypeScript, JavaScript, Python, Docker, Kubernetes, React, Node.js, terminal, VS Code, OpenAI, Claude Code, pull request, branch, commit"
    @AppStorage("vocamac.logLevel") var logLevel: String = "info"

    // Post-processing (AD-9). The stage reads the same keys through
    // PostProcessSettings, so no service has to depend on AppState.
    @AppStorage(PostProcessSettings.Key.enabled) var postProcessEnabled: Bool = PostProcessSettings.Default.enabled
    @AppStorage(PostProcessSettings.Key.baseURL) var postProcessBaseURL: String = PostProcessSettings.Default.baseURL
    @AppStorage(PostProcessSettings.Key.model) var postProcessModel: String = PostProcessSettings.Default.model
    @AppStorage(PostProcessSettings.Key.timeout) var postProcessTimeout: Double = PostProcessSettings.Default.timeout
    @AppStorage(PostProcessSettings.Key.temperature) var postProcessTemperature: Double = PostProcessSettings.Default.temperature
    @AppStorage(PostProcessSettings.Key.systemPrompt) var postProcessSystemPrompt: String = PostProcessSettings.Default.systemPrompt

    private var hotKeySafetyTimeout: Double {
        Double(maxRecordingDuration) + 5.0
    }

    // MARK: - Services

    let audioEngine: AudioRecording
    let whisperService: SpeechTranscribing
    let textInjector: TextInjecting
    let hotKeyManager: HotKeyMonitoring
    let modelManager: ModelManaging
    let soundManager: SoundPlaying
    let cursorOverlay: CursorOverlayManaging
    let statsManager: StatsManaging
    let historyStore: HistoryRecording
    let transcriptPipeline: TranscriptPipelining
    let axContextReader: ContextReading
    let updateChecker = UpdateChecker()
    let permissionManager: any PermissionManaging

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false

    /// Bumped every time a new recording genuinely begins (`startRecording`)
    /// or the pipeline is forcibly abandoned (`forceRecovery`). A dictation
    /// in flight through `transcriptPipeline.run` can suspend for as long as
    /// the post-process timeout; if the user starts a new recording while
    /// the old one is still suspended there, the old call must not be
    /// allowed to inject, hide the overlay, touch `appStatus`, or write
    /// history once it finally resumes (MAJOR 2).
    private var dictationGeneration = 0

    /// The last application other than VocaMac to become frontmost.
    ///
    /// Re-paste is reached through VocaMac's own menu-bar panel or History
    /// window, which means *we* are frontmost by the time the action runs —
    /// injecting right then types into our own search field rather than the
    /// user's document (BLOCKER 2, Story 3.3 AC). This is the application to
    /// hand focus back to first.
    private(set) var lastNonSelfFrontmostApp: NSRunningApplication?

    /// What `axContextReader.capture(...)` returned when the *current* (or
    /// most recently finished) recording started — captured once, at that
    /// moment, per AD-5. `stopRecordingAndTranscribe` reads this to build the
    /// `TranscriptContext` for the pipeline; it is not re-captured at stop
    /// time even if the user switched applications while dictating (Story 4.1
    /// AC). Cleared once consumed so Cursor Context (Story 4.4) is never held
    /// any longer than the one request that needs it.
    private var capturedContext: CapturedContext?

    /// AudioEngine serializes its own lifecycle internally; this wrapper makes
    /// the intentional background handoff explicit for Dispatch's @Sendable API.
    private struct AudioEngineWorker: @unchecked Sendable {
        let audioEngine: AudioRecording

        func startRecording(
            silenceThreshold: Float,
            silenceDuration: Double,
            maxDuration: TimeInterval,
            preferredInputDeviceID: String?
        ) -> Bool {
            audioEngine.startRecording(
                silenceThreshold: silenceThreshold,
                silenceDuration: silenceDuration,
                maxDuration: maxDuration,
                preferredInputDeviceID: preferredInputDeviceID
            )
        }

        func stopRecording() -> [Float] {
            audioEngine.stopRecording()
        }
    }

    /// Process-level flag that prevents performStartup from running more than
    /// once even when SwiftUI instantiates multiple AppState objects (which it
    /// does during MenuBarExtra scene setup). Instance-level `hasStarted` guards
    /// re-entry on the same object; this static flag guards across all instances.
    ///
    /// Internal (not private) so test teardown can reset it between test cases.
    static var hasStartedGlobally = false
    static var hasPerformedStartupGlobally = false

    /// Whether to skip system integration calls (SMAppService, etc.) during init.
    /// Set to `true` in tests to avoid side effects.
    let skipSystemIntegration: Bool

    // MARK: - Initialization

    init(
        audioEngine: AudioRecording = AudioEngine(),
        whisperService: SpeechTranscribing = WhisperService(),
        textInjector: TextInjecting = TextInjector(),
        hotKeyManager: HotKeyMonitoring = HotKeyManager(),
        modelManager: ModelManaging = ModelManager(),
        soundManager: SoundPlaying = SoundManager(),
        cursorOverlay: CursorOverlayManaging,
        statsManager: StatsManaging,
        historyStore: HistoryRecording,
        transcriptPipeline: TranscriptPipelining? = nil,
        axContextReader: ContextReading,
        permissionManager: (any PermissionManaging)? = nil,
        skipSystemIntegration: Bool = false
    ) {
        self.audioEngine = audioEngine
        self.whisperService = whisperService
        self.textInjector = textInjector
        self.hotKeyManager = hotKeyManager
        self.modelManager = modelManager
        self.soundManager = soundManager
        self.cursorOverlay = cursorOverlay
        self.statsManager = statsManager
        self.historyStore = historyStore
        self.transcriptPipeline = transcriptPipeline ?? TranscriptPipeline.production()
        self.axContextReader = axContextReader
        self.permissionManager = permissionManager ?? PermissionManager(audioEngine: audioEngine, hotKeyManager: hotKeyManager)
        self.skipSystemIntegration = skipSystemIntegration

        VocaLogger.info(.appState, "Initializing... id=\(ObjectIdentifier(self))")
        if !skipSystemIntegration {
            syncLaunchAtLogin()
        }
        setupServices()

        // Forward updateChecker changes so SwiftUI views observing AppState
        // re-render when updateState changes (nested ObservableObject fix).
        updateChecker.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Forward statsManager changes
        statsManager.objectWillChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Forward historyStore changes so the History view re-renders
        historyStore.objectWillChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        if !skipSystemIntegration {
            observeFrontmostApplication()
        }
    }

    /// Remembers who held focus before VocaMac's own UI took it, so re-paste
    /// can give it back (BLOCKER 2). Deliberately not `@Published`: nothing
    /// renders from it, and republishing on every app switch in the system
    /// would re-render the whole menu bar.
    private func observeFrontmostApplication() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .filter { $0.processIdentifier != NSRunningApplication.current.processIdentifier }
            .sink { [weak self] app in
                self?.lastNonSelfFrontmostApp = app
            }
            .store(in: &cancellables)
    }

    /// Single production AppState instance for the process.
    ///
    /// SwiftUI can recreate the `App` value during scene setup, especially for
    /// menu bar apps. Keeping the production instance outside the `App` value's
    /// stored-property initialization prevents duplicate service graphs, event
    /// taps, audio observers, and stale SwiftUI environment objects.
    @MainActor
    private static let sharedProductionInstance = AppState(
        cursorOverlay: CursorOverlayManager(),
        statsManager: StatsManager(),
        historyStore: HistoryStore(),
        axContextReader: AXContextReader()
    )

    /// Convenience factory for creating AppState with all real services.
    /// Needed because CursorOverlayManager is @MainActor and can't be a default parameter.
    @MainActor
    static func production() -> AppState {
        VocaLogger.debug(.appState, "Using production AppState id=\(ObjectIdentifier(sharedProductionInstance))")
        return sharedProductionInstance
    }

    /// Called once from the SwiftUI lifecycle to complete initialization.
    /// Safe to call multiple times and across multiple instances — only the
    /// first call across the entire process takes effect.
    func triggerStartupIfNeeded() {
        guard !hasStarted, !AppState.hasStartedGlobally else {
            VocaLogger.debug(.appState, "triggerStartupIfNeeded called again — skipping (already started)")
            return
        }
        hasStarted = true
        AppState.hasStartedGlobally = true
        Task {
            await performStartup()
        }
    }

    // MARK: - Launch at Login

    /// Sync the persisted launchAtLogin preference with SMAppService.
    /// Called once on init to reconcile state (e.g. if the user toggled it
    /// in System Settings directly, or if the app was re-installed).
    private func syncLaunchAtLogin() {
        let currentStatus = SMAppService.mainApp.status
        let isRegistered = currentStatus == .enabled

        if launchAtLogin && !isRegistered {
            // User wants launch-at-login but it's not registered — register now
            setLaunchAtLogin(true)
        } else if !launchAtLogin && isRegistered {
            // Persisted preference says disabled but system says enabled — unregister
            setLaunchAtLogin(false)
        }
    }

    /// Register or unregister the app as a login item via SMAppService.
    /// Updates the persisted `launchAtLogin` preference to match.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                VocaLogger.info(.appState, "Registered as login item")
            } else {
                try SMAppService.mainApp.unregister()
                VocaLogger.info(.appState, "Unregistered as login item")
            }
            launchAtLogin = enabled
        } catch {
            VocaLogger.error(.appState, "Failed to \(enabled ? "register" : "unregister") login item: \(error.localizedDescription)")
            // Revert the preference to match the actual system state
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Setup

    private func setupServices() {
        // Detect system capabilities
        systemCapabilities = SystemInfo.detect()

        // Get WhisperKit's device recommendation.
        // WhisperKit's `.default` may not be in the supported list for some
        // devices. If so, fall back to the best supported model instead.
        let recommendation = modelManager.deviceRecommendation()
        VocaLogger.info(.appState, "WhisperKit recommendation — default: \(recommendation.defaultModel), supported: [\(recommendation.supported.joined(separator: ", "))], disabled: [\(recommendation.disabled.joined(separator: ", "))]")
        let defaultIsSupported = recommendation.supported.contains(recommendation.defaultModel)
        if !defaultIsSupported, let bestSupported = recommendation.supported.last {
            deviceRecommendedModel = bestSupported
        } else {
            deviceRecommendedModel = recommendation.defaultModel
        }

        rebuildAvailableModels()

        // Validate that the recommended model maps to a supported ModelSize.
        // If the recommendation points to an unsupported model, fall back to
        // the largest supported model instead.
        if let recommended = deviceRecommendedModel {
            let recommendedSize = modelManager.modelSize(from: recommended)
            let isRecommendedSupported = recommendedSize.map { size in
                availableModels.first(where: { $0.size == size })?.isSupported == true
            } ?? false

            if !isRecommendedSupported {
                // Fall back to the largest supported model. Exclude sideload-only
                // models: they're never a device recommendation, just a manual
                // install, so they shouldn't be surfaced as "recommended".
                if let bestSupported = availableModels.last(where: { $0.isSupported && !$0.size.isSideloadOnly }) {
                    deviceRecommendedModel = modelManager.whisperKitModelName(for: bestSupported.size)
                } else {
                    // No models are supported — clear the recommendation
                    deviceRecommendedModel = nil
                }
            }
        }

        // Setup audio level reporting
        audioEngine.onAudioLevel = { [weak self] level in
            Task { @MainActor in
                self?.audioLevel = level
                self?.cursorOverlay.updateAudioLevel(level)
            }
        }

        // Setup silence detection callback
        audioEngine.onSilenceDetected = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                if self.activationMode == .doubleTapToggle && self.isRecording {
                    VocaLogger.info(.appState, "Silence detected — auto-stopping recording (double-tap mode)")
                    await self.stopRecordingAndTranscribe()
                }
            }
        }

        // Setup max recording duration callback.
        // AudioEngine fires this when the recording reaches maxRecordingDuration.
        // This is the primary duration limit — the HotKeyManager safety timer
        // (maxRecordingDuration + 5s) acts as a backstop in case this callback
        // fails or the key-up event is lost entirely.
        audioEngine.onMaxDurationReached = { [weak self] in
            Task { @MainActor in
                guard let self = self, self.isRecording else { return }
                VocaLogger.info(.appState, "Max recording duration (\(self.maxRecordingDuration)s) reached — auto-stopping")
                await self.stopRecordingAndTranscribe()
            }
        }

        // Setup audio device change callback.
        // Fires when the microphone is unplugged/replugged, Bluetooth disconnects,
        // or the default audio device changes (e.g., after sleep). AudioEngine has
        // already stopped and reset itself — we just need to recover the app state.
        audioEngine.onAudioDeviceChanged = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                VocaLogger.warning(.appState, "Audio device changed — recovering from interrupted recording")
                self.isRecording = false
                self.audioLevel = 0.0
                self.cursorOverlay.hide()
                self.hotKeyManager.resetKeyState()
                self.appStatus = .idle
                self.errorMessage = nil
            }
        }

        // Setup hotkey callbacks
        hotKeyManager.onRecordingStart = { [weak self] in
            Task { @MainActor in
                await self?.startRecording()
            }
        }

        hotKeyManager.onRecordingStop = { [weak self] in
            Task { @MainActor in
                await self?.stopRecordingAndTranscribe()
            }
        }

        // Wire permission manager: start hotkey listener when permissions granted
        permissionManager.onAllPermissionsGranted = { [weak self] in
            guard let self = self else { return }
            self.hotKeyManager.startListening(
                keyCode: self.hotKeyCode,
                mode: self.activationMode,
                doubleTapThreshold: self.doubleTapThreshold,
                safetyTimeout: self.hotKeySafetyTimeout
            )
            VocaLogger.info(.appState, "Hotkey listener started after permission grant")
        }

        // Forward PermissionManager state changes to trigger SwiftUI updates
        permissionManager.objectWillChangePublisher
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Check permissions
        checkPermissions()
    }

    /// Build the model list shown in Settings and onboarding.
    ///
    /// The base catalog is curated for M-series Macs, then extended with any
    /// exact variants WhisperKit marks supported for the current device.
    private func modelCatalog() -> [ModelSize] {
        var catalog = ModelSize.standardCatalog

        for size in ModelSize.allCases where modelManager.isModelSupported(size) {
            if !catalog.contains(size) {
                catalog.append(size)
            }
        }

        if let selected = ModelSize(rawValue: selectedModelSize),
           !catalog.contains(selected) {
            catalog.append(selected)
        }

        return catalog
    }

    /// Recreate model UI state from the latest catalog and local cache status.
    private func rebuildAvailableModels() {
        availableModels = modelCatalog().map { size in
            WhisperModelInfo(
                size: size,
                filePath: modelManager.modelFolder(for: size),
                isDownloaded: modelManager.isModelDownloaded(size),
                isActive: size.rawValue == selectedModelSize,
                isSupported: modelManager.isModelSupported(size)
            )
        }
    }

    /// Resolve WhisperKit's recommended exact model variant into app metadata.
    private func recommendedModelSize() -> ModelSize? {
        guard let recommended = deviceRecommendedModel,
              let size = modelManager.modelSize(from: recommended),
              modelManager.isModelSupported(size) else {
            return nil
        }
        return size
    }

    /// Pick a supported startup model when the stored preference is no longer valid.
    private func startupFallbackModel(for preferred: ModelSize) -> ModelSize {
        guard !modelManager.isModelSupported(preferred) else {
            return preferred
        }

        if let downloadedSupported = availableModels.last(where: { $0.isSupported && $0.isDownloaded && !$0.size.isSideloadOnly })?.size {
            return downloadedSupported
        }

        if let recommended = recommendedModelSize() {
            return recommended
        }

        return .tiny
    }

    // MARK: - Permission Handling (delegated to PermissionManager)

    func checkPermissions() { permissionManager.checkPermissions() }
    func startPermissionPolling() { permissionManager.startPermissionPolling() }
    func stopPermissionPolling() { permissionManager.stopPermissionPolling() }
    var allPermissionsGranted: Bool { permissionManager.allPermissionsGranted }
    func requestMicrophonePermission() { permissionManager.requestMicrophonePermission() }
    func openMicrophoneSettings() { permissionManager.openMicrophoneSettings() }
    func requestAccessibilityPermission() { permissionManager.requestAccessibilityPermission() }
    func requestInputMonitoringPermission() { permissionManager.requestInputMonitoringPermission() }

    // MARK: - Hotkey Configuration

    /// Apply persisted hotkey settings to the active listener.
    /// `@AppStorage` updates save preferences immediately, but an already-running
    /// event tap also needs its in-memory configuration refreshed.
    func syncHotKeyConfiguration() {
        hotKeyManager.updateConfiguration(
            keyCode: hotKeyCode,
            mode: activationMode,
            doubleTapThreshold: doubleTapThreshold,
            safetyTimeout: hotKeySafetyTimeout
        )
        VocaLogger.debug(.appState, "Hotkey configuration synced (keyCode=\(hotKeyCode), mode=\(activationMode.rawValue))")
    }

    // MARK: - Force Recovery

    /// Forcibly reset the entire recording pipeline to idle state.
    /// This is a last-resort recovery mechanism callable from the menu bar UI.
    /// It unconditionally resets the audio engine, hotkey state, cursor overlay,
    /// and all published state back to idle.
    func forceRecovery() {
        VocaLogger.warning(.appState, "Force recovery: resetting all state to idle (was appStatus=\(appStatus.rawValue), isRecording=\(isRecording))")

        // Invalidate any dictation still suspended in the pipeline (MAJOR 2)
        // before touching anything else it might race with.
        dictationGeneration += 1

        // Reset audio engine unconditionally
        audioEngine.forceReset()

        // Reset hotkey tracking state
        hotKeyManager.resetKeyState()

        // Reset UI state
        isRecording = false
        audioLevel = 0.0
        cursorOverlay.hide()
        appStatus = .idle
        errorMessage = nil
    }

    // MARK: - Recording Flow

    func startRecording() async {
        // If we're already recording, this is a recovery attempt — the user
        // pressed the hotkey again because a previous key-up was missed.
        // Stop the current recording and transcribe what we have.
        if appStatus == .recording || isRecording {
            VocaLogger.warning(.appState, "startRecording called while already recording — treating as stop (recovery)")
            await stopRecordingAndTranscribe()
            return
        }

        guard appStatus == .idle else {
            // If stuck in .processing or .error for too long, force recovery
            // so the user can start a fresh recording.
            if appStatus == .error || appStatus == .processing {
                VocaLogger.warning(.appState, "startRecording called in \(appStatus.rawValue) state — force recovering to allow new recording")
                forceRecovery()
                // Don't start recording in the same call — let the user press again
                return
            }
            VocaLogger.warning(.appState, "startRecording called in non-idle state: \(appStatus.rawValue) — ignoring")
            return
        }
        guard micPermission == .granted else {
            errorMessage = "Microphone permission is required. Please grant access in System Settings."
            appStatus = .error
            return
        }

        // A genuinely new recording starts here — invalidate any dictation
        // still suspended in the pipeline from a previous one (MAJOR 2).
        dictationGeneration += 1

        // AD-5: captured now, at the moment recording starts — not when it
        // stops. The user may switch applications while dictating; only what
        // was frontmost when they started speaking is the app they meant to
        // dictate into. Cursor Context stays off (Story 4.4 turns it on
        // behind its own toggles); this call still resolves the bundle
        // identifier unconditionally (Story 4.1).
        capturedContext = axContextReader.capture(readCursorContext: false)

        appStatus = .recording
        isRecording = true
        errorMessage = nil

        // Show cursor indicator
        if showCursorIndicator {
            cursorOverlay.show()
        }

        // Start recording immediately for instant responsiveness.
        // The start sound is played concurrently — any brief bleed into the
        // mic buffer is negligible and handled well by WhisperKit's noise model.
        let didStartRecording = await startAudioEngine(
            silenceThreshold: Float(silenceThreshold),
            silenceDuration: silenceDuration,
            maxDuration: TimeInterval(maxRecordingDuration),
            preferredInputDeviceID: selectedAudioDeviceID.isEmpty ? nil : selectedAudioDeviceID
        )

        guard didStartRecording else {
            VocaLogger.warning(.appState, "Audio engine failed to start — resetting recording state")
            isRecording = false
            audioLevel = 0.0
            cursorOverlay.hide()
            hotKeyManager.resetKeyState()
            appStatus = .idle
            return
        }

        // Play start sound after mic is active (fire-and-forget)
        if soundEffectsEnabled && isRecording && appStatus == .recording {
            soundManager.playStartSound()
        }
    }

    func stopRecordingAndTranscribe() async {
        // Accept stop if we're recording OR if the audio engine thinks
        // it's recording (covers stuck-state recovery scenarios where
        // isRecording and appStatus may be out of sync).
        guard isRecording || appStatus == .recording else { return }

        let audioData = await stopAudioEngine()
        isRecording = false
        audioLevel = 0.0

        // Play stop sound
        if soundEffectsEnabled {
            soundManager.playStopSound()
        }

        // Transition cursor indicator to processing state (red -> purple)
        // Keeps the overlay visible so the user knows text is on its way
        cursorOverlay.transitionToProcessing()

        guard !audioData.isEmpty else {
            cursorOverlay.hide()
            appStatus = .idle
            return
        }

        appStatus = .processing
        // Snapshot before the two await points below (ASR, then the
        // post-process pipeline), either of which can suspend long enough
        // for a new recording to start (MAJOR 2). Nothing this dictation
        // produces may be applied once it resumes into a different one.
        let generation = dictationGeneration

        do {
            let language = selectedLanguage == "auto" ? nil : selectedLanguage
            let result = try await whisperService.transcribe(
                audioData: audioData,
                language: language,
                translate: translationEnabled,
                vocabulary: customVocabulary
            )

            // Stats are keyed off the raw ASR result, deliberately: they are
            // a measure of what the user actually said (and how long
            // WhisperKit took to hear it), not of what post-processing
            // decided to keep. Toggling cleanup on/off must not change the
            // word counts a past dictation is remembered by (MINOR 16).
            lastTranscription = result
            statsManager.recordTranscription(result)

            // Inject text at cursor position
            // by WhisperService to remove hallucination tokens like [BLANK_AUDIO])
            let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

            // Consume what was captured at recording start (AD-5) and clear it
            // immediately — nothing here is held any longer than this one
            // pipeline run needs it for.
            let context = capturedContext
            capturedContext = nil

            // AD-1: the single seam for every post-ASR text transformation.
            // With no stages enabled this returns trimmedText unchanged (AD-2).
            let pipelineContext = await transcriptPipeline.run(TranscriptContext(
                rawTranscript: trimmedText,
                targetBundleIdentifier: context?.bundleIdentifier
            ))

            // A new recording started while this one was suspended above —
            // discard the result. No injection, no history, no state change;
            // the newer generation owns appStatus/cursorOverlay now (MAJOR 2).
            guard generation == dictationGeneration else {
                VocaLogger.warning(.appState, "Dictation generation changed during processing — discarding stale result")
                return
            }

            let finalText = pipelineContext.currentText
            if !finalText.isEmpty {
                textInjector.inject(
                    text: finalText,
                    preserveClipboard: preserveClipboard
                )
            } else {
                VocaLogger.info(.appState, "Transcription produced no usable text (silence or blank audio)")
            }

            // The record is written even when there was nothing to inject, as
            // long as ASR heard something. A dictation that produced words and
            // then ended up with nothing to paste is precisely the one worth
            // having a record of — losing it silently is the worse failure
            // (MINOR 12). Only genuinely blank audio writes nothing.
            if !pipelineContext.rawTranscript.isEmpty || !finalText.isEmpty {
                recordHistory(
                    context: pipelineContext,
                    model: result.modelUsed,
                    recordingMillis: result.audioLengthSeconds * 1000,
                    asrMillis: result.duration * 1000
                )
            }

            cursorOverlay.hide()
            appStatus = .idle
        } catch {
            // Same guard as above: a transcription that fails after a new
            // recording has already started must not clobber it either.
            guard generation == dictationGeneration else {
                VocaLogger.warning(.appState, "Dictation generation changed before failure could be reported — discarding")
                return
            }

            cursorOverlay.hide()
            errorMessage = "Transcription failed: \(error.localizedDescription)"
            appStatus = .error

            // Auto-recover after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                if self?.appStatus == .error {
                    self?.appStatus = .idle
                    self?.errorMessage = nil
                }
            }
        }
    }

    // MARK: - Re-paste (FR-9)

    /// Re-inject a previous dictation's Final Text via the same `TextInjector`
    /// path a live dictation uses. Does not write a new History Record — the
    /// record already exists, and re-pasting it must not duplicate it.
    ///
    /// Only while idle (MAJOR 7): re-pasting mid-dictation overlaps the live
    /// injection on the clipboard and overwrites `lastInjection`, so a
    /// subsequent undo would retract the wrong text.
    func rePaste(_ record: HistoryRecord) {
        guard appStatus == .idle else {
            VocaLogger.info(.appState, "Re-paste requested while \(appStatus.rawValue) — ignoring")
            return
        }

        // The action was triggered from VocaMac's own UI, which holds key
        // status right now. Hand focus back to the app the user was actually
        // typing in before injecting anything (BLOCKER 2).
        let generation = dictationGeneration
        let text = record.finalText
        withTargetAppActivated { [weak self] in
            guard let self else { return }
            // A recording may have started during the activation delay; the
            // newer dictation owns the injection point now (MAJOR 2).
            guard generation == self.dictationGeneration, self.appStatus == .idle else {
                VocaLogger.info(.appState, "Re-paste abandoned — a new dictation started while focus was being handed back")
                return
            }
            self.textInjector.inject(text: text, preserveClipboard: self.preserveClipboard)
        }
    }

    /// Gives focus back to `lastNonSelfFrontmostApp` and runs `work` once the
    /// activation has settled. Runs `work` immediately when there is nothing
    /// to activate — no known target, or it is already frontmost — which is
    /// also what keeps this synchronous under test.
    private func withTargetAppActivated(_ work: @escaping () -> Void) {
        guard let target = lastNonSelfFrontmostApp, !target.isActive else {
            work()
            return
        }

        VocaLogger.info(.appState, "Re-activating \(target.bundleIdentifier ?? "the previous app") before injecting")
        NSApp.deactivate()
        target.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + TextInjector.focusSettleDelay) {
            work()
        }
    }

    /// Re-paste the most recent dictation, if any exist.
    func rePasteMostRecent() {
        guard let mostRecent = historyStore.records.first else {
            VocaLogger.info(.appState, "Re-paste requested with no history — nothing to do")
            return
        }
        rePaste(mostRecent)
    }

    // MARK: - Undo (FR-10)

    /// True when the last injection can still be retracted safely (FR-10) —
    /// see `TextInjector.canUndoLastInjection` for the exact conditions.
    var canUndoLastInjection: Bool { textInjector.canUndoLastInjection }

    /// Best-effort retraction of the last injection. Returns `false` —
    /// changing nothing — when it cannot be performed safely.
    @discardableResult
    func undoLastInjection() -> Bool {
        textInjector.undoLastInjection()
    }

    /// Persist the completed dictation (FR-8). `context.rawTranscript` and
    /// `context.currentText` are exactly what was injected; per AD-5, nothing
    /// about Cursor Context is read or passed here — HistoryRecord has no
    /// field that could hold it.
    ///
    /// Per-stage latency (FR-3, Story 1.3): `recordingMillis` and `asrMillis`
    /// come from measurements WhisperService already makes (audio length and
    /// transcription elapsed time); `postProcessMillis` comes from the
    /// PostProcess stage's own `StageReport.duration`.
    ///
    /// `TranscriptPipeline` reports every stage it runs, including ones that
    /// declined before doing any work — a disabled PostProcess stage still
    /// files a report worth a few microseconds, which the History view then
    /// showed as a spurious "Post-process 0ms" row (MAJOR 6). `didRun` is what
    /// separates that from a stage that really did make an LLM round trip and
    /// came back with `.skipped("no changes needed")`: the latter's two
    /// seconds are real and must be shown.
    private func recordHistory(
        context: TranscriptContext,
        model: ModelSize,
        recordingMillis: Double,
        asrMillis: Double
    ) {
        let didFallback = context.reports.contains { report in
            if case .failed = report.outcome { return true }
            return false
        }
        let postProcessReport = context.reports.first { $0.stageName == PostProcessStage.stageName }
        let postProcessMillis = (postProcessReport?.didRun == true ? postProcessReport?.duration ?? 0 : 0) * 1000

        historyStore.record(HistoryRecord(
            rawTranscript: context.rawTranscript,
            finalText: context.currentText,
            targetBundleId: context.targetBundleIdentifier,
            modelName: model.displayName,
            recordingMillis: recordingMillis,
            asrMillis: asrMillis,
            postProcessMillis: postProcessMillis,
            didFallback: didFallback
        ))
    }

    private func startAudioEngine(
        silenceThreshold: Float,
        silenceDuration: Double,
        maxDuration: TimeInterval,
        preferredInputDeviceID: String?
    ) async -> Bool {
        let worker = AudioEngineWorker(audioEngine: audioEngine)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let didStart = worker.startRecording(
                    silenceThreshold: silenceThreshold,
                    silenceDuration: silenceDuration,
                    maxDuration: maxDuration,
                    preferredInputDeviceID: preferredInputDeviceID
                )
                continuation.resume(returning: didStart)
            }
        }
    }

    private func stopAudioEngine() async -> [Float] {
        let worker = AudioEngineWorker(audioEngine: audioEngine)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: worker.stopRecording())
            }
        }
    }

    // MARK: - Model Management

    func loadModel(_ size: ModelSize? = nil) async {
        let previousLoadedModelName = whisperService.loadedModelName
        let previousModelSize = currentModel?.size
            ?? previousLoadedModelName.flatMap { modelManager.modelSize(from: $0) }
            ?? ModelSize(rawValue: selectedModelSize)
        let hadLoadedModel = whisperService.isModelLoaded

        let modelName: String?
        if let size = size {
            modelName = modelManager.whisperKitModelName(for: size)
        } else {
            modelName = nil  // Let WhisperKit auto-select
        }

        // Resolve which ModelSize we're loading. When size is nil (auto-select),
        // we don't know yet — we'll detect it after loading completes.
        let targetSize = size

        // Mark the model as loading in the UI
        if let targetSize = targetSize, let idx = availableModels.firstIndex(where: { $0.size == targetSize }) {
            availableModels[idx].isLoading = true
            availableModels[idx].loadingStatus = "Preparing…"
        }

        do {
            // If model is downloaded locally, pass the folder URL so WhisperKit
            // loads from disk instead of downloading again. WhisperKit handles
            // tokenizer fetching itself — we don't pre-validate those files.
            let folderURL: URL?
            if let targetSize = targetSize, modelManager.isModelDownloaded(targetSize) {
                folderURL = modelManager.modelFolder(for: targetSize)
            } else {
                folderURL = nil
            }

            // Update status: unpacking
            if let targetSize = targetSize, let idx = availableModels.firstIndex(where: { $0.size == targetSize }) {
                availableModels[idx].loadingStatus = "Unpacking model…"
            }

            // Load model with status callback
            try await whisperService.loadModel(name: modelName, folder: folderURL) { [weak self] phase in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let targetSize = targetSize,
                       let idx = self.availableModels.firstIndex(where: { $0.size == targetSize }) {
                        self.availableModels[idx].loadingStatus = phase
                    }
                }
            }

            // Determine which ModelSize was actually loaded.
            // When auto-selecting, WhisperKit chooses the model and we need
            // to detect which one it picked by inspecting the loaded model name.
            let resolvedSize: ModelSize
            if let targetSize = targetSize {
                resolvedSize = targetSize
            } else {
                let loadedName = (whisperService.loadedModelName ?? "").lowercased()
                if let loadedSize = modelManager.modelSize(from: whisperService.loadedModelName ?? "") {
                    resolvedSize = loadedSize
                } else if loadedName.contains("ivrit") {
                    // Checked before the generic "large"+"turbo" branches below,
                    // since the ivrit.ai folder name also contains both words.
                    resolvedSize = .ivritAiWhisperLargeV3Turbo
                } else if loadedName.contains("v20240930_turbo") {
                    resolvedSize = .largeV3LatestTurbo
                } else if loadedName.contains("v20240930") {
                    resolvedSize = .largeV3Latest
                } else if loadedName.contains("distil") && loadedName.contains("turbo") {
                    resolvedSize = .distilLargeV3TurboCompact
                } else if loadedName.contains("distil") {
                    resolvedSize = .distilLargeV3Compact
                } else if loadedName.contains("large") && loadedName.contains("turbo") {
                    resolvedSize = .largeV3Turbo
                } else if loadedName.contains("large") {
                    resolvedSize = .largeV3
                } else if loadedName.contains("medium") {
                    resolvedSize = .medium
                } else if loadedName.contains("small") {
                    resolvedSize = .small
                } else if loadedName.contains("base") {
                    resolvedSize = .base
                } else {
                    resolvedSize = .tiny
                }
                VocaLogger.info(.appState, "Auto-selected model resolved to: \(resolvedSize.displayName) (from '\(whisperService.loadedModelName ?? "unknown")')")
            }

            // Persist the resolved model as the user's preference
            selectedModelSize = resolvedSize.rawValue

            // Update model states — clear all, then mark the loaded one as active
            for i in availableModels.indices {
                let matches = availableModels[i].size == resolvedSize
                availableModels[i].isActive = matches
                availableModels[i].isLoading = false
                availableModels[i].loadingStatus = "Loading…"
                if matches {
                    // Refresh download status in case the auto-select downloaded it
                    availableModels[i].isDownloaded = modelManager.isModelDownloaded(resolvedSize)
                    currentModel = availableModels[i]
                }
            }

            VocaLogger.info(.appState, "Model ready: \(resolvedSize.displayName)")
        } catch {
            // Clear loading state on error for all models (covers auto-select case)
            for i in availableModels.indices {
                availableModels[i].isLoading = false
                availableModels[i].loadingStatus = "Loading…"
            }

            let modelDisplayName = targetSize?.displayName ?? "model"
            let failureMessage = "Failed to load \(modelDisplayName): \(error.localizedDescription)"
            showTemporaryError(failureMessage)
            VocaLogger.error(.appState, failureMessage)

            await restorePreviousModelIfNeeded(
                afterFailedLoadFor: targetSize,
                previousSize: previousModelSize,
                previousName: previousLoadedModelName,
                hadLoadedModel: hadLoadedModel,
                originalFailureMessage: failureMessage
            )
        }
    }

    /// Surface a short-lived error state for settings and menu UI.
    private func showTemporaryError(_ message: String) {
        errorMessage = message
        appStatus = .error

        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            if self?.appStatus == .error, self?.errorMessage == message {
                self?.appStatus = .idle
                self?.errorMessage = nil
            }
        }
    }

    /// Restore the model that was active before a failed switch.
    private func restorePreviousModelIfNeeded(
        afterFailedLoadFor failedSize: ModelSize?,
        previousSize: ModelSize?,
        previousName: String?,
        hadLoadedModel: Bool,
        originalFailureMessage: String
    ) async {
        guard hadLoadedModel,
              let previousSize,
              failedSize != previousSize else {
            clearActiveModelState()
            return
        }

        do {
            VocaLogger.info(.appState, "Restoring previous model: \(previousSize.displayName)")
            let folderURL = modelManager.isModelDownloaded(previousSize)
                ? modelManager.modelFolder(for: previousSize)
                : nil
            let restoreName = previousName ?? modelManager.whisperKitModelName(for: previousSize)
            try await whisperService.loadModel(name: restoreName, folder: folderURL)
            markModelActive(previousSize)
            VocaLogger.info(.appState, "Restored previous model: \(previousSize.displayName)")
        } catch {
            clearActiveModelState()
            let restoreFailure = "Previous model could not be restored: \(error.localizedDescription)"
            errorMessage = "\(originalFailureMessage) \(restoreFailure)"
            VocaLogger.error(.appState, restoreFailure)
        }
    }

    /// Synchronize AppState's model metadata after a successful load.
    private func markModelActive(_ size: ModelSize) {
        currentModel = nil
        for i in availableModels.indices {
            let matches = availableModels[i].size == size
            availableModels[i].isActive = matches
            availableModels[i].isLoading = false
            availableModels[i].loadingStatus = "Loading…"
            if matches {
                availableModels[i].isDownloaded = modelManager.isModelDownloaded(size)
                currentModel = availableModels[i]
            }
        }
    }

    /// Clear active model metadata when no model is loaded in WhisperService.
    private func clearActiveModelState() {
        currentModel = nil
        for i in availableModels.indices {
            availableModels[i].isActive = false
            availableModels[i].isLoading = false
            availableModels[i].loadingStatus = "Loading…"
        }
    }

    func downloadModel(_ size: ModelSize) async {
        guard let index = availableModels.firstIndex(where: { $0.size == size }) else { return }

        availableModels[index].downloadProgress = 0.0

        do {
            try await modelManager.downloadModel(size: size) { [weak self] progress in
                Task { @MainActor in
                    guard let self = self else { return }
                    if let idx = self.availableModels.firstIndex(where: { $0.size == size }) {
                        // Only update progress if we haven't already completed (1.0)
                        // This prevents race conditions with the simulated progress task
                        if progress >= 1.0 || self.availableModels[idx].downloadProgress != nil {
                            self.availableModels[idx].downloadProgress = progress
                        }
                    }
                }
            }

            // Small delay to let the final progress (1.0) callback settle on MainActor
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

            // Refresh all model statuses to ensure previously downloaded models are preserved
            refreshModelStatuses()
            VocaLogger.info(.appState, "Download complete for \(size.displayName), isDownloaded=\(modelManager.isModelDownloaded(size))")
        } catch {
            if let idx = availableModels.firstIndex(where: { $0.size == size }) {
                availableModels[idx].downloadProgress = nil
            }
            errorMessage = "Download failed: \(error.localizedDescription)"
            VocaLogger.error(.appState, "Download failed for \(size.displayName): \(error.localizedDescription)")
        }
    }

    /// Refresh the download status of all models
    /// This ensures that all previously downloaded models are detected and marked correctly
    private func refreshModelStatuses() {
        for i in availableModels.indices {
            let size = availableModels[i].size
            availableModels[i].isDownloaded = modelManager.isModelDownloaded(size)
            availableModels[i].downloadProgress = nil
            availableModels[i].filePath = modelManager.modelFolder(for: size)
        }
    }

    // MARK: - Startup

    private func installBundledOrFallback(preferred: ModelSize) async -> Bool {
        do {
            return try modelManager.installBundledModelIfAvailable(for: preferred)
        } catch {
            VocaLogger.warning(.appState, "Bundled model install failed for \(preferred.displayName): \(error.localizedDescription)")
            return false
        }
    }

    func performStartup() async {
        guard !AppState.hasPerformedStartupGlobally else {
            VocaLogger.debug(.appState, "performStartup called again — skipping (already performed)")
            return
        }
        AppState.hasPerformedStartupGlobally = true

        VocaLogger.info(.appState, "performStartup beginning...")

        // 1. Detect hardware
        systemCapabilities = SystemInfo.detect()
        let sysInfo = systemCapabilities
        VocaLogger.info(.appState, "System: \(sysInfo?.processorName ?? "unknown") | \(sysInfo?.physicalMemoryGB ?? 0) GB RAM | \(sysInfo?.coreCount ?? 0) cores")

        // 2. Check/request permissions
        checkPermissions()
        VocaLogger.info(.appState, "Mic permission: \(micPermission.rawValue) | Accessibility: \(accessibilityPermission.rawValue) | Input Monitoring: \(inputMonitoringPermission.rawValue)")

        // Auto-prompt for microphone permission on first launch
        if micPermission == .notDetermined {
            VocaLogger.info(.appState, "Mic permission not determined — requesting...")
            requestMicrophonePermission()
        }

        // Start polling if any permission is still missing
        startPermissionPolling()

        // 3. Load the user's preferred model.
        // On first launch the preferred model (tiny by default) won't be
        // downloaded yet. We download it explicitly so the UI can show real
        // progress, rather than delegating to WhisperKit's opaque auto-select
        // which provides no progress callbacks and may pick a different model.
        let preferredModel = ModelSize(rawValue: selectedModelSize) ?? .tiny
        var modelToLoad = startupFallbackModel(for: preferredModel)
        if modelToLoad != preferredModel {
            let fallbackMessage = "\(preferredModel.displayName) is no longer available — using \(modelToLoad.displayName) instead"
            VocaLogger.warning(.appState, fallbackMessage)
            showTemporaryError(fallbackMessage)
            selectedModelSize = modelToLoad.rawValue
            rebuildAvailableModels()
        }

        if !modelManager.isModelDownloaded(modelToLoad) {
            // Try bundled model for the preferred size first
            let installedPreferred = await installBundledOrFallback(preferred: modelToLoad)
            if installedPreferred {
                refreshModelStatuses()
            } else {
                VocaLogger.info(.appState, "Preferred model \(modelToLoad.displayName) not downloaded — downloading now...")
                await downloadModel(modelToLoad)
            }

            // If preferred model still isn't ready, try bundled tiny as a last resort
            if !modelManager.isModelDownloaded(modelToLoad), modelToLoad != .tiny {
                let installedTiny = await installBundledOrFallback(preferred: .tiny)
                if installedTiny {
                    modelToLoad = .tiny
                    refreshModelStatuses()
                    VocaLogger.info(.appState, "Falling back to bundled Tiny model")
                }
            }
        }

        VocaLogger.info(.appState, "Loading model: \(modelToLoad.displayName)...")
        await loadModel(modelToLoad)
        VocaLogger.info(.appState, "Model loaded: \(whisperService.loadedModelName ?? "none")")

        // 4. Always attempt to start hotkey listener
        // The event tap creation itself will fail if permissions aren't granted,
        // and we handle that gracefully in HotKeyManager.
        VocaLogger.info(.appState, "Attempting to start hotkey listener...")
        hotKeyManager.startListening(
            keyCode: hotKeyCode,
            mode: activationMode,
            doubleTapThreshold: doubleTapThreshold,
            safetyTimeout: hotKeySafetyTimeout
        )
        if hotKeyManager.isListening {
            VocaLogger.info(.appState, "Hotkey listener active (keyCode=\(hotKeyCode), mode=\(activationMode.rawValue))")
        } else {
            VocaLogger.warning(.appState, "Hotkey listener failed to start. Check Accessibility & Input Monitoring permissions.")
        }

        VocaLogger.info(.appState, "Startup complete!")
    }
    func completeOnboarding() {
        syncHotKeyConfiguration()
        if !isRecording {
            hotKeyManager.resetKeyState()
        }
        hasCompletedOnboarding = true
        VocaLogger.info(.appState, "Onboarding completed")
    }
}
