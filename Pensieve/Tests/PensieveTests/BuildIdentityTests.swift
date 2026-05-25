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
}
