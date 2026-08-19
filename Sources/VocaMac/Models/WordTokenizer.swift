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
}
