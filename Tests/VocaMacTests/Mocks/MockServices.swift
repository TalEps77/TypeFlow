// MockServices.swift
// VocaMac Tests
//
// Mock implementations of service protocols for unit testing.
// These avoid triggering real system side effects (sounds, permissions, mic, etc.).

import Foundation
import Combine
import AppKit
@testable import VocaMac

// MARK: - MockAudioEngine

final class MockAudioEngine: AudioRecording {
    var isCurrentlyRecording = false
    var onAudioLevel: ((Float) -> Void)?
    var onSilenceDetected: (() -> Void)?
    var onMaxDurationReached: (() -> Void)?
    var onAudioDeviceChanged: (() -> Void)?

    var lastSilenceThreshold: Float?
    var lastSilenceDuration: Double?
    var lastMaxDuration: TimeInterval?
    var lastPreferredInputDeviceID: String?
    var lastDetectorKind: VADDetectorKind?
    var stopRecordingResult: [Float] = []
    var forceResetCallCount = 0
    var startRecordingResult = true
    var startRecordingDelay: TimeInterval = 0

    private var permissionStatus: PermissionStatus = .granted

    @discardableResult
    func startRecording(
        silenceThreshold: Float,
        silenceDuration: Double,
        maxDuration: TimeInterval,
        preferredInputDeviceID: String?,
        detectorKind: VADDetectorKind = .energyVAD
    ) -> Bool {
        if startRecordingDelay > 0 {
            Thread.sleep(forTimeInterval: startRecordingDelay)
        }
        isCurrentlyRecording = startRecordingResult
        lastSilenceThreshold = silenceThreshold
        lastSilenceDuration = silenceDuration
        lastMaxDuration = maxDuration
        lastPreferredInputDeviceID = preferredInputDeviceID
        lastDetectorKind = detectorKind
        return startRecordingResult
    }

    @discardableResult
    func stopRecording() -> [Float] {
        isCurrentlyRecording = false
        return stopRecordingResult
    }

    func forceReset() {
        forceResetCallCount += 1
        isCurrentlyRecording = false
    }

    func checkPermissionStatus() -> PermissionStatus {
        permissionStatus
    }

    func setPermissionStatus(_ status: PermissionStatus) {
        permissionStatus = status
    }

    func requestPermission(completion: @escaping (Bool) -> Void) {
        completion(permissionStatus == .granted)
    }
}

// MARK: - MockSoundManager

final class MockSoundManager: SoundPlaying {
    var volume: Float = 0.5
    var startSoundCallCount = 0
    var stopSoundCallCount = 0
    var startSoundAsyncCallCount = 0
    var stopSoundAsyncCallCount = 0

    func playStartSound() {
        startSoundCallCount += 1
    }

    func playStartSoundAsync() async {
        startSoundAsyncCallCount += 1
    }

    func playStopSound() {
        stopSoundCallCount += 1
    }

    func playStopSoundAsync() async {
        stopSoundAsyncCallCount += 1
    }

    /// Story 6.3: the Command Mode abort cue.
    var errorSoundCallCount = 0

    func playErrorSound() {
        errorSoundCallCount += 1
    }
}

// MARK: - MockHotKeyManager

final class MockHotKeyManager: HotKeyMonitoring {
    var isListening = false
    var eventTap: CFMachPort? = nil
    var onRecordingStart: (() -> Void)?
    var onRecordingStop: (() -> Void)?
    var onCommandStart: (() -> Void)?
    var onCommandStop: (() -> Void)?

    var startListeningCallCount = 0
    var lastKeyCode: Int?
    var lastMode: ActivationMode?
    var lastDoubleTapThreshold: Double?
    var lastSafetyTimeout: Double?
    var resetKeyStateCallCount = 0
    var updateConfigurationCallCount = 0

    var updateCommandConfigurationCallCount = 0
    var lastCommandKeyCode: Int?
    var lastCommandMode: ActivationMode?
    var lastCommandDoubleTapThreshold: Double?
    var lastCommandSafetyTimeout: Double?
    var lastCommandIsEnabled: Bool?

    private var accessibilityPermission = false

    func checkAccessibilityPermission(prompt: Bool) -> Bool {
        accessibilityPermission
    }

    func setAccessibilityPermission(_ granted: Bool) {
        accessibilityPermission = granted
    }

