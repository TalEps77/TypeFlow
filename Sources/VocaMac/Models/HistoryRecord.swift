// HistoryRecord.swift
// VocaMac
//
// One completed dictation (or, from Epic 6 onward, Command Mode operation),
// persisted locally via HistoryStore (AD-10).
//
// AD-5 as a schema constraint: Cursor Context is read once at recording start
// and must never be persisted. There is deliberately no field here capable of
// holding it — not a String, not an Optional, nothing. Only the bundle
// identifier and the resolved Profile *name* are kept.

import Foundation

struct HistoryRecord: Codable, Identifiable, Equatable {

    /// Distinguishes a Command Mode rewrite from a normal dictation (FR-21).
    /// Command Mode does not exist yet (Epic 6) — every record today is `.dictation`.
    enum Mode: String, Codable, Equatable {
        case dictation
        case command
    }

    let id: UUID
    let timestamp: Date

    /// Exactly what left the ASR stage, before any pipeline transformation.
    let rawTranscript: String

    /// What was actually injected — identical to `rawTranscript` unless a
    /// pipeline stage changed it.
    let finalText: String

    /// Bundle identifier of the app that was frontmost when recording started.
    /// `nil` until Epic 4 (Story 4.1) starts populating it.
    let targetBundleId: String?

    /// Name of the Profile that was resolved for this dictation.
    /// `nil` until Epic 4 (Story 4.2) starts populating it.
    let profileName: String?

    /// Display name of the ASR model used for this dictation.
    let modelName: String

    /// Recording duration in milliseconds. Zero until Story 1.3 instruments it.
    let recordingMillis: Double

    /// ASR (transcription) duration in milliseconds. Zero until Story 1.3
    /// instruments it.
    let asrMillis: Double

    /// Post-processing (LLM) duration in milliseconds. Zero when
    /// post-processing did not run, per Story 1.3's AC.
    let postProcessMillis: Double

    /// True if any pipeline stage fell back to identity (AD-2) — e.g. the LLM
    /// was unreachable, timed out, or returned an invalid response.
    let didFallback: Bool

    let mode: Mode

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        rawTranscript: String,
        finalText: String,
        targetBundleId: String? = nil,
        profileName: String? = nil,
        modelName: String,
        recordingMillis: Double = 0,
        asrMillis: Double = 0,
        postProcessMillis: Double = 0,
        didFallback: Bool = false,
        mode: Mode = .dictation
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawTranscript = rawTranscript
        self.finalText = finalText
        self.targetBundleId = targetBundleId
        self.profileName = profileName
        self.modelName = modelName
        self.recordingMillis = recordingMillis
        self.asrMillis = asrMillis
        self.postProcessMillis = postProcessMillis
        self.didFallback = didFallback
        self.mode = mode
    }

    /// Short preview for list rows — collapses newlines so multi-line
    /// dictations still read as one line in the history list.
    var preview: String {
        let collapsed = finalText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed
    }
}
