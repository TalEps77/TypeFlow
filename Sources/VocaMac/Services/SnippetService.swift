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

    /// Whether `text` still carries something shaped like one of our
    /// placeholders. `TranscriptPipeline` uses this as its last line of
    /// defence: a placeholder that reaches injection is raw machinery in the
    /// user's document, and no arrangement of stage outcomes may allow it
    /// (BLOCKER 1).
    static func containsPlaceholder(_ text: String) -> Bool {
        text.range(of: "⟦S[0-9]+⟧", options: .regularExpression) != nil
    }

    func protect(in text: String, using snippets: [Snippet]) -> SnippetProtectionResult {
        guard !snippets.isEmpty else {
            return SnippetProtectionResult(text: text, protectedSpans: [:])
        }

        let tokens = WordTokenizer.tokenize(text)
        guard !tokens.isEmpty else {
            return SnippetProtectionResult(text: text, protectedSpans: [:])
        }

        // Each Cue's own word sequence and separators, normalized once up
        // front rather than per candidate position.
        //
        // A Snippet whose body is blank is skipped outright (BLOCKER 1). Its
        // placeholder would rehydrate to nothing, and a dictation consisting of
        // just that Cue would rehydrate to an empty string — which the runner's
        // AD-2 blank guard then rejects, leaving the raw `⟦S0⟧` as the text to
        // inject and to write to History. Never minting the placeholder is the
        // one fix that cannot be undone by a later stage.
        let candidates: [(cue: WordTokenizer.Phrase, body: String)] = snippets.compactMap { snippet in
            guard !snippet.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let cue = WordTokenizer.phrase(snippet.cue, normalizing: HebrewNormalizer.normalize),
                  !cue.words.contains(where: { $0.isEmpty }) else {
                return nil
            }
            return (cue, snippet.body)
        }
        guard !candidates.isEmpty else {
            return SnippetProtectionResult(text: text, protectedSpans: [:])
        }

        let normalizedTokens = tokens.map { HebrewNormalizer.normalize(String($0.text)).lowercased() }
        let gaps = WordTokenizer.canonicalGaps(in: text, tokens: tokens)

        var result = ""
        var cursor = text.startIndex
        var protectedSpans: [String: String] = [:]
        var nextPlaceholderIndex = 0
        var tokenIndex = 0

        while tokenIndex < tokens.count {
            // First candidate (in Snippet array order) whose full word
            // sequence matches starting at this position — deterministic,
            // mirroring DictionaryService's overlap resolution (Story 5.2).
            // The separators between the Cue's words have to match too, so a
            // multi-word Cue can no longer reach across a full stop or a line
            // break and swallow it — "תודה. רבה" is two sentences, not the Cue
            // "תודה רבה" (MINOR 3).
            let match = candidates.first { candidate in
                WordTokenizer.matches(candidate.cue, words: normalizedTokens, gaps: gaps, at: tokenIndex)
            }

            guard let match else {
                tokenIndex += 1
                continue
            }

            let length = match.cue.words.count
            let matchStart = tokens[tokenIndex].range.lowerBound
            var matchEnd = tokens[tokenIndex + length - 1].range.upperBound
            // A Cue ending in punctuation takes the text's copy of it with it,
            // the same way a Dictionary trigger does.
            let trailing = WordTokenizer.trailingLength(of: match.cue, in: text, from: matchEnd)
            if trailing > 0 {
                matchEnd = text.index(matchEnd, offsetBy: trailing)
            }

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
