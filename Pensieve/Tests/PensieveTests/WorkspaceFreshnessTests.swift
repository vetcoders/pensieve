import Foundation
import XCTest

@testable import Pensieve

@MainActor
final class WorkspaceFreshnessTests: XCTestCase {
  func testPresentationSignatureChangesWhenEmptyFolderIsRenamed() throws {
    let sandbox = try makeSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    let emptyA = root.appendingPathComponent("empty-a", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyA, withIntermediateDirectories: true)

    let before = FolderManager.refreshSnapshot(
      roots: [root], exclusions: [], builder: WorkspaceScanner.defaultBuilder)
    let emptyB = root.appendingPathComponent("empty-b", isDirectory: true)
    try FileManager.default.moveItem(at: emptyA, to: emptyB)
    let after = FolderManager.refreshSnapshot(
      roots: [root], exclusions: [], builder: WorkspaceScanner.defaultBuilder)

    XCTAssertEqual(before.presentationSignature.entries.count, 2)
    XCTAssertEqual(after.presentationSignature.entries.count, 2)
    XCTAssertNotEqual(before.presentationSignature, after.presentationSignature)
    XCTAssertEqual(
      before.presentationSignature.entries,
      [
        .init(path: root.standardizedFileURL.path, kind: .folder),
        .init(path: emptyA.standardizedFileURL.path, kind: .folder),
      ]
    )
    XCTAssertEqual(
      after.presentationSignature.entries,
      [
        .init(path: root.standardizedFileURL.path, kind: .folder),
        .init(path: emptyB.standardizedFileURL.path, kind: .folder),
      ]
    )
    XCTAssertEqual(before.searchSignature, after.searchSignature)
  }

  func testEmptyFolderReconcilePublishesTreeAndCacheWithoutSearchWrite() async throws {
    let sandbox = try makeSandbox()
    let root = try makeRealFixture(in: sandbox)
    let harness = try makeHarness(in: sandbox.support)
    let appState = AppState()

    harness.manager.open(url: root, into: appState)
    await settle(harness)
    let callsAfterOpen = harness.scanProbe.callCount
    let writesAfterOpen = harness.searchWrites.totalRecords

    let emptyA = root.appendingPathComponent("empty-a", isDirectory: true)
    try FileManager.default.createDirectory(at: emptyA, withIntermediateDirectories: true)
    harness.manager.scheduleWatcherRefresh(into: appState)
    await settleWatcher(harness)

    XCTAssertEqual(harness.scanProbe.callCount, callsAfterOpen + 1)
    XCTAssertEqual(harness.searchWrites.totalRecords, writesAfterOpen)
    XCTAssertTrue(containsNode(at: emptyA, in: appState.workspaceTree))
    try assertCachedNode(emptyA, root: root, appState: appState, harness: harness)

    let emptyB = root.appendingPathComponent("empty-b", isDirectory: true)
    try FileManager.default.moveItem(at: emptyA, to: emptyB)
    harness.manager.scheduleWatcherRefresh(into: appState)
    await settleWatcher(harness)

    XCTAssertEqual(harness.scanProbe.callCount, callsAfterOpen + 2)
    XCTAssertEqual(harness.searchWrites.totalRecords, writesAfterOpen)
    XCTAssertFalse(containsNode(at: emptyA, in: appState.workspaceTree))
    XCTAssertTrue(containsNode(at: emptyB, in: appState.workspaceTree))
    try assertCachedNode(emptyB, root: root, appState: appState, harness: harness)

    try FileManager.default.removeItem(at: emptyB)
    harness.manager.scheduleWatcherRefresh(into: appState)
    await settleWatcher(harness)

    XCTAssertEqual(harness.scanProbe.callCount, callsAfterOpen + 3)
    XCTAssertEqual(harness.searchWrites.totalRecords, writesAfterOpen)
    XCTAssertFalse(containsNode(at: emptyB, in: appState.workspaceTree))
    let cached = try cachedScans(root: root, appState: appState, harness: harness)
    XCTAssertFalse(containsNode(at: emptyB, in: cached.map(\.rootNode)))
  }

