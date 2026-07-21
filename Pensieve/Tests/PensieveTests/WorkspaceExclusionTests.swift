import Foundation
import XCTest

@testable import Pensieve

final class WorkspaceExclusionTests: XCTestCase {
  @MainActor
  func testMarkdownFreeFolderDisappearsImmediatelyAndStaysExcludedAfterReopen() async throws {
    let sandbox = try makeSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    let assets = root.appendingPathComponent("Assets", isDirectory: true)
    let image = assets.appendingPathComponent("cover.png")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
    try "# Keep".write(
      to: root.appendingPathComponent("keep.md"),
      atomically: true,
      encoding: .utf8
    )

    let harness = try makeHarness(in: sandbox.support)
    let appState = AppState()
    harness.manager.open(url: root, into: appState)
    await settle(harness)
    XCTAssertTrue(containsNode(at: assets, in: appState.workspaceTree))

    harness.manager.addExcludedURLs([assets], into: appState)
    await settle(harness)

    let expectedKey = try XCTUnwrap(
      WorkspaceExclusion.scopedKey(for: assets, roots: [root])
    )
    XCTAssertFalse(containsNode(at: assets, in: appState.workspaceTree))
    XCTAssertEqual(appState.excludedWorkspacePaths, [expectedKey])
    XCTAssertEqual(harness.metadataStore.load().excludedPaths, [expectedKey])
    XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))

    let reopenedState = AppState()
    let reopenedManager = FolderManager(
      metadataStore: harness.metadataStore,
      indexDatabase: harness.indexDatabase,
      bookmarkStore: harness.bookmarkStore,
      workspaceSubstrate: harness.workspaceSubstrate
    )
    reopenedManager.open(url: root, into: reopenedState)
    await settle(reopenedManager, indexDatabase: harness.indexDatabase)

    XCTAssertFalse(containsNode(at: assets, in: reopenedState.workspaceTree))
    XCTAssertEqual(reopenedState.excludedWorkspacePaths, [expectedKey])
  }

  @MainActor
  func testMarkdownExclusionDeletesFTSRowsAndClearRestoresThemWithoutTouchingDisk() async throws {
    let sandbox = try makeSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    let hidden = root.appendingPathComponent("Hidden", isDirectory: true)
    let secret = hidden.appendingPathComponent("secret.md")
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try "quasar-needle".write(to: secret, atomically: true, encoding: .utf8)
    try "ordinary".write(
      to: root.appendingPathComponent("keep.md"), atomically: true, encoding: .utf8)

    let harness = try makeHarness(in: sandbox.support)
    let appState = AppState()
    harness.manager.open(url: root, into: appState)
    await settle(harness)
    let secretDocument = try XCTUnwrap(
      appState.documents.first { $0.url.standardizedFileURL == secret.standardizedFileURL }
    )
    XCTAssertEqual(
      harness.indexDatabase.search(
        query: "quasar", documents: [secretDocument], appState: appState
      ).count,
      1
    )

    harness.manager.addExcludedURLs([hidden], into: appState)
    await settle(harness)

    XCTAssertFalse(appState.documents.contains { $0.id == secretDocument.id })
    XCTAssertTrue(
      harness.indexDatabase.search(
        query: "quasar", documents: [secretDocument], appState: appState
      ).isEmpty
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))

    harness.manager.clearExclusions(into: appState)
    await settle(harness)

    XCTAssertTrue(appState.excludedWorkspacePaths.isEmpty)
    XCTAssertTrue(appState.documents.contains { $0.id == secretDocument.id })
    XCTAssertEqual(
      harness.indexDatabase.search(
        query: "quasar", documents: [secretDocument], appState: appState
      ).count,
      1
    )
  }

  @MainActor
  func testExclusionIsScopedToOneRootAndLegacyBarePathsRemainReadable() async throws {
    let sandbox = try makeSandbox()
    let rootA = sandbox.root.appendingPathComponent("RootA", isDirectory: true)
    let rootB = sandbox.root.appendingPathComponent("RootB", isDirectory: true)
    let docsA = rootA.appendingPathComponent("docs", isDirectory: true)
    let docsB = rootB.appendingPathComponent("docs", isDirectory: true)
    let noteA = docsA.appendingPathComponent("a.md")
    let noteB = docsB.appendingPathComponent("b.md")
    try FileManager.default.createDirectory(at: docsA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: docsB, withIntermediateDirectories: true)
    try "alpha".write(to: noteA, atomically: true, encoding: .utf8)
    try "beta".write(to: noteB, atomically: true, encoding: .utf8)

    let harness = try makeHarness(in: sandbox.support)
    let appState = AppState()
    harness.manager.open(url: rootA, into: appState)
    harness.manager.open(url: rootB, into: appState)
    await settle(harness)

    harness.manager.addExcludedURLs([docsA], into: appState)
    await settle(harness)

    XCTAssertFalse(
      appState.documents.contains { $0.url.standardizedFileURL == noteA.standardizedFileURL }
    )
    XCTAssertTrue(
      appState.documents.contains { $0.url.standardizedFileURL == noteB.standardizedFileURL }
    )
    XCTAssertEqual(
      appState.excludedWorkspacePaths,
      [try XCTUnwrap(WorkspaceExclusion.scopedKey(for: docsA, roots: [rootA, rootB]))]
    )

    // Compatibility contract: old bare metadata still applies to every root. New writes above
    // are scoped, so only legacy state retains the historical cross-root behavior.
    try harness.metadataStore.save(WorkspaceMetadata(excludedPaths: ["docs"]))
    let legacyState = AppState()
    let legacyManager = FolderManager(
      metadataStore: harness.metadataStore,
      indexDatabase: harness.indexDatabase,
      bookmarkStore: harness.bookmarkStore,
      workspaceSubstrate: harness.workspaceSubstrate
    )
    legacyManager.open(url: rootA, into: legacyState)
    legacyManager.open(url: rootB, into: legacyState)
    await settle(legacyManager, indexDatabase: harness.indexDatabase)
    XCTAssertTrue(legacyState.documents.isEmpty)
  }

  @MainActor
  func testRemovingOneRootUpdatesBookmarksIndexWatcherInputsAndProtectsDirtyBuffer() async throws {
    let sandbox = try makeSandbox()
    let rootA = sandbox.root.appendingPathComponent("RootA", isDirectory: true)
    let rootB = sandbox.root.appendingPathComponent("RootB", isDirectory: true)
    try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
    let noteA = rootA.appendingPathComponent("a.md")
    let noteB = rootB.appendingPathComponent("b.md")
    try "root-a-needle".write(to: noteA, atomically: true, encoding: .utf8)
    try "root-b".write(to: noteB, atomically: true, encoding: .utf8)

    let harness = try makeHarness(in: sandbox.support)
    let appState = AppState()
    harness.manager.open(url: rootA, into: appState)
    harness.manager.open(url: rootB, into: appState)
    await settle(harness)
    let documentA = try XCTUnwrap(
      appState.documents.first { $0.url.standardizedFileURL == noteA.standardizedFileURL }
    )
    let documentB = try XCTUnwrap(
      appState.documents.first { $0.url.standardizedFileURL == noteB.standardizedFileURL }
    )
    DocumentStore(indexDatabase: harness.indexDatabase).load(ref: documentA, into: appState)
    appState.activeDocumentText = "unsaved root A buffer"
    appState.activeDocumentDirty = true

    harness.manager.removeRoot(rootA, into: appState)
    await settle(harness)

    XCTAssertEqual(
      appState.workspaceRoots.map { $0.url.standardizedFileURL },
      [rootB.standardizedFileURL]
    )
    XCTAssertEqual(
      appState.documents.map { $0.url.standardizedFileURL },
      [noteB.standardizedFileURL]
    )
    XCTAssertEqual(appState.activeDocumentURL?.standardizedFileURL, noteA.standardizedFileURL)
    XCTAssertEqual(appState.activeDocumentText, "unsaved root A buffer")
    XCTAssertTrue(appState.activeDocumentDirty)
    XCTAssertTrue(
      harness.indexDatabase.search(
        query: "root-a-needle", documents: [documentA], appState: appState
      ).isEmpty
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: noteA.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: noteB.path))

    let restoredState = AppState()
    let restored = harness.bookmarkStore.restoreWorkspace(into: restoredState)
    XCTAssertEqual(restored.rootURLs.map(\.standardizedFileURL), [rootB.standardizedFileURL])

    // Removing the last root delegates to closeWorkspace and preserves the same dirty session.
    harness.manager.removeRoot(rootB, into: appState)
    await settle(harness)
    XCTAssertTrue(appState.workspaceRoots.isEmpty)
    XCTAssertEqual(appState.activeDocumentText, "unsaved root A buffer")
    XCTAssertTrue(appState.activeDocumentDirty)
    XCTAssertTrue(harness.bookmarkStore.restoreWorkspace(into: AppState()).rootURLs.isEmpty)
    XCTAssertTrue(
      harness.indexDatabase.search(
        query: "root-b", documents: [documentB], appState: appState
      ).isEmpty
    )
  }

  private struct Sandbox {
    let root: URL
    let support: URL
  }

  @MainActor
  private struct Harness {
    let manager: FolderManager
    let indexDatabase: IndexDatabase
    let metadataStore: WorkspaceMetadataStore
    let bookmarkStore: BookmarkStore
    let workspaceSubstrate: WorkspaceSubstrate
  }

  private func makeSandbox() throws -> Sandbox {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveWorkspaceExclusionTests-\(UUID().uuidString)",
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
    let metadataStore = WorkspaceMetadataStore(
      metadataURL: support.appendingPathComponent("workspace.json")
    )
    let indexDatabase = IndexDatabase(
      databaseURL: support.appendingPathComponent("index.db")
    )
    let bookmarkStore = BookmarkStore(
      defaults: makeEphemeralDefaults(prefix: "PensieveWorkspaceExclusionBookmarks"))
    let workspaceSubstrate = WorkspaceSubstrate(
      store: WorkspaceCacheStore(
        baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true)
      )
    )
    let manager = FolderManager(
      metadataStore: metadataStore,
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceSubstrate: workspaceSubstrate
    )
    return Harness(
      manager: manager,
      indexDatabase: indexDatabase,
      metadataStore: metadataStore,
      bookmarkStore: bookmarkStore,
      workspaceSubstrate: workspaceSubstrate
    )
  }

  @MainActor
  private func settle(_ harness: Harness) async {
    await settle(harness.manager, indexDatabase: harness.indexDatabase)
  }

  @MainActor
  private func settle(_ manager: FolderManager, indexDatabase: IndexDatabase) async {
    await manager.waitForPendingWorkspaceBuild()
    await manager.waitForPendingForcedRefresh()
    await manager.waitForPendingIndexUpdate()
    await manager.waitForPendingWorkspaceIndexWrite()
    await indexDatabase.waitForPendingReindex()
  }

  private func containsNode(at url: URL, in nodes: [WorkspaceNode]) -> Bool {
    let standardizedURL = url.standardizedFileURL
    return nodes.contains { node in
      node.url?.standardizedFileURL == standardizedURL
        || containsNode(at: standardizedURL, in: node.children ?? [])
    }
  }
}
