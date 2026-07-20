import XCTest

@testable import Pensieve

@MainActor
final class WorkspaceScanSafetyTests: XCTestCase {
  func testScannerExcludesHomeExternalAndCycleSymlinks() throws {
    let root = try makeTemporaryFolder(prefix: "PensieveScanSafetyRoot")
    let external = try makeTemporaryFolder(prefix: "PensieveScanSafetyExternal")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: external)
    }

    let localNote = root.appendingPathComponent("local.md")
    let externalNote = external.appendingPathComponent("external.md")
    try "# Local".write(to: localNote, atomically: true, encoding: .utf8)
    try "# External".write(to: externalNote, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("home-link"),
      withDestinationURL: FileManager.default.homeDirectoryForCurrentUser
    )
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("external-link"),
      withDestinationURL: external
    )
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("self-cycle"),
      withDestinationURL: root
    )

    let startedAt = ContinuousClock.now
    let scans = WorkspaceScanner.build(rootURLs: [root], exclusions: [])
    let elapsed = ContinuousClock.now - startedAt

    XCTAssertLessThan(elapsed, .seconds(1), "a symlink cycle must terminate promptly")
    XCTAssertEqual(scans.count, 1)
    XCTAssertEqual(scans[0].documents.map(\.url), [localNote.standardizedFileURL])

    let nodes = flatten(scans[0].rootNode)
    XCTAssertFalse(nodes.contains { $0.name == "home-link" })
    XCTAssertFalse(nodes.contains { $0.name == "external-link" })
    XCTAssertFalse(nodes.contains { $0.name == "self-cycle" })
    XCTAssertTrue(
      nodes.compactMap(\.url).allSatisfy { WorkspaceScanner.contains($0, in: root) },
      "the scanner must never publish a node outside its root"
    )
  }

  func testScannerPreservesWorkspaceOpenedThroughSymlinkWithoutFollowingNestedSymlinks() throws {
    let container = try makeTemporaryFolder(prefix: "PensieveSymlinkRoot")
    let external = try makeTemporaryFolder(prefix: "PensieveSymlinkRootExternal")
    defer {
      try? FileManager.default.removeItem(at: container)
      try? FileManager.default.removeItem(at: external)
    }

    let realRoot = container.appendingPathComponent("real", isDirectory: true)
    let linkedRoot = container.appendingPathComponent("linked")
    try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
    try "# Local".write(
      to: realRoot.appendingPathComponent("local.md"), atomically: true, encoding: .utf8)
    try "# External".write(
      to: external.appendingPathComponent("external.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: realRoot.appendingPathComponent("external-link"), withDestinationURL: external)

    let scans = WorkspaceScanner.build(rootURLs: [linkedRoot], exclusions: [])

    XCTAssertEqual(scans.count, 1)
    XCTAssertEqual(
      scans[0].documents.map(\.url),
      [linkedRoot.appendingPathComponent("local.md").standardizedFileURL])
    XCTAssertFalse(flatten(scans[0].rootNode).contains { $0.name == "external-link" })
  }

  func testCancellableScannerThrowsWithoutReturningPartialScan() async throws {
    let root = try makeTemporaryFolder(prefix: "PensieveScanCancellation")
    defer { try? FileManager.default.removeItem(at: root) }

    for index in 0..<300 {
      let directory = root.appendingPathComponent("folder-\(index)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try "# \(index)".write(
        to: directory.appendingPathComponent("note.md"),
        atomically: true,
        encoding: .utf8
      )
    }

    let startedAt = ContinuousClock.now
    let scanTask = Task.detached {
      try WorkspaceScanner.buildCancellable(rootURLs: [root], exclusions: [])
    }
    scanTask.cancel()

    do {
      _ = try await scanTask.value
      XCTFail("a cancelled scan must not return a partial result")
    } catch is CancellationError {
      // Expected: cancellation is explicit and no scan can be published.
    }
    XCTAssertLessThan(
      ContinuousClock.now - startedAt,
      .seconds(1),
      "cooperative cancellation must finish within a bounded interval"
    )
  }

  func testHotReopenValidationAndMissingSignatureFallbackStayOffMainAndWalkOnce() async throws {
    let root = try makeTemporaryFolder(prefix: "PensieveHotReopenSafety")
    let support = try makeTemporaryFolder(prefix: "PensieveHotReopenSupport")
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: support)
    }
    let noteURL = root.appendingPathComponent("hot.md")
    try "# Hot".write(to: noteURL, atomically: true, encoding: .utf8)

    let store = WorkspaceCacheStore(baseDirectory: support)
    let substrate = WorkspaceSubstrate(store: store)
    let counter = ScanSafetyCounter()
    let scanStarted = expectation(description: "hot-reopen scan started")
    let releaseScan = DispatchSemaphore(value: 0)
    let probe = ScanSafetyProbeRecorder()
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: IndexDatabase(
        databaseURL: support.appendingPathComponent("index.db", isDirectory: false)),
      bookmarkStore: try temporaryBookmarkStore(),
      workspaceBuilder: { roots, exclusions in
        let call = counter.increment()
        if call == 2 {
          scanStarted.fulfill()
          releaseScan.wait()
        }
        return WorkspaceScanner.defaultBuilder(roots, exclusions)
      },
      workspaceSubstrate: substrate,
      workspaceValidationProbe: { stage in probe.record(stage) }
    )

    // Warm the manifest, index, and presentation tree synchronously.
    manager.open(url: root, into: appState)
    await manager.waitForPendingIndexUpdate()
    let identity = WorkspaceIdentity.make(
      roots: [root], bookmarkData: appState.bookmarkData)
    try? FileManager.default.removeItem(at: store.searchSignatureURL(for: identity))

    let startedAt = ContinuousClock.now
    manager.openInBackground(url: root, into: appState)
    let callDuration = ContinuousClock.now - startedAt
    XCTAssertLessThan(
      callDuration,
      .milliseconds(100),
      "hot reopen must return to the main actor before validation starts walking"
    )
    await fulfillment(of: [scanStarted], timeout: 1)
    XCTAssertEqual(appState.documents.map(\.url), [noteURL.standardizedFileURL])
    XCTAssertNil(appState.workspaceActivity, "stale content stays usable during revalidation")

    let heartbeat = expectation(description: "main actor heartbeat")
    Task { @MainActor in heartbeat.fulfill() }
    await fulfillment(of: [heartbeat], timeout: 0.1)

    releaseScan.signal()
    await manager.waitForPendingWorkspaceBuild()

    let observations = probe.snapshot()
    XCTAssertEqual(Set(observations.map(\.stage)), Set(WorkspaceValidationStage.allCases))
    XCTAssertTrue(
      observations.allSatisfy { !$0.wasMainThread },
      "scan, fingerprint, substrate validation, and signature fallback must all run off-main"
    )
    XCTAssertEqual(counter.value, 2, "warm open + one hot-reopen walk; no validation re-walk")
    XCTAssertNil(appState.workspaceActivity)
  }

  func testSupersededOpenCannotPublishOrClearNewerOpenActivity() async throws {
    let firstRoot = try makeTemporaryFolder(prefix: "PensieveSupersededA")
    let secondRoot = try makeTemporaryFolder(prefix: "PensieveSupersededB")
    let support = try makeTemporaryFolder(prefix: "PensieveSupersededSupport")
    defer {
      try? FileManager.default.removeItem(at: firstRoot)
      try? FileManager.default.removeItem(at: secondRoot)
      try? FileManager.default.removeItem(at: support)
    }
    let firstNote = firstRoot.appendingPathComponent("a.md")
    let secondNote = secondRoot.appendingPathComponent("b.md")
    try "# A".write(to: firstNote, atomically: true, encoding: .utf8)
    try "# B".write(to: secondNote, atomically: true, encoding: .utf8)

    let firstStarted = expectation(description: "first scan started")
    let releaseFirst = DispatchSemaphore(value: 0)
    let secondStarted = expectation(description: "second scan started")
    let releaseSecond = DispatchSemaphore(value: 0)
    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: IndexDatabase(
        databaseURL: support.appendingPathComponent("index.db", isDirectory: false)),
      bookmarkStore: try temporaryBookmarkStore(),
      workspaceBuilder: { roots, exclusions in
        if roots.map({ $0.standardizedFileURL }).contains(firstRoot.standardizedFileURL) {
          firstStarted.fulfill()
          releaseFirst.wait()
        } else {
          secondStarted.fulfill()
          releaseSecond.wait()
        }
        return WorkspaceScanner.defaultBuilder(roots, exclusions)
      },
      workspaceSubstrate: WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: support))
    )

    manager.openInBackground(url: firstRoot, into: appState)
    await fulfillment(of: [firstStarted], timeout: 1)
    XCTAssertEqual(appState.workspaceActivity?.kind, .opening)

    manager.closeWorkspace(into: appState)
    manager.openInBackground(url: secondRoot, into: appState)
    await fulfillment(of: [secondStarted], timeout: 1)
    XCTAssertEqual(appState.workspaceActivity?.kind, .opening)

    releaseFirst.signal()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(
      appState.workspaceActivity?.kind,
      .opening,
      "the cancelled A flow must not clear B's activity"
    )
    XCTAssertFalse(appState.documents.contains { $0.url == firstNote.standardizedFileURL })

    releaseSecond.signal()
    await manager.waitForPendingWorkspaceBuild()
    await manager.waitForPendingIndexUpdate()
    XCTAssertEqual(appState.documents.map(\.url), [secondNote.standardizedFileURL])
    XCTAssertNil(appState.workspaceActivity)
  }

  private func makeTemporaryFolder(prefix: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func temporaryMetadataStore() -> WorkspaceMetadataStore {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveScanSafetyMetadata-\(UUID().uuidString)", isDirectory: true)
    return WorkspaceMetadataStore(
      metadataURL: folder.appendingPathComponent("workspace.json", isDirectory: false))
  }

  private func temporaryBookmarkStore() throws -> BookmarkStore {
    let suiteName = "PensieveScanSafetyBookmarks-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return BookmarkStore(defaults: defaults)
  }

  private func flatten(_ root: WorkspaceNode) -> [WorkspaceNode] {
    [root] + (root.children ?? []).flatMap(flatten)
  }
}

private final class ScanSafetyCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  @discardableResult
  func increment() -> Int {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return count
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

private final class ScanSafetyProbeRecorder: @unchecked Sendable {
  struct Observation: Sendable {
    var stage: WorkspaceValidationStage
    var wasMainThread: Bool
  }

  private let lock = NSLock()
  private var observations: [Observation] = []

  func record(_ stage: WorkspaceValidationStage) {
    lock.lock()
    defer { lock.unlock() }
    observations.append(Observation(stage: stage, wasMainThread: Thread.isMainThread))
  }

  func snapshot() -> [Observation] {
    lock.lock()
    defer { lock.unlock() }
    return observations
  }
}
