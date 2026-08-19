// SnippetSettings.swift
// VocaMac
//
// The Snippet stage's one scalar setting, read straight from UserDefaults
// (AD-9) — the same `vocamac.snippets.enabled` key is bound with
// @AppStorage on AppState for the settings UI. Snippets themselves are a
// collection and live in SnippetStore's JSON file instead (AD-10).

import Foundation

struct SnippetSettings: Equatable {

    enum Key {
        static let enabled = "vocamac.snippets.enabled"
    }

    enum Default {
        /// Ships on: with no Snippets yet defined, SnippetStage has nothing
        /// to match and is already an identity operation (AD-2).
        static let enabled = true
    }

    var isEnabled: Bool

    init(isEnabled: Bool = Default.enabled) {
        self.isEnabled = isEnabled
    }

    static func current(from defaults: UserDefaults = .standard) -> SnippetSettings {
        guard defaults.object(forKey: Key.enabled) != nil else {
            return SnippetSettings(isEnabled: Default.enabled)
        }
        return SnippetSettings(isEnabled: defaults.bool(forKey: Key.enabled))
    }
}
