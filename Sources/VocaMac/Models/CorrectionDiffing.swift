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

    /// Hebrew's bound prefixes — the single letters that attach to the front of
    /// a word (ב "in", ל "to", מ "from", ש "that", ו "and", כ "as", ה "the").
    private static let boundPrefixes: Set<Character> = ["ב", "ל", "מ", "ש", "ו", "כ", "ה"]

    /// The largest edit distance between two normalized words that still reads
    /// as "the same word, spelled differently" rather than "a different word"
    /// (MAJOR 11).
    private static let maximumPlausibleDistance = 2

    /// And a floor on similarity, so the bound above cannot wave through a
    /// two-edit difference between two very short words ("cat"/"dog" is
    /// distance 3, but "at"/"on" is distance 2 over two characters).
    private static let minimumPlausibleSimilarity = 0.5

    /// A field larger than this is not something a dictation is a small edit
    /// inside; scanning it would also make an AX re-read cost grow with
    /// document size, which NFR-4 rules out.
    private static let maximumFieldWords = 5_000

    /// Compares `injected` (what VocaMac typed) against `current` (the same
    /// field, re-read after a short delay) and returns a candidate only when
    /// the injected text can be located in the field with exactly one word
    /// changed, and that change is small enough to plausibly be a spelling
    /// correction of the same word.
    ///
    /// Anything else — the injected text not locatable, locatable in more than
    /// one place, unchanged, or changed by more than one word — returns `nil`.
    /// This is deliberately strict: a conservative miss costs nothing; a wrong
    /// candidate installs a permanent global find-and-replace.
    static func detectCandidate(injected: String, current: String) -> CorrectionCandidate? {
        let injectedWords = WordTokenizer.tokenize(injected).map(\.text)
        let currentWords = WordTokenizer.tokenize(current).map(\.text)

        guard !injectedWords.isEmpty else { return nil }
        guard currentWords.count >= injectedWords.count else { return nil }
        guard currentWords.count <= maximumFieldWords else { return nil }

        // MAJOR 7: the field almost never contains *only* the dictation — a
        // reply typed under a quoted thread, a note appended to an existing
        // paragraph, a sentence dictated into the middle of a document. Diffing
        // against the whole value meant every one of those cases bailed on the
        // word-count check, so correction learning was inert in exactly the
        // situations it ships for, while still paying the AX read. Locate the
        // injected run first, and diff only that window.
        var located: (index: Int, differingOffset: Int?)?
        for start in 0...(currentWords.count - injectedWords.count) {
            var differingOffset: Int?
            var isCandidateWindow = true
            for offset in injectedWords.indices where injectedWords[offset] != currentWords[start + offset] {
                if differingOffset != nil {
                    isCandidateWindow = false
                    break
                }
                differingOffset = offset
            }
            guard isCandidateWindow else { continue }

            // The injected text is still there verbatim: the user carried on
            // typing around it, they did not correct it.
            guard differingOffset != nil else { return nil }

            // Two places it could equally well be. Which one the user edited is
            // a guess, and a guess is exactly what must not be proposed here.
            guard located == nil else { return nil }
            located = (start, differingOffset)
        }

        guard let located, let differingOffset = located.differingOffset else { return nil }

        return candidate(
            original: String(injectedWords[differingOffset]),
            corrected: String(currentWords[located.index + differingOffset])
        )
    }

    /// Turns one located word-level difference into a candidate, or refuses it.
    private static func candidate(original: String, corrected: String) -> CorrectionCandidate? {
        let (strippedOriginal, strippedCorrected) = strippingSharedBoundPrefix(original, corrected)

        let normalizedOriginal = HebrewNormalizer.normalize(strippedOriginal).lowercased()
        let normalizedCorrected = HebrewNormalizer.normalize(strippedCorrected).lowercased()
        guard !normalizedOriginal.isEmpty, !normalizedCorrected.isEmpty else { return nil }

        let distance = levenshteinDistance(normalizedOriginal, normalizedCorrected)
        // Identical once normalized: the user changed niqqud or a final form,
        // which every comparison in this epic already treats as the same word.
        guard distance > 0, distance <= maximumPlausibleDistance else { return nil }

        let maxLength = max(normalizedOriginal.count, normalizedCorrected.count)
        let similarity = 1.0 - Double(distance) / Double(maxLength)
        guard similarity >= minimumPlausibleSimilarity else { return nil }

        return CorrectionCandidate(original: strippedOriginal, corrected: strippedCorrected)
    }

    /// Drops a bound prefix the two words share (MINOR 15).
    ///
    /// "בקוברנטיס" corrected to "בקוברנטס" is a correction of קוברנטיס, not of
    /// the prefixed form: learning the prefixed pair produces a Dictionary
    /// Entry that only ever fires after ב, and the user has to correct the same
    /// word again for every other prefix. The letter is only dropped when both
    /// sides carry it — so it is provably not part of what changed — and only
    /// when a real word is left behind.
    ///
    /// These letters do also begin ordinary words (שולחן, הרים), so this
    /// sometimes strips a first letter that was never a prefix. That costs a
    /// narrower entry, never a wrong replacement: `DictionaryService` matches
    /// whole token runs and anchors on the first character, so a trigger that
    /// is a fragment of a longer word simply never fires on that word.
    private static func strippingSharedBoundPrefix(_ original: String, _ corrected: String) -> (String, String) {
        guard let first = original.first,
              corrected.first == first,
              boundPrefixes.contains(first),
              original.count > 3,
              corrected.count > 3 else {
            return (original, corrected)
        }
        return (String(original.dropFirst()), String(corrected.dropFirst()))
    }
}
