// CorrectionDiffing.swift
// VocaMac
//
// The bounded word-level diff Story 5.6 requires (R-6): comparing an
// injected transcript against the same field re-read shortly afterward must
// only ever surface a single, localized, word-level edit as a candidate
// correction — never a large or diffuse difference, which is far more
// likely to be the user simply continuing to type than fixing a
// mis-transcription.
//
// A dependency-free leaf (AD-8), like HebrewNormalizer and WordTokenizer:
// pure, side-effect free, and the entire reason this story's core logic is
// unit-testable without any AX access at all.

import Foundation

enum CorrectionDiffing {

    /// Compares `injected` (what VocaMac typed) against `current` (the same
    /// field, re-read after a short delay) and returns a candidate only when
    /// the two differ by exactly one word, with every other word identical.
    ///
    /// Anything else — a different word count (something was typed or
    /// deleted, not just corrected), more than one differing word, or no
    /// difference at all — returns `nil`. This is deliberately strict:
    /// a conservative miss costs nothing; a wrong candidate trains the
    /// Dictionary on noise.
    static func detectCandidate(injected: String, current: String) -> CorrectionCandidate? {
        let injectedWords = WordTokenizer.tokenize(injected).map(\.text)
        let currentWords = WordTokenizer.tokenize(current).map(\.text)

        guard injectedWords.count == currentWords.count else { return nil }
        guard !injectedWords.isEmpty else { return nil }

        var differingIndex: Int?
        for index in injectedWords.indices {
            guard injectedWords[index] != currentWords[index] else { continue }
            guard differingIndex == nil else { return nil }
            differingIndex = index
        }

        guard let differingIndex else { return nil }
        return CorrectionCandidate(
            original: String(injectedWords[differingIndex]),
            corrected: String(currentWords[differingIndex])
        )
    }
}
