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

    /// Whether the stage actually did its work before answering.
    ///
    /// `.skipped` alone cannot tell the two apart: a stage that declined
    /// because it is switched off costs microseconds, while a stage that
    /// called the LLM and got back text identical to its input also reports
    /// `.skipped` — after a real, multi-second round trip. Only the latter's
    /// duration means anything to a reader (MAJOR 6).
    let didRun: Bool

    /// Placeholder token -> original text, for a stage that hides spans from
    /// the LLM (Story 5.4, AD-3). Empty for every stage except `SnippetStage`.
    /// `TranscriptPipeline` — the sole writer of `TranscriptContext` — merges
    /// this into `context.protectedSpans` so a later stage (`RehydrateStage`)
    /// can read the mapping back off the context it receives.
    let protectedSpans: [String: String]

    /// Whether the stage adopted a fallback instead of the result it was
    /// working towards — it produced usable text, so the outcome is still
    /// `.applied`, but something the user might want to know about went wrong
    /// getting there.
    ///
    /// `RehydrateStage` is the case this exists for (MAJOR 4): when the LLM
    /// drops a placeholder it throws the *entire* post-processing result away
    /// and rehydrates the pre-LLM snapshot instead. That is exactly the
    /// "cleanup was discarded" event `HistoryRecord.didFallback` is meant to
    /// surface, yet it reported plain `.applied` — so History showed a full
    /// post-processing round trip that had in fact been discarded, with no
    /// indication anywhere. `.failed` cannot express it either: the pipeline
    /// would then keep the text it had, which is the text *still full of
    /// placeholders*.
    let usedFallback: Bool

    init(
        text: String,
        outcome: StageOutcome,
        didRun: Bool = true,
        protectedSpans: [String: String] = [:],
        usedFallback: Bool = false
    ) {
        self.text = text
        self.outcome = outcome
        self.didRun = didRun
        self.protectedSpans = protectedSpans
        self.usedFallback = usedFallback
    }

    /// Convenience for the overwhelmingly common "leave it alone" answer.
    static func unchanged(_ text: String, outcome: StageOutcome) -> StageResult {
        StageResult(text: text, outcome: outcome)
    }

    /// A stage declining before it did any work at all — disabled, or handed
    /// nothing to work on. Its duration is measurement noise, not latency.
    static func declined(_ text: String, reason: String) -> StageResult {
        StageResult(text: text, outcome: .skipped(reason: reason), didRun: false)
    }
}

/// One stage's record on the context: what ran, how it went, how long it took.
struct StageReport: Equatable {
    let stageName: String
    let outcome: StageOutcome
    let duration: TimeInterval

    /// Mirrors `StageResult.didRun`. `duration` is only meaningful when true.
    let didRun: Bool

    init(stageName: String, outcome: StageOutcome, duration: TimeInterval, didRun: Bool = true) {
        self.stageName = stageName
        self.outcome = outcome
        self.duration = duration
        self.didRun = didRun
    }
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
