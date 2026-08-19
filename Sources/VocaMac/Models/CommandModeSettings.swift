// CommandModeSettings.swift
// VocaMac
//
// Command Mode's scalar settings (AD-9). Epic 6, Stories 6.1 and 6.3.
//
// A namespace of keys and defaults rather than a value type with a `current()`
// reader, unlike DictionarySettings and SnippetSettings: those are read by a
// pipeline stage that must not depend on `AppState`, whereas everything here
// is read through `AppState`'s own @AppStorage bindings and pushed to
// `HotKeyManager`. There is no second reader to serve, so there is no snapshot
// type to build. The command prompt is likewise not a setting — it is a
// reviewable `static let` in Prompts.swift with no editor behind it.

import Foundation

enum CommandModeSettings {

    enum Key {
        static let enabled = "vocamac.commandMode.enabled"
        static let hotKeyCode = "vocamac.commandMode.hotKeyCode"
        static let activationMode = "vocamac.commandMode.activationMode"
    }

    enum Default {
        /// Ships **off**, unlike Dictionary and Snippets.
        ///
        /// Those two are inert until configured; this one is not. Enabling it
        /// binds a second global hotkey, and `HotKeyBinding` *consumes* the
        /// events for the key it watches — so shipping this on would silently
        /// take the shipped default key away from every existing user's own
        /// shortcuts on upgrade (NFR-5). It is also the only flow in the app
        /// that overwrites text the user already has, which is the other
        /// reason to make turning it on a deliberate act (AD-4).
        static let enabled = false

        /// Right Command. Distinct from the Dictation Mode default of Right
        /// Option (61), which is what Story 6.1's AC requires. Of the modifier
        /// keys present on every Mac keyboard it is the one left over once
        /// Right Option is spoken for and Shift is excluded — a push-to-talk
        /// binding on Shift would fight every capital letter the user types.
        static let hotKeyCode = 54

        /// Matches the dictation default so both gestures feel the same
        /// (Story 6.1 AC), and is separately configurable.
        static let activationMode = ActivationMode.pushToTalk
    }
}
