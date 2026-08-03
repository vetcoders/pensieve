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
    // Opening a workspace shows its tree; the document being read is the user's
    // pick (RefreshOpensNothingTests), and this test is about what a refresh
    // does to it afterwards.
    selectDocument(at: note, in: appState)
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

  // MARK: - R21 / F1: an abandoned index write must not leave a manifest the next start believes

  /// Round 21, finding 1 — the two cold-start artifacts are written in OPPOSITE orders around the
  /// index write they describe, and the skip gate trusted the wrong one.
  ///
  /// `commitWorkspaceManifest` writes the manifest and its tree fingerprint SYNCHRONOUSLY, before the
  /// paired index write is even handed to `scheduleIndexWrite`. If the quit's budget closes the
  /// termination latch in between, that write is abandoned — documents and FTS roll back — but the
  /// fingerprint stays on disk describing the tree the index does NOT hold. The `.md` signature, by
  /// contrast, is written by `persistSearchSignature` only AFTER its write reported success, so an
  /// abandoned write correctly leaves the previous one in place.
  ///
  /// The next cold start then asked only for `.valid` plus "the index has ANY rows for this
  /// workspace" — and rows from the PREVIOUS launch satisfy that. It skipped over its own repair, and
  /// because a skip issues no index write and no manifest re-commit, nothing at startup ever revisited
  /// it: on an unchanged tree the stale FTS survived indefinitely. That is the shape this pin drives —
  /// three sessions over ONE support directory, the middle one killed mid-write.
  ///
  /// The assertion is CONTENT, at the substrate: the edited body must be searchable and the superseded
  /// one must not. "It reindexed" would pass on a build that reindexed the wrong thing.
  func testAColdStartAfterAnAbandonedIndexWriteRepairsInsteadOfSkipping() async throws {
    try await assertAColdStartAfterAnAbandonedIndexWriteRepairs(
      openThirdSession: { manager, url, appState in manager.open(url: url, into: appState) })
  }

  /// The same contract on the BACKGROUND open, which carries a gate of its own: the branch at
  /// `cacheIsValid, indexedCount > 0` in the validation job's continuation suppresses the manifest
  /// commit AND `performColdIndex` exactly as the synchronous gate does, and it believed the same
  /// fingerprint. Two gates, one substrate — a fix that reached only the synchronous one would leave
  /// every background import still skipping its repair.
  func testABackgroundColdStartAfterAnAbandonedIndexWriteRepairsInsteadOfSkipping() async throws {
    try await assertAColdStartAfterAnAbandonedIndexWriteRepairs(
      openThirdSession: { manager, url, appState in
        manager.openInBackground(url: url, into: appState)
      })
  }

  /// The control, and the reason the pin above cannot be satisfied by a gate that simply never skips:
  /// a session that abandoned NOTHING must still be skipped over on the next start.
  ///
  /// The valid-skip is the whole point of the workspace cache — it is what keeps a cold start off a
  /// full reindex — so a fix that bought correctness by reindexing every launch would be a regression
  /// wearing a green test. Here the middle session closes cleanly, the `.md` signature is persisted
  /// alongside the fingerprint, and the third session must write nothing at all.
  func testAColdStartStillSkipsWhenTheMiddleSessionAbandonedNothing() async throws {
    let sandbox = try makeSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("note.md")
    try "originalneedle the body the first session indexed".write(
      to: note, atomically: true, encoding: .utf8)
    let bookmarkStore = BookmarkStore(
      defaults: makeEphemeralDefaults(prefix: "PensieveAbandonedControlBookmarks"))

    let first = try makeHarness(in: sandbox.support, bookmarkStore: bookmarkStore)
    let firstState = AppState()
    first.manager.open(url: root, into: firstState)
    await settle(first)
    try await endSession(first, state: firstState)

    // The middle session edits the file and lets its index write LAND. Signature and fingerprint end
    // the session describing the same tree, which is the state the skip exists for.
    try "editedneedle the body the middle session did index".write(
      to: note, atomically: true, encoding: .utf8)
    let second = try makeHarness(in: sandbox.support, bookmarkStore: bookmarkStore)
    let secondState = AppState()
    second.manager.open(url: root, into: secondState)
    await settle(second)
    XCTAssertGreaterThan(
      second.searchWrites.totalRecords, 0,
      "fixture precondition: the middle session must actually have written its index, or this is the "
        + "abandoned case wearing the control's name")
    try await endSession(second, state: secondState)

    let third = try makeHarness(in: sandbox.support, bookmarkStore: bookmarkStore)
    let thirdState = AppState()
    third.manager.open(url: root, into: thirdState)
    await settle(third)

    XCTAssertEqual(
      third.searchWrites.totalRecords, 0,
      "a cold start whose persisted signature still describes the tree must take the valid-skip — the "
        + "round-21 corroboration tightens the gate, it does not retire it")
    XCTAssertEqual(
      third.indexDatabase.search(query: "editedneedle", documents: thirdState.allDocuments).count, 1,
      "…and the index it skipped over must be the correct one")
  }

  /// Three sessions over ONE support directory: a warm baseline, a session whose index write is
  /// abandoned after its manifest has already been persisted, and the cold start that has to repair.
  ///
  /// The middle session is killed with `backgroundWriteGateOverride` plus `closeForTermination()`
  /// rather than a wedge inside the write, because that is where the quit's latch actually closes:
  /// `commitWorkspaceManifest` has already committed the fingerprint to the cache store (a synchronous
  /// FILE write, which no database rollback can retract), and everything it handed to
  /// `scheduleIndexWrite` — plus `performColdIndex`'s own delta — is still parked in front of the pool.
  ///
  /// Each session gets a FRESH `IndexDatabase` and `FolderManager` over the same directory, which is
  /// what "the process restarted" means here; the bookmark store is shared, because a new bookmark
  /// would change the `WorkspaceIdentity` and every session would miss the cache for the wrong reason.
  private func assertAColdStartAfterAnAbandonedIndexWriteRepairs(
    openThirdSession: (FolderManager, URL, AppState) -> Void
  ) async throws {
    let sandbox = try makeSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let note = root.appendingPathComponent("note.md")
    try "originalneedle the body the first session indexed".write(
      to: note, atomically: true, encoding: .utf8)
    let bookmarkStore = BookmarkStore(
      defaults: makeEphemeralDefaults(prefix: "PensieveAbandonedManifestBookmarks"))

    // Session 1 — the warm baseline every later session is measured against: manifest, fingerprint,
    // `.md` signature and FTS rows all agreeing on the original body.
    let first = try makeHarness(in: sandbox.support, bookmarkStore: bookmarkStore)
    let firstState = AppState()
    first.manager.open(url: root, into: firstState)
    await settle(first)
    XCTAssertEqual(
      first.indexDatabase.search(query: "originalneedle", documents: firstState.allDocuments).count,
      1, "fixture precondition: the first session must leave a populated index behind")
    try await endSession(first, state: firstState)

    // Session 2 — the edit lands on DISK, the manifest and its fingerprint land in the cache store,
    // and then the quit closes the latch while every index write is still parked in front of the pool.
    try "editedneedle the body no index write ever recorded".write(
      to: note, atomically: true, encoding: .utf8)
    let gate = ParkedWriteGate()
    let second = try makeHarness(in: sandbox.support, bookmarkStore: bookmarkStore)
    second.indexDatabase.backgroundWriteGateOverride = { await gate.arrive() }
    let secondState = AppState()
    second.manager.open(url: root, into: secondState)
    try await waitUntil("an index write to park in front of the pool") { await gate.arrivals >= 1 }
    second.indexDatabase.closeForTermination()
    await gate.open()
    await settle(second)

    XCTAssertEqual(
      second.searchWrites.totalRecords, 0,
      "fixture precondition: NOTHING may have been written — the latch closed while every write was "
        + "still parked, which is the state the finding is about")

    // Session 3 — the restart. Fresh database, fresh manager, same directory on disk.
    let third = try makeHarness(in: sandbox.support, bookmarkStore: bookmarkStore)
    let thirdState = AppState()
    openThirdSession(third.manager, root, thirdState)
    await settle(third)

    XCTAssertEqual(
      third.indexDatabase.search(query: "editedneedle", documents: thirdState.allDocuments).count, 1,
      "a cold start whose fingerprint matches an index the abandoned write never delivered must take "
        + "the FULL cold path and repair: the persisted `.md` signature is the only artifact written "
        + "AFTER its index write, so it is the only one that can corroborate the fingerprint")
    XCTAssertTrue(
      third.indexDatabase.search(query: "originalneedle", documents: thirdState.allDocuments)
        .isEmpty,
      "…and the superseded body must be gone, not merely joined by the new one — a skip left it "
        + "there for the life of the workspace, because a skip issues no write and no re-commit")
    XCTAssertGreaterThan(
      third.searchWrites.totalRecords, 0,
      "…which necessarily means this start wrote an index at all, rather than skipping over its own "
        + "repair")
  }

  /// Ends a session the way a quit does, and — the part these multi-session pins cannot do without —
  /// WAITS for the close-time maintenance pass.
  ///
  /// `closeWorkspace` arms that pass without awaiting it, and it takes the pool's barrier (and, on a
  /// legacy file, the `auto_vacuum` conversion). Every session here keeps its own `DatabasePool` alive
  /// over the same file, so a next session opened while that barrier is held meets `SQLite error 5:
  /// database is locked` and writes NOTHING — which would make the control fail for a reason that has
  /// nothing to do with the skip gate, and could make an abandoned-write pin pass for one.
  private func endSession(_ harness: Harness, state: AppState) async throws {
    harness.manager.closeWorkspace(into: state)
    await harness.manager.waitForPendingIndexMaintenance()
    await harness.indexDatabase.waitForPendingReindex()
  }

  /// Parks EVERY background index write until the test opens it. The round-21 F1 fixture needs all of
  /// them held at once: the manifest's three writes and `performColdIndex`'s delta are what the latch
  /// has to catch still queued.
  private actor ParkedWriteGate {
    private(set) var arrivals = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arrive() async {
      arrivals += 1
      guard !isOpen else { return }
      await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
      isOpen = true
      for waiter in waiters { waiter.resume() }
      waiters.removeAll()
    }
  }

  private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 10,
    _ condition: () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("timed out waiting for \(description)")
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

  /// `bookmarkStore` is injectable for the round-21 multi-session pins only: a workspace's cache
  /// identity is derived from its bookmark data, so a "restart" that minted a new bookmark store would
  /// miss the cache for a reason that has nothing to do with what is being tested.
  private func makeHarness(in support: URL, bookmarkStore: BookmarkStore? = nil) throws -> Harness {
    let metadataStore = WorkspaceMetadataStore(
      metadataURL: support.appendingPathComponent("workspace.json"))
    let writes = SearchWriteRecorder()
    let indexDatabase = IndexDatabase(
      databaseURL: support.appendingPathComponent("index.db"),
      searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { writes.record($0) }
    )
    let bookmarkStore =
      bookmarkStore
      ?? BookmarkStore(
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
