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
    ///
    /// Known consequence of Dictionary running first (MINOR 7): a fuzzy
    /// Dictionary hit on a word that is *part of a Cue* rewrites it, and the
    /// Cue then no longer matches — the Snippet silently fails to expand. The
    /// fuzzy tier's strict threshold and first-character anchor (see
    /// `DictionaryService`) make this narrow, and reversing the order would
    /// trade it for the worse problem of the Dictionary never being able to
    /// repair a mis-transcribed Cue at all. Documented rather than fixed;
    /// protecting matched Cues before the Dictionary pass is the real fix if
    /// this is ever observed in practice.
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
            let didInstallText = result.outcome.didChangeText
                && !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if didInstallText {
                context.currentText = result.text
            }

            if result.usedFallback {
                context.didFallback = true
            }

            // Story 5.4/AD-3: fold in whatever placeholder mapping this stage
            // produced (only ever non-empty for SnippetStage) so a later
            // stage — RehydrateStage — can read it back off the context. Only
            // when the text carrying those placeholders was actually installed:
            // a mapping whose placeholders are nowhere in `currentText` hands
            // the rehydrate step a fallback it never needed to take.
            if didInstallText, !result.protectedSpans.isEmpty {
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
                context.didFallback = true
                VocaLogger.warning(.pipeline, "\(stage.name) failed — passing text through unchanged: \(reason)")
            }
        }

        // BLOCKER 1: nothing that looks like Snippet machinery may reach the
        // user's document. Rehydration is the one stage whose correct output
        // can be shorter than its input — including empty — so a blank body, a
        // duplicated placeholder, or any future arrangement of outcomes could
        // leave `⟦S0⟧` standing as the text about to be injected and written to
        // History. Each of those is fixed at its source; this is the assertion
        // that says so, and it costs one regex on text that almost never
        // contains a `⟦` at all.
        //
        // Scoped to runs that actually minted a placeholder, so a user who
        // dictates the characters themselves is unaffected — and skipped when a
        // Snippet body legitimately contains placeholder-shaped text of its
        // own, which is verbatim content, not leftover machinery.
        if !context.protectedSpans.isEmpty,
           SnippetService.containsPlaceholder(context.currentText),
           !context.protectedSpans.values.contains(where: SnippetService.containsPlaceholder) {
            VocaLogger.error(.pipeline, "A snippet placeholder survived rehydration — falling back to the raw transcript rather than injecting it")
            context.currentText = context.rawTranscript
            context.didFallback = true
        }

        // AD-5, same retention argument as Cursor Context below: `protectedSpans`
        // holds whole Snippet bodies and `textBeforePostProcess` a full copy of
        // the transcript, and both are dead the moment rehydration is done. The
        // returned context goes back to `AppState`, so leaving them populated
        // keeps them alive well past the run that needed them (MINOR 9).
        context.protectedSpans = [:]
        context.textBeforePostProcess = nil

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