  func testExplicitContentRefreshIsOneOffMainScanAndIncrementalSearchWrite() async throws {
    let sandbox = try makeSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let target = root.appendingPathComponent("target.md")
    let stable = root.appendingPathComponent("stable.md")
    try "before-token".write(to: target, atomically: true, encoding: .utf8)
    try "stable-token".write(to: stable, atomically: true, encoding: .utf8)

    let harness = try makeHarness(in: sandbox.support)
    let appState = AppState()
    harness.manager.open(url: root, into: appState)
    await settle(harness)
    let callsAfterOpen = harness.scanProbe.callCount
    let writesAfterOpen = harness.searchWrites.totalRecords
    let presentationBefore = appState.workspaceTree

    try "after-token replacement content is longer".write(
      to: target, atomically: true, encoding: .utf8)
    harness.manager.refresh(into: appState)
    await settleExplicit(harness)

    XCTAssertEqual(harness.scanProbe.callCount, callsAfterOpen + 1)
    XCTAssertEqual(harness.scanProbe.mainThreadSamples(after: callsAfterOpen), [false])
    XCTAssertEqual(harness.searchWrites.totalRecords - writesAfterOpen, 1)
    XCTAssertEqual(appState.workspaceTree, presentationBefore)
    XCTAssertEqual(
      harness.indexDatabase.search(query: "after-token", documents: appState.allDocuments).count,
      1
    )
    XCTAssertTrue(
      harness.indexDatabase.search(query: "before-token", documents: appState.allDocuments)
        .isEmpty
    )
    XCTAssertEqual(
      harness.indexDatabase.search(query: "stable-token", documents: appState.allDocuments).count,
      1
    )
  }

  func testExplicitRefreshReloadsCleanSelectionButProtectsDirtyBuffer() async throws {
    let sandbox = try makeSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("note.md")
    try "clean original".write(to: note, atomically: true, encoding: .utf8)

    let harness = try makeHarness(in: sandbox.support)
    let appState = AppState()
    harness.manager.open(url: root, into: appState)
    await settle(harness)
    let callsAfterOpen = harness.scanProbe.callCount

    try "clean external replacement".write(to: note, atomically: true, encoding: .utf8)
    harness.manager.refresh(into: appState)
    await settleExplicit(harness)

    XCTAssertEqual(appState.selectedDocumentID?.standardizedFileURL, note.standardizedFileURL)
    XCTAssertEqual(appState.documentSession.text, "clean external replacement")
    XCTAssertFalse(appState.documentSession.isDirty)

    appState.activeDocumentText = "dirty local edit"
    appState.activeDocumentDirty = true
    try "dirty external replacement is longer".write(
      to: note, atomically: true, encoding: .utf8)
    harness.manager.refresh(into: appState)
    await settleExplicit(harness)

    XCTAssertEqual(harness.scanProbe.callCount, callsAfterOpen + 2)
    XCTAssertEqual(harness.scanProbe.mainThreadSamples(after: callsAfterOpen), [false, false])
    XCTAssertEqual(appState.selectedDocumentID?.standardizedFileURL, note.standardizedFileURL)
    XCTAssertEqual(appState.documentSession.text, "dirty local edit")
    XCTAssertTrue(appState.documentSession.isDirty)
  }

