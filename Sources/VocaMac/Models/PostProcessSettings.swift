// PostProcessSettings.swift
// VocaMac
//
// The post-processing settings, read straight from UserDefaults.
//
// The same `vocamac.postProcess.*` keys are bound with @AppStorage on AppState
// for the settings UI (AD-9). This type is how the pipeline stage reads them,
// so no service has to depend on AppState.

import Foundation

struct PostProcessSettings: Equatable {

    // MARK: - Keys

    enum Key {
        static let enabled = "vocamac.postProcess.enabled"
        static let baseURL = "vocamac.postProcess.baseURL"
        static let model = "vocamac.postProcess.model"
        static let timeout = "vocamac.postProcess.timeout"
        static let temperature = "vocamac.postProcess.temperature"
        static let systemPrompt = "vocamac.postProcess.systemPrompt"
    }

    // MARK: - Defaults

    enum Default {
        /// Ships off. Post-processing is opt-in — a user who never opens the
        /// tab never makes a network call and never sees a changed transcript.
        static let enabled = false
        static let baseURL = "http://localhost:1234"
        static let model = "qwen3-4b-instruct-2507-mlx"
        /// Low single-digit seconds: dictation must not wait on the LLM.
        static let timeout: Double = 5.0
        static let temperature: Double = 0.0
        static var systemPrompt: String { Prompts.cleanTranscriptSystemPrompt }
    }

    // MARK: - Values

    var isEnabled: Bool
    var baseURL: String
    var model: String
    var timeout: TimeInterval
    var temperature: Double
    var systemPrompt: String

    init(
        isEnabled: Bool = Default.enabled,
        baseURL: String = Default.baseURL,
        model: String = Default.model,
        timeout: TimeInterval = Default.timeout,
        temperature: Double = Default.temperature,
        systemPrompt: String = Default.systemPrompt
    ) {
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.temperature = temperature
        self.systemPrompt = systemPrompt
    }

    /// Reads the current values. An absent or empty stored value falls back to
    /// the default, so a half-written defaults domain cannot produce a request
    /// with an empty model or a zero timeout.
    static func current(from defaults: UserDefaults = .standard) -> PostProcessSettings {
        func string(_ key: String, _ fallback: String) -> String {
            let stored = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (stored?.isEmpty == false) ? stored! : fallback
        }

        let storedTimeout = defaults.object(forKey: Key.timeout) as? Double
        let storedTemperature = defaults.object(forKey: Key.temperature) as? Double

        return PostProcessSettings(
            isEnabled: defaults.bool(forKey: Key.enabled),
            baseURL: string(Key.baseURL, Default.baseURL),
            model: string(Key.model, Default.model),
            timeout: (storedTimeout.map { $0 > 0 } == true) ? storedTimeout! : Default.timeout,
            temperature: storedTemperature ?? Default.temperature,
            systemPrompt: string(Key.systemPrompt, Default.systemPrompt)
        )
    }

    /// The subset the HTTP client needs.
    var configuration: PostProcessConfiguration {
        PostProcessConfiguration(
            baseURL: baseURL,
            model: model,
            timeout: timeout,
            temperature: temperature
        )
    }
}

/// What one request needs to know. Passed per call rather than held on the
/// service, so a settings change takes effect on the very next dictation.
struct PostProcessConfiguration: Equatable {
    var baseURL: String
    var model: String
    var timeout: TimeInterval
    var temperature: Double

    init(
        baseURL: String = PostProcessSettings.Default.baseURL,
        model: String = PostProcessSettings.Default.model,
        timeout: TimeInterval = PostProcessSettings.Default.timeout,
        temperature: Double = PostProcessSettings.Default.temperature
    ) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.temperature = temperature
    }
}
