// PostProcessStage.swift
// VocaMac
//
// The LLM stage. Everything that can go wrong here — disabled, unreachable,
// slow, or an answer that fails validation — ends the same way: the text the
// stage was handed is what the pipeline keeps (AD-2).

import Foundation

@MainActor
final class PostProcessStage: TranscriptStage {

    /// The stable stage name, shared rather than re-spelled: `AppState` looks
    /// its report up by this exact string when reading back the stage's
    /// latency, and a silent typo there would zero the field forever (MINOR 10).
    static let stageName = "PostProcess"

    let name = PostProcessStage.stageName

    private let service: PostProcessing
    /// Read per run, so toggling the feature or editing the prompt takes effect
    /// on the very next dictation without rebuilding the pipeline.
    private let settingsProvider: () -> PostProcessSettings

    init(
        service: PostProcessing = PostProcessService(),
        settingsProvider: @escaping () -> PostProcessSettings = { PostProcessSettings.current() }
    ) {
        self.service = service
        self.settingsProvider = settingsProvider
    }

    /// Picks the cleanup prompt for this dictation's language (MAJOR 1).
    ///
    /// Only substitutes when the stored prompt is still the shipped Hebrew
    /// default — the moment the user has edited it, their text is what gets
    /// sent, in every language. Swapping an edited prompt out from under them
    /// because ASR heard English would silently discard their work, and there
    /// is exactly one prompt field in Settings to put it back into.
    ///
    /// The "has the user edited it" test is the same string comparison the
    /// Settings tab already uses to enable its "Restore Default" button, so
    /// the two cannot disagree about what "default" means.
    static func languageAwarePrompt(_ storedPrompt: String, language: String?) -> String {
        guard storedPrompt == Prompts.cleanTranscriptSystemPrompt else { return storedPrompt }
        return Prompts.cleanTranscriptSystemPrompt(for: language)
    }

    func run(_ context: TranscriptContext) async -> StageResult {
        let text = context.currentText
        let settings = settingsProvider()
        let profile = context.resolvedProfile

        // The master toggle is checked before anything else, so that with
        // post-processing off no request is constructed, let alone sent.
        // Both of these decline before any work happens, so their duration is
        // measurement noise — `.declined` says so, and stops the History view
        // showing a "Post-process 0ms" row for a stage that never ran (MAJOR 6).
        guard settings.isEnabled else {
            return StageResult.declined(text, reason: "post-processing disabled")
        }
        // Story 4.2: the resolved Profile's own toggle is honored in addition
        // to the global one, never instead of it. A `nil` Profile (every
        // caller before Epic 4, and any pipeline run with Profiles disabled)
        // is treated as "allows it" so existing behavior is unchanged.
        guard profile?.postProcessEnabled ?? true else {
            return StageResult.declined(text, reason: "post-processing disabled for Profile \"\(profile?.name ?? "")\"")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return StageResult.declined(text, reason: "nothing to clean")
        }

        // An empty override means "use the global prompt unchanged" — how the
        // Default Profile stays identical to Epic 2/3's behavior. Trimmed
        // first: a Profile whose override is a stray space or newline reads
        // as empty to the user but as a real override here, and would send
        // the LLM a blank system prompt for every dictation into that app
        // (MINOR 15).
        let promptOverride = profile?.promptOverride.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let systemPrompt = promptOverride.isEmpty
            ? PostProcessStage.languageAwarePrompt(settings.systemPrompt, language: context.language)
            : promptOverride

        // Story 4.4: whatever is here was already gated by both the global
        // and Profile Cursor Context toggles at capture time (AppState) —
        // this stage does not re-check either toggle, it only forwards what
        // it was handed. `nil` here (the common case) sends no context at
        // all, identical to before Story 4.4.
        switch await service.clean(
            text: text,
            systemPrompt: systemPrompt,
            contextBefore: context.cursorContextBefore,
            contextAfter: context.cursorContextAfter,
            configuration: settings.configuration
        ) {
        case .success(let cleaned):
            // A model that hands back exactly what it was given is a success
            // with nothing to show for it; say so rather than claiming a change.
            guard cleaned != text else {
                return StageResult(text: text, outcome: .skipped(reason: "no changes needed"))
            }
            return StageResult(text: cleaned, outcome: .applied)

        case .failure(let error):
            // No modal, no dialog, no error state — the user gets their raw
            // transcript and only the timeout's delay.
            return StageResult(text: text, outcome: .failed(reason: error.reason))
        }
    }
}