  func testUnsupportedFileChurnChangesNeitherPresentationNorSearchDelivery() async throws {
    let sandbox = try makeSandbox()
    let root = try makeRealFixture(in: sandbox)
    let image = root.appendingPathComponent("assets/image.png")
    let harness = try makeHarness(in: sandbox.support)
    let appState = AppState()
    harness.manager.open(url: root, into: appState)
    await settle(harness)

    let before = FolderManager.refreshSnapshot(
      roots: [root], exclusions: [], builder: WorkspaceScanner.defaultBuilder)
    let callsAfterOpen = harness.scanProbe.callCount
    let writesAfterOpen = harness.searchWrites.totalRecords
    let treeBefore = appState.workspaceTree

    try Data([0x89, 0x50, 0x4E, 0x47, 0x01]).write(to: image)
    harness.manager.scheduleWatcherRefresh(into: appState)
    await settleWatcher(harness)
    let after = FolderManager.refreshSnapshot(
      roots: [root], exclusions: [], builder: WorkspaceScanner.defaultBuilder)

    XCTAssertEqual(harness.scanProbe.callCount, callsAfterOpen + 1)
    XCTAssertEqual(harness.scanProbe.mainThreadSamples(after: callsAfterOpen), [false])
    XCTAssertEqual(harness.searchWrites.totalRecords, writesAfterOpen)
    XCTAssertEqual(appState.workspaceTree, treeBefore)
    XCTAssertEqual(before.presentationSignature, after.presentationSignature)
    XCTAssertEqual(before.searchSignature, after.searchSignature)
  }

  func testMdFreeExclusionIsAbsentFromBothSignaturesAndDoesNotWriteSearch() async throws {
    let sandbox = try makeSandbox()
    let root = try makeRealFixture(in: sandbox)
    let assets = root.appendingPathComponent("assets", isDirectory: true)
    let nested = assets.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    let harness = try makeHarness(in: sandbox.support)
    let appState = AppState()
    harness.manager.open(url: root, into: appState)
    await settle(harness)
    let callsAfterOpen = harness.scanProbe.callCount
    let writesAfterOpen = harness.searchWrites.totalRecords

    harness.manager.addExcludedURLs([assets], into: appState)
    await settleExplicit(harness)

    let exclusion = try XCTUnwrap(
      WorkspaceExclusion.scopedKey(for: assets, roots: [root]))
    let snapshot = FolderManager.refreshSnapshot(
      roots: [root], exclusions: [exclusion], builder: WorkspaceScanner.defaultBuilder)
    let presentationPaths = Set(snapshot.presentationSignature.entries.map(\.path))

    XCTAssertEqual(harness.scanProbe.callCount, callsAfterOpen + 1)
    XCTAssertEqual(harness.scanProbe.mainThreadSamples(after: callsAfterOpen), [false])
    XCTAssertEqual(harness.searchWrites.totalRecords, writesAfterOpen)
    XCTAssertFalse(containsNode(at: assets, in: appState.workspaceTree))
    XCTAssertFalse(presentationPaths.contains(assets.standardizedFileURL.path))
    XCTAssertFalse(presentationPaths.contains(nested.standardizedFileURL.path))
    XCTAssertEqual(
      Set(snapshot.searchSignature?.entries.keys.map { $0 } ?? []),
      Set([root.appendingPathComponent("docs/a.md").standardizedFileURL.path])
    )
    XCTAssertEqual(appState.excludedWorkspacePaths, [exclusion])
  }

  private struct Sandbox {
    let root: URL
    let support: URL
  }

  private struct Harness {
    let manager: FolderManager
    let indexDatabase: IndexDatabase
    let bookmarkStore: BookmarkStore
    let cacheStore: WorkspaceCacheStore
    let scanProbe: FreshnessScanProbe
    let searchWrites: SearchWriteRecorder
  }

