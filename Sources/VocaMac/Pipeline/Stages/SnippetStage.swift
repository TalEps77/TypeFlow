// SnippetStage.swift
// VocaMac
//
// Runs after Dictionary and before PostProcess (AD-3): replaces each matched
// Cue with an opaque placeholder and records the mapping on the context, so
// PostProcess's LLM never sees — and so can never rewrite — a Snippet body.
// RehydrateStage substitutes the real bodies back in afterwards.

import Foundation

@MainActor
final class SnippetStage: TranscriptStage {

    static let stageName = "Snippet"

    let name = SnippetStage.stageName

    private let service: SnippetProviding
    /// Read per run, mirroring DictionaryStage: a Snippet added in the
    /// settings tab takes effect on the very next dictation.
    private let snippetsProvider: () -> [Snippet]
    private let settingsProvider: () -> SnippetSettings

    init(
        service: SnippetProviding = SnippetService(),
        snippetsProvider: @escaping () -> [Snippet],
        settingsProvider: @escaping () -> SnippetSettings = { SnippetSettings.current() }
    ) {
        self.service = service
        self.snippetsProvider = snippetsProvider
        self.settingsProvider = settingsProvider
    }

    func run(_ context: TranscriptContext) async -> StageResult {
        let text = context.currentText

        guard settingsProvider().isEnabled else {
            return StageResult.declined(text, reason: "snippets disabled")
        }
        let snippets = snippetsProvider()
        guard !snippets.isEmpty else {
            return StageResult.declined(text, reason: "no snippets defined")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return StageResult.declined(text, reason: "nothing to expand")
        }

        let protection = service.protect(in: text, using: snippets)
        guard !protection.protectedSpans.isEmpty else {
            return StageResult(text: text, outcome: .skipped(reason: "no cues matched"))
        }
        return StageResult(text: protection.text, outcome: .applied, protectedSpans: protection.protectedSpans)
    }
}
