// CorrectionCandidate.swift
// VocaMac
//
// A single word-level edit detected between an injected transcript and the
// same text field re-read shortly afterward (Story 5.6). Deliberately holds
// only the two words involved — never the surrounding sentence or field
// contents, which are transient and must never be persisted or logged
// (AD-5 still holds for the re-read).

import Foundation

struct CorrectionCandidate: Equatable, Hashable, Sendable {
    /// What VocaMac injected for this word.
    let original: String
    /// What the user's own retyping replaced it with.
    let corrected: String
}
