// Snippet.swift
// VocaMac
//
// A spoken Cue and the fixed block of text it expands into (Story 5.4/5.5).
// Persisted via SnippetStore (AD-9, AD-10). The body can be multi-line
// (a signature block, boilerplate) and is always substituted verbatim — it
// is never seen by the LLM (AD-3): `SnippetStage` protects it behind an
// opaque placeholder before post-processing, and `RehydrateStage`
// substitutes it back afterwards.

import Foundation

struct Snippet: Codable, Identifiable, Equatable, Sendable {
    let id: UUID

    /// The spoken phrase that triggers expansion. Matched case-insensitively
    /// and via `HebrewNormalizer` (Story 5.4 AC), so niqqud or spelling
    /// variance in how it was transcribed does not prevent a match.
    var cue: String

    /// What the Cue expands into. Preserved exactly, including line breaks —
    /// never touched by post-processing.
    var body: String

    init(id: UUID = UUID(), cue: String, body: String = "") {
        self.id = id
        self.cue = cue
        self.body = body
    }
}
