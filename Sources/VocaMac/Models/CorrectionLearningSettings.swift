// CorrectionLearningSettings.swift
// VocaMac
//
// Correction learning's one scalar setting, read straight from UserDefaults
// (AD-9) — the same `vocamac.correctionLearning.enabled` key is bound with
// @AppStorage on AppState for the settings UI. Decoupled from AppState so
// CorrectionLearner (a plain collaborator, not a view) never needs a live
// reference to it — the same reason PostProcessStage reads
// PostProcessSettings.current() instead of taking AppState directly.

import Foundation

struct CorrectionLearningSettings: Equatable {

    enum Key {
        static let enabled = "vocamac.correctionLearning.enabled"
    }

    enum Default {
        /// Ships off (Story 5.6 AC, architecture "Feature flags" table,
        /// R-6): re-reading and diffing a text field the user is actively
        /// editing is the kind of feature that can only earn trust opt-in —
        /// "shipping it loud is not an option" (PRD §9.3).
        static let enabled = false
    }

    var isEnabled: Bool

    init(isEnabled: Bool = Default.enabled) {
        self.isEnabled = isEnabled
    }

    static func current(from defaults: UserDefaults = VocaDefaults.store) -> CorrectionLearningSettings {
        guard defaults.object(forKey: Key.enabled) != nil else {
            return CorrectionLearningSettings(isEnabled: Default.enabled)
        }
        return CorrectionLearningSettings(isEnabled: defaults.bool(forKey: Key.enabled))
    }
}
