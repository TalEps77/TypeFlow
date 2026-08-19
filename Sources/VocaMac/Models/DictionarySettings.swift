// DictionarySettings.swift
// VocaMac
//
// The Dictionary's one scalar setting, read straight from UserDefaults
// (AD-9) — the same `vocamac.dictionary.enabled` key is bound with
// @AppStorage on AppState for the settings UI. The entries themselves are a
// collection and live in DictionaryStore's JSON file instead (AD-10).

import Foundation

struct DictionarySettings: Equatable {

    enum Key {
        static let enabled = "vocamac.dictionary.enabled"
    }

    enum Default {
        /// Ships on: a conservative, deterministic text fix carries none of
        /// post-processing's latency or LLM-availability risk, and with no
        /// entries yet added the stage is already an identity operation
        /// (AD-2) — there is nothing for an unconfigured install to notice.
        static let enabled = true
    }

    var isEnabled: Bool

    init(isEnabled: Bool = Default.enabled) {
        self.isEnabled = isEnabled
    }

    static func current(from defaults: UserDefaults = .standard) -> DictionarySettings {
        guard defaults.object(forKey: Key.enabled) != nil else {
            return DictionarySettings(isEnabled: Default.enabled)
        }
        return DictionarySettings(isEnabled: defaults.bool(forKey: Key.enabled))
    }
}
