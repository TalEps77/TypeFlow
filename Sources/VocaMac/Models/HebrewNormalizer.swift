// HebrewNormalizer.swift
// VocaMac
//
// Story 5.1: a correct, pure Hebrew text normalizer. Every fuzzy match in
// Epic 5 (Dictionary replacement, Snippet cue matching) compares
// HebrewNormalizer-normalized forms, so getting this right once here is what
// makes every later comparison "like with like" (NFR-6).
//
// A dependency-free leaf (AD-8): no audio, no LLM, no AX, no I/O. Pure
// `static` functions on purpose, so this is trivially unit-testable and can
// never itself be the reason a stage fails.

import Foundation

enum HebrewNormalizer {

    /// The Hebrew consonant block, including the five final-letter forms —
    /// used to decide whether an apostrophe/quote-like character sits after a
    /// Hebrew letter (and is therefore a geresh/gershayim) or not (and is
    /// therefore ordinary Latin punctuation that must pass through untouched).
    private static let hebrewLetterRange: ClosedRange<UInt32> = 0x05D0...0x05EA

    /// The Yiddish ligatures װ (double vav), ױ (vav-yod) and ײ (double yod).
    /// They are Hebrew *letters* — a geresh after one is still a geresh — but
    /// they sit outside the consonant block above, so the adjacency test used
    /// to answer "no" for them and leave the geresh un-canonicalized
    /// (MINOR 6). `decomposeLigatures` normally converts them away before that
    /// test ever runs; this range is what makes the answer right even for a
    /// caller reaching `normalizeGereshGershayim` on its own.
    private static let yiddishLigatureRange: ClosedRange<UInt32> = 0x05F0...0x05F2

    private static func isHebrewLetter(_ value: UInt32) -> Bool {
        hebrewLetterRange.contains(value) || yiddishLigatureRange.contains(value)
    }

    /// Cantillation marks (trope) that decorate Biblical/liturgical text.
    private static let cantillationRange: ClosedRange<UInt32> = 0x0591...0x05AF

    /// Niqqud vowel points, the meteg stress mark, and rafe. Deliberately
    /// excludes 0x05BE (maqaf — a hyphen, not a diacritic) and 0x05C0/0x05C3
    /// (paseq/sof pasuq — punctuation, not diacritics): stripping those would
    /// corrupt word boundaries rather than merely removing pronunciation
    /// information.
    private static let niqqudRange: ClosedRange<UInt32> = 0x05B0...0x05BD

    /// Shin/sin dot, the Yiddish upper/lower dot marks, and qamats qatan —
    /// all diacritics layered on a base consonant, none of them punctuation.
    private static let otherDiacritics: Set<UInt32> = [0x05BF, 0x05C1, 0x05C2, 0x05C4, 0x05C5, 0x05C7]

    private static func isNiqqudOrCantillation(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return cantillationRange.contains(value)
            || niqqudRange.contains(value)
            || otherDiacritics.contains(value)
    }

