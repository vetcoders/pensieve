import XCTest

@testable import Pensieve

/// Regression guards for the open-flow activity presentation: EVERY exit from the
/// background workspace build must tear the `.opening`/`.indexing` spinner down.
/// Before the generation-guarded terminal clear, two real routes left the sidebar
/// stuck on "Opening Workspace" forever:
///   1. an ad-hoc file opened mid-walk fails `matchesCurrentWorkspace` → bare return;
///   2. `refresh(force:)` (file create, exclusion edit, trash/delete) cancels the build task via
///      `applyRefresh` without ever owning the activity display.
@MainActor
final class WorkspaceOpenActivityTests: XCTestCase {
  func testColdStartPublishesCachedWorkspaceBeforeValidationWalkFinishes() async throws {
    let folder = try makeTemporaryFolder()
    let support = try makeTemporaryFolder(prefix: "PensieveCachedWorkspaceSupportTests")
    defer {
      try? FileManager.default.removeItem(at: folder)
      try? FileManager.default.removeItem(at: support)
    }
    let noteURL = folder.appendingPathComponent("instant.md")
    try "# Cached immediately".write(to: noteURL, atomically: true, encoding: .utf8)

    let store = WorkspaceCacheStore(baseDirectory: support)
    let substrate = WorkspaceSubstrate(store: store)
    let bookmarkStore = try temporaryBookmarkStore()
    let indexDatabase = IndexDatabase(
      databaseURL: support.appendingPathComponent("index.db", isDirectory: false))

    let warmState = AppState()
    let warmManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceSubstrate: substrate
    )
    warmManager.open(url: folder, into: warmState)
    await warmManager.waitForPendingIndexUpdate()

    let scanStarted = DispatchSemaphore(value: 0)
    let releaseScan = DispatchSemaphore(value: 0)
    let coldState = AppState()
    let coldManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceBuilder: { roots, exclusions in
        scanStarted.signal()
        releaseScan.wait()
        return WorkspaceScanner.defaultBuilder(roots, exclusions)
      },
      workspaceSubstrate: substrate
    )

    let startedAt = ContinuousClock.now
    coldManager.openInBackground(url: folder, into: coldState)
    XCTAssertEqual(scanStarted.wait(timeout: .now() + 1), .success)
    let elapsedToUsableWorkspace = ContinuousClock.now - startedAt
    XCTAssertLessThan(
      elapsedToUsableWorkspace,
      .milliseconds(100),
      "the cached workspace must become usable in a fraction of a second"
    )
    XCTAssertEqual(
      coldState.documents.map(\.url),
      [noteURL.standardizedFileURL],
      "a cached workspace must be usable before background validation finishes"
    )
    XCTAssertNil(
      coldState.workspaceActivity,
      "stale-while-revalidate must not cover cached content with an opening spinner"
    )

    releaseScan.signal()
    await coldManager.waitForPendingWorkspaceBuild()
  }

  func testWorkspaceMismatchMidWalkClearsOpeningActivity() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try "# Alpha".write(
      to: folder.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
    let adHocURL = folder.appendingPathComponent("outside.md")
    try "# Outside".write(to: adHocURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let gate = DispatchSemaphore(value: 0)
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: IndexDatabase(
        databaseURL: folder.appendingPathComponent("index.db", isDirectory: false)),
      bookmarkStore: try temporaryBookmarkStore(),
      workspaceBuilder: { roots, exclusions in
        gate.wait()
        return WorkspaceScanner.defaultBuilder(roots, exclusions)
      },
      workspaceSubstrate: WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: folder))
    )

    manager.openInBackground(url: folder, into: appState)
    XCTAssertEqual(
      appState.workspaceActivity?.kind, .opening,
      "background open should present the honest .opening state while the walk runs")

    // The user opens an ad-hoc file while the walk is still in flight: the build's
    // captured openFile set no longer matches, so the task bails on the mismatch guard.
    appState.openFiles.append(DocumentRef(id: adHocURL.standardizedFileURL, isAdHoc: true))
    gate.signal()
    await manager.waitForPendingWorkspaceBuild()

    XCTAssertNil(
      appState.workspaceActivity,
      "a workspace-mismatch bailout must clear the activity — not leave 'Opening Workspace' stuck"
    )
  }

  func testRefreshCancellingBackgroundOpenClearsOpeningActivity() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try "# Alpha".write(
      to: folder.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)

    let appState = AppState()
    let gate = DispatchSemaphore(value: 0)
    let walkCounter = WalkCallCounter()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: IndexDatabase(
        databaseURL: folder.appendingPathComponent("index.db", isDirectory: false)),
      bookmarkStore: try temporaryBookmarkStore(),
      // Block ONLY the cold-open walk; the refresh below re-walks synchronously on the
      // main actor and must not deadlock against the gate.
      workspaceBuilder: { roots, exclusions in
        if walkCounter.increment() == 1 {
          gate.wait()
        }
        return WorkspaceScanner.defaultBuilder(roots, exclusions)
      },
      workspaceSubstrate: WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: folder))
    )

    manager.openInBackground(url: folder, into: appState)
    XCTAssertEqual(appState.workspaceActivity?.kind, .opening)

    try FileManager.default.removeItem(at: folder.appendingPathComponent("alpha.md"))

    // A forced refresh (file create / exclusion edit / trash-delete) cancels the in-flight build via
    // applyRefresh without taking over the activity presentation.
    manager.refresh(into: appState, force: true)
    gate.signal()
    await manager.waitForPendingWorkspaceBuild()
    await manager.waitForPendingIndexUpdate()

    XCTAssertNil(
      appState.workspaceActivity,
      "a build cancelled by refresh must clear the activity — not leave 'Opening Workspace' stuck"
    )
  }

  func testCompletedBackgroundOpenStillEndsWithNoActivity() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try "# Alpha".write(
      to: folder.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)

    let appState = AppState()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: IndexDatabase(
        databaseURL: folder.appendingPathComponent("index.db", isDirectory: false)),
      bookmarkStore: try temporaryBookmarkStore(),
      workspaceSubstrate: WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: folder))
    )

    manager.openInBackground(url: folder, into: appState)
    await manager.waitForPendingWorkspaceBuild()
    await manager.waitForPendingIndexUpdate()

    XCTAssertNil(appState.workspaceActivity)
    XCTAssertEqual(appState.allDocuments.count, 1)
  }

  private func makeTemporaryFolder(prefix: String = "PensieveOpenActivityTests") throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func temporaryMetadataStore() -> WorkspaceMetadataStore {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveOpenActivityMetadataTests-\(UUID().uuidString)", isDirectory: true)
    return WorkspaceMetadataStore(
      metadataURL: folder.appendingPathComponent("workspace.json", isDirectory: false))
  }

  private func temporaryBookmarkStore() throws -> BookmarkStore {
    BookmarkStore(defaults: makeEphemeralDefaults(prefix: "PensieveOpenActivityBookmarkTests"))
  }
}

/// Thread-safe walk counter for the `@Sendable` builder closure (mirrors the pattern in
/// `IndexDatabaseV2StatsTests`).
private final class WalkCallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  @discardableResult
  func increment() -> Int {
    lock.lock()
    defer { lock.unlock() }
    count += 1
    return count
  }
}
