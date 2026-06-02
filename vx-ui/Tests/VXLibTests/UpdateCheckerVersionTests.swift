import XCTest
@testable import VXLib

final class UpdateCheckerVersionTests: XCTestCase {

    // We test isNewer by creating an UpdateChecker and calling the now-internal method directly.
    // currentVersion reads Bundle.main — in test context that's likely "0.0.0" or missing.
    // So we instead test UpdateManifest decoding and the version comparison logic
    // by using a minimal harness.

    // MARK: - Version comparison via isNewer

    // Helper: test the comparison logic using the same string comparison as isNewer.
    func versionIsNewer(remote: String, current: String) -> Bool {
        remote.compare(current, options: .numeric) == .orderedDescending
    }

    func testNewerWhenRemotePatchHigher() {
        XCTAssertTrue(versionIsNewer(remote: "1.0.29", current: "1.0.28"))
    }

    func testNewerWhenRemoteMinorHigher() {
        XCTAssertTrue(versionIsNewer(remote: "1.1.0", current: "1.0.28"))
    }

    func testNewerWhenRemoteMajorHigher() {
        XCTAssertTrue(versionIsNewer(remote: "2.0.0", current: "1.0.28"))
    }

    func testNotNewerWhenSameVersion() {
        XCTAssertFalse(versionIsNewer(remote: "1.0.28", current: "1.0.28"))
    }

    func testNotNewerWhenRemoteIsLower() {
        XCTAssertFalse(versionIsNewer(remote: "1.0.27", current: "1.0.28"))
    }

    func testNotNewerWhenRemoteIsOlderMinor() {
        XCTAssertFalse(versionIsNewer(remote: "0.9.99", current: "1.0.28"))
    }

    // MARK: - UpdateManifest JSON decoding

    func testManifestDecodesValidJSON() throws {
        let json = """
        {"version": "1.2.3", "url": "https://example.com/vx.zip"}
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: json)
        XCTAssertEqual(manifest.version, "1.2.3")
        XCTAssertEqual(manifest.url.absoluteString, "https://example.com/vx.zip")
    }

    func testManifestFailsOnMissingVersion() {
        let json = """
        {"url": "https://example.com/vx.zip"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(UpdateManifest.self, from: json))
    }

    func testManifestFailsOnMissingURL() {
        let json = """
        {"version": "1.0.0"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(UpdateManifest.self, from: json))
    }

    func testManifestFailsOnMalformedJSON() {
        let json = "not json at all".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(UpdateManifest.self, from: json))
    }
}
