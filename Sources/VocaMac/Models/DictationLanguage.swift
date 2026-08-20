// DictationLanguage.swift
// VocaMac
//
// The one list of dictation languages (Story 8.2 / MAJOR 2).
//
// There used to be two: nineteen `Text(...).tag(...)` rows in
// `SettingsView`'s Language picker, and three in `MenuBarView`'s segmented
// quick toggle. Both wrote the same `vocamac.selectedLanguage` key, so
// picking any of the sixteen languages only Settings knew about left the
// menu-bar control with a selection it could not represent: no segment
// highlighted, a SwiftUI runtime warning, and touching any segment silently
// discarded the user's choice. A shared list plus an explicit
// `quickToggleCodes` subset is what stops the two drifting again.

import Foundation

enum DictationLanguage {

    /// Everything `vocamac.selectedLanguage` may legitimately hold, in the
    /// order Settings offers it. `"auto"` is a real stored value, not the
    /// absence of one — it means "let WhisperKit detect".
    struct Choice: Identifiable, Equatable {
        let code: String
        let name: String
        var id: String { code }
    }

    static let auto = Choice(code: "auto", name: "Auto-detect")

    /// The two languages this fork is actually used in day to day, and the
    /// only ones with a hand-tuned post-processing prompt (see `Prompts`).
    static let primary: [Choice] = [
        Choice(code: "en", name: "English"),
        Choice(code: "he", name: "Hebrew")
    ]

    static let secondary: [Choice] = [
        Choice(code: "es", name: "Spanish"),
        Choice(code: "fr", name: "French"),
        Choice(code: "de", name: "German"),
        Choice(code: "it", name: "Italian"),
        Choice(code: "pt", name: "Portuguese"),
        Choice(code: "nl", name: "Dutch")
    ]

    static let additional: [Choice] = [
        Choice(code: "zh", name: "Chinese"),
        Choice(code: "ja", name: "Japanese"),
        Choice(code: "ko", name: "Korean"),
        Choice(code: "hi", name: "Hindi"),
        Choice(code: "ar", name: "Arabic"),
        Choice(code: "ru", name: "Russian"),
        Choice(code: "tr", name: "Turkish"),
        Choice(code: "pl", name: "Polish"),
        Choice(code: "sv", name: "Swedish"),
        Choice(code: "uk", name: "Ukrainian")
    ]

    /// All nineteen, `auto` first — the exact set Settings writes.
    static let all: [Choice] = [auto] + primary + secondary + additional

    /// The codes the menu bar's segmented control can show. Anything else has
    /// to be rendered as a label instead (MAJOR 2): a segmented picker with a
    /// selection outside its own tags has no valid state to be in.
    static let quickToggleCodes: Set<String> = ["he", "en", "auto"]

    static func canQuickToggle(_ code: String) -> Bool {
        quickToggleCodes.contains(code)
    }

    /// Human-readable name for a stored or ASR-reported code, falling back to
    /// the code itself uppercased so an unknown value still reads as something
    /// deliberate rather than as blank space.
    ///
    /// Case-insensitive because the two sources disagree: the picker stores
    /// lowercase codes, while WhisperKit's `detectedLanguage` has been seen to
    /// report other casings.
    static func displayName(for code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let normalized = code.lowercased()
        if let match = all.first(where: { $0.code == normalized }) {
            return match.name
        }
        // Deprecated ISO code for Hebrew; some detectors still emit it.
        if normalized == "iw" { return "Hebrew" }
        return code.uppercased()
    }
}
