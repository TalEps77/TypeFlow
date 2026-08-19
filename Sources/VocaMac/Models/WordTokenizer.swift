// WordTokenizer.swift
// VocaMac
//
// Splits text into maximal runs of letters/digits — the shared word-boundary
// primitive both DictionaryService (Story 5.2) and SnippetService
// (Story 5.4) match against, so a trigger or Cue can never fire as a
// substring inside a longer, unrelated word, and surrounding whitespace and
// punctuation are always preserved untouched. A dependency-free leaf
// (AD-8), like HebrewNormalizer.

import Foundation

enum WordTokenizer {

    struct Token {
        let text: Substring
        let range: Range<String.Index>
    }

    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isLetter || text[index].isNumber {
                let start = index
                while index < text.endIndex, text[index].isLetter || text[index].isNumber {
                    index = text.index(after: index)
                }
                tokens.append(Token(text: text[start..<index], range: start..<index))
            } else {
                index = text.index(after: index)
            }
        }
        return tokens
    }

    // MARK: - Phrases (multi-token triggers and Cues)

    /// A trigger or Cue reduced to what matching actually compares: its
    /// normalized words, plus the canonical form of whatever sits between
    /// consecutive words.
    ///
    /// Multi-token patterns are the whole reason this exists (MAJOR 3):
    /// geresh/gershayim and full stops are not `isLetter`, so מנכ״ל, צה״ל,
    /// ג׳ורג׳, node.js and every multi-word trigger tokenize into two or more
    /// words while the trigger itself was compared whole — and so could never
    /// match anything, ever, silently.
    struct Phrase: Equatable {
        /// Normalized, lowercased words, in order. Never empty.
        let words: [String]
        /// `words.count - 1` entries: the canonical gap between word *i* and
        /// word *i+1*.
        let gaps: [String]

        /// The canonical form of whatever trails the last word — the closing
        /// geresh in ג׳ורג׳, say. Empty for the overwhelmingly common case.
        /// Consumed by the match when the text has it too, so a replacement
        /// does not leave a stray ׳ behind (MAJOR 3).
        let trailing: String
    }

    /// Builds a `Phrase` from `text`, or `nil` when it has no word tokens at
    /// all or holds a gap that is not a legal in-phrase separator.
    static func phrase(_ text: String, normalizing: (String) -> String) -> Phrase? {
        let tokens = tokenize(text)
        guard !tokens.isEmpty else { return nil }

        var gaps: [String] = []
        gaps.reserveCapacity(tokens.count - 1)
        for index in 1..<tokens.count {
            guard let gap = canonicalGap(text[tokens[index - 1].range.upperBound..<tokens[index].range.lowerBound]) else {
                return nil
            }
            gaps.append(gap)
        }

        let trailingRun = text[tokens[tokens.count - 1].range.upperBound...]
        let trailing = trailingRun.contains(where: \.isWhitespace) ? "" : String(trailingRun.map(canonicalPunctuation))

        return Phrase(
            words: tokens.map { normalizing(String($0.text)).lowercased() },
            gaps: gaps,
            trailing: trailing
        )
    }

    /// How many characters at `start` in `text` reproduce `phrase.trailing`,
    /// or `0` when they do not (an absent closing geresh must not block a
    /// match — the ASR drops them routinely).
    static func trailingLength(of phrase: Phrase, in text: String, from start: String.Index) -> Int {
        guard !phrase.trailing.isEmpty else { return 0 }
        var index = start
        for expected in phrase.trailing {
            guard index < text.endIndex, canonicalPunctuation(text[index]) == expected else { return 0 }
            index = text.index(after: index)
        }
        return phrase.trailing.count
    }

    /// The canonical gaps between consecutive tokens of an already-tokenized
    /// text. `gaps[i]` sits between `tokens[i]` and `tokens[i + 1]`, and is
    /// `nil` where that run is not a legal in-phrase separator — which is what
    /// stops a phrase match from spanning it.
    static func canonicalGaps(in text: String, tokens: [Token]) -> [String?] {
        guard tokens.count > 1 else { return [] }
        return (1..<tokens.count).map {
            canonicalGap(text[tokens[$0 - 1].range.upperBound..<tokens[$0].range.lowerBound])
        }
    }

    /// Whether `phrase` matches the token run starting at `index` — same
    /// words, and every gap between them canonically the same as the phrase's
    /// own.
    static func matches(
        _ phrase: Phrase,
        words: [String],
        gaps: [String?],
        at index: Int
    ) -> Bool {
        let length = phrase.words.count
        guard index + length <= words.count else { return false }
        for offset in 0..<length where words[index + offset] != phrase.words[offset] {
            return false
        }
        for offset in 0..<(length - 1) where gaps[index + offset] != phrase.gaps[offset] {
            return false
        }
        return true
    }

    /// The canonical form of the run of non-word characters between two
    /// consecutive tokens, or `nil` when that run cannot legally sit inside a
    /// single phrase.
    ///
    /// Two rules, both there to stop a pattern from swallowing a boundary the
    /// speaker put in (MINOR 3): a gap is either **all whitespace** (and no
    /// line break — a Cue does not span paragraphs) or **no whitespace at all**
    /// (the geresh in מנכ״ל, the dot in node.js, a maqaf). A mixture such as
    /// `". "` is a sentence boundary, so "תודה. רבה" can never match the Cue
    /// "תודה רבה" and take the full stop with it.
    ///
    /// Whitespace runs collapse to one space, and the apostrophe/quote family
    /// folds onto geresh/gershayim, so `מנכ״ל` and `מנכ"ל` produce the same gap
    /// — the same tolerance `HebrewNormalizer.normalizeGereshGershayim` gives
    /// the words themselves.
    static func canonicalGap(_ gap: Substring) -> String? {
        guard !gap.isEmpty else { return "" }

        let isAllWhitespace = gap.allSatisfy { $0.isWhitespace }
        if isAllWhitespace {
            return gap.contains(where: \.isNewline) ? nil : " "
        }
        guard !gap.contains(where: \.isWhitespace) else { return nil }

        return String(gap.map(canonicalPunctuation))
    }

    /// Folds the apostrophe/quote family onto geresh/gershayim, so `מנכ״ל` and
    /// `מנכ"ל` produce the same separator — the same tolerance
    /// `HebrewNormalizer.normalizeGereshGershayim` gives the words themselves.
    /// Every other character passes through, one for one.
    static func canonicalPunctuation(_ character: Character) -> Character {
        switch character {
        case "'", "\u{2018}", "\u{2019}", "\u{05F3}": return "\u{05F3}"
        case "\"", "\u{201C}", "\u{201D}", "\u{05F4}": return "\u{05F4}"
        default: return character
        }
    }
}
