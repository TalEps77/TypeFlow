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
    /// inert until its own setting is turned on (or, for Dictionary/Snippets,
    /// until entries/Snippets exist), so this is still an identity pipeline
    /// for a user who has changed nothing.
    ///
    /// Order is fixed by AD-3: Dictionary repairs ASR errors first; Snippet
    /// protection replaces each matched Cue with an opaque placeholder before
    /// PostProcess's LLM ever sees the text; Rehydrate substitutes the real
    /// bodies back in afterwards, regardless of whether PostProcess is on.
    static func production(dictionaryStore: DictionaryStore, snippetStore: SnippetStore) -> TranscriptPipeline {
        TranscriptPipeline(stages: [
            DictionaryStage(entriesProvider: { dictionaryStore.entries }),
            SnippetStage(snippetsProvider: { snippetStore.snippets }),
            PostProcessStage(),
            RehydrateStage()
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

            // Story 5.4/AD-3: fold in whatever placeholder mapping this stage
            // produced (only ever non-empty for SnippetStage) so a later
            // stage — RehydrateStage — can read it back off the context.
            if !result.protectedSpans.isEmpty {
                context.protectedSpans.merge(result.protectedSpans) { _, new in new }
            }

            // Snapshot the text as it stands right after Snippet protection —
            // guaranteed to still have every placeholder intact — so
            // RehydrateStage has something safe to fall back to if
            // PostProcess's LLM drops or alters one (Story 5.4 AC).
            if stage.name == SnippetStage.stageName {
                context.textBeforePostProcess = context.currentText
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

        // AD-5 again, now unconditionally. The clear inside the loop fires as
        // soon as the one consuming stage has run, which is what keeps every
        // *later* stage from seeing Cursor Context; this one covers the case
        // the loop cannot — a pipeline with no `PostProcessStage` in it at
        // all, whether because post-processing was compiled out of a test's
        // stage list or because a future assembly drops it. Without it that
        // pipeline hands the context straight back to `AppState`, still
        // populated, inside the returned value (MINOR 1). Clearing twice
        // costs nothing and makes the guarantee a property of the runner
        // rather than of the stage list it happens to be given.
        context.cursorContextBefore = nil
        context.cursorContextAfter = nil

        return context
    }
}
