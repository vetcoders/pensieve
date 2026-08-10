import XCTest

@testable import Pensieve

/// S5: a diagnostic run must be able to keep its Application Support state out
/// of the operator's. The override is the only lever that does that without
/// moving the operator's real directory aside. Tests also share one temporary
/// root across every default store, so an accidentally reached singleton cannot
/// read or write the operator's production state.
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

  func testEveryDefaultStoreSharesOneTemporaryRootInsideATestProcess() throws {
    let expectedRoot = AppSupportLocation.isolationRoot(
      environment: [:], fileManager: .default, isTestProcess: true)
    let productionRoot = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Pensieve", isDirectory: true)

    let recoveryRoot = RecoveryStore.defaultDirectoryURL(
      fileManager: .default, environment: [:], isTestProcess: true)
      .deletingLastPathComponent()
    let workspaceRoot = WorkspaceMetadataStore.applicationSupportDirectory(
      environment: [:], fileManager: .default, isTestProcess: true)
    let indexRoot = try IndexDatabase.applicationSupportDirectory(
      environment: [:], fileManager: .default, isTestProcess: true)
    let aiSessionRoot = DocumentAISessionStore.defaultFileURL(
      environment: [:], fileManager: .default, isTestProcess: true)
      .deletingLastPathComponent()

    for root in [recoveryRoot, workspaceRoot, indexRoot, aiSessionRoot] {
      XCTAssertEqual(root.standardizedFileURL, expectedRoot?.standardizedFileURL)
      XCTAssertNotEqual(root.standardizedFileURL, productionRoot.standardizedFileURL)
    }
  }

  func testExplicitSupportOverrideWinsForEveryDefaultStoreInsideATestProcess() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pensieve-all-store-override-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    let environment = [AppSupportLocation.overrideEnvironmentKey: root.path]

    let resolvedRoots = try [
      RecoveryStore.defaultDirectoryURL(
        fileManager: .default, environment: environment, isTestProcess: true)
        .deletingLastPathComponent(),
      WorkspaceMetadataStore.applicationSupportDirectory(
        environment: environment, fileManager: .default, isTestProcess: true),
      IndexDatabase.applicationSupportDirectory(
        environment: environment, fileManager: .default, isTestProcess: true),
      DocumentAISessionStore.defaultFileURL(
        environment: environment, fileManager: .default, isTestProcess: true)
        .deletingLastPathComponent(),
    ]

    XCTAssertTrue(
      resolvedRoots.allSatisfy { $0.standardizedFileURL == root.standardizedFileURL })
  }
}
