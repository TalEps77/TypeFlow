// SnippetService.swift
// VocaMac
//
// Snippet expansion, protection half (Story 5.4): finds each spoken Cue in
// a transcript — case-insensitively, over HebrewNormalizer-normalized
// forms — and replaces it with an opaque placeholder token, recording what
// the placeholder stands for. The LLM (PostProcessStage) only ever sees the
// placeholder; RehydrateStage substitutes the real, verbatim body back in
// after post-processing (AD-3).
//
// Stateless and pure (AD-8), like DictionaryService: a struct with no
// mutable state, matched against through the `SnippetProviding` protocol.

import Foundation

protocol SnippetProviding {
    /// Replaces every matched Cue in `text` with a distinct placeholder
    /// (`⟦S0⟧`, `⟦S1⟧`, …), leaving everything else — including all
    /// surrounding whitespace and punctuation — untouched.
    func protect(in text: String, using snippets: [Snippet]) -> SnippetProtectionResult
}

/// What one protection pass produced: the placeholder-substituted text, and
/// the mapping `RehydrateStage` needs to substitute the real bodies back in.
struct SnippetProtectionResult: Equatable {
    let text: String
    let protectedSpans: [String: String]
}

struct SnippetService: SnippetProviding, Sendable {

    /// The opaque placeholder form (Story 5.4/AD-3): the mathematical
    /// white-bracket characters `⟦`/`⟧` are not used anywhere in ordinary
    /// Hebrew or English text, so an LLM has no reason to "correct",
    /// translate, or otherwise alter them the way it might plain brackets
    /// or a made-up word.
    private static func placeholder(_ index: Int) -> String {
        "⟦S\(index)⟧"
    }

    func protect(in text: String, using snippets: [Snippet]) -> SnippetProtectionResult {
        guard !snippets.isEmpty else {
            return SnippetProtectionResult(text: text, protectedSpans: [:])
        }

        let tokens = WordTokenizer.tokenize(text)
        guard !tokens.isEmpty else {
            return SnippetProtectionResult(text: text, protectedSpans: [:])
        }

        // Each Cue's own word sequence, normalized once up front rather than
        // per candidate position.
        let candidates: [(cueWords: [String], body: String)] = snippets.compactMap { snippet in
            let cueWords = WordTokenizer.tokenize(snippet.cue).map {
                HebrewNormalizer.normalize(String($0.text)).lowercased()
            }
            guard !cueWords.isEmpty else { return nil }
            return (cueWords, snippet.body)
        }
        guard !candidates.isEmpty else {
            return SnippetProtectionResult(text: text, protectedSpans: [:])
        }

        let normalizedTokens = tokens.map { HebrewNormalizer.normalize(String($0.text)).lowercased() }

        var result = ""
        var cursor = text.startIndex
        var protectedSpans: [String: String] = [:]
        var nextPlaceholderIndex = 0
        var tokenIndex = 0

        while tokenIndex < tokens.count {
            // First candidate (in Snippet array order) whose full word
            // sequence matches starting at this position — deterministic,
            // mirroring DictionaryService's overlap resolution (Story 5.2).
            let match = candidates.first { candidate in
                let length = candidate.cueWords.count
                guard tokenIndex + length <= tokens.count else { return false }
                return Array(normalizedTokens[tokenIndex..<(tokenIndex + length)]) == candidate.cueWords
            }

            guard let match else {
                tokenIndex += 1
                continue
            }

            let length = match.cueWords.count
            let matchStart = tokens[tokenIndex].range.lowerBound
            let matchEnd = tokens[tokenIndex + length - 1].range.upperBound

            // Copy whatever sits before this match (whitespace, punctuation,
            // unmatched words) through byte-for-byte.
            result += text[cursor..<matchStart]

            let token = Self.placeholder(nextPlaceholderIndex)
            nextPlaceholderIndex += 1
            protectedSpans[token] = match.body
            result += token

            cursor = matchEnd
            tokenIndex += length
        }
        result += text[cursor...]

        return SnippetProtectionResult(text: result, protectedSpans: protectedSpans)
    }
}
