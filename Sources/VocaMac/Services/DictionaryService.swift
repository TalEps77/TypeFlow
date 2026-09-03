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
    /// Replaces every `WordTokenizer` token in `text` that matches a trigger
    /// closely enough, leaving everything else — including all surrounding
    /// whitespace and punctuation — untouched.
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

    /// Similarity (1.0 == identical) a near-match must **exceed** for the
    /// fuzzy tier to accept it. Chosen conservatively (SM-C2): a miss costs the
    /// user nothing they didn't already have; a wrong replacement corrupts text
    /// they never said.
    ///
    /// The comparison is strict (`>`, not `>=`) because the inclusive boundary
    /// landed exactly on Hebrew's most productive inflection (MAJOR 2): a
    /// four-letter stem plus the feminine -ת is distance 1 over five characters
    /// — similarity 0.800 on the nose — so עובד→עובדת, מנהל→מנהלת and
    /// דוקר→דוקרת all cleared the shipped 0.8 threshold, turning
    /// "היא דוקרת אותי" into "היא Docker אותי". Strict comparison also means
    /// the fuzzy tier cannot fire at all below six characters, where a single
    /// edit is never distinguishable from a different word.
    let similarityThreshold: Double

    init(similarityThreshold: Double = 0.8) {
        self.similarityThreshold = similarityThreshold
    }

    /// One trigger, prepared once per `replace` call rather than recomputed
    /// per token × trigger × tier (MINOR 8).
    private struct PreparedTrigger {
        /// The trigger's own words and gaps, for the exact tier.
        let phrase: WordTokenizer.Phrase
        /// The same words joined letters-only, for the edit-distance tier —
        /// which is what lets a trigger the ASR ran together (מנכ״ל heard as
        /// מנכל) still match.
        let joined: String
        let canonicalForm: String
    }

    func replace(in text: String, using entries: [DictionaryEntry]) -> DictionaryReplacementResult {
        guard !entries.isEmpty else {
            return DictionaryReplacementResult(text: text, replacementCount: 0)
        }

        let tokens = WordTokenizer.tokenize(text)
        guard !tokens.isEmpty else {
            return DictionaryReplacementResult(text: text, replacementCount: 0)
        }

        // MAJOR 3: a trigger is tokenized the same way the transcript is, and
        // matched as a contiguous run of tokens. Compared whole against a
        // single token — as this used to be — every trigger containing a
        // geresh, gershayim, apostrophe, full stop or space (מנכ״ל, צה״ל,
        // ג׳ורג׳, node.js, and every multi-word trigger) was unmatchable
        // forever, with nothing anywhere saying so.
        let prepared: [PreparedTrigger] = entries.flatMap { entry in
            entry.triggers.compactMap { trigger -> PreparedTrigger? in
                guard let phrase = WordTokenizer.phrase(trigger, normalizing: HebrewNormalizer.normalize),
                      !phrase.words.contains(where: { $0.isEmpty }) else {
                    return nil
                }
                return PreparedTrigger(
                    phrase: phrase,
                    joined: phrase.words.joined(),
                    canonicalForm: entry.canonicalForm
                )
            }
        }
        guard !prepared.isEmpty else {
            return DictionaryReplacementResult(text: text, replacementCount: 0)
        }
        let longestTrigger = prepared.map { $0.phrase.words.count }.max() ?? 1

        let normalizedWords = tokens.map { HebrewNormalizer.normalize(String($0.text)).lowercased() }
        let gaps = WordTokenizer.canonicalGaps(in: text, tokens: tokens)

        var result = ""
        var cursor = text.startIndex
        var replacementCount = 0
        var tokenIndex = 0

        while tokenIndex < tokens.count {
            guard let match = Self.match(
                at: tokenIndex,
                normalizedWords: normalizedWords,
                gaps: gaps,
                prepared: prepared,
                longestTrigger: longestTrigger,
                similarityThreshold: similarityThreshold
            ) else {
                result += text[cursor..<tokens[tokenIndex].range.upperBound]
                cursor = tokens[tokenIndex].range.upperBound
                tokenIndex += 1
                continue
            }

            // Copy whatever sits between the previous match and this one
            // (whitespace, punctuation, unmatched words) through byte-for-byte.
            result += text[cursor..<tokens[tokenIndex].range.lowerBound]
            if !match.prefix.isEmpty {
                // Hebrew joins a bound prefix to a Latin word with a maqaf:
                // "אחרי הקומיט" → "אחרי ה־commit", "תפרוס לורסל" → "תפרוס ל־Vercel".
                result += match.prefix + "\u{05BE}"
            }
            result += match.trigger.canonicalForm
            replacementCount += 1

            var matchEnd = tokens[tokenIndex + match.length - 1].range.upperBound
            // A trigger that ends in punctuation takes the text's copy of it
            // with it, so replacing ג׳ורג׳ does not leave a stray ׳ behind.
            let trailing = WordTokenizer.trailingLength(of: match.trigger.phrase, in: text, from: matchEnd)
            if trailing > 0 {
                matchEnd = text.index(matchEnd, offsetBy: trailing)
            }
            cursor = matchEnd
            tokenIndex += match.length
        }
        result += text[cursor...]

        return DictionaryReplacementResult(text: result, replacementCount: replacementCount)
    }

    // MARK: - Matching

    /// Deterministic and ordered (Story 5.2 AC): entries with overlapping
    /// triggers resolve by array order. Every trigger is checked for an exact
    /// (normalized) match before any is checked for a near-match, so an exact
    /// match anywhere in the Dictionary always outranks a fuzzier one; within a
    /// tier, a longer token run outranks a shorter one, so "node.js" is never
    /// left half-matched by a "node" trigger.
    /// Hebrew's bound prefixes — conjunction, article, prepositions and the
    /// relative ש — longest first so "והקומיט" is read as וה + קומיט rather
    /// than ו + הקומיט. Two-letter combinations only where Hebrew actually
    /// stacks them.
    static let boundPrefixes: [String] = [
        "וה", "וב", "ול", "ומ", "וש", "וכ", "שה", "שב", "כש", "מה",
        "ו", "ה", "ב", "ל", "מ", "ש", "כ",
    ]

    /// A remainder shorter than this never counts as a prefixed trigger, so a
    /// two-letter trigger cannot turn an ordinary three-letter word into
    /// prefix + term.
    private static let minimumPrefixedRemainder = 3

    private static func match(
        at index: Int,
        normalizedWords: [String],
        gaps: [String?],
        prepared: [PreparedTrigger],
        longestTrigger: Int,
        similarityThreshold: Double
    ) -> (trigger: PreparedTrigger, length: Int, prefix: String)? {
        guard !normalizedWords[index].isEmpty else { return nil }
        let maximumRun = min(longestTrigger, normalizedWords.count - index)
        guard maximumRun > 0 else { return nil }

        // Exact tier.
        for length in stride(from: maximumRun, through: 1, by: -1) {
            for trigger in prepared where trigger.phrase.words.count == length {
                if WordTokenizer.matches(trigger.phrase, words: normalizedWords, gaps: gaps, at: index) {
                    return (trigger, length, "")
                }
            }
        }

        // Bound-prefix tier: exact only. Hebrew glues ה/ל/ב/ו/מ/ש/כ onto the
        // next word, so a dictation about a commit says "הקומיט" far more often
        // than "קומיט", and the fuzzy tier below refuses that on purpose (its
        // first-character anchor exists precisely to keep prefixed real words
        // out). Here the prefix is peeled off and the remainder must equal a
        // single-word trigger exactly — no edit distance — which keeps the
        // conservative bias (SM-C2) while letting the term pack fire on the
        // forms people actually say. The prefix survives, joined with a maqaf.
        let word = normalizedWords[index]
        for prefix in boundPrefixes where word.hasPrefix(prefix) && word.count - prefix.count >= minimumPrefixedRemainder {
            let remainder = String(word.dropFirst(prefix.count))
            // A trigger with a trailing geresh (ברנץ׳) is fine here: the match
            // below consumes the text's copy of it exactly as the exact tier does.
            for trigger in prepared where trigger.phrase.words.count == 1 && trigger.phrase.words[0] == remainder {
                return (trigger, 1, prefix)
            }
        }

        // Fuzzy tier, over the letters-only joins on both sides — so a trigger
        // and a transcript that disagree about where the word boundaries are
        // still compare (MAJOR 3).
        for length in stride(from: maximumRun, through: 1, by: -1) {
            guard Self.runIsContiguous(gaps: gaps, at: index, length: length) else { continue }
            let candidate = normalizedWords[index..<(index + length)].joined()
            guard !candidate.isEmpty else { continue }

            for trigger in prepared {
                let normalizedTrigger = trigger.joined
                guard !normalizedTrigger.isEmpty else { continue }
                // First-character anchor: Hebrew's bound prefixes (ב/ל/מ/ש/ו/כ/ה,
                // e.g. "קוברנטיס" -> "בקוברנטיס", "in Kubernetes") add exactly one
                // leading letter, which pure edit distance cannot tell apart from a
                // genuine ASR substitution/omission — a same-length-difference,
                // similarly-scored case. Requiring the first character to match
                // rules out prefixed real words while still catching the
                // in-place errors (missing/extra internal letter) this stage
                // exists for (SM-C2: a conservative miss beats a wrong replacement).
                guard normalizedTrigger.first == candidate.first else { continue }
                let maxLength = max(candidate.count, normalizedTrigger.count)
                guard maxLength > 0 else { continue }
                let distance = levenshteinDistance(candidate, normalizedTrigger)
                let similarity = 1.0 - Double(distance) / Double(maxLength)
                if similarity > similarityThreshold {
                    return (trigger, length, "")
                }
            }
        }

        return nil
    }

    /// Whether every gap inside a run of `length` tokens starting at `index` is
    /// a legal in-phrase separator — the fuzzy tier joins the run's letters, so
    /// without this it would happily merge two words across a sentence boundary.
    private static func runIsContiguous(gaps: [String?], at index: Int, length: Int) -> Bool {
        guard length > 1 else { return true }
        for offset in 0..<(length - 1) where gaps[index + offset] == nil {
            return false
        }
        return true
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
