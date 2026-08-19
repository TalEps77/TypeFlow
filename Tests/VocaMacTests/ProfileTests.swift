// ProfileTests.swift
// VocaMac Tests
//
// The Profile model itself: the Default Profile's invariants, the starter
// set's shape (Story 4.3 AC), and Codable round-tripping (needed for both
// JSONFileStore persistence and JSON export/import).

import XCTest
@testable import VocaMac

final class ProfileTests: XCTestCase {

    func testDefaultProfileIsMarkedDefaultAndHasNoBoundApps() {
        let profile = Profile.makeDefault()

        XCTAssertTrue(profile.isDefault)
        XCTAssertTrue(profile.bundleIdentifiers.isEmpty)
        XCTAssertTrue(profile.promptOverride.isEmpty, "An empty override is what keeps Default identical to Epic 2/3")
        XCTAssertTrue(profile.postProcessEnabled)
        XCTAssertFalse(profile.contextCaptureEnabled, "Cursor Context ships off by default (FR-14)")
    }

    func testDefaultProfileIDIsStableAcrossCalls() {
        XCTAssertEqual(Profile.makeDefault().id, Profile.makeDefault().id)
    }

    func testStarterProfilesCoverChatMailAndCodeEditor() {
        let starters = Profile.starterProfiles()
        let names = Set(starters.map(\.name))

        XCTAssertEqual(names, ["Chat", "Mail", "Code Editor"])
        XCTAssertTrue(starters.allSatisfy { !$0.isDefault })
        XCTAssertTrue(starters.allSatisfy { !$0.bundleIdentifiers.isEmpty }, "A starter Profile that matches nothing would never be seen")
        XCTAssertTrue(starters.allSatisfy { !$0.promptOverride.isEmpty }, "Each starter Profile must actually illustrate a different tone")
    }

    /// Story 4.4 privacy default: no starter Profile may pre-enable Cursor
    /// Context, even if the global toggle is off today — a later, unrelated
    /// reason to flip the global toggle on must not silently start reading
    /// document text for a Profile the user never opted in themselves.
    func testNoStarterProfilePreEnablesContextCapture() {
        XCTAssertTrue(Profile.starterProfiles().allSatisfy { !$0.contextCaptureEnabled })
    }

    func testEncodeDecodeRoundTrips() throws {
        let profile = Profile(
            name: "Code Editor",
            bundleIdentifiers: ["com.apple.dt.Xcode", "com.microsoft.VSCode"],
            promptOverride: "custom prompt",
            postProcessEnabled: false,
            contextCaptureEnabled: true,
            isDefault: false
        )

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)

