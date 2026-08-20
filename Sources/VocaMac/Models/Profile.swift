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

    /// Per-Profile override of the transcription language (Story 8.2): one of
    /// "he", "en", "auto", or `nil` to fall back to the app-wide
    /// `AppState.selectedLanguage`. Lets e.g. a Slack Profile force English
    /// regardless of what the menu bar toggle is currently set to.
    var language: String?

    init(
        id: UUID = UUID(),
        name: String,
        bundleIdentifiers: [String] = [],
        promptOverride: String = "",
        postProcessEnabled: Bool = true,
        contextCaptureEnabled: Bool = false,
        isDefault: Bool = false,
        language: String? = nil
    ) {
        self.id = id
        self.name = name
        self.bundleIdentifiers = bundleIdentifiers
        self.promptOverride = promptOverride
        self.postProcessEnabled = postProcessEnabled
        self.contextCaptureEnabled = contextCaptureEnabled
        self.isDefault = isDefault
        self.language = language
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

    /// What `sanitizedForImport` produced, and what it had to change.
    struct SanitizedImport: Equatable {
        let profiles: [Profile]
        /// Names of imported Profiles that asked for Cursor Context. The
        /// request is always denied (see below); these are surfaced so the
        /// user is told which Profiles wanted it rather than silently
        /// losing a setting they may have meant to keep.
        let contextCaptureRequestedBy: [String]
    }

    /// Hardens a decoded Profiles file before it is allowed anywhere near the
    /// store (MAJOR 5). A Profiles export is a plain JSON file people mail
    /// each other and paste from the internet; `Codable` proves only that the
    /// *shape* is right, and every invariant the rest of the app relies on is
    /// trivially violated by hand-editing one:
    ///
    /// - **Cursor Context is forced off.** `contextCaptureEnabled` is one half
    ///   of the two-key gate on the highest-privacy-cost capability in the app
    ///   (AD-5, R-8). A file must never be able to arm it — otherwise
    ///   importing a shared Profile set silently pre-authorizes reading the
    ///   user's documents the moment they turn the global toggle on for some
    ///   unrelated reason.
    /// - **Exactly one Default Profile** — the one carrying `defaultProfileID`
    ///   when the file has it, otherwise the first that claims the flag, and a
    ///   freshly made one when it claims none. Several
    ///   `isDefault: true` Profiles would all be undeletable (`delete` refuses
    ///   them), and whichever landed first would become the fallback for every
    ///   unmatched app — an imported Default carrying a prompt override that
    ///   the UI offers no way to remove.
    /// - **The Default Profile is unbound.** `bundleIdentifiers` on it breaks
    ///   the "fallback, not a match target" invariant resolution assumes.
    /// - **Ids are unique.** Duplicates make `update` edit only the first and
    ///   `delete` remove all of them at once.
    static func sanitizedForImport(_ profiles: [Profile]) -> SanitizedImport {
        var seenIDs = Set<UUID>()
        var deduped: [Profile] = []
        for profile in profiles where seenIDs.insert(profile.id).inserted {
            deduped.append(profile)
        }

        let contextCaptureRequestedBy = deduped.filter { $0.contextCaptureEnabled }.map { $0.name }

        // The Profile that gets to be Default: the one carrying the canonical
        // id if the file has it, otherwise the first that claims the flag.
        let defaultCandidate = deduped.first { $0.id == Profile.defaultProfileID }
            ?? deduped.first { $0.isDefault }

        var sanitized = deduped.map { profile -> Profile in
            let isDefault = profile.id == defaultCandidate?.id
            return Profile(
                id: profile.id,
                name: profile.name,
                bundleIdentifiers: isDefault ? [] : profile.bundleIdentifiers,
                promptOverride: profile.promptOverride,
                postProcessEnabled: profile.postProcessEnabled,
                contextCaptureEnabled: false,
                isDefault: isDefault,
                language: profile.language
            )
        }

        if defaultCandidate == nil {
            sanitized.insert(Profile.makeDefault(), at: 0)
        }

        return SanitizedImport(profiles: sanitized, contextCaptureRequestedBy: contextCaptureRequestedBy)
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
