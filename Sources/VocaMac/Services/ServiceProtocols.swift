// ServiceProtocols.swift
// VocaMac
//
// Protocol abstractions for all services that AppState depends on.
// Enables dependency injection and test mocking.

import Foundation
import Combine

// MARK: - AudioRecording

protocol AudioRecording: AnyObject {
    var isCurrentlyRecording: Bool { get }
    var onAudioLevel: ((Float) -> Void)? { get set }
    var onSilenceDetected: (() -> Void)? { get set }
    var onMaxDurationReached: (() -> Void)? { get set }
    var onAudioDeviceChanged: (() -> Void)? { get set }

    @discardableResult
    func startRecording(
        silenceThreshold: Float,
        silenceDuration: Double,
        maxDuration: TimeInterval,
        preferredInputDeviceID: String?
    ) -> Bool
    @discardableResult func stopRecording() -> [Float]
    func forceReset()
    func checkPermissionStatus() -> PermissionStatus
    func requestPermission(completion: @escaping (Bool) -> Void)
}

// MARK: - SoundPlaying

protocol SoundPlaying: AnyObject {
    var volume: Float { get set }
    func playStartSound()
    func playStartSoundAsync() async
    func playStopSound()
    func playStopSoundAsync() async
}

// MARK: - HotKeyMonitoring

protocol HotKeyMonitoring: AnyObject {
    var isListening: Bool { get }
    var eventTap: CFMachPort? { get }
    var onRecordingStart: (() -> Void)? { get set }
    var onRecordingStop: (() -> Void)? { get set }

    func checkAccessibilityPermission(prompt: Bool) -> Bool
    func startListening(keyCode: Int, mode: ActivationMode, doubleTapThreshold: Double, safetyTimeout: Double)
    func stopListening()
    func resetKeyState()
    func _updateConfiguration(keyCode: Int?, mode: ActivationMode?, doubleTapThreshold: Double?, safetyTimeout: Double?)
}

extension HotKeyMonitoring {
    func updateConfiguration(keyCode: Int? = nil, mode: ActivationMode? = nil, doubleTapThreshold: Double? = nil, safetyTimeout: Double? = nil) {
        _updateConfiguration(keyCode: keyCode, mode: mode, doubleTapThreshold: doubleTapThreshold, safetyTimeout: safetyTimeout)
    }
}

// MARK: - PermissionManaging

@MainActor
protocol PermissionManaging: AnyObject {
    var micPermission: PermissionStatus { get set }
    var accessibilityPermission: PermissionStatus { get set }
    var inputMonitoringPermission: PermissionStatus { get set }
    var allPermissionsGranted: Bool { get }
    var onAllPermissionsGranted: (() -> Void)? { get set }

    var objectWillChangePublisher: AnyPublisher<Void, Never> { get }

    func checkPermissions()
    func startPermissionPolling()
    func stopPermissionPolling()
    func requestMicrophonePermission()
    func openMicrophoneSettings()
    func requestAccessibilityPermission()
    func requestInputMonitoringPermission()
}

// MARK: - CursorOverlayManaging

@MainActor
protocol CursorOverlayManaging: AnyObject {
    func show()
    func hide()
    func transitionToProcessing()
    func updateAudioLevel(_ level: Float)
}

// MARK: - ModelManaging

protocol ModelManaging: AnyObject {
    func deviceRecommendation() -> (defaultModel: String, supported: [String], disabled: [String])
    func modelFolder(for size: ModelSize) -> URL?
    func bundledModelFolder(for size: ModelSize) -> URL?
    func installBundledModelIfAvailable(for size: ModelSize) throws -> Bool
    func ensureTokenizerAssets(for size: ModelSize) throws -> URL
    func isModelDownloaded(_ size: ModelSize) -> Bool
    func isModelSupported(_ size: ModelSize) -> Bool
    func whisperKitModelName(for size: ModelSize) -> String
    func expectedModelDirectory(for size: ModelSize) -> URL
    func modelSize(from whisperKitName: String) -> ModelSize?
    func downloadModel(size: ModelSize, onProgress: @escaping (Double) -> Void) async throws
    func diskUsageDescription() -> String
}

extension ModelManaging {
    func bundledModelFolder(for size: ModelSize) -> URL? { nil }
}

