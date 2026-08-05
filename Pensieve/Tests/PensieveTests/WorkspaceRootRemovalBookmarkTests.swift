import AppKit
import Foundation
import XCTest

@testable import Pensieve

/// `removeRoot` rebuilds the GLOBAL persisted bookmark set, so it has to
/// reconcile the two sources of open-document truth this app keeps by design:
/// the working set (`openFiles`, the persistence truth) and the live tab chain
/// across every window (`DocumentWindowRegistry`, the UI truth).
///
/// A workspace document is never in `openFiles` — `applyWorkspaceScans` takes it
/// out, because its access comes from its ROOT's bookmark. Remove that root and
/// both halves vanish at once: the root bookmark goes, and the caller's working
/// set never named the file, so the rewrite persisted nothing for a document a
/// window still has open in a tab. Its save could fail on the spot, and after a
/// relaunch the file could no longer be reopened at all.
final class WorkspaceRootRemovalBookmarkTests: XCTestCase {

  /// The load-bearing case: a document from the root being removed is open in
  /// another window's tab. It loses its root's bookmark by definition, so the
  /// rewrite has to give it one of its own.
  @MainActor
  func testRemovingRootKeepsBookmarksForItsDocumentsStillOpenInWindows() async throws {
    let scenario = try await makeScenario()

    scenario.harness.manager.removeRoot(scenario.rootA, into: scenario.appState)
    await settle(scenario.harness)

    XCTAssertEqual(
      scenario.appState.workspaceRoots.map { $0.url.standardizedFileURL },
      [scenario.rootB.standardizedFileURL]
    )

    let restoredFiles = restoredFileURLs(scenario.harness)
    XCTAssertTrue(
      restoredFiles.contains(scenario.noteInRemovedRoot.standardizedFileURL),
      """
      A document still open in a tab lost its access when its root was removed: \
      restored files were \(restoredFiles.map(\.lastPathComponent))
      """
    )
  }

  /// The union must not become a resurrection: a document of the removed root
  /// that no window holds, and that the working set never named, stays gone.
  @MainActor
  func testRemovingRootDropsBookmarksForItsDocumentsOpenInNoWindow() async throws {
    let scenario = try await makeScenario()

    scenario.harness.manager.removeRoot(scenario.rootA, into: scenario.appState)
    await settle(scenario.harness)

    let restoredFiles = restoredFileURLs(scenario.harness)
    XCTAssertFalse(
      restoredFiles.contains(scenario.fileInNoWindow.standardizedFileURL),
      """
      A file no window holds and the working set never named was resurrected: \
      restored files were \(restoredFiles.map(\.lastPathComponent))
      """
    )
  }

  /// A document covered by a SURVIVING root keeps its access through that root.
  /// Persisting it as a file bookmark too would come back as a spurious ad-hoc
  /// row in the working set on the next launch.
  @MainActor
  func testRemovingRootDoesNotMintFileBookmarksForSurvivingRootDocuments() async throws {
    let scenario = try await makeScenario()

    scenario.harness.manager.removeRoot(scenario.rootA, into: scenario.appState)
    await settle(scenario.harness)

    XCTAssertFalse(
      restoredFileURLs(scenario.harness)
        .contains(scenario.noteInSurvivingRoot.standardizedFileURL),
      "A document a surviving root already grants access to must not become an ad-hoc file bookmark"
    )
  }

  /// The working-set half must survive the rewrite untouched: an ad-hoc file the
  /// user opened from outside every root keeps its bookmark.
  @MainActor
  func testRemovingRootKeepsTheWorkingSetsOwnFiles() async throws {
    let scenario = try await makeScenario()

    scenario.harness.manager.removeRoot(scenario.rootA, into: scenario.appState)
    await settle(scenario.harness)

    XCTAssertTrue(
      restoredFileURLs(scenario.harness).contains(scenario.adHocFile.standardizedFileURL),
      "Removing a root must not disturb files the working set names in its own right"
    )
  }

  // MARK: - Scenario

  @MainActor
  private struct Scenario {
    let harness: Harness
    let appState: AppState
    let rootA: URL
    let rootB: URL
    /// Document inside the root about to be removed, open in window C.
    let noteInRemovedRoot: URL
    /// Document inside the root about to be removed, open in no window at all.
    let fileInNoWindow: URL
    /// Document inside the surviving root, open in window A.
    let noteInSurvivingRoot: URL
    /// Out-of-workspace file the working set names in its own right.
    let adHocFile: URL
  }

  /// Two roots and three document windows. The load-bearing state is ordinary,
  /// not exotic: the documents of a workspace are NOT in `openFiles` — the scan
  /// commit removes them, because their access comes from their root — so every
  /// tab showing one of them is invisible to the caller's working set.
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
    let fileInNoWindow = rootA.appendingPathComponent("closed.md")
    let noteInSurvivingRoot = rootB.appendingPathComponent("b.md")
    let adHocFile = outside.appendingPathComponent("ad-hoc.md")
    for url in [noteInRemovedRoot, fileInNoWindow, noteInSurvivingRoot, adHocFile] {
      try url.lastPathComponent.write(to: url, atomically: true, encoding: .utf8)
    }

    let harness = try makeHarness(in: sandbox.support)
    let appState = AppState()
    harness.manager.open(url: rootA, into: appState)
    harness.manager.open(url: rootB, into: appState)
    await settle(harness)
    XCTAssertNotNil(harness.manager.registerOpenFile(url: adHocFile, into: appState))

    let openFilePaths = Set(appState.openFiles.map { $0.url.standardizedFileURL.path })
    XCTAssertFalse(
      openFilePaths.contains(noteInRemovedRoot.standardizedFileURL.path),
      "Precondition: a workspace document is not in the working set — that is the whole gap"
    )
    XCTAssertTrue(openFilePaths.contains(adHocFile.standardizedFileURL.path))

    let windowA = makeWindow()
    let windowB = makeWindow()
    addTeardownBlock { @MainActor in
      for window in [windowA, windowB] { window.close() }
    }
    attach(noteInSurvivingRoot, to: windowA, in: harness.documentWindowRegistry)
    attach(noteInRemovedRoot, to: windowB, in: harness.documentWindowRegistry)

    return Scenario(
      harness: harness,
      appState: appState,
      rootA: rootA,
      rootB: rootB,
      noteInRemovedRoot: noteInRemovedRoot.standardizedFileURL,
      fileInNoWindow: fileInNoWindow.standardizedFileURL,
      noteInSurvivingRoot: noteInSurvivingRoot.standardizedFileURL,
      adHocFile: adHocFile.standardizedFileURL
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
