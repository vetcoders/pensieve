import XCTest

@testable import Pensieve

final class BuildIdentityTests: XCTestCase {
  func testBuildIdentityReadsBundleInfoAndEightCharacterSlug() {
    let identity = BuildIdentity(info: [
      "CFBundleDisplayName": "Pensieve",
      "CFBundleShortVersionString": "0.1.0",
      "CFBundleVersion": "42",
      "PensieveBuildCommit": "abcdef1234567890",
      "PensieveBuildCommitSlug": "abcdef12",
      "PensieveBuildDate": "2026-05-25T23:30:00Z",
      "PensieveComponentVersions": [
        "Editor": "0.1.0",
        "Preview": "0.1.0+abcdef12",
      ],
    ])

    XCTAssertEqual(identity.appName, "Pensieve")
    XCTAssertEqual(identity.version, "0.1.0")
    XCTAssertEqual(identity.buildNumber, "42")
    XCTAssertEqual(identity.commitHash, "abcdef1234567890")
    XCTAssertEqual(identity.commitSlug, "abcdef12")
    XCTAssertEqual(identity.conciseLabel, "0.1.0 (abcdef12)")
    XCTAssertTrue(identity.aboutDetails.contains("Preview: 0.1.0+abcdef12"))
  }

  func testBuildIdentityFallsBackToHashPrefixWhenSlugIsMissing() {
    let identity = BuildIdentity(info: [
      "CFBundleName": "Pensieve",
      "CFBundleShortVersionString": "0.1.0",
      "CFBundleVersion": "7",
      "PensieveBuildCommit": "1234567890abcdef",
    ])

    XCTAssertEqual(identity.commitSlug, "12345678")
  }

  /// `VERSION` (stamped in by scripts/build-release.sh) is the only producer of a
  /// real marketing version. The bundle template must keep the `0.0.0` placeholder —
  /// BuildIdentity's own "no version truth" fallback — so an unstamped bundle
  /// (smoke app, hand-rolled wrapper) reads as "not a release" instead of
  /// masquerading as an old one.
  func testInfoPlistTemplateClaimsOnlyPlaceholderVersions() throws {
    let templateURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // PensieveTests/
      .deletingLastPathComponent()  // Tests/
      .deletingLastPathComponent()  // package root
      .appendingPathComponent("Resources/Info.plist")
    let data = try Data(contentsOf: templateURL)
    let info = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        as? [String: Any])

    XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "0.0.0")
    XCTAssertEqual(info["CFBundleGetInfoString"] as? String, "Pensieve 0.0.0 (dev)")
    XCTAssertEqual(info["PensieveBuildCommitSlug"] as? String, "dev")

    let components = try XCTUnwrap(
      info[BuildIdentity.componentVersionsKey] as? [String: String])
    for (name, version) in components where name != "Mermaid" {
      XCTAssertEqual(
        version, "0.0.0", "component \(name) must stay a placeholder until stamped")
    }
  }
}