    func startListening(keyCode: Int, mode: ActivationMode, doubleTapThreshold: Double, safetyTimeout: Double) {
        startListeningCallCount += 1
        lastKeyCode = keyCode
        lastMode = mode
        lastDoubleTapThreshold = doubleTapThreshold
        lastSafetyTimeout = safetyTimeout
        isListening = true
    }

    func stopListening() {
        isListening = false
    }

    func resetKeyState() {
        resetKeyStateCallCount += 1
    }

    func _updateConfiguration(keyCode: Int?, mode: ActivationMode?, doubleTapThreshold: Double?, safetyTimeout: Double?) {
        updateConfigurationCallCount += 1
        if let keyCode = keyCode {
            lastKeyCode = keyCode
        }
        if let mode = mode {
            lastMode = mode
        }
        if let doubleTapThreshold = doubleTapThreshold {
            lastDoubleTapThreshold = doubleTapThreshold
        }
        if let safetyTimeout = safetyTimeout {
            lastSafetyTimeout = safetyTimeout
        }
    }

    func _updateCommandConfiguration(keyCode: Int?, mode: ActivationMode?, doubleTapThreshold: Double?, safetyTimeout: Double?, isEnabled: Bool?) {
        updateCommandConfigurationCallCount += 1
        if let keyCode { lastCommandKeyCode = keyCode }
        if let mode { lastCommandMode = mode }
        if let doubleTapThreshold { lastCommandDoubleTapThreshold = doubleTapThreshold }
        if let safetyTimeout { lastCommandSafetyTimeout = safetyTimeout }
        if let isEnabled { lastCommandIsEnabled = isEnabled }
    }
}

// MARK: - MockPermissionManager

@MainActor
final class MockPermissionManager: ObservableObject, PermissionManaging {
    @Published var micPermission: PermissionStatus = .granted
    @Published var accessibilityPermission: PermissionStatus = .granted
    @Published var inputMonitoringPermission: PermissionStatus = .granted
    var onAllPermissionsGranted: (() -> Void)?

    var checkPermissionsCallCount = 0
    var startPollingCallCount = 0
    var stopPollingCallCount = 0
    var requestMicPermissionCallCount = 0
    var openMicSettingsCallCount = 0
    var requestAccessibilityCallCount = 0
    var requestInputMonitoringCallCount = 0

    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    var allPermissionsGranted: Bool {
        micPermission == .granted &&
        accessibilityPermission == .granted &&
        inputMonitoringPermission == .granted
    }

    func checkPermissions() {
        checkPermissionsCallCount += 1
    }

    func startPermissionPolling() {
        startPollingCallCount += 1
    }

    func stopPermissionPolling() {
        stopPollingCallCount += 1
    }

    func requestMicrophonePermission() {
        requestMicPermissionCallCount += 1
    }

    func openMicrophoneSettings() {
        openMicSettingsCallCount += 1
    }

    func requestAccessibilityPermission() {
        requestAccessibilityCallCount += 1
    }

    func requestInputMonitoringPermission() {
        requestInputMonitoringCallCount += 1
    }
}

// MARK: - MockCursorOverlay

@MainActor
final class MockCursorOverlay: CursorOverlayManaging {
    var showCallCount = 0
    var hideCallCount = 0
    var transitionCallCount = 0
    var lastAudioLevel: Float?

    func show() {
        showCallCount += 1
    }

    func hide() {
        hideCallCount += 1
    }

    func transitionToProcessing() {
        transitionCallCount += 1
    }

    func updateAudioLevel(_ level: Float) {
        lastAudioLevel = level
    }
}

// MARK: - MockModelManager

final class MockModelManager: ModelManaging {
    var supportedModels: [ModelSize] = ModelSize.allCases
    var defaultModel: String = "openai_whisper-tiny"
    var supportedModelNames: [String]?
    var disabledModelNames: [String] = []
    var downloadedModels: Set<ModelSize> = []
    var diskUsage: String = "100 MB"
    var bundledModels: Set<ModelSize> = []
    var installedBundledModels: [ModelSize] = []
    var ensuredTokenizerSizes: [ModelSize] = []
    var installBundledModelError: Error?

    func deviceRecommendation() -> (defaultModel: String, supported: [String], disabled: [String]) {
        (
            defaultModel: defaultModel,
            supported: supportedModelNames ?? supportedModels.map(whisperKitModelName(for:)),
            disabled: disabledModelNames
        )
    }

