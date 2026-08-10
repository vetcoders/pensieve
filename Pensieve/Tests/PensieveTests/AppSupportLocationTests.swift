import XCTest

@testable import Pensieve

/// S5: a diagnostic run must be able to keep its Application Support state out
/// of the operator's. The override is the only lever that does that without
/// moving the operator's real directory aside, so its contract is pinned here:
/// silent by default, absolute-only, and ready to be written into.
final class AppSupportLocationTests: XCTestCase {

  func testAbsentVariableLeavesEveryCallerOnItsOwnDerivation() {
    XCTAssertNil(AppSupportLocation.overrideRoot(environment: [:]))
  }

  func testEmptyValueIsTreatedAsAbsent() {
    XCTAssertNil(
      AppSupportLocation.overrideRoot(
        environment: [AppSupportLocation.overrideEnvironmentKey: ""]))
  }

  /// A relative path would resolve against whatever working directory
  /// LaunchServices handed the app — an isolation switch that lands somewhere
  /// unpredictable is worse than no switch at all, so it is refused outright.
  func testRelativePathIsRefusedRatherThanResolvedAgainstTheWorkingDirectory() {
    XCTAssertNil(
      AppSupportLocation.overrideRoot(
        environment: [AppSupportLocation.overrideEnvironmentKey: "smoke-support"]))
  }

  func testAbsolutePathIsHonoredAndTheDirectoryExistsAfterwards() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pensieve-support-override-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }

    let resolved = AppSupportLocation.overrideRoot(
      environment: [AppSupportLocation.overrideEnvironmentKey: root.path])

    XCTAssertEqual(resolved?.standardizedFileURL, root.standardizedFileURL)
    // The four call sites write into this directory at wildly different points
    // in the launch; none of them should have to create it first.
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
  }

  func testTildeIsExpandedSoAnOperatorWrittenValueBehavesAsTyped() {
    let resolved = AppSupportLocation.overrideRoot(
      environment: [AppSupportLocation.overrideEnvironmentKey: "~"])

    XCTAssertEqual(resolved?.path, NSHomeDirectory())
  }

  func testXCTestDetectionAcceptsEverySupportedHostSignal() {
    XCTAssertTrue(
      AppSupportLocation.isRunningTests(
        environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"],
        processName: "PensieveTests",
        isXCTestRuntimeLoaded: false))
    XCTAssertTrue(
      AppSupportLocation.isRunningTests(
        environment: [:], processName: "PensievePackageTests.xctest",
        isXCTestRuntimeLoaded: false))
    XCTAssertTrue(
      AppSupportLocation.isRunningTests(
        environment: [:], processName: "PensieveTests",
        isXCTestRuntimeLoaded: true))
    XCTAssertFalse(
      AppSupportLocation.isRunningTests(
        environment: [:], processName: "Pensieve", isXCTestRuntimeLoaded: false))
  }

  func testTheCurrentTestHostIsDetectedWithoutInjectedSignals() {
    XCTAssertTrue(AppSupportLocation.isRunningTests())
  }

  func testRecoveryDefaultsToTemporaryStorageInsideATestProcess() {
    let resolved = RecoveryStore.defaultDirectoryURL(
      fileManager: .default, environment: [:], isTestProcess: true)
    let production = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Pensieve/Recovery", isDirectory: true)

    XCTAssertTrue(resolved.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    XCTAssertNotEqual(resolved.standardizedFileURL, production.standardizedFileURL)
  }

  func testExplicitSupportOverrideWinsInsideATestProcess() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pensieve-explicit-test-root-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }

    let resolved = RecoveryStore.defaultDirectoryURL(
      fileManager: .default,
      environment: [AppSupportLocation.overrideEnvironmentKey: root.path],
      isTestProcess: true)

    XCTAssertEqual(
      resolved.standardizedFileURL,
      root.appendingPathComponent("Recovery", isDirectory: true).standardizedFileURL)
  }
}
