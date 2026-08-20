// TranscriptContext.swift
// VocaMac
//
// The value carried through the transcript pipeline (AD-1).
// A struct on purpose: stages receive it by value, so there is nothing
// shared and nothing to race on.

import Foundation

/// Everything one pipeline run needs to know, plus what it learned along the way.
struct TranscriptContext {

    /// The transcript exactly as it left the ASR stage, trimmed. Never mutated —
    /// this is what gets injected if every stage declines to change the text,
    /// and what a History Record keeps alongside the final text.
    let rawTranscript: String

    /// The text as it stands after the stages that have run so far.
    /// The last value of this is what gets injected.
    var currentText: String

    /// Bundle identifier of the app that was frontmost when recording started.
    /// Populated from Epic 4 onwards; `nil` until then.
    let targetBundleIdentifier: String?

    /// The Profile resolved from `targetBundleIdentifier` at recording start
    /// (Story 4.2). `nil` until Epic 4; `PostProcessStage` treats a `nil`
    /// Profile the same as one with every toggle on and no prompt override,
    /// so existing callers that never pass this keep Epic 2/3's behavior.
    let resolvedProfile: Profile?

    /// The language this dictation is in, as an ISO code ("he", "en", …), or
    /// `nil` when it could not be resolved (Story 8.2 / MAJOR 1).
    ///
    /// Resolution order, decided by the caller: the language the user asked
    /// for wins whenever they asked for one — a Profile override first, then
    /// the app-wide toggle — and ASR's `detectedLanguage` only fills in for
    /// Auto. That order matters because detection is unreliable enough that an
    /// English-forced dictation was being reported as Hebrew (MEDIUM 1).
    ///
    /// Used for `HistoryRecord.language` and the glossary gate (`AppState`),
    /// where requested-wins-over-detected is the correct precedence.
    /// `PostProcessStage` does *not* read this to pick the cleanup prompt
    /// variant — see `scriptLanguage(of:)` below for why.
    let language: String?

    /// Text immediately before/after the caret, read via Accessibility at
    /// recording start when both the global and Profile toggles allow it
    /// (Story 4.4). `var`, not `let`: AD-5 requires this to be dropped as
    /// soon as the one stage that consumes it has run, and `TranscriptPipeline`
    /// — the sole writer of this type — is what clears it (see there).
    /// **Never** read this into `HistoryRecord` or `VocaLogger`, at any level.
    var cursorContextBefore: String?
    var cursorContextAfter: String?

    /// Placeholder token -> the original text it stands in for, for stages that
    /// hide spans from the LLM and restore them afterwards (AD-3).
    var protectedSpans: [String: String]

    /// A snapshot of `currentText` taken right after `SnippetStage` runs, so
    /// `RehydrateStage` has something to fall back to if post-processing
    /// drops or alters a placeholder (Story 5.4 AC): every placeholder is
    /// guaranteed to still be intact here, since it is the text as it stood
    /// the moment before the LLM ever saw it. `nil` until `SnippetStage` runs
    /// (which `TranscriptPipeline` — the sole writer of this type — sets).
    var textBeforePostProcess: String?

    /// One entry per stage that ran, in order.
    var reports: [StageReport]

    /// True when this run had to fall back on something — a stage failed and
    /// its work was discarded, a stage adopted a fallback of its own
    /// (`StageResult.usedFallback`), or the runner's own placeholder guard
    /// fired. `HistoryRecord.didFallback` is written from this.
    ///
    /// `var`, and written only by `TranscriptPipeline` — the sole writer of
    /// this type — for the same reason the reports are: deriving it in
    /// `AppState` from outcomes alone missed every fallback that legitimately
    /// reports `.applied` (MAJOR 4).
    var didFallback: Bool

    init(
        rawTranscript: String,
        targetBundleIdentifier: String? = nil,
        resolvedProfile: Profile? = nil,
        language: String? = nil,
        cursorContextBefore: String? = nil,
        cursorContextAfter: String? = nil
    ) {
        self.rawTranscript = rawTranscript
        self.currentText = rawTranscript
        self.targetBundleIdentifier = targetBundleIdentifier
        self.resolvedProfile = resolvedProfile
        self.language = language
        self.cursorContextBefore = cursorContextBefore
        self.cursorContextAfter = cursorContextAfter
        self.protectedSpans = [:]
        self.textBeforePostProcess = nil
        self.reports = []
        self.didFallback = false
    }

    /// Total time spent inside stages for this run.
    var totalStageDuration: TimeInterval {
        reports.reduce(0) { $0 + $1.duration }
    }

    /// True when no stage changed the text — the identity case (AD-2).
    var isUnchanged: Bool {
        currentText == rawTranscript
    }
}

extension TranscriptContext {

    /// A rough guess at which language a piece of text is actually written
    /// in, judged purely from its script — never from `language` above, and
    /// never from what the user selected in the toggle.
    ///
    /// `PostProcessStage` uses this instead of `language` to pick the
    /// cleanup prompt variant. `language` is requested-wins-over-detected,
    /// which is correct for `HistoryRecord` and the glossary gate, but wrong
    /// here: a user who selects English and then dictates in Hebrew has
    /// Whisper correctly transcribe Hebrew text, and running the *English*
    /// cleanup prompt on it — wrong self-correction markers, wrong few-shot
    /// examples — undoes exactly what the toggle was supposed to help with.
    /// Deriving the prompt language from the transcript itself sidesteps the
    /// toggle entirely for this one decision.
    ///
    /// Counts letters in the Hebrew Unicode block (U+0590–U+05FF) against
    /// every letter seen; "he" once they are more than 30% of the letters,
    /// "en" otherwise — including text with no letters at all (numbers only,
    /// empty), which has nothing Hebrew to detect and falls back to the same
    /// default `Prompts.cleanTranscriptSystemPrompt(for:)` already uses for
    /// "not Hebrew".
    static func scriptLanguage(of text: String) -> String {
        var hebrewLetters = 0
        var totalLetters = 0

        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            totalLetters += 1
            if (0x0590...0x05FF).contains(scalar.value) {
                hebrewLetters += 1
            }
        }

        guard totalLetters > 0 else { return "en" }
        return Double(hebrewLetters) / Double(totalLetters) > 0.3 ? "he" : "en"
    }
}
