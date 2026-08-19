// TranscriptPipeline.swift
// VocaMac
//
// The ordered runner that sits between transcription and injection (AD-1).
// It is the only writer of TranscriptContext, which is what makes the identity
// guarantee (AD-2, AD-13) enforceable here rather than in every stage.

import Foundation

@MainActor
final class TranscriptPipeline: TranscriptPipelining {

    /// Stage order is fixed by AD-3: Dictionary -> Snippet-protect ->
    /// PostProcess -> Snippet-rehydrate. Stages are added epic by epic.
    private let stages: [TranscriptStage]

    init(stages: [TranscriptStage] = []) {
        self.stages = stages
    }

    /// The pipeline as the shipping app assembles it. Every stage in here is
    /// inert until its own setting is turned on, so this is still an identity
    /// pipeline for a user who has changed nothing.
    static func production() -> TranscriptPipeline {
        TranscriptPipeline(stages: [
            PostProcessStage()
        ])
    }

    func run(_ context: TranscriptContext) async -> TranscriptContext {
        var context = context

        for stage in stages {
            let startedAt = CFAbsoluteTimeGetCurrent()
            let result = await stage.run(context)
            let duration = CFAbsoluteTimeGetCurrent() - startedAt

            // AD-2: only an `.applied` outcome may change the text. A skipped or
            // failed stage cannot alter the transcript even if it returns
            // something in `result.text`. Nor can an `.applied` outcome that
            // trims to blank — the runner is the sole enforcer of AD-2, so a
            // stage claiming success with nothing in it must not clobber
            // whatever the pipeline already had (MINOR 7).
            if result.outcome.didChangeText,
               !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                context.currentText = result.text
            }

            context.reports.append(
                StageReport(
                    stageName: stage.name,
                    outcome: result.outcome,
                    duration: duration,
                    didRun: result.didRun
                )
            )

            // AD-5: Cursor Context is read once, used once, by the one stage
            // that consumes it, and released immediately after — never held
            // any longer than this one request needs it for, regardless of
            // how the stage's own attempt went (success, failure, or
            // disabled). `TranscriptPipeline` is the sole writer of
            // `TranscriptContext`, which is what makes clearing it here —
            // rather than trusting every current and future stage to do it
            // — the one place this is enforced.
            if stage.name == PostProcessStage.stageName {
                context.cursorContextBefore = nil
                context.cursorContextAfter = nil
            }

            if case .failed(let reason) = result.outcome {
                VocaLogger.warning(.pipeline, "\(stage.name) failed — passing text through unchanged: \(reason)")
            }
        }

        return context
    }
}
