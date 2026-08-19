// DictionaryService.swift
// VocaMac
//
// Post-ASR dictionary replacement (Story 5.2): fixes recurring
// mis-transcriptions by matching each word-like token in a transcript
// against a user's Dictionary Entries, exactly or by edit distance over
// HebrewNormalizer-normalized forms, and swapping in the canonical form.
//
// Stateless and pure (AD-8): a struct with no mutable state, so it needs no
// mocking of its own internals — DictionaryStage depends on it through the
// `DictionaryProviding` protocol (registered in ServiceProtocols.swift) the
// same way PostProcessStage depends on `PostProcessing`.

import Foundation

protocol DictionaryProviding {
    /// Replaces every token in `text` that matches a trigger closely enough,
    /// leaving everything else — including all surrounding whitespace and
    /// punctuation — untouched.
    func replace(in text: String, using entries: [DictionaryEntry]) -> DictionaryReplacementResult
}

/// What one replacement pass produced.
struct DictionaryReplacementResult: Equatable {
    let text: String
    /// How many tokens were matched and replaced. Purely informational —
    /// `DictionaryStage` decides its outcome from `text`, since a match whose
    /// canonical form happens to equal the original token changes nothing
    /// visible even though a match occurred.
    let replacementCount: Int
}

struct DictionaryService: DictionaryProviding, Sendable {

    /// Minimum normalized-form similarity (1.0 == identical) for a near-match
    /// to be accepted. Chosen conservatively (SM-C2): a miss costs the user
    /// nothing they didn't already have; a wrong replacement corrupts text
    /// they never said.
    let similarityThreshold: Double

    init(similarityThreshold: Double = 0.8) {
        self.similarityThreshold = similarityThreshold
    }

    func replace(in text: String, using entries: [DictionaryEntry]) -> DictionaryReplacementResult {
        guard !entries.isEmpty else {
            return DictionaryReplacementResult(text: text, replacementCount: 0)
        }

        let tokens = Self.tokenize(text)
        guard !tokens.isEmpty else {
            return DictionaryReplacementResult(text: text, replacementCount: 0)
        }

        var result = ""
        var cursor = text.startIndex
        var replacementCount = 0

        for token in tokens {
            // Copy whatever sits between the previous token and this one
            // (whitespace, punctuation) through byte-for-byte.
            result += text[cursor..<token.range.lowerBound]

            if let canonicalForm = Self.match(token: token.text, entries: entries, similarityThreshold: similarityThreshold) {
                result += canonicalForm
                replacementCount += 1
            } else {
                result += token.text
            }
            cursor = token.range.upperBound
        }
        result += text[cursor...]

        return DictionaryReplacementResult(text: result, replacementCount: replacementCount)
    }

    // MARK: - Tokenization

    private struct Token {
        let text: Substring
        let range: Range<String.Index>
    }

    /// Splits `text` into maximal runs of letters/digits, each a candidate
    /// for whole-word replacement. Everything else (spaces, punctuation) is a
    /// separator that is never touched and never itself considered for a
    /// match — this is what keeps a trigger from matching a substring inside
    /// a longer, unrelated word, and what preserves surrounding whitespace
    /// and punctuation exactly (Story 5.2 AC).
    private static func tokenize(_ text: String) -> [Token] {
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

    // MARK: - Matching

    /// Deterministic and ordered (Story 5.2 AC): entries with overlapping
    /// triggers resolve by array order. Every entry is checked for an exact
    /// (normalized) match before any entry is checked for a near-match, so an
    /// exact match anywhere in the Dictionary always outranks a fuzzier one.
    private static func match(token: Substring, entries: [DictionaryEntry], similarityThreshold: Double) -> String? {
        let normalizedToken = HebrewNormalizer.normalize(String(token)).lowercased()
        guard !normalizedToken.isEmpty else { return nil }

        for entry in entries {
            for trigger in entry.triggers {
                if HebrewNormalizer.normalize(trigger).lowercased() == normalizedToken {
                    return entry.canonicalForm
                }
            }
        }

        for entry in entries {
            for trigger in entry.triggers {
                let normalizedTrigger = HebrewNormalizer.normalize(trigger).lowercased()
                guard !normalizedTrigger.isEmpty else { continue }
                // First-character anchor: Hebrew's bound prefixes (ב/ל/מ/ש/ו/כ/ה,
                // e.g. "קוברנטיס" -> "בקוברנטיס", "in Kubernetes") add exactly one
                // leading letter, which pure edit distance cannot tell apart from a
                // genuine ASR substitution/omission — a same-length-difference,
                // similarly-scored case. Requiring the first character to match
                // rules out prefixed real words while still catching the
                // in-place errors (missing/extra internal letter) this stage
                // exists for (SM-C2: a conservative miss beats a wrong replacement).
                guard normalizedTrigger.first == normalizedToken.first else { continue }
                let maxLength = max(normalizedToken.count, normalizedTrigger.count)
                guard maxLength > 0 else { continue }
                let distance = levenshteinDistance(normalizedToken, normalizedTrigger)
                let similarity = 1.0 - Double(distance) / Double(maxLength)
                if similarity >= similarityThreshold {
                    return entry.canonicalForm
                }
            }
        }

        return nil
    }
}

/// Classic edit-distance dynamic program over two strings' characters.
/// Free-standing (not a method) so it is trivially unit-testable on its own.
func levenshteinDistance(_ a: String, _ b: String) -> Int {
    let aChars = Array(a)
    let bChars = Array(b)
    if aChars.isEmpty { return bChars.count }
    if bChars.isEmpty { return aChars.count }

    var previousRow = Array(0...bChars.count)
    var currentRow = [Int](repeating: 0, count: bChars.count + 1)

    for i in 1...aChars.count {
        currentRow[0] = i
        for j in 1...bChars.count {
            if aChars[i - 1] == bChars[j - 1] {
                currentRow[j] = previousRow[j - 1]
            } else {
                let substitution = previousRow[j - 1] + 1
                let deletion = previousRow[j] + 1
                let insertion = currentRow[j - 1] + 1
                currentRow[j] = min(substitution, deletion, insertion)
            }
        }
        swap(&previousRow, &currentRow)
    }

    return previousRow[bChars.count]
}
