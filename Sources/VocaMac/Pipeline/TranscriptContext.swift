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

    /// One entry per stage that ran, in order.
    var reports: [StageReport]

    init(
        rawTranscript: String,
        targetBundleIdentifier: String? = nil,
        resolvedProfile: Profile? = nil,
        cursorContextBefore: String? = nil,
        cursorContextAfter: String? = nil
    ) {
        self.rawTranscript = rawTranscript
        self.currentText = rawTranscript
        self.targetBundleIdentifier = targetBundleIdentifier
        self.resolvedProfile = resolvedProfile
        self.cursorContextBefore = cursorContextBefore
        self.cursorContextAfter = cursorContextAfter
        self.protectedSpans = [:]
        self.reports = []
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
