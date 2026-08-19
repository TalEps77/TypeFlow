// TranscriptStage.swift
// VocaMac
//
// The stage protocol and the outcome vocabulary every stage reports in.
//
// AD-2: a stage that is disabled, errors, times out, or produces output that
// fails its own validity check returns its input unchanged. Stages never throw
// out of `run` — `run` is not marked `throws`, so the compiler enforces it.

import Foundation

/// What a stage did. Only `.applied` lets the stage's text through; for every
/// other case the pipeline keeps the text it had (AD-2).
enum StageOutcome: Equatable {
    /// The stage ran and its text is adopted.
    case applied
    /// The stage declined to run — disabled, or nothing to work on.
    case skipped(reason: String)
    /// The stage tried and failed. The input is passed through untouched.
    case failed(reason: String)

    /// Human-readable reason, for logs and History Records.
    var reason: String {
        switch self {
        case .applied:                 return "applied"
        case .skipped(let reason):     return reason
        case .failed(let reason):      return reason
        }
    }

    var didChangeText: Bool {
        if case .applied = self { return true }
        return false
    }
}

/// What a stage hands back: the text it would like to install, and why.
struct StageResult: Equatable {
    let text: String
    let outcome: StageOutcome

    /// Convenience for the overwhelmingly common "leave it alone" answer.
    static func unchanged(_ text: String, outcome: StageOutcome) -> StageResult {
        StageResult(text: text, outcome: outcome)
    }
}

/// One stage's record on the context: what ran, how it went, how long it took.
struct StageReport: Equatable {
    let stageName: String
    let outcome: StageOutcome
    let duration: TimeInterval
}

/// One link in the pipes-and-filters chain.
///
/// `run` cannot throw. A stage that fails catches internally and returns a
/// `.failed` outcome carrying its input text; the pipeline then keeps the text
/// it already had, so a broken stage is indistinguishable from an absent one.
@MainActor
protocol TranscriptStage: AnyObject {
    /// Stable identifier used in logs and stage reports.
    var name: String { get }

    func run(_ context: TranscriptContext) async -> StageResult
}
