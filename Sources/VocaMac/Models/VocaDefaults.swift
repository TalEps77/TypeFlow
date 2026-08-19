// VocaDefaults.swift
// VocaMac
//
// The one `UserDefaults` domain every VocaMac setting is read from and
// written to (AD-9).
//
// In the shipping app this is `.standard` and always has been; nothing about
// the app's behavior changes by going through here. It exists so a test run
// can point the whole app at a throwaway suite instead (MAJOR 8).
//
// Why that matters: the tests reach real settings through `@AppStorage` on
// `AppState` and through `PostProcessSettings.current()` and friends, which
// means they have to write real keys. Several of them then "cleaned up" with
// `removeObject(forKey:)` in a `defer` — which does not restore the previous
// value, it deletes it. A test run was silently wiping whatever the person
// running it had configured, and leaving later tests to depend on a key
// happening to be absent. Redirecting the domain once, for the whole process,
// makes both problems structurally impossible rather than something every new
// test has to remember.

import Foundation

enum VocaDefaults {

    /// Every settings read and write in the app goes through this.
    ///
    /// Resolved once, lazily, on first use — which under XCTest is before any
    /// test has had a chance to write a key, and in the app is during the
    /// first `AppState`. Self-resolving rather than something a test opts
    /// into on purpose: an opt-in would have to be performed by every test
    /// class, in `setUp`, before touching any setting, and the one that
    /// forgot would put the whole process back to writing real preferences
    /// while the rest wrote the scratch suite.
    static var store: UserDefaults = VocaDefaults.resolveStore()

    /// The throwaway domain used while testing. Named, rather than per-run
    /// unique, so a run cannot leave an unbounded pile of preference files
    /// behind; wiped on creation, so it never carries anything into a run
    /// either.
    static let testSuiteName = "com.vocamac.tests.scratch"

    private static func resolveStore() -> UserDefaults {
        // `XCTestCase` only exists in a process that has loaded XCTest — the
        // shipping app never has, so it always takes `.standard` here.
        guard NSClassFromString("XCTestCase") != nil else {
            return .standard
        }
        UserDefaults.standard.removePersistentDomain(forName: testSuiteName)
        return UserDefaults(suiteName: testSuiteName) ?? .standard
    }
}
