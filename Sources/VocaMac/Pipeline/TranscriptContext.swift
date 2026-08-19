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

    /// Placeholder token -> the original text it stands in for, for stages that
    /// hide spans from the LLM and restore them afterwards (AD-3).
    var protectedSpans: [String: String]

    /// One entry per stage that ran, in order.
    var reports: [StageReport]

    init(
        rawTranscript: String,
        targetBundleIdentifier: String? = nil
    ) {
        self.rawTranscript = rawTranscript
        self.currentText = rawTranscript
        self.targetBundleIdentifier = targetBundleIdentifier
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