    func modelFolder(for size: ModelSize) -> URL? {
        downloadedModels.contains(size) ? URL(fileURLWithPath: "/mock/path/\(size.rawValue)") : nil
    }

    func bundledModelFolder(for size: ModelSize) -> URL? {
        bundledModels.contains(size) ? URL(fileURLWithPath: "/mock/bundled/\(size.rawValue)") : nil
    }

    func installBundledModelIfAvailable(for size: ModelSize) throws -> Bool {
        if let installBundledModelError {
            throw installBundledModelError
        }
        guard bundledModels.contains(size) else { return false }
        installedBundledModels.append(size)
        downloadedModels.insert(size)
        return true
    }

    func ensureTokenizerAssets(for size: ModelSize) throws -> URL {
        ensuredTokenizerSizes.append(size)
        return URL(fileURLWithPath: "/mock/path/\(size.rawValue)")
    }

    func isModelDownloaded(_ size: ModelSize) -> Bool {
        downloadedModels.contains(size)
    }

    func isModelSupported(_ size: ModelSize) -> Bool {
        // Mirrors ModelManager's AD-11 bypass: side-loaded models are never
        // endorsed by a device recommendation, so support tracks on-disk
        // presence instead.
        if size.isSideloadOnly {
            return isModelDownloaded(size)
        }
        if let supportedModelNames {
            return supportedModelNames.contains(whisperKitModelName(for: size))
                && !disabledModelNames.contains(whisperKitModelName(for: size))
        }
        return supportedModels.contains(size)
    }

    func whisperKitModelName(for size: ModelSize) -> String {
        switch size {
        case .tiny:
            return "openai_whisper-tiny"
        case .base:
            return "openai_whisper-base"
        case .small:
            return "openai_whisper-small"
        case .largeV3LatestTurboCompact:
            return "openai_whisper-large-v3-v20240930_turbo_632MB"
        case .distilLargeV3Compact:
            return "distil-whisper_distil-large-v3_594MB"
        case .distilLargeV3TurboCompact:
            return "distil-whisper_distil-large-v3_turbo_600MB"
        case .largeV3LatestCompact:
            return "openai_whisper-large-v3-v20240930_626MB"
        case .largeV3Latest:
            return "openai_whisper-large-v3-v20240930"
        case .largeV3LatestTurbo:
            return "openai_whisper-large-v3-v20240930_turbo"
        case .largeV3:
            return "openai_whisper-large-v3"
        case .largeV3Turbo:
            return "openai_whisper-large-v3_turbo"
        case .medium:
            return "openai_whisper-medium"
        case .ivritAiWhisperLargeV3Turbo:
            return "ivrit-ai_whisper-large-v3-turbo"
        }
    }

    func expectedModelDirectory(for size: ModelSize) -> URL {
        URL(fileURLWithPath: "/mock/path/\(whisperKitModelName(for: size))")
    }

    func modelSize(from whisperKitName: String) -> ModelSize? {
        ModelSize.allCases.first { whisperKitModelName(for: $0) == whisperKitName }
    }

    func downloadModel(size: ModelSize, onProgress: @escaping (Double) -> Void) async throws {
        downloadedModels.insert(size)
    }

    func diskUsageDescription() -> String {
        diskUsage
    }
}

// MARK: - MockWhisperService

final class MockWhisperService: SpeechTranscribing {
    typealias LoadRequest = (name: String?, folder: URL?)

    var loadedModelName: String? = "openai_whisper-tiny"
    var isModelLoaded: Bool = true
    var lastTranscribedAudioData: [Float]?
    var lastLanguage: String?
    var lastTranslate: Bool?
    var lastVocabulary: String?
    var loadRequests: [LoadRequest] = []
    var loadResponses: [Result<String?, Error>] = []
    var mockTranscriptionResult: VocaTranscription = VocaTranscription(text: "mock transcription", duration: 1.0, detectedLanguage: "en", audioLengthSeconds: 1.0, modelUsed: .tiny)
    var shouldThrow = false

    func transcribe(audioData: [Float], language: String?, translate: Bool, vocabulary: String) async throws -> VocaTranscription {
        lastTranscribedAudioData = audioData
        lastLanguage = language
        lastTranslate = translate
        lastVocabulary = vocabulary
        if shouldThrow {
            throw WhisperError.transcriptionFailed(reason: "mock error")
        }
        return mockTranscriptionResult
    }