    /// Strips niqqud and cantillation marks (Story 5.1 AC). Latin text has
    /// none of these code points, so it passes through untouched.
    static func stripNiqqud(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !isNiqqudOrCantillation($0) }))
    }

    /// Expands the Yiddish ligatures װ/ױ/ײ into the letter pairs they stand
    /// for, so the same word typed either way compares equal (MINOR 6). This
    /// is a genuine canonicalization — one word, two encodings — unlike
    /// matres-lectionis collapsing below, which merges *different* words.
    static func decomposeLigatures(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\u{05F0}": result.append("וו")
            case "\u{05F1}": result.append("וי")
            case "\u{05F2}": result.append("יי")
            default:         result.append(character)
            }
        }
        return result
    }

    /// Unifies matres lectionis variants — ו/וו and י/יי — by collapsing any
    /// run of the same letter down to one (Story 5.1 AC). A single-pass
    /// find-and-replace of the literal doubled form does not fully collapse a
    /// run of three or more identical letters in one call, which would break
    /// idempotence; scanning run-by-run does not have that failure mode
    /// regardless of run length.
    ///
    /// **No longer part of `normalize`, and not used by any matcher**
    /// (MAJOR 1). Collapsing these runs is lossy in a way every other step here
    /// is not: מוות/מות, עוול/עול, ראייה/ראיה and חייב/חיב are distinct Hebrew
    /// words that all become identical under it, and the exact-match tiers that
    /// consume `normalize` — `DictionaryService`'s first pass,
    /// `SnippetService`'s cue matching, `SnippetStore.hasCollision` — bypass
    /// every similarity threshold and anchor, so the collapse silently
    /// rewrote words the user really said.
    ///
    /// Nor does it belong in the fuzzy tier, where it looks safer than it is: a
    /// collapse there scores מות against מוות at similarity 1.0, which clears
    /// any threshold — the same false replacement, arrived at differently.
    /// Edit distance already subsumes what this was for, and better: a doubled
    /// letter is exactly one insertion, so קווברנטיס still matches קוברנטיס at
    /// 0.889, while מות is held at 0.75 and correctly refused. Kept as a
    /// standalone, tested transform because Story 5.1's AC names it.
    static func normalizeMatresLectionis(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var previous: Character?
        for character in text {
            if (character == "ו" || character == "י") && character == previous {
                continue
            }
            result.append(character)
            previous = character
        }
        return result
    }

    private static let finalToBaseForm: [Character: Character] = [
        "ך": "כ",
        "ם": "מ",
        "ן": "נ",
        "ף": "פ",
        "ץ": "צ"
    ]

    /// Normalizes final-letter forms to their base forms (Story 5.1 AC), so a
    /// trigger/canonical pair that happens to differ only in word-final
    /// position (e.g. a substring match landing mid-word) still compares equal.
    static func normalizeFinalForms(_ text: String) -> String {
        String(text.map { finalToBaseForm[$0] ?? $0 })
    }

    /// Canonicalizes geresh (׳) and gershayim (״) — handling both the proper
    /// Hebrew punctuation code points and the ASCII/typographic apostrophe
    /// and quote characters ASR and typing commonly substitute for them
    /// (Story 5.1 AC).
    ///
    /// Only converts when immediately preceded by a Hebrew letter — a geresh
    /// marks a preceding Hebrew consonant (e.g. ג׳ for the /dʒ/ sound), so
    /// that adjacency is what distinguishes it from an English contraction's
    /// apostrophe ("don't") or an inch/quote mark, which must pass through
    /// unchanged per the mixed Hebrew/English AC.
    static func normalizeGereshGershayim(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var previousWasHebrewLetter = false

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0027, 0x2018, 0x2019, 0x05F3:
                result.append(previousWasHebrewLetter ? Unicode.Scalar(0x05F3)! : scalar)
            case 0x0022, 0x201C, 0x201D, 0x05F4:
                result.append(previousWasHebrewLetter ? Unicode.Scalar(0x05F4)! : scalar)
            default:
                result.append(scalar)
            }
            previousWasHebrewLetter = isHebrewLetter(scalar.value)
        }

        return String(result)
    }

    /// The full pipeline (Story 5.1 AC), in an order chosen so each step only
    /// ever sees output already clean of the previous step's noise: strip
    /// diacritics first so the ligature and geresh/gershayim adjacency checks
    /// operate on plain consonants, then expand ligatures, then final forms,
    /// then geresh/gershayim last (it depends on final forms still being
    /// Hebrew letters, which they are either way since final forms are
    /// themselves in the Hebrew consonant range).
    ///
    /// Every step here is *information-preserving up to encoding*: two strings
    /// that normalize equal are the same word written two ways. Matres-lectionis
    /// collapsing is deliberately **not** among them — see
    /// `normalizeMatresLectionis` (MAJOR 1).
    ///
    /// Side-effect free, requires no audio/LLM/AX, and is idempotent:
    /// `normalize(normalize(x)) == normalize(x)` for any `x`.
    static func normalize(_ text: String) -> String {
        var result = text
        result = stripNiqqud(result)
        result = decomposeLigatures(result)
        result = normalizeFinalForms(result)
        result = normalizeGereshGershayim(result)
        return result
    }
}
