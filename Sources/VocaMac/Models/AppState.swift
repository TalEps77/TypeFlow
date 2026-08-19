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

    @AppStorage("vocamac.hasCompletedOnboarding", store: VocaDefaults.store) var hasCompletedOnboarding: Bool = false
    @AppStorage("vocamac.activationMode", store: VocaDefaults.store) var activationMode: ActivationMode = .pushToTalk
    @AppStorage("vocamac.hotKeyCode", store: VocaDefaults.store) var hotKeyCode: Int = 61  // Right Option
    @AppStorage("vocamac.doubleTapThreshold", store: VocaDefaults.store) var doubleTapThreshold: Double = 0.4
    @AppStorage("vocamac.silenceThreshold", store: VocaDefaults.store) var silenceThreshold: Double = 0.01
    @AppStorage("vocamac.silenceDuration", store: VocaDefaults.store) var silenceDuration: Double = 1.2
    @AppStorage("vocamac.maxRecordingDuration", store: VocaDefaults.store) var maxRecordingDuration: Int = 180
    @AppStorage("vocamac.selectedAudioDeviceID", store: VocaDefaults.store) var selectedAudioDeviceID: String = ""
    @AppStorage("vocamac.selectedAudioDeviceName", store: VocaDefaults.store) var selectedAudioDeviceName: String = ""
    @AppStorage("vocamac.selectedModelSize", store: VocaDefaults.store) var selectedModelSize: String = ModelSize.largeV3LatestCompact.rawValue
    @AppStorage("vocamac.selectedLanguage", store: VocaDefaults.store) var selectedLanguage: String = "he"
    @AppStorage("vocamac.launchAtLogin", store: VocaDefaults.store) var launchAtLogin: Bool = false
    @AppStorage("vocamac.preserveClipboard", store: VocaDefaults.store) var preserveClipboard: Bool = true
    @AppStorage("vocamac.soundEffectsEnabled", store: VocaDefaults.store) var soundEffectsEnabled: Bool = false
    @AppStorage("vocamac.showCursorIndicator", store: VocaDefaults.store) var showCursorIndicator: Bool = true
    @AppStorage("vocamac.translationEnabled", store: VocaDefaults.store) var translationEnabled: Bool = false
    @AppStorage("vocamac.customVocabulary", store: VocaDefaults.store) var customVocabulary: String = "WhisperKit, CoreML, Apple Silicon, macOS, Swift, SwiftUI, Xcode, Homebrew, GitHub, API, JSON, TypeScript, JavaScript, Python, Docker, Kubernetes, React, Node.js, terminal, VS Code, OpenAI, Claude Code, pull request, branch, commit"
    @AppStorage("vocamac.logLevel", store: VocaDefaults.store) var logLevel: String = "info"

    // Post-processing (AD-9). The stage reads the same keys through
    // PostProcessSettings, so no service has to depend on AppState.
    @AppStorage(PostProcessSettings.Key.enabled, store: VocaDefaults.store) var postProcessEnabled: Bool = PostProcessSettings.Default.enabled
    @AppStorage(PostProcessSettings.Key.baseURL, store: VocaDefaults.store) var postProcessBaseURL: String = PostProcessSettings.Default.baseURL
    @AppStorage(PostProcessSettings.Key.model, store: VocaDefaults.store) var postProcessModel: String = PostProcessSettings.Default.model
    @AppStorage(PostProcessSettings.Key.timeout, store: VocaDefaults.store) var postProcessTimeout: Double = PostProcessSettings.Default.timeout
    @AppStorage(PostProcessSettings.Key.temperature, store: VocaDefaults.store) var postProcessTemperature: Double = PostProcessSettings.Default.temperature
    @AppStorage(PostProcessSettings.Key.systemPrompt, store: VocaDefaults.store) var postProcessSystemPrompt: String = PostProcessSettings.Default.systemPrompt

    /// Master switch for Profile resolution (Story 4.2, AD-9). When off, the
    /// Default Profile always applies and dictation behaves exactly like
    /// Epic 2/3's, regardless of what Profiles exist or how they're bound.
    @AppStorage("vocamac.profiles.enabled", store: VocaDefaults.store) var profilesEnabled: Bool = true

    /// Global master switch for Cursor Context (Story 4.4, FR-14, AD-9).
    /// Ships **off**: reading text is the highest-privacy-cost capability
    /// here (AD-5, R-8), and it stays off even when this is on unless the
    /// resolved Profile's own toggle also allows it.
    @AppStorage("vocamac.contextCapture.enabled", store: VocaDefaults.store) var contextCaptureEnabled: Bool = false

    /// Master switch for post-ASR Dictionary replacement (Story 5.2, AD-9).
    /// Ships on: with no entries yet added the stage is already an identity
    /// operation (AD-2), so there is nothing for a fresh install to notice.
    @AppStorage(DictionarySettings.Key.enabled, store: VocaDefaults.store) var dictionaryEnabled: Bool = DictionarySettings.Default.enabled

    /// Master switch for Snippet expansion (Story 5.4, AD-9). Ships on for
    /// the same reason as Dictionary: no Snippets defined means the stage
    /// pair is already an identity operation (AD-2).
    @AppStorage(SnippetSettings.Key.enabled, store: VocaDefaults.store) var snippetsEnabled: Bool = SnippetSettings.Default.enabled

    /// Master switch for correction learning (Story 5.6, FR-18, AD-9). Ships
    /// **off** — this is the highest-noise-risk capability in this epic
    /// (R-6): it re-reads a text field the user is actively editing, and a
    /// stream of bad suggestions would make dictation worse, not better.
    @AppStorage(CorrectionLearningSettings.Key.enabled, store: VocaDefaults.store) var correctionLearningEnabled: Bool = CorrectionLearningSettings.Default.enabled

    /// Command Mode's second hotkey binding (Story 6.1, AD-9). Ships **off** —
    /// see `CommandModeSettings.Default.enabled` for why this one is not like
    /// Dictionary and Snippets.
    @AppStorage(CommandModeSettings.Key.enabled, store: VocaDefaults.store) var commandModeEnabled: Bool = CommandModeSettings.Default.enabled
    @AppStorage(CommandModeSettings.Key.hotKeyCode, store: VocaDefaults.store) var commandHotKeyCode: Int = CommandModeSettings.Default.hotKeyCode
    @AppStorage(CommandModeSettings.Key.activationMode, store: VocaDefaults.store) var commandActivationMode: ActivationMode = CommandModeSettings.Default.activationMode

    private var hotKeySafetyTimeout: Double {
        Double(maxRecordingDuration) + 5.0
    }

    /// True when the Command Mode binding is both enabled and bound to a key
    /// that is not already the dictation key. The settings UI refuses to
    /// create the collision (Story 6.1 AC); this is what makes a preference
    /// that arrived some other way inert rather than ambiguous.
    var isCommandModeUsable: Bool {
        commandModeEnabled && commandHotKeyCode != hotKeyCode
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
    let profileManager: ProfileResolving

    /// The concrete store behind `profileManager`, exposed directly for the
    /// Profiles settings tab (Story 4.3) to drive CRUD and reordering. Not
    /// behind its own protocol/mock — unlike `historyStore`, nothing in
    /// AppState's own business logic calls its mutating methods, only the UI
    /// does, mirroring the existing `updateChecker` precedent.
    let profileStore: ProfileStore

    /// The store behind the Dictionary stage's entries (Story 5.2) and the
    /// Dictionary settings tab's CRUD (Story 5.3) — same shape as
    /// `profileStore` above, and for the same reason: nothing in AppState's
    /// own business logic mutates it, only the UI does.
    let dictionaryStore: DictionaryStore

    /// Same shape as `dictionaryStore`, behind SnippetStage's Cues
    /// (Story 5.4) and the Snippets settings UI's CRUD (Story 5.5).
    let snippetStore: SnippetStore

    /// Watches injections for a hand-typed correction and proposes a
    /// Dictionary Entry for it (Story 5.6) — never adds one silently.
    let correctionLearner: CorrectionLearning

    /// What the user has dismissed, so the same pair is never proposed
    /// again. Exposed directly (like `profileStore`/`dictionaryStore`
    /// above) so `dismissCorrectionCandidate` can record a dismissal.
    let dismissedCorrectionsStore: DismissedCorrectionsStore

    /// Candidates awaiting the user's confirmation or dismissal (Story 5.6
    /// AC: "proposed for confirmation, never added silently"). In-memory
    /// only and deliberately not `@AppStorage`/JSON-backed — unlike a
    /// dismissal, an unconfirmed candidate is not data worth persisting
    /// across a relaunch, and it holds only the two words involved, never
    /// the field contents it was detected from (AD-5).
    @Published var pendingCorrectionCandidates: [CorrectionCandidate] = []

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
    ///
    /// `private(set)` rather than `private` only so the AD-5 abort-path tests
    /// can assert it really is `nil` after every way a dictation can end
    /// (BLOCKER 1); nothing outside this type writes it.
    private(set) var capturedContext: CapturedContext?

    /// The Profile resolved inside that same `capture()` call (Story 4.2),
    /// kept alongside it for the same reason and cleared at the same time.
    private(set) var capturedProfile: Profile?

    /// Set synchronously at the top of `stopRecordingAndTranscribe`, before
    /// its first `await`. A hotkey release and `onSilenceDetected` /
    /// `onMaxDurationReached` can both reach that method in the same turn;
    /// without this both pass the `isRecording` guard, both suspend, and both
    /// race to consume `capturedContext` — the loser writing a History Record
    /// with a `nil` target app (MINOR 10).
    private var isStopping = false

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
        profileManager: ProfileResolving,
        profileStore: ProfileStore,
        dictionaryStore: DictionaryStore,
        snippetStore: SnippetStore,
        correctionLearner: CorrectionLearning,
        dismissedCorrectionsStore: DismissedCorrectionsStore,
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
        self.dictionaryStore = dictionaryStore
        self.snippetStore = snippetStore
        self.correctionLearner = correctionLearner
        self.dismissedCorrectionsStore = dismissedCorrectionsStore
        self.transcriptPipeline = transcriptPipeline ?? TranscriptPipeline.production(dictionaryStore: dictionaryStore, snippetStore: snippetStore)
        self.axContextReader = axContextReader
        self.profileManager = profileManager
        self.profileStore = profileStore
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

        // Forward profileStore changes so the Profiles settings tab re-renders
        profileStore.objectWillChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Forward dictionaryStore changes so the Dictionary settings tab re-renders
        dictionaryStore.objectWillChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Forward snippetStore changes so the Snippets settings tab re-renders
        snippetStore.objectWillChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Forward dismissedCorrectionsStore changes so the "Clear Dismissed
        // Corrections" control and its count re-render (MAJOR 9).
        dismissedCorrectionsStore.objectWillChangePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Story 5.6: a candidate is proposed, never added silently — it
        // waits here for the user to confirm or dismiss via the settings UI.
        correctionLearner.onCandidateProposed = { [weak self] candidate in
            self?.proposeCorrectionCandidate(candidate)
        }

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
    private static let sharedProductionInstance: AppState = {
        // Shared with `profileManager` below — resolution at dictation time
        // and the Profiles settings tab must see the same Profiles, not two
        // independently-loaded copies.
        let profileStore = ProfileStore()
        // Shared with `correctionLearner` below, for the same reason as
        // `profileStore` above.
        let axContextReader = AXContextReader()
        let dismissedCorrectionsStore = DismissedCorrectionsStore()
        return AppState(
            cursorOverlay: CursorOverlayManager(),
            statsManager: StatsManager(),
            historyStore: HistoryStore(),
            axContextReader: axContextReader,
            profileManager: ProfileManager(store: profileStore),
            profileStore: profileStore,
            dictionaryStore: DictionaryStore(),
            snippetStore: SnippetStore(),
            correctionLearner: CorrectionLearner(contextReader: axContextReader, dismissedStore: dismissedCorrectionsStore),
            dismissedCorrectionsStore: dismissedCorrectionsStore
        )
    }()

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
                // This recording is over and nothing will ever consume what
                // it captured. A Bluetooth headset dropping mid-sentence must
                // not leave the surrounding document text resident (BLOCKER 1).
                self.discardCapturedContext()
                self.isStopping = false
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
            // `startListening` configures the dictation binding only; the
            // command binding is configured separately by design (Story 6.1).
            self.syncCommandHotKeyConfiguration()
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

        // The command binding shares the dictation binding's safety timeout,
        // which is derived from `maxRecordingDuration` — so a change to either
        // hotkey's settings has to re-push both (Story 6.1).
        syncCommandHotKeyConfiguration()
    }

    /// Apply persisted Command Mode hotkey settings to the second binding
    /// (Story 6.1). Pushes `isEnabled: false` whenever the binding would
    /// collide with the dictation key, so the collision can never produce two
    /// gestures on one key.
    func syncCommandHotKeyConfiguration() {
        hotKeyManager.updateCommandConfiguration(
            keyCode: commandHotKeyCode,
            mode: commandActivationMode,
            doubleTapThreshold: doubleTapThreshold,
            safetyTimeout: hotKeySafetyTimeout,
            isEnabled: isCommandModeUsable
        )
        VocaLogger.debug(.appState, "Command hotkey configuration synced (keyCode=\(commandHotKeyCode), mode=\(commandActivationMode.rawValue), enabled=\(isCommandModeUsable))")
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
        discardCapturedContext()
        isStopping = false

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

    /// Releases everything captured at recording start — the bundle
    /// identifier, the resolved Profile, and, the reason this exists at all,
    /// Cursor Context (Story 4.4 AC: "released from memory immediately after
    /// the request").
    ///
    /// The success path already consumed and cleared these; this is for every
    /// other way a dictation can end (BLOCKER 1). Without it a mic unplug, a
    /// Bluetooth headset dropping, a wake-from-sleep device change, a failed
    /// audio-engine start, blank audio, a transcription error, or a force
    /// recovery all leave up to 1000 characters of the user's document alive
    /// in a process-lifetime singleton — reachable from a crash report, a
    /// memory dump, or swap — for as long as the app stays running.
    ///
    /// Story 5.6's pending correction re-read is dropped here too: it holds
    /// the injected text and is about to AX-read a field the user may well
    /// have moved on from, and a dictation that was abandoned has no business
    /// still reaching into their screen a second later.
    private func discardCapturedContext() {
        capturedContext = nil
        capturedProfile = nil
        correctionLearner.cancelPendingObservation()
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

        // And drop the previous dictation's pending correction re-read with it
        // (MAJOR 8): by the time it would fire the user is mid-sentence into
        // the next dictation, so whatever it read could only produce noise —
        // and rapid dictations would otherwise queue overlapping reads of the
        // same field.
        correctionLearner.cancelPendingObservation()

        // AD-5: captured now, at the moment recording starts — not when it
        // stops. The user may switch applications while dictating; only what
        // was frontmost when they started speaking is the app they meant to
        // dictate into.
        //
        // The Profile is resolved right here too, inside the same call's
        // decision closure (Story 4.2) — not re-resolved later — because
        // deciding whether to read Cursor Context (Story 4.4) needs to know
        // it: that read only happens when both the global toggle and this
        // Profile's own toggle allow it. Capturing the Profile now, rather
        // than at stop time, is also what makes it consistent with the
        // bundle identifier: both reflect this exact moment, never a
        // mid-dictation app switch.
        var profileForThisRecording: Profile?
        capturedContext = axContextReader.capture(fallbackApplication: lastNonSelfFrontmostApp) { bundleIdentifier in
            let profile = self.profileManager.resolve(bundleIdentifier: bundleIdentifier, profilesEnabled: self.profilesEnabled)
            profileForThisRecording = profile
            return self.contextCaptureEnabled && profile.contextCaptureEnabled
        }
        capturedProfile = profileForThisRecording

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
            // Nothing will consume what was captured a moment ago — drop it
            // now rather than leaving it alive until the next dictation
            // happens to overwrite it (BLOCKER 1, AD-5).
            discardCapturedContext()
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

        // MINOR 10: a hotkey release and an auto-stop (silence detected, max
        // duration reached) can both arrive before either has suspended. Both
        // would pass the guard above, both would suspend on `stopAudioEngine`,
        // and both would come back to consume the same captured context — the
        // second one finding it already `nil` and writing a History Record
        // with no target app. Latched synchronously, before the first await.
        guard !isStopping else {
            VocaLogger.info(.appState, "stopRecordingAndTranscribe re-entered while already stopping — ignoring")
            return
        }
        isStopping = true
        defer { isStopping = false }

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
            // Blank audio: there is no pipeline run coming, so nothing will
            // consume the capture this recording made (BLOCKER 1, AD-5).
            discardCapturedContext()
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
            // immediately — nothing here, Cursor Context least of all, is
            // held any longer than this one pipeline run needs it for.
            let context = capturedContext
            let resolvedProfile = capturedProfile
            capturedContext = nil
            capturedProfile = nil

            // AD-1: the single seam for every post-ASR text transformation.
            // With no stages enabled this returns trimmedText unchanged (AD-2).
            let pipelineContext = await transcriptPipeline.run(TranscriptContext(
                rawTranscript: trimmedText,
                targetBundleIdentifier: context?.bundleIdentifier,
                resolvedProfile: resolvedProfile,
                cursorContextBefore: context?.cursorContextBefore,
                cursorContextAfter: context?.cursorContextAfter
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
                // Story 5.6: off by default, and a no-op call when it is —
                // observeInjection checks the toggle itself, mirroring every
                // other feature gate in this epic.
                if correctionLearningEnabled {
                    correctionLearner.observeInjection(
                        finalText,
                        targetProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
                    )
                }
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
            // ASR threw before the capture was consumed below — release it
            // here, on the one remaining path out of this method that has not
            // already done so (BLOCKER 1, AD-5).
            discardCapturedContext()

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

    // MARK: - Correction Learning (Story 5.6)

    /// Adds a proposed candidate to the pending list, unless it is already
    /// there or already answered.
    ///
    /// The pending list is rendered with `id: \.self` (MINOR 1), so appending
    /// the same pair twice — trivially done by correcting the same word in two
    /// dictations — gives SwiftUI two rows with identical identity, and it
    /// animates and updates them incorrectly. A pair the Dictionary already
    /// covers is dropped for a plainer reason: there is nothing to approve.
    private func proposeCorrectionCandidate(_ candidate: CorrectionCandidate) {
        guard !pendingCorrectionCandidates.contains(candidate) else { return }
        guard !dictionaryCovers(candidate) else { return }
        pendingCorrectionCandidates.append(candidate)
    }

    /// Whether an entry already maps this candidate's original to its
    /// corrected form, compared the normalization-tolerant way every other
    /// match in this epic is.
    private func dictionaryCovers(_ candidate: CorrectionCandidate) -> Bool {
        let canonical = HebrewNormalizer.normalize(candidate.corrected).lowercased()
        let trigger = HebrewNormalizer.normalize(candidate.original).lowercased()
        return dictionaryStore.entries.contains { entry in
            HebrewNormalizer.normalize(entry.canonicalForm).lowercased() == canonical
                && entry.triggers.contains { HebrewNormalizer.normalize($0).lowercased() == trigger }
        }
    }

    /// The user approved a proposed correction: it becomes a Dictionary
    /// Entry, marked `learned` so it's distinguishable from one typed in by
    /// hand, and the candidate leaves the pending list.
    func confirmCorrectionCandidate(_ candidate: CorrectionCandidate) {
        // MINOR 16: confirming a pair the Dictionary already has adds a second
        // entry saying the same thing — inert, but it accumulates in a list the
        // user has to maintain by hand.
        if !dictionaryCovers(candidate) {
            dictionaryStore.add(DictionaryEntry(
                canonicalForm: candidate.corrected,
                triggers: [candidate.original],
                learned: true
            ))
        }
        pendingCorrectionCandidates.removeAll { $0 == candidate }
    }

    /// The user dismissed a proposed correction: recorded so the same pair
    /// is never proposed again (Story 5.6 AC), and it leaves the pending list.
    func dismissCorrectionCandidate(_ candidate: CorrectionCandidate) {
        dismissedCorrectionsStore.dismiss(candidate)
        pendingCorrectionCandidates.removeAll { $0 == candidate }
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
        // Written by the pipeline, which sees the fallbacks a report's outcome
        // cannot express — RehydrateStage discarding a whole post-processing
        // result still reports `.applied`, because its text really is adopted
        // (MAJOR 4).
        let didFallback = context.didFallback
        let postProcessReport = context.reports.first { $0.stageName == PostProcessStage.stageName }
        let postProcessMillis = (postProcessReport?.didRun == true ? postProcessReport?.duration ?? 0 : 0) * 1000

        historyStore.record(HistoryRecord(
            rawTranscript: context.rawTranscript,
            finalText: context.currentText,
            targetBundleId: context.targetBundleIdentifier,
            profileName: context.resolvedProfile?.name,
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