    func _loadModel(name: String?, folder: URL?, onPhaseChange: ((String) -> Void)?) async throws {
        loadRequests.append((name: name, folder: folder))
        onPhaseChange?("Loading model…")

        if !loadResponses.isEmpty {
            let response = loadResponses.removeFirst()
            switch response {
            case .success(let loadedName):
                loadedModelName = loadedName ?? name ?? "mock-model"
                isModelLoaded = true
                return
            case .failure(let error):
                loadedModelName = nil
                isModelLoaded = false
                throw error
            }
        }

        loadedModelName = name ?? "mock-model"
        isModelLoaded = true
    }
}

// MARK: - MockTextInjector

final class MockTextInjector: TextInjecting {
    var injectCallCount = 0
    var lastInjectedText: String?
    var lastPreserveClipboard: Bool?

    /// Test-controlled answer for `canUndoLastInjection` and the result
    /// `undoLastInjection()` returns.
    var canUndoLastInjection = false
    var undoLastInjectionResult = false
    var undoLastInjectionCallCount = 0

    func inject(text: String, preserveClipboard: Bool) {
        injectCallCount += 1
        lastInjectedText = text
        lastPreserveClipboard = preserveClipboard
    }

    func undoLastInjection() -> Bool {
        undoLastInjectionCallCount += 1
        return undoLastInjectionResult
    }

    // MARK: - Selection (Story 6.2)

    /// What `readSelectionResult()` answers. Defaults to "nothing selected",
    /// which is the Command Mode abort case every test that does not opt in
    /// should see.
    var selectionResult: Result<SelectionSnapshot, SelectionError> = .failure(.noSelection)

    var readSelectionCallCount = 0

    /// What `replaceSelection` answers once the snapshot checks are skipped
    /// (there is no real AX element to compare against here).
    var replaceSelectionResult: Result<Void, SelectionError> = .success(())

    var replaceSelectionCallCount = 0
    var lastReplacementText: String?

    /// Convenience for the common case: pretend `text` is selected.
    ///
    /// The element is a system-wide `AXUIElement` used purely as an opaque
    /// token — nothing in these tests reads through it.
    func stubSelection(_ text: String) {
        selectionResult = .success(SelectionSnapshot(
            element: AXUIElementCreateSystemWide(),
            text: text,
            range: CFRange(location: 0, length: text.utf16.count),
            processIdentifier: 1234,
            bundleIdentifier: "com.apple.TextEdit"
        ))
    }

    func readSelectionResult() -> Result<SelectionSnapshot, SelectionError> {
        readSelectionCallCount += 1
        return selectionResult
    }

    func replaceSelection(_ text: String, replacing snapshot: SelectionSnapshot) -> Result<Void, SelectionError> {
        replaceSelectionCallCount += 1
        lastReplacementText = text
        return replaceSelectionResult
    }
}

// MARK: - MockStatsManager

@MainActor
final class MockStatsManager: StatsManaging, ObservableObject {
    @Published var stats: UserStats = UserStats()

    var recordCallCount = 0
    var resetCallCount = 0

    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    func recordTranscription(_ transcription: VocaTranscription) {
        recordCallCount += 1
    }

    func resetStats() {
        resetCallCount += 1
    }
}

// MARK: - MockHistoryStore

@MainActor
final class MockHistoryStore: HistoryRecording, ObservableObject {
    @Published var records: [HistoryRecord] = []
    var retentionLimit: Int = 0
    var recordCallCount = 0
    var lastRecordedRecord: HistoryRecord?
    var deleteCallCount = 0
    var deleteAllCallCount = 0

    var objectWillChangePublisher: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }

    func record(_ record: HistoryRecord) {
        recordCallCount += 1
        lastRecordedRecord = record
        records.insert(record, at: 0)
    }

    func delete(_ id: UUID) {
        deleteCallCount += 1
        records.removeAll { $0.id == id }
    }

    func deleteAll() {
        deleteAllCallCount += 1
        records.removeAll()
    }

    /// Mirrors `HistoryStore.search` exactly, diacritic folding included
    /// (MINOR 2) — a mock that matches differently from the real store is a
    /// test that proves nothing.
    func search(_ query: String) -> [HistoryRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return records }
        return records.filter {
            $0.rawTranscript.localizedStandardContains(trimmed) ||
            $0.finalText.localizedStandardContains(trimmed)
        }
    }
}

