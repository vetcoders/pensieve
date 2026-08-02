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
    XCTAssertEqual(
      info["LSMinimumSystemVersion"] as? String,
      "15.0",
      "the shipped bundle must not claim support below SwiftPM's macOS 15 deployment target"
    )

    let components = try XCTUnwrap(
      info[BuildIdentity.componentVersionsKey] as? [String: String])
    for (name, version) in components {
      XCTAssertEqual(
        version, "0.0.0", "component \(name) must stay a placeholder until stamped")
    }
  }

  /// `PensieveAppDelegate.applicationWillTerminate` is where the index's truncating checkpoint
  /// lives, and AppKit only runs that hook when the process is NOT sudden-termination safe.
  /// A packaged build that advertises `NSSupportsSuddenTermination` is killed with `exit()` on
  /// every quit path — Dock, logout, even `NSApp.terminate(nil)` — so the checkpoint silently
  /// never runs and the WAL keeps its high-water mark. Measured on 2026-07-29: with the key
  /// `true` the delegate hook was entered 0/2 runs of a packaged probe; with it `false`, 2/2.
  /// The template is the only producer of that claim, so this is where it has to be pinned.
  func testInfoPlistTemplateDoesNotPromiseSuddenTerminationOverTheIndexCheckpoint() throws {
    let templateURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // PensieveTests/
      .deletingLastPathComponent()  // Tests/
      .deletingLastPathComponent()  // package root
      .appendingPathComponent("Resources/Info.plist")
    let data = try Data(contentsOf: templateURL)
    let info = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        as? [String: Any])

    XCTAssertEqual(
      info["NSSupportsSuddenTermination"] as? Bool,
      false,
      """
      the shipped bundle must not claim it is safe to kill without notice while \
      applicationWillTerminate owns the WAL checkpoint
      """
    )

    let delegateSource = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/Pensieve/App/LaunchIntentCoordinator.swift"),
      encoding: .utf8)
    XCTAssertTrue(
      delegateSource.contains("func applicationWillTerminate("),
      "the plist claim above is only worth pinning while this hook is the checkpoint's home")
  }

  func testPackageAndPublicDocsAgreeOnMacOS15Support() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let repositoryRoot = packageRoot.deletingLastPathComponent()
    let packageManifest = try String(
      contentsOf: packageRoot.appendingPathComponent("Package.swift"), encoding: .utf8)
    let readme = try String(
      contentsOf: repositoryRoot.appendingPathComponent("README.md"), encoding: .utf8)
    let contributing = try String(
      contentsOf: repositoryRoot.appendingPathComponent("CONTRIBUTING.md"), encoding: .utf8)
    let landingPage = try String(
      contentsOf: repositoryRoot.appendingPathComponent("docs/index.html"), encoding: .utf8)

    XCTAssertTrue(packageManifest.contains(".macOS(.v15)"))
    XCTAssertTrue(readme.contains("macOS 15 or newer"))
    XCTAssertTrue(contributing.contains("macOS 15.0 (Sequoia) or newer"))
    XCTAssertTrue(landingPage.contains("macOS 15+"))
  }

  func testReleasePipelineDefaultsToOptimizedFFIAndRejectsDebugDistribution() throws {
    let packageRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let releaseScript = try String(
      contentsOf: packageRoot.deletingLastPathComponent()
        .appendingPathComponent("scripts/build-release.sh"),
      encoding: .utf8)

    XCTAssertTrue(releaseScript.contains(#"FFI_PROFILE="${FFI_PROFILE:-release}""#))
    XCTAssertTrue(releaseScript.contains("export FFI_PROFILE"))
    XCTAssertTrue(
      releaseScript.contains(
        "Distributable releases require FFI_PROFILE=release; debug FFI is local-only."))
  }

  /// scripts/build-release.sh stamps the Mermaid component version by
  /// extracting it from the vendored runtime's banner (line 1) — the file
  /// itself is the only producer of that claim. Guard the extraction
  /// contract: the banner must keep carrying `Mermaid v<x.y.z>`.
  func testVendoredMermaidBannerCarriesExtractableVersion() throws {
    let mermaidURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // PensieveTests/
      .deletingLastPathComponent()  // Tests/
      .deletingLastPathComponent()  // package root
      .appendingPathComponent("Sources/Pensieve/Resources/mermaid.min.js")
    let handle = try FileHandle(forReadingFrom: mermaidURL)
    defer { try? handle.close() }
    let banner = String(decoding: handle.readData(ofLength: 256), as: UTF8.self)

    XCTAssertNotNil(
      banner.range(of: #"Mermaid v\d+\.\d+\.\d+"#, options: .regularExpression),
      "vendored mermaid.min.js banner lost its extractable version marker")
  }
}
