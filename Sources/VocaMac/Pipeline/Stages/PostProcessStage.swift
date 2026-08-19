// PostProcessStage.swift
// VocaMac
//
// The LLM stage. Everything that can go wrong here — disabled, unreachable,
// slow, or an answer that fails validation — ends the same way: the text the
// stage was handed is what the pipeline keeps (AD-2).

import Foundation

@MainActor
final class PostProcessStage: TranscriptStage {

    let name = "PostProcess"

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

    func run(_ context: TranscriptContext) async -> StageResult {
        let text = context.currentText
        let settings = settingsProvider()

        // The master toggle is checked before anything else, so that with
        // post-processing off no request is constructed, let alone sent.
        guard settings.isEnabled else {
            return StageResult(text: text, outcome: .skipped(reason: "post-processing disabled"))
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return StageResult(text: text, outcome: .skipped(reason: "nothing to clean"))
        }

        switch await service.clean(
            text: text,
            systemPrompt: settings.systemPrompt,
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