extension ModelManaging {
    func installBundledModelIfAvailable(for size: ModelSize) throws -> Bool { false }
}

extension ModelManaging {
    func ensureTokenizerAssets(for size: ModelSize) throws -> URL {
        guard let folder = modelFolder(for: size) else {
            throw NSError(domain: "VocaMac.ModelManaging", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model folder unavailable for \(size.rawValue)"])
        }
        return folder
    }
}

// MARK: - SpeechTranscribing

protocol SpeechTranscribing: AnyObject {
    var loadedModelName: String? { get }
    var isModelLoaded: Bool { get }
    func transcribe(audioData: [Float], language: String?, translate: Bool, vocabulary: String) async throws -> VocaTranscription
    func _loadModel(name: String?, folder: URL?, onPhaseChange: ((String) -> Void)?) async throws
}

extension SpeechTranscribing {
    func loadModel(name: String? = nil, folder: URL? = nil, onPhaseChange: ((String) -> Void)? = nil) async throws {
        try await _loadModel(name: name, folder: folder, onPhaseChange: onPhaseChange)
    }
}

// MARK: - TextInjecting

protocol TextInjecting: AnyObject {
    func inject(text: String, preserveClipboard: Bool)

    /// True when the last injection can still be retracted safely (FR-10):
    /// within a short window, and with the same application still frontmost.
    var canUndoLastInjection: Bool { get }

    /// Best-effort retraction of the last injection. Returns `false` —
    /// changing nothing — when it cannot be performed safely.
    @discardableResult
    func undoLastInjection() -> Bool
}

// MARK: - PostProcessing
//
// Declared alongside its vocabulary in Services/PostProcessService.swift.
// The app's only network boundary (AD-6).

// MARK: - ContextReading
//
// Declared alongside its vocabulary (CapturedContext) in
// Services/AXContextReader.swift. Captures the frontmost app's bundle
// identifier and, when asked, Cursor Context — in one call, at recording
// start (AD-5).

// MARK: - ProfileResolving
//
// Declared in Services/ProfileManager.swift, alongside its one method.
// Resolves a captured bundle identifier to a Profile (Story 4.2).

// MARK: - DictionaryProviding
//
// Declared in Services/DictionaryService.swift, alongside its vocabulary.
// Matches transcript tokens against Dictionary Entries and replaces them
// (Story 5.2). Not @MainActor-bound: it is a pure, stateless struct with no
// UI-observable state (AD-8).

// MARK: - SnippetProviding
//
// Declared in Services/SnippetService.swift, alongside its vocabulary.
// Matches transcript text against Snippet Cues and replaces each with an
// opaque placeholder (Story 5.4). Not @MainActor-bound, same reason as
// DictionaryProviding.

// MARK: - CorrectionLearning
//
// Declared in Services/CorrectionLearner.swift, alongside its vocabulary
// (CorrectionCandidate). Watches for the user hand-correcting an injected
// word and proposes a Dictionary Entry for it — never adds one silently
// (Story 5.6). @MainActor-bound: it schedules work via GCD and calls back
// into AppState.

// MARK: - TranscriptPipelining

/// The ordered post-ASR transform chain (AD-1). Runs on the main actor because
/// `AppState` already does; stages await their own work off it.
@MainActor
protocol TranscriptPipelining: AnyObject {
    /// Never throws and never fails: with no stages, or with every stage
    /// disabled or erroring, it returns its input unchanged (AD-2).
    func run(_ context: TranscriptContext) async -> TranscriptContext
}

// MARK: - StatsManaging

@MainActor
protocol StatsManaging: AnyObject {
    var stats: UserStats { get }
    var objectWillChangePublisher: AnyPublisher<Void, Never> { get }
    func recordTranscription(_ transcription: VocaTranscription)
    func resetStats()
}

// MARK: - HistoryRecording
//
// Persists every dictation locally (AD-10, FR-8). Never carries Cursor
// Context — see HistoryRecord.swift and AD-5.

@MainActor
protocol HistoryRecording: AnyObject {
    var records: [HistoryRecord] { get }
    var retentionLimit: Int { get set }
    var objectWillChangePublisher: AnyPublisher<Void, Never> { get }

    func record(_ record: HistoryRecord)
    func delete(_ id: UUID)
    func deleteAll()
    func search(_ query: String) -> [HistoryRecord]
}
