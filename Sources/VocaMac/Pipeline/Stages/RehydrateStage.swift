// RehydrateStage.swift
// VocaMac
//
// Runs after PostProcess (AD-3): substitutes each placeholder SnippetStage
// left behind with its real, verbatim body. Has no toggle of its own — it
// isn't a feature a user turns on or off, it's the second half of Snippet
// expansion, and it only ever has anything to do when `context.protectedSpans`
// is non-empty, which only happens when SnippetStage already ran.
//
// Its one piece of real logic is the validation the AC calls for: if the LLM
// dropped or altered a placeholder, the *entire* post-processing result is
// rejected — rehydration falls back to the text as it stood right after
// Snippet protection (`context.textBeforePostProcess`), which is guaranteed
// to still contain every placeholder intact, and substitutes there instead.

import Foundation

@MainActor
final class RehydrateStage: TranscriptStage {

    static let stageName = "Rehydrate"

    let name = RehydrateStage.stageName

    func run(_ context: TranscriptContext) async -> StageResult {
        let text = context.currentText
        let spans = context.protectedSpans

        guard !spans.isEmpty else {
            return StageResult.declined(text, reason: "no snippets to rehydrate")
        }

        guard Self.everyPlaceholderPresent(spans, in: text) else {
            // AD-3: a placeholder missing or altered anywhere in the
            // post-processed text means the whole result is untrustworthy —
            // not just the missing span — so the fallback is the pre-LLM
            // snapshot, not a partial patch of `text`.
            VocaLogger.warning(.pipeline, "\(name): a snippet placeholder was missing from the post-processed text — reverting to the pre-LLM text")
            let fallback = context.textBeforePostProcess ?? text
            return StageResult(text: Self.substitute(fallback, spans: spans), outcome: .applied)
        }

        return StageResult(text: Self.substitute(text, spans: spans), outcome: .applied)
    }

    private static func everyPlaceholderPresent(_ spans: [String: String], in text: String) -> Bool {
        spans.keys.allSatisfy { text.contains($0) }
    }

    private static func substitute(_ text: String, spans: [String: String]) -> String {
        var result = text
        for (placeholder, body) in spans {
            result = result.replacingOccurrences(of: placeholder, with: body)
        }
        return result
    }
}
