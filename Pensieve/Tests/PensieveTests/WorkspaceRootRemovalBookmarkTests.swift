import AppKit
import Foundation
import XCTest

@testable import Pensieve

/// `removeRoot` rebuilds the GLOBAL persisted bookmark set, so it has to
/// reconcile the two sources of open-document truth this app keeps by design:
/// the capped working set (`openFiles`, the persistence truth) and the live tab
/// chain across every window (`DocumentWindowRegistry`, the UI truth).
final class WorkspaceRootRemovalBookmarkTests: XCTestCase {

  /// Window A removes a root while window B has an out-of-workspace file open in
  /// a tab that the working set no longer lists. Rebuilding the bookmark set
  /// from `openFiles` alone silently revoked window B's sandbox access.
  @MainActor
  func testRemovingRootKeepsBookmarksForFilesOpenInOtherWindows() async throws {
    let scenario = try await makeScenario()

    scenario.harness.manager.removeRoot(scenario.rootA, into: scenario.appState)
    await settle(scenario.harness)

    XCTAssertEqual(
      scenario.appState.workspaceRoots.map { $0.url.standardizedFileURL },
      [scenario.rootB.standardizedFileURL]
    )

    let restoredFiles = restoredFileURLs(scenario.harness)
    XCTAssertTrue(
      restoredFiles.contains(scenario.fileOnlyInOtherWindow.standardizedFileURL),
      """
      A file open in another window's tab lost its security-scoped bookmark: \
      restored files were \(restoredFiles.map(\.lastPathComponent))
      """
    )
    XCTAssertTrue(
      restoredFiles.contains(scenario.noteInRemovedRoot.standardizedFileURL),
      "A document still open in a tab lost its access when its root was removed"
    )
    XCTAssertFalse(
      restoredFiles.contains(scenario.noteInSurvivingRoot.standardizedFileURL),
      "A document covered by a surviving root bookmark must not be persisted as a file bookmark"
    )
  }

  /// The union must not become a resurrection: a file that is in no window and
  /// no longer in the working set stays gone after the rewrite.
  @MainActor
  func testRemovingRootDropsBookmarksForFilesOpenInNoWindow() async throws {
    let scenario = try await makeScenario()

    scenario.harness.manager.removeRoot(scenario.rootA, into: scenario.appState)
    await settle(scenario.harness)

    let restoredFiles = restoredFileURLs(scenario.harness)
    XCTAssertFalse(
      restoredFiles.contains(scenario.fileInNoWindow.standardizedFileURL),
      """
      A file the working set dropped and no window holds was resurrected: \
      restored files were \(restoredFiles.map(\.lastPathComponent))
      """
    )
  }

  // MARK: - Scenario

  @MainActor
  private struct Scenario {
    let harness: Harness
    let appState: AppState
    let rootA: URL
    let rootB: URL
    /// Out-of-workspace file evicted from the working set, still open in window B.
    let fileOnlyInOtherWindow: URL
    /// Out-of-workspace file evicted from the working set and open nowhere.
    let fileInNoWindow: URL
    /// Document inside the root about to be removed, open in window C.
    let noteInRemovedRoot: URL
    /// Document inside the surviving root, open in window A.
    let noteInSurvivingRoot: URL
  }

