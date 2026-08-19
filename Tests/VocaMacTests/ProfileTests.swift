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
}