// MARK: - MockPostProcessService

/// Moved here from PostProcessStageTests.swift (MINOR 9 / AD-7) so it can be
/// threaded through `makeTestState` and used to build a real
/// `TranscriptPipeline` for AppState-level seam tests, not just stage-level
/// ones.
final class MockPostProcessService: PostProcessing {
    var cleanResult: Result<String, PostProcessError> = .success("cleaned")
    var testConnectionResult: Result<String, PostProcessError> = .success("mock-model")

    /// Simulates a slow backend: `clean` suspends for this long before
    /// returning `cleanResult`. Used to reproduce the re-entrancy window at
    /// the AppState seam (MAJOR 2) and to prove the seam doesn't block the
    /// main actor while suspended (MINOR 10).
    var cleanDelay: TimeInterval = 0

    var cleanCallCount = 0
    var lastText: String?
    var lastSystemPrompt: String?
    var lastConfiguration: PostProcessConfiguration?
    /// Story 4.4: what the caller passed as Cursor Context, so tests can
    /// assert it reached the service (and, separately, that it never reaches
    /// anything it shouldn't).
    var lastContextBefore: String?
    var lastContextAfter: String?

    func _clean(
        text: String,
        systemPrompt: String,
        contextBefore: String?,
        contextAfter: String?,
        configuration: PostProcessConfiguration
    ) async -> Result<String, PostProcessError> {
        cleanCallCount += 1
        lastText = text
        lastSystemPrompt = systemPrompt
        lastContextBefore = contextBefore
        lastContextAfter = contextAfter
        lastConfiguration = configuration
        if cleanDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(cleanDelay * 1_000_000_000))
        }
        return cleanResult
    }

    // MARK: - Command Mode (Story 6.3)

    var commandResult: Result<String, PostProcessError> = .success("rewritten")

    /// Simulates a slow backend on the command route, so a test can drive the
    /// re-entrancy window the same way `cleanDelay` does for cleanup.
    var commandDelay: TimeInterval = 0

    var commandCallCount = 0
    var lastCommandSelection: String?
    var lastCommandInstruction: String?
    var lastCommandSystemPrompt: String?

    func _command(
        selection: String,
        instruction: String,
        systemPrompt: String,
        configuration: PostProcessConfiguration
    ) async -> Result<String, PostProcessError> {
        commandCallCount += 1
        lastCommandSelection = selection
        lastCommandInstruction = instruction
        lastCommandSystemPrompt = systemPrompt
        lastConfiguration = configuration
        if commandDelay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(commandDelay * 1_000_000_000))
        }
        return commandResult
    }

    func testConnection(configuration: PostProcessConfiguration) async -> Result<String, PostProcessError> {
        testConnectionResult
    }
}

// MARK: - MockContextReader

@MainActor
final class MockContextReader: ContextReading {
    /// What `capture` returns, regardless of what the decision closure
    /// answers — a test that wants to see Cursor Context reach the pipeline
    /// sets this directly rather than relying on the real AX-gating logic.
    var captureResult: CapturedContext = .empty
    var captureCallCount = 0

    /// What the caller's closure answered when asked about
    /// `captureResult.bundleIdentifier` — this is what the toggle-gating
    /// tests actually assert on.
    var lastShouldReadCursorContextAnswer: Bool?

    /// What the caller offered as the target to use when VocaMac itself is
    /// frontmost (MINOR 9).
    var lastFallbackApplication: NSRunningApplication?

    func capture(
        fallbackApplication: NSRunningApplication?,
        shouldReadCursorContext: (String?) -> Bool
    ) -> CapturedContext {
        captureCallCount += 1
        lastFallbackApplication = fallbackApplication
        lastShouldReadCursorContextAnswer = shouldReadCursorContext(captureResult.bundleIdentifier)
        return captureResult
    }

    /// Story 5.6: what `CorrectionLearner`'s re-read sees.
    var readFocusedElementTextResult: String?
    var readFocusedElementTextCallCount = 0
    var lastReadProcessIdentifier: pid_t?

    func readFocusedElementText(processIdentifier: pid_t?) -> String? {
        readFocusedElementTextCallCount += 1
        lastReadProcessIdentifier = processIdentifier
        return readFocusedElementTextResult
    }
}

