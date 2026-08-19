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

        guard Self.everyPlaceholderIntact(spans, in: text) else {
            // AD-3: a placeholder missing, altered or duplicated anywhere in
            // the post-processed text means the whole result is untrustworthy —
            // not just the affected span — so the fallback is the pre-LLM
            // snapshot, not a partial patch of `text`.
            VocaLogger.warning(.pipeline, "\(name): a snippet placeholder did not survive post-processing intact — reverting to the pre-LLM text")
            let fallback = context.textBeforePostProcess ?? text
            // MAJOR 4: `.applied` because the text really is adopted (a
            // `.failed` here would leave raw placeholders to be injected), but
            // flagged, so History records that the cleanup round trip it also
            // records the latency of was thrown away.
            return StageResult(text: Self.substitute(fallback, spans: spans), outcome: .applied, usedFallback: true)
        }

        return StageResult(text: Self.substitute(text, spans: spans), outcome: .applied)
    }

    /// Every placeholder must appear in `text` **exactly once** (MINOR 5).
    /// Presence alone was not enough: an LLM that repeated a sentence leaves
    /// two copies of the same placeholder, and substitution would then paste
    /// the whole Snippet body — a signature block, boilerplate — into the
    /// document twice.
    private static func everyPlaceholderIntact(_ spans: [String: String], in text: String) -> Bool {
        spans.keys.allSatisfy { placeholder in
            var count = 0
            var searchRange = text.startIndex..<text.endIndex
            while let found = text.range(of: placeholder, range: searchRange) {
                count += 1
                if count > 1 { return false }
                searchRange = found.upperBound..<text.endIndex
            }
            return count == 1
        }
    }

    /// Substitutes in descending placeholder-index order (MINOR 4).
    /// `Dictionary` iteration order is unspecified and varies run to run, so a
    /// body that itself contains something shaped like another placeholder used
    /// to expand or not depending on hash order — a bug that reproduces on one
    /// launch and not the next. Descending order also means `⟦S1⟧` is consumed
    /// before `⟦S1` could ever be seen as a prefix of `⟦S10⟧`.
    private static func substitute(_ text: String, spans: [String: String]) -> String {
        var result = text
        for placeholder in spans.keys.sorted(by: { Self.index(of: $0) > Self.index(of: $1) }) {
            guard let body = spans[placeholder] else { continue }
            result = result.replacingOccurrences(of: placeholder, with: body)
        }
        return result
    }

    /// The numeric index inside `⟦S<n>⟧`. An unparseable key sorts last, which
    /// is the safe end: it is substituted after every well-formed one.
    private static func index(of placeholder: String) -> Int {
        Int(placeholder.filter(\.isNumber)) ?? -1
    }
}