  private func makeSandbox() throws -> Sandbox {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveWorkspaceFreshness-\(UUID().uuidString)", isDirectory: true)
    let support = root.appendingPathComponent("Support", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return Sandbox(root: root, support: support)
  }

  private func makeRealFixture(in sandbox: Sandbox) throws -> URL {
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    let docs = root.appendingPathComponent("docs", isDirectory: true)
    let assets = root.appendingPathComponent("assets", isDirectory: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try "alpha-token".write(
      to: docs.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    try Data([0x89, 0x50, 0x4E, 0x47]).write(
      to: assets.appendingPathComponent("image.png"))
    return root
  }

  private func makeHarness(in support: URL) throws -> Harness {
    let metadataStore = WorkspaceMetadataStore(
      metadataURL: support.appendingPathComponent("workspace.json"))
    let writes = SearchWriteRecorder()
    let indexDatabase = IndexDatabase(
      databaseURL: support.appendingPathComponent("index.db"),
      searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { writes.record($0) }
    )
    let bookmarkStore = BookmarkStore(
      defaults: makeEphemeralDefaults(prefix: "PensieveWorkspaceFreshnessBookmarks"))
    let cacheStore = WorkspaceCacheStore(
      baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true))
    let scanProbe = FreshnessScanProbe()
    let manager = FolderManager(
      metadataStore: metadataStore,
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceBuilder: { roots, exclusions in
        scanProbe.record(isMainThread: Thread.isMainThread)
        return WorkspaceScanner.defaultBuilder(roots, exclusions)
      },
      workspaceSubstrate: WorkspaceSubstrate(store: cacheStore),
      // This suite asserts exact scan counts around manually driven reconciles. A live FSEvents
      // stream on the fixture root would deliver real events for the same mutations and add
      // machine-timing-dependent scans, so the watcher gets an inert injected source.
      watcher: FileWatcher(sourceFactory: { @Sendable in InertFileWatcherEventSource() }),
      watcherDebounceMilliseconds: 1
    )
    return Harness(
      manager: manager,
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      cacheStore: cacheStore,
      scanProbe: scanProbe,
      searchWrites: writes
    )
  }

  private func settle(_ harness: Harness) async {
    await harness.manager.waitForPendingWorkspaceBuild()
    await harness.manager.waitForPendingIndexUpdate()
    await harness.manager.waitForPendingWorkspaceIndexWrite()
    await harness.indexDatabase.waitForPendingReindex()
  }

  private func settleWatcher(_ harness: Harness) async {
    await harness.manager.waitForPendingWatcherRefresh()
    await harness.manager.waitForPendingIndexUpdate()
    await harness.manager.waitForPendingWorkspaceIndexWrite()
    await harness.indexDatabase.waitForPendingReindex()
  }

  private func settleExplicit(_ harness: Harness) async {
    await harness.manager.waitForPendingForcedRefresh()
    await harness.manager.waitForPendingIndexUpdate()
    await harness.manager.waitForPendingWorkspaceIndexWrite()
    await harness.indexDatabase.waitForPendingReindex()
  }

  private func cachedScans(
    root: URL,
    appState: AppState,
    harness: Harness
  ) throws -> [WorkspaceScan] {
    let identity = WorkspaceIdentity.make(
      roots: [root],
      bookmarkData: appState.bookmarkData ?? harness.bookmarkStore.bookmarkData
    )
    return try XCTUnwrap(try harness.cacheStore.readWorkspaceScans(for: identity))
  }

  private func assertCachedNode(
    _ url: URL,
    root: URL,
    appState: AppState,
    harness: Harness
  ) throws {
    let cached = try cachedScans(root: root, appState: appState, harness: harness)
    XCTAssertTrue(containsNode(at: url, in: cached.map(\.rootNode)))
  }

  private func containsNode(at url: URL, in nodes: [WorkspaceNode]) -> Bool {
    let standardizedURL = url.standardizedFileURL
    return nodes.contains { node in
      node.url?.standardizedFileURL == standardizedURL
        || containsNode(at: standardizedURL, in: node.children ?? [])
    }
  }
}

private final class FreshnessScanProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var mainThreadFlags: [Bool] = []

  func record(isMainThread: Bool) {
    lock.lock()
    mainThreadFlags.append(isMainThread)
    lock.unlock()
  }

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return mainThreadFlags.count
  }

  func mainThreadSamples(after callCount: Int) -> [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return Array(mainThreadFlags.dropFirst(callCount))
  }
}

private final class SearchWriteRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var batchSizes: [Int] = []

  func record(_ size: Int) {
    lock.lock()
    batchSizes.append(size)
    lock.unlock()
  }

  var totalRecords: Int {
    lock.lock()
    defer { lock.unlock() }
    return batchSizes.reduce(0, +)
  }
}

private final class InertFileWatcherEventSource: FileWatcherEventSource, @unchecked Sendable {
  func start(
    paths: [String],
    onEvents: @escaping @Sendable ([FileWatcherEvent]) -> Void
  ) throws {}

  func stop() {}
}