// MARK: - MockProfileManager

/// Defaults to resolving the Default Profile, mirroring what the real
/// `ProfileManager` always falls back to — the Default Profile's empty
/// prompt override and enabled toggles make `PostProcessStage` behave
/// identically to Epic 2/3 for any test that never overrides
/// `resolvedProfile`.
@MainActor
final class MockProfileManager: ProfileResolving {
    var resolvedProfile: Profile = Profile.makeDefault()
    var resolveCallCount = 0
    var lastBundleIdentifier: String?
    var lastProfilesEnabled: Bool?

    func resolve(bundleIdentifier: String?, profilesEnabled: Bool) -> Profile {
        resolveCallCount += 1
        lastBundleIdentifier = bundleIdentifier
        lastProfilesEnabled = profilesEnabled
        return resolvedProfile
    }
}

// MARK: - MockDictionaryService

/// Identity by default (AD-2): a test that never sets `replaceResult`
/// returns the input text unchanged, matching what an empty/disabled
/// Dictionary does in production.
final class MockDictionaryService: DictionaryProviding {
    var replaceResult: DictionaryReplacementResult?
    var replaceCallCount = 0
    var lastText: String?
    var lastEntries: [DictionaryEntry]?

    func replace(in text: String, using entries: [DictionaryEntry]) -> DictionaryReplacementResult {
        replaceCallCount += 1
        lastText = text
        lastEntries = entries
        return replaceResult ?? DictionaryReplacementResult(text: text, replacementCount: 0)
    }
}

// MARK: - MockSnippetService

/// Identity by default (AD-2): a test that never sets `protectResult`
/// returns the input text unchanged with no protected spans, matching what
/// an empty/disabled Snippet set does in production.
final class MockSnippetService: SnippetProviding {
    var protectResult: SnippetProtectionResult?
    var protectCallCount = 0
    var lastText: String?
    var lastSnippets: [Snippet]?

    func protect(in text: String, using snippets: [Snippet]) -> SnippetProtectionResult {
        protectCallCount += 1
        lastText = text
        lastSnippets = snippets
        return protectResult ?? SnippetProtectionResult(text: text, protectedSpans: [:])
    }
}

// MARK: - MockCorrectionLearner

/// A no-op by default (Story 5.6, AD-2): `observeInjection` just records
/// what it was called with, so a test proves the *seam* (AppState calls it
/// only when the toggle is on, with the right text) without exercising the
/// real AX re-read or timer.
@MainActor
final class MockCorrectionLearner: CorrectionLearning {
    var onCandidateProposed: ((CorrectionCandidate) -> Void)?

    var observeInjectionCallCount = 0
    var lastText: String?
    var lastProcessIdentifier: pid_t?
    /// BLOCKER 1: every abort path must drop a scheduled re-read along with
    /// the captured Cursor Context.
    var cancelPendingObservationCallCount = 0

    func observeInjection(_ text: String, targetProcessIdentifier: pid_t?) {
        observeInjectionCallCount += 1
        lastText = text
        lastProcessIdentifier = targetProcessIdentifier
    }

    func cancelPendingObservation() {
        cancelPendingObservationCallCount += 1
    }
}

// MARK: - MockTranscriptPipeline

/// Identity by default (AD-2): unless a test sets `transform`, it returns its
/// input unchanged, so every existing AppState test keeps its old behavior.
@MainActor
final class MockTranscriptPipeline: TranscriptPipelining {
    var runCallCount = 0
    var lastContext: TranscriptContext?
    var transform: ((String) -> String)?

    /// Extra stage reports to append to the result, so a test can simulate a
    /// named stage (e.g. "PostProcess") having run with a specific outcome
    /// and duration — used by Story 1.3's per-stage latency tests.
    var additionalReports: [StageReport] = []

    func run(_ context: TranscriptContext) async -> TranscriptContext {
        runCallCount += 1
        lastContext = context
        var result = context
        if let transform {
            result.currentText = transform(context.currentText)
            result.reports.append(
                StageReport(stageName: "MockStage", outcome: .applied, duration: 0)
            )
        }
        result.reports.append(contentsOf: additionalReports)
        return result
    }
}

// MARK: - StubTranscriptStage

/// A stage whose answer a test dictates outright, including the "failed"
/// answer used to prove pass-through.
@MainActor
final class StubTranscriptStage: TranscriptStage {
    let name: String
    var result: StageResult
    var runCallCount = 0

