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

  /// The process-scoped root is named per pid AND per nonce, so nothing can
  /// ever recognize a previous run's directory and clear it: every test process
  /// that reached a production singleton once used to leave one behind in
  /// `$TMPDIR` permanently. The REGISTRATION is what a test can assert — the
  /// removal itself runs after this process is gone.
  func testTheProcessScopedTestRootIsRegisteredForRemovalWhenTheProcessExits() {
    let root = AppSupportLocation.testProcessRoot()

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: root.path),
      "premise: the shared test root is created eagerly, not on first write")
    XCTAssertTrue(
      AppSupportLocation.rootsRegisteredForRemovalAtExit.contains(root.path),
      "the process-scoped test root was created without being handed to atexit — nothing else "
        + "ever deletes it, so every run of this suite leaks one directory into \(root.path)")
  }

  /// Asking twice is one directory, so it is also one registration: the handler
  /// list is process-global and a per-call `atexit_b` would grow it once per
  /// store that consulted the isolation root.
  func testRepeatedResolutionRegistersTheSharedRootOnlyOnce() {
    _ = AppSupportLocation.testProcessRoot()
    let registeredAfterFirst = AppSupportLocation.rootsRegisteredForRemovalAtExit

    _ = AppSupportLocation.isolationRoot(
      environment: [:], fileManager: .default, isTestProcess: true)

    XCTAssertEqual(AppSupportLocation.rootsRegisteredForRemovalAtExit, registeredAfterFirst)
  }

  func testFailedExitRegistrationCanRetryAndRecordsOnlyTheSuccess() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pensieve-exit-registration-retry-\(UUID().uuidString)", isDirectory: true)
    var registrationAttempts = 0
    var capturedHandler: AppSupportLocation.ProcessExitHandler?
    var removedPaths: [String] = []

    let failed = AppSupportLocation.registerForRemovalAtProcessExit(
      root,
      registrar: { _ in
        registrationAttempts += 1
        return 1
      },
      removeItem: { removedPaths.append($0) })

    XCTAssertFalse(failed)
    XCTAssertFalse(AppSupportLocation.rootsRegisteredForRemovalAtExit.contains(root.path))

    let retried = AppSupportLocation.registerForRemovalAtProcessExit(
      root,
      registrar: { handler in
        registrationAttempts += 1
        capturedHandler = handler
        return 0
      },
      removeItem: { removedPaths.append($0) })

    XCTAssertTrue(retried)
    XCTAssertEqual(registrationAttempts, 2)
    XCTAssertTrue(AppSupportLocation.rootsRegisteredForRemovalAtExit.contains(root.path))
    XCTAssertNotNil(capturedHandler)

    XCTAssertTrue(
      AppSupportLocation.registerForRemovalAtProcessExit(
        root,
        registrar: { _ in
          registrationAttempts += 1
          return 0
        },
        removeItem: { removedPaths.append($0) }))
    XCTAssertEqual(
      registrationAttempts, 2,
      "a successful path must not append a second process-exit handler")

    capturedHandler?()
    XCTAssertEqual(removedPaths, [root.path])
  }

  func testExitCallbackUsesTheInjectedRemovalOperation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pensieve-exit-callback-\(UUID().uuidString)", isDirectory: true)
    var capturedHandler: AppSupportLocation.ProcessExitHandler?
    var removedPaths: [String] = []

    XCTAssertTrue(
      AppSupportLocation.registerForRemovalAtProcessExit(
        root,
        registrar: { handler in
          capturedHandler = handler
          return 0
        },
        removeItem: { removedPaths.append($0) }))

    capturedHandler?()

    XCTAssertEqual(removedPaths, [root.path])
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
      fileManager: .default, environment: [:], isTestProcess: true
    )
    .deletingLastPathComponent()
    let workspaceRoot = WorkspaceMetadataStore.applicationSupportDirectory(
      environment: [:], fileManager: .default, isTestProcess: true)
    let indexRoot = try IndexDatabase.applicationSupportDirectory(
      environment: [:], fileManager: .default, isTestProcess: true)
    let aiSessionRoot = DocumentAISessionStore.defaultFileURL(
      environment: [:], fileManager: .default, isTestProcess: true
    )
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
        fileManager: .default, environment: environment, isTestProcess: true
      )
      .deletingLastPathComponent(),
      WorkspaceMetadataStore.applicationSupportDirectory(
        environment: environment, fileManager: .default, isTestProcess: true),
      IndexDatabase.applicationSupportDirectory(
        environment: environment, fileManager: .default, isTestProcess: true),
      DocumentAISessionStore.defaultFileURL(
        environment: environment, fileManager: .default, isTestProcess: true
      )
      .deletingLastPathComponent(),
    ]

    XCTAssertTrue(
      resolvedRoots.allSatisfy { $0.standardizedFileURL == root.standardizedFileURL })
  }
}