        XCTAssertEqual(decoded, profile)
    }

    func testProfileArrayRoundTripsForExportImport() throws {
        let profiles = [Profile.makeDefault()] + Profile.starterProfiles()

        let data = try JSONEncoder().encode(profiles)
        let decoded = try JSONDecoder().decode([Profile].self, from: data)

        XCTAssertEqual(decoded, profiles)
    }

    // MARK: - Import hardening (MAJOR 5)

    /// A Profiles export is a plain JSON file that people mail each other and
    /// download. `Codable` proves the shape is right and nothing else — every
    /// invariant the app relies on is one hand-edit away from being violated,
    /// and one of them decides whether the app reads the user's documents.

    func testImportCannotArmCursorContextOnAnyProfile() {
        let hostile = [
            Profile(id: Profile.defaultProfileID, name: "Default", contextCaptureEnabled: true, isDefault: true),
            Profile(name: "Notes", bundleIdentifiers: ["com.apple.Notes"], contextCaptureEnabled: true),
            Profile(name: "Mail", bundleIdentifiers: ["com.apple.mail"], contextCaptureEnabled: false)
        ]

        let sanitized = Profile.sanitizedForImport(hostile)

        XCTAssertTrue(
            sanitized.profiles.allSatisfy { !$0.contextCaptureEnabled },
            "a file must never be able to switch on the per-Profile half of the Cursor Context gate"
        )
        XCTAssertEqual(sanitized.contextCaptureRequestedBy, ["Default", "Notes"],
                       "the user is told which Profiles asked, rather than silently overridden")
    }

    func testImportCoercesExactlyOneDefaultProfile() {
        let hostile = [
            Profile(name: "Impostor A", bundleIdentifiers: ["com.example.a"], promptOverride: "steer everything", isDefault: true),
            Profile(id: Profile.defaultProfileID, name: "Default", isDefault: true),
            Profile(name: "Impostor B", isDefault: true)
        ]

        let sanitized = Profile.sanitizedForImport(hostile)

        XCTAssertEqual(sanitized.profiles.filter(\.isDefault).count, 1)
        // The canonical id wins over whichever impostor happened to be first,
        // so the fallback stays the Profile the app already knows.
        XCTAssertEqual(sanitized.profiles.first(where: \.isDefault)?.id, Profile.defaultProfileID)
        // And the demoted ones are ordinary Profiles now — deletable, which
        // is exactly what `ProfileStore.delete` refuses to do for a Default.
        XCTAssertEqual(sanitized.profiles.count, 3)
    }

    func testImportUnbindsTheDefaultProfile() {
        let hostile = [Profile(
            id: Profile.defaultProfileID,
            name: "Default",
            bundleIdentifiers: ["com.apple.mail", "com.apple.Safari"],
            isDefault: true
        )]

        let sanitized = Profile.sanitizedForImport(hostile)

        XCTAssertEqual(sanitized.profiles.first?.bundleIdentifiers, [],
                       "the Default Profile is the fallback, never a match target")
    }

    func testImportDropsDuplicateIdentifiers() {
        let shared = UUID()
        let hostile = [
            Profile.makeDefault(),
            Profile(id: shared, name: "First", bundleIdentifiers: ["com.example.a"]),
            Profile(id: shared, name: "Second", bundleIdentifiers: ["com.example.b"])
        ]

        let sanitized = Profile.sanitizedForImport(hostile)

        XCTAssertEqual(sanitized.profiles.count, 2)
        XCTAssertEqual(Set(sanitized.profiles.map(\.id)).count, 2)
        XCTAssertEqual(sanitized.profiles.last?.name, "First", "the first occurrence is the one kept")
    }

    func testImportWithNoDefaultProfileGetsOne() {
        let sanitized = Profile.sanitizedForImport([Profile(name: "Only", bundleIdentifiers: ["com.example.a"])])

        XCTAssertEqual(sanitized.profiles.count, 2)
        XCTAssertTrue(sanitized.profiles.first?.isDefault ?? false)
        XCTAssertEqual(sanitized.profiles.first?.id, Profile.defaultProfileID)
    }

    /// The settings tab sanitizes once to tell the user what changed, then
    /// hands the result to `ProfileStore.replaceAll`, which sanitizes again.
    /// The second pass has to be a no-op.
    func testSanitizingIsIdempotent() {
        let hostile = [
            Profile(name: "Impostor", contextCaptureEnabled: true, isDefault: true),
            Profile(id: Profile.defaultProfileID, name: "Default", bundleIdentifiers: ["com.apple.mail"], isDefault: true)
        ]

        let once = Profile.sanitizedForImport(hostile)
        let twice = Profile.sanitizedForImport(once.profiles)

        XCTAssertEqual(twice.profiles, once.profiles)
        XCTAssertEqual(twice.contextCaptureRequestedBy, [])
    }

    /// A well-formed export of a real installation must survive the trip
    /// completely unchanged — sanitizing is a guard, not a transformation.
    func testAnHonestExportRoundTripsThroughSanitizingUntouched() {
        let honest = [Profile.makeDefault()] + Profile.starterProfiles()

        let sanitized = Profile.sanitizedForImport(honest)

        XCTAssertEqual(sanitized.profiles, honest)
        XCTAssertEqual(sanitized.contextCaptureRequestedBy, [])
    }
}