    /// The context this stage actually received — e.g. used to prove Cursor
    /// Context (Story 4.4) has already been cleared by the time a stage
    /// after PostProcess runs (AD-5).
    var lastContext: TranscriptContext?

    init(name: String = "Stub", result: StageResult) {
        self.name = name
        self.result = result
    }

    func run(_ context: TranscriptContext) async -> StageResult {
        runCallCount += 1
        lastContext = context
        return result
    }
}

// MARK: - Test Helper

/// One directory per test *process*, holding every throwaway JSON store any
/// test creates, and swept when the process exits (MINOR 12).
///
/// `makeTestState` mints five stores per call and there are hundreds of calls
/// in a run; each used to get its own `FileManager.temporaryDirectory`
/// subdirectory and nothing ever removed any of them, so a test run left a
/// few thousand directories behind in `/var/folders` every time. Keeping the
/// per-call directories (tests must not share a `profiles.json`) but rooting
/// them under one parent makes a single `removeItem` at exit enough.
let vocaMacTestStorageRoot: URL = FileManager.default.temporaryDirectory
    .appendingPathComponent("vocamac_tests_\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

/// Registering the sweep is a side effect of first use. The closure captures
/// nothing — it reads the global above — which is what lets it be passed to
/// `atexit`'s C function pointer at all.
private let vocaMacTestStorageCleanupRegistered: Bool = {
    atexit {
        try? FileManager.default.removeItem(at: vocaMacTestStorageRoot)
    }
    return true
}()

/// A fresh, uniquely-named directory under the swept root.
func makeTestStorageDirectory(_ name: String) -> URL {
    _ = vocaMacTestStorageCleanupRegistered
    return vocaMacTestStorageRoot.appendingPathComponent("\(name)_\(UUID().uuidString)", isDirectory: true)
}

extension AppState {
    @MainActor
    static func makeTestState(
        modelManager: MockModelManager = MockModelManager(),
        whisperService: MockWhisperService = MockWhisperService(),
        postProcessService: MockPostProcessService = MockPostProcessService(),
        /// When supplied, wired into AppState as the real `transcriptPipeline`
        /// instead of the `MockTranscriptPipeline` below — e.g. a real
        /// `TranscriptPipeline(stages: [PostProcessStage(service:
        /// postProcessService, ...)])` for a test that needs the actual seam
        /// behavior. `mocks.transcriptPipeline` is still created either way,
        /// for tests that don't need this and read/configure it directly.
        transcriptPipelineOverride: TranscriptPipelining? = nil,
        /// The collaborators below are all `@MainActor`-isolated, so their
        /// construction cannot sit in a default-argument expression: default
        /// arguments are evaluated in the *caller's* (nonisolated) context,
        /// which Swift 6 rejects with `#ActorIsolatedCall`. They default to
        /// `nil` and are materialized inside this `@MainActor` body instead;
        /// call sites that pass a value are unaffected.
        contextReader: MockContextReader? = nil,
        profileManager: MockProfileManager? = nil,
        profileStore: ProfileStore? = nil,
        dictionaryStore: DictionaryStore? = nil,
        snippetStore: SnippetStore? = nil,
        correctionLearner: MockCorrectionLearner? = nil,
        dismissedCorrectionsStore: DismissedCorrectionsStore? = nil,
        /// Keeps whatever silence-detection preferences the test seeded into
        /// VocaDefaults instead of clearing them — for the tests that exercise
        /// AppState's own init-time VAD migration. Such a test owns cleaning
        /// those keys up again.
        preserveSilenceDetectionDefaults: Bool = false
    ) -> (appState: AppState, mocks: TestMocks) {
        let contextReader = contextReader ?? MockContextReader()
        let profileManager = profileManager ?? MockProfileManager()
        let profileStore = profileStore ?? ProfileStore(store: JSONFileStore(
            fileName: "profiles.json",
            defaultValue: [],
            directoryURL: makeTestStorageDirectory("profiles")
        ))
        let dictionaryStore = dictionaryStore ?? DictionaryStore(store: JSONFileStore(
            fileName: "dictionary.json",
            defaultValue: [],
            directoryURL: makeTestStorageDirectory("dictionary")
        ))
        let snippetStore = snippetStore ?? SnippetStore(store: JSONFileStore(
            fileName: "snippets.json",
            defaultValue: [],
            directoryURL: makeTestStorageDirectory("snippets")
        ))
        let correctionLearner = correctionLearner ?? MockCorrectionLearner()
        let dismissedCorrectionsStore = dismissedCorrectionsStore ?? DismissedCorrectionsStore(
            store: JSONFileStore(
                fileName: "dismissed-corrections.json",
                defaultValue: [],
                directoryURL: makeTestStorageDirectory("dismissed_corrections")
            )
        )

        // AppState.hasPerformedStartupGlobally is a process-level static that
        // performStartup() only ever flips true. Reset it here (rather than
        // per-test-class setUp) so every test built through makeTestState —
        // across all test files — gets a fresh startup run.
        AppState.hasPerformedStartupGlobally = false
        VocaDefaults.store.removeObject(forKey: "vocamac.selectedAudioDeviceID")
        VocaDefaults.store.removeObject(forKey: "vocamac.selectedAudioDeviceName")
        // Silence-detection preferences (Story 7.1). @AppStorage writes these
        // into the one process-wide VocaDefaults suite, so a test that sets
        // them would otherwise leak into every later test in the process —
        // and into AppState's own first-launch VAD migration, which reads
        // them during init below.
        if !preserveSilenceDetectionDefaults {
            VocaDefaults.store.removeObject(forKey: "vocamac.silenceThreshold")
            VocaDefaults.store.removeObject(forKey: "vocamac.vadDetectorKind")
            VocaDefaults.store.removeObject(forKey: "vocamac.vadEnergyThreshold")
            VocaDefaults.store.removeObject(forKey: "vocamac.vadKeptLegacyForTunedThreshold")
            VocaDefaults.store.removeObject(forKey: "vocamac.vadDetectorMigrationCompleted")
        }

        let audioEngine = MockAudioEngine()
        let soundManager = MockSoundManager()
        let hotKeyManager = MockHotKeyManager()
        let permissionManager = MockPermissionManager()
        let cursorOverlay = MockCursorOverlay()
        let textInjector = MockTextInjector()
        let statsManager = MockStatsManager()
        let historyStore = MockHistoryStore()
        let transcriptPipeline = MockTranscriptPipeline()

        let mocks = TestMocks(
            audioEngine: audioEngine,
            soundManager: soundManager,
            hotKeyManager: hotKeyManager,
            permissionManager: permissionManager,
            cursorOverlay: cursorOverlay,
            modelManager: modelManager,
            whisperService: whisperService,
            textInjector: textInjector,
            statsManager: statsManager,
            historyStore: historyStore,
            transcriptPipeline: transcriptPipeline,
            postProcessService: postProcessService,
            contextReader: contextReader,
            profileManager: profileManager,
            correctionLearner: correctionLearner
        )
        let appState = AppState(
            audioEngine: audioEngine,
            whisperService: whisperService,
            textInjector: textInjector,
            hotKeyManager: hotKeyManager,
            modelManager: modelManager,
            soundManager: soundManager,
            cursorOverlay: cursorOverlay,
            statsManager: statsManager,
            historyStore: historyStore,
            transcriptPipeline: transcriptPipelineOverride ?? transcriptPipeline,
            axContextReader: contextReader,
            profileManager: profileManager,
            profileStore: profileStore,
            dictionaryStore: dictionaryStore,
            snippetStore: snippetStore,
            correctionLearner: correctionLearner,
            dismissedCorrectionsStore: dismissedCorrectionsStore,
            postProcessService: postProcessService,
            permissionManager: permissionManager,
            skipSystemIntegration: true
        )
        return (appState, mocks)
    }
}

struct TestMocks {
    let audioEngine: MockAudioEngine
    let soundManager: MockSoundManager
    let hotKeyManager: MockHotKeyManager
    let permissionManager: MockPermissionManager
    let cursorOverlay: MockCursorOverlay
    let modelManager: MockModelManager
    let whisperService: MockWhisperService
    let textInjector: MockTextInjector
    let statsManager: MockStatsManager
    let historyStore: MockHistoryStore
    let transcriptPipeline: MockTranscriptPipeline
    let postProcessService: MockPostProcessService
    let contextReader: MockContextReader
    let profileManager: MockProfileManager
    let correctionLearner: MockCorrectionLearner
}
