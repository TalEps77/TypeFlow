// Profile.swift
// VocaMac
//
// A named, app-scoped set of dictation behavior: which apps it applies to,
// what it tells the LLM, and which optional features it turns on for those
// apps (Story 4.2). Persisted via ProfileStore (AD-9, AD-10).

import Foundation

struct Profile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String

    /// Bundle identifiers this Profile applies to. The Default Profile's is
    /// always empty — it is the fallback every dictation can resolve to, not
    /// a match target itself.
    var bundleIdentifiers: [String]

    /// Steers the LLM's system prompt for this Profile in place of the global
    /// one (Story 4.2 AC). Empty means "use the global system prompt
    /// unchanged" — which is what keeps the Default Profile's behavior
    /// identical to Epic 2's for anyone who never creates another Profile.
    var promptOverride: String

    /// Per-Profile gates. Honored in addition to — never instead of — the
    /// matching global toggle: post-processing only runs when both the
    /// global master toggle and this are on (Story 4.2 AC).
    var postProcessEnabled: Bool
    var contextCaptureEnabled: Bool

    /// True for exactly one Profile in a ProfileStore: the one that always
    /// exists, cannot be deleted (Story 4.2/4.3 AC), and is what a dictation
    /// resolves to when nothing else matches.
    let isDefault: Bool

    init(
        id: UUID = UUID(),
        name: String,
        bundleIdentifiers: [String] = [],
        promptOverride: String = "",
        postProcessEnabled: Bool = true,
        contextCaptureEnabled: Bool = false,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifiers = bundleIdentifiers
        self.promptOverride = promptOverride
        self.postProcessEnabled = postProcessEnabled
        self.contextCaptureEnabled = contextCaptureEnabled
        self.isDefault = isDefault
    }

    /// Fixed so the Default Profile is recognizable across relaunches and
    /// JSON round-trips by identity, not only by its `isDefault` flag.
    static let defaultProfileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    /// The one Profile every install ships with (Story 4.2 AC).
    static func makeDefault() -> Profile {
        Profile(
            id: Profile.defaultProfileID,
            name: "Default",
            bundleIdentifiers: [],
            promptOverride: "",
            postProcessEnabled: true,
            contextCaptureEnabled: false,
            isDefault: true
        )
    }

    /// Ships on a fresh install alongside the Default Profile (Story 4.3 AC),
    /// illustrating casual, formal, and identifier-shaped output for a chat
    /// app, a mail app, and a code editor respectively. Bundle identifiers
    /// are the real, well-known ones for these apps so the starter set is
    /// useful out of the box rather than a placeholder the user must rebind.
    static func starterProfiles() -> [Profile] {
        [
            Profile(
                name: "Chat",
                bundleIdentifiers: ["com.tinyspeck.slackmacgap", "com.apple.iChat"],
                promptOverride: Prompts.casualChatSystemPrompt,
                postProcessEnabled: true,
                contextCaptureEnabled: false
            ),
            Profile(
                name: "Mail",
                bundleIdentifiers: ["com.apple.mail"],
                promptOverride: Prompts.formalEmailSystemPrompt,
                postProcessEnabled: true,
                contextCaptureEnabled: false
            ),
            Profile(
                name: "Code Editor",
                bundleIdentifiers: ["com.microsoft.VSCode", "com.apple.dt.Xcode"],
                promptOverride: Prompts.codeIdentifierSystemPrompt,
                postProcessEnabled: true,
                // Left off like every other starter Profile: the global
                // Cursor Context toggle ships off (AD-5, FR-14), but a
                // Profile shipping with its own toggle pre-enabled would
                // start reading document text the moment a user turns the
                // global toggle on for any other reason — without ever
                // having opted this specific Profile in themselves.
                contextCaptureEnabled: false
            )
        ]
    }
}
