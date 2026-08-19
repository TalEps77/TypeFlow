// DictionaryStage.swift
// VocaMac
//
// Runs first in the pipeline (AD-3): it repairs ASR errors in the raw
// transcript so every stage after it — Snippet protection, and especially
// PostProcess's LLM — reasons over corrected terms rather than garbled ones.
// Pure, synchronous, and has no failure mode of its own (no network, no
// disk, no AX); the only paths out are "declined" and "applied"/"skipped".

import Foundation

@MainActor
final class DictionaryStage: TranscriptStage {

    static let stageName = "Dictionary"

    let name = DictionaryStage.stageName

    private let service: DictionaryProviding
    /// Read per run, mirroring PostProcessStage: a Dictionary edit made in
    /// the settings tab takes effect on the very next dictation.
    private let entriesProvider: () -> [DictionaryEntry]
    private let settingsProvider: () -> DictionarySettings

    init(
        service: DictionaryProviding = DictionaryService(),
        entriesProvider: @escaping () -> [DictionaryEntry],
        settingsProvider: @escaping () -> DictionarySettings = { DictionarySettings.current() }
    ) {
        self.service = service
        self.entriesProvider = entriesProvider
        self.settingsProvider = settingsProvider
    }

    func run(_ context: TranscriptContext) async -> StageResult {
        let text = context.currentText

        guard settingsProvider().isEnabled else {
            return StageResult.declined(text, reason: "dictionary disabled")
        }
        let entries = entriesProvider()
        guard !entries.isEmpty else {
            return StageResult.declined(text, reason: "dictionary is empty")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return StageResult.declined(text, reason: "nothing to correct")
        }

        let replaced = service.replace(in: text, using: entries)
        guard replaced.text != text else {
            return StageResult(text: text, outcome: .skipped(reason: "no matches"))
        }
        return StageResult(text: replaced.text, outcome: .applied)
    }
}