  /// Two roots, three document windows, and a working set that has overflowed
  /// its `maxOpenFiles` cap — the production eviction that leaves a genuinely
  /// open tab absent from `openFiles`.
  @MainActor
  private func makeScenario() async throws -> Scenario {
    let sandbox = try makeSandbox()
    let rootA = sandbox.root.appendingPathComponent("RootA", isDirectory: true)
    let rootB = sandbox.root.appendingPathComponent("RootB", isDirectory: true)
    let outside = sandbox.root.appendingPathComponent("Outside", isDirectory: true)
    for directory in [rootA, rootB, outside] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let noteInRemovedRoot = rootA.appendingPathComponent("a.md")
    let noteInSurvivingRoot = rootB.appendingPathComponent("b.md")
    try "root-a".write(to: noteInRemovedRoot, atomically: true, encoding: .utf8)
    try "root-b".write(to: noteInSurvivingRoot, atomically: true, encoding: .utf8)

    let harness = try makeHarness(in: sandbox.support)
    let appState = AppState()
    harness.manager.open(url: rootA, into: appState)
    harness.manager.open(url: rootB, into: appState)
    await settle(harness)

    // Open two more ad-hoc files than the working set can hold. The two OLDEST
    // rows fall out of `openFiles` while their bookmarks stay persisted — the
    // exact state in which the caller's working set stops describing what the
    // app has open.
    var adHocFiles: [URL] = []
    for index in 0..<(WorkspaceStore.maxOpenFiles + 2) {
      let url = outside.appendingPathComponent("outside-\(index).md")
      try "outside-\(index)".write(to: url, atomically: true, encoding: .utf8)
      XCTAssertNotNil(harness.manager.registerOpenFile(url: url, into: appState))
      adHocFiles.append(url.standardizedFileURL)
    }
    let fileOnlyInOtherWindow = adHocFiles[0]
    let fileInNoWindow = adHocFiles[1]
    let openFilePaths = Set(appState.openFiles.map { $0.url.standardizedFileURL.path })
    XCTAssertFalse(openFilePaths.contains(fileOnlyInOtherWindow.path))
    XCTAssertFalse(openFilePaths.contains(fileInNoWindow.path))
    XCTAssertTrue(
      restoredFileURLs(harness).contains(fileOnlyInOtherWindow),
      "Precondition: the evicted file still holds its persisted bookmark"
    )

    let windowA = makeWindow()
    let windowB = makeWindow()
    let windowC = makeWindow()
    addTeardownBlock { @MainActor in
      for window in [windowA, windowB, windowC] { window.close() }
    }
    attach(noteInSurvivingRoot, to: windowA, in: harness.documentWindowRegistry)
    attach(fileOnlyInOtherWindow, to: windowB, in: harness.documentWindowRegistry)
    attach(noteInRemovedRoot, to: windowC, in: harness.documentWindowRegistry)

    return Scenario(
      harness: harness,
      appState: appState,
      rootA: rootA,
      rootB: rootB,
      fileOnlyInOtherWindow: fileOnlyInOtherWindow,
      fileInNoWindow: fileInNoWindow,
      noteInRemovedRoot: noteInRemovedRoot.standardizedFileURL,
      noteInSurvivingRoot: noteInSurvivingRoot.standardizedFileURL
    )
  }

  // MARK: - Harness

  private struct Sandbox {
    let root: URL
    let support: URL
  }

  @MainActor
  private struct Harness {
    let manager: FolderManager
    let indexDatabase: IndexDatabase
    let bookmarkStore: BookmarkStore
    let documentWindowRegistry: DocumentWindowRegistry
  }

  private func makeSandbox() throws -> Sandbox {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveWorkspaceRootRemovalTests-\(UUID().uuidString)",
        isDirectory: true
      )
    let support = root.appendingPathComponent("Support", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }
    return Sandbox(root: root, support: support)
  }

  @MainActor
  private func makeHarness(in support: URL) throws -> Harness {
    let indexDatabase = IndexDatabase(
      databaseURL: support.appendingPathComponent("index.db")
    )
    let bookmarkStore = BookmarkStore(
      defaults: makeEphemeralDefaults(prefix: "PensieveWorkspaceRootRemovalBookmarks"))
    let documentWindowRegistry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { _ in },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      applicationWindows: { [] },
      closeWindow: { _ in })
    let manager = FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: support.appendingPathComponent("workspace.json")
      ),
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      documentWindowRegistry: documentWindowRegistry,
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true)
        )
      )
    )
    return Harness(
      manager: manager,
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      documentWindowRegistry: documentWindowRegistry
    )
  }

  @MainActor
  private func settle(_ harness: Harness) async {
    await harness.manager.waitForPendingWorkspaceBuild()
    await harness.manager.waitForPendingForcedRefresh()
    await harness.manager.waitForPendingIndexUpdate()
    await harness.manager.waitForPendingWorkspaceIndexWrite()
    await harness.indexDatabase.waitForPendingReindex()
  }

  /// Files the NEXT launch would resolve from the persisted bookmark set.
  @MainActor
  private func restoredFileURLs(_ harness: Harness) -> [URL] {
    harness.bookmarkStore.restoreWorkspace(into: AppState()).fileURLs
      .map(\.standardizedFileURL)
  }

  @MainActor
  private func attach(_ url: URL, to window: NSWindow, in registry: DocumentWindowRegistry) {
    XCTAssertTrue(
      registry.attach(
        window,
        identity: .file(url.standardizedFileURL),
        documentID: url.standardizedFileURL,
        title: url.lastPathComponent,
        representedURL: url.standardizedFileURL,
        hasEditableBuffer: true))
  }

  @MainActor
  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: .zero)
    return window
  }
}
