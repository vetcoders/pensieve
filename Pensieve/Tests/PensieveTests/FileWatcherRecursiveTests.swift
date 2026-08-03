import Foundation
import XCTest

@testable import Pensieve

@MainActor
final class FileWatcherRecursiveTests: XCTestCase {
  func testStartStopRestartStandardizesRootsAndFencesStaleCallbacks() throws {
    let sandbox = try makeSandbox()
    let rootA = sandbox.root.appendingPathComponent("Root-A", isDirectory: true)
    let rootB = sandbox.root.appendingPathComponent("Root-B", isDirectory: true)
    try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)

    let tracker = FileWatcherSourceTracker()
    let received = FileWatcherEventRecorder()
    let watcher = FileWatcher(sourceFactory: { @Sendable in tracker.makeSource() })
    let nonstandardRootA = URL(fileURLWithPath: rootA.path + "/unused/..")

    try watcher.start(watching: [rootB, nonstandardRootA, rootB]) { events in
      received.record(events)
    }
    let firstSource = try XCTUnwrap(tracker.latestSource)
    XCTAssertEqual(watcher.watchedPaths, [rootA.path, rootB.path].sorted())
    XCTAssertEqual(firstSource.paths, watcher.watchedPaths)
    XCTAssertTrue(watcher.isWatching)
    XCTAssertEqual(tracker.activeCount, 1)

    firstSource.emit([.init(path: rootA.appendingPathComponent("one.md").path)])
    XCTAssertEqual(received.batchCount, 1)

    watcher.stop()
    XCTAssertFalse(watcher.isWatching)
    XCTAssertEqual(tracker.activeCount, 0)
    firstSource.emit([.init(path: rootA.appendingPathComponent("stale.md").path)])
    XCTAssertEqual(received.batchCount, 1, "A stopped source must not escape its generation")

    try watcher.start(watching: [rootB]) { events in
      received.record(events)
    }
    let secondSource = try XCTUnwrap(tracker.latestSource)
    XCTAssertFalse(firstSource === secondSource)
    XCTAssertEqual(tracker.activeCount, 1)
    XCTAssertEqual(tracker.maximumActiveCount, 1)

    firstSource.emit([.init(path: rootA.appendingPathComponent("older.md").path)])
    secondSource.emit([.init(path: rootB.appendingPathComponent("current.md").path)])
    XCTAssertEqual(received.batchCount, 2)
  }

  func testSelfWriteSuppressionFiltersOnlyMatchingDescendantPaths() throws {
    let sandbox = try makeSandbox()
    let harness = try makeHarness(in: sandbox.support)
    let note = sandbox.root.appendingPathComponent("Root/a.md")
    let folder = sandbox.root.appendingPathComponent("Root/self-folder", isDirectory: true)
    let external = sandbox.root.appendingPathComponent("Root/deep/empty", isDirectory: true)
    harness.manager.noteSelfWrite(at: note)
    harness.manager.noteSelfWrite(at: folder)

    let actionable = harness.manager.actionableWatcherEvents([
      .init(path: note.path, flags: .itemModified),
      .init(path: folder.appendingPathComponent("child.md").path, flags: .itemCreated),
      .init(path: external.path, flags: .itemRemoved),
    ])

    XCTAssertEqual(actionable, [.init(path: external.path, flags: .itemRemoved)])

    let safetyEvents = harness.manager.actionableWatcherEvents([
      .init(path: note.path, flags: [.rootChanged]),
      .init(path: folder.path, flags: [.kernelDropped, .mustScanSubdirectories]),
    ])
    XCTAssertEqual(safetyEvents.count, 2)
    XCTAssertTrue(safetyEvents.allSatisfy(\.requiresFullReconcile))
  }

  func testInjectedBurstReconcilesDeepEmptyFolderAndDocumentOffMain() async throws {
    let sandbox = try makeSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    let deep = root.appendingPathComponent("a/b", isDirectory: true)
    let note = deep.appendingPathComponent("note.md")
    try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    try "before-watcher-token".write(to: note, atomically: true, encoding: .utf8)

    let tracker = FileWatcherSourceTracker()
    let harness = try makeHarness(in: sandbox.support, sourceTracker: tracker)
    let appState = AppState()
    harness.manager.open(url: root, into: appState)
    await settleOpen(harness)
    let source = try XCTUnwrap(tracker.latestSource)
    let callsAfterOpen = harness.scanProbe.callCount
    let writesAfterOpen = harness.searchWrites.totalRecords

    let empty = deep.appendingPathComponent("empty", isDirectory: true)
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    source.emit([.init(path: empty.path, flags: .itemCreated)])
    source.emit([.init(path: deep.path)])
    source.emit([.init(path: empty.path, flags: .itemCreated)])
    await yieldWatcherDelivery()
    await settleWatcher(harness)

    XCTAssertEqual(harness.scanProbe.callCount, callsAfterOpen + 1)
    XCTAssertEqual(harness.scanProbe.mainThreadSamples(after: callsAfterOpen), [false])
    XCTAssertEqual(harness.searchWrites.totalRecords, writesAfterOpen)
    XCTAssertTrue(containsNode(at: empty, in: appState.workspaceTree))

    try "after-watcher-token with a longer replacement".write(
      to: note, atomically: true, encoding: .utf8)
    source.emit([.init(path: note.path, flags: .itemModified)])
    await yieldWatcherDelivery()
    await settleWatcher(harness)

    XCTAssertEqual(harness.scanProbe.callCount, callsAfterOpen + 2)
    XCTAssertEqual(harness.scanProbe.mainThreadSamples(after: callsAfterOpen), [false, false])
    XCTAssertEqual(harness.searchWrites.totalRecords - writesAfterOpen, 1)
    XCTAssertEqual(
      harness.indexDatabase.search(query: "after-watcher-token", documents: appState.allDocuments)
        .count,
      1
    )
  }

  func testMixedSelfWriteCannotHideExternalDeepFolderRemoval() async throws {
    let sandbox = try makeSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    let deep = root.appendingPathComponent("a/b", isDirectory: true)
    let empty = deep.appendingPathComponent("empty", isDirectory: true)
    let note = deep.appendingPathComponent("note.md")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    try "stable".write(to: note, atomically: true, encoding: .utf8)

    let tracker = FileWatcherSourceTracker()
    let harness = try makeHarness(in: sandbox.support, sourceTracker: tracker)
    let appState = AppState()
    harness.manager.open(url: root, into: appState)
    await settleOpen(harness)
    XCTAssertTrue(containsNode(at: empty, in: appState.workspaceTree))

    harness.manager.noteSelfWrite(at: note)
    try FileManager.default.removeItem(at: empty)
    let source = try XCTUnwrap(tracker.latestSource)
    source.emit([
      .init(path: note.path, flags: .itemModified),
      .init(path: empty.path, flags: .itemRemoved),
    ])
    await yieldWatcherDelivery()
    await settleWatcher(harness)

    XCTAssertFalse(containsNode(at: empty, in: appState.workspaceTree))
  }

  func testExcludedSubtreeEventLeavesTreeAndSearchUntouched() async throws {
    let sandbox = try makeSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    let excluded = root.appendingPathComponent("Excluded", isDirectory: true)
    let secret = excluded.appendingPathComponent("secret.md")
    let visible = root.appendingPathComponent("visible.md")
    try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
    try "hidden-before-token".write(to: secret, atomically: true, encoding: .utf8)
    try "visible-token".write(to: visible, atomically: true, encoding: .utf8)

    let tracker = FileWatcherSourceTracker()
    let harness = try makeHarness(in: sandbox.support, sourceTracker: tracker)
    let appState = AppState()
    harness.manager.open(url: root, into: appState)
    await settleOpen(harness)
    harness.manager.addExcludedURLs([excluded], into: appState)
    await settleForced(harness)

    let treeBefore = appState.workspaceTree
    let callsBefore = harness.scanProbe.callCount
    let writesBefore = harness.searchWrites.totalRecords
    try "hidden-after-token with longer replacement".write(
      to: secret, atomically: true, encoding: .utf8)
    let source = try XCTUnwrap(tracker.latestSource)
    source.emit([.init(path: secret.path, flags: .itemModified)])
    await yieldWatcherDelivery()
    await settleWatcher(harness)

    XCTAssertEqual(harness.scanProbe.callCount, callsBefore + 1)
    XCTAssertEqual(harness.scanProbe.mainThreadSamples(after: callsBefore), [false])
    XCTAssertEqual(harness.searchWrites.totalRecords, writesBefore)
    XCTAssertEqual(appState.workspaceTree, treeBefore)
    XCTAssertFalse(containsNode(at: excluded, in: appState.workspaceTree))
    XCTAssertTrue(
      harness.indexDatabase.search(query: "hidden-after-token", documents: appState.allDocuments)
        .isEmpty
    )
  }

  func testScannerVisibilityFilterDropsHiddenAndExcludedDescendants() throws {
    let sandbox = try makeSandbox()
    let harness = try makeHarness(in: sandbox.support)
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    let rootPath = FileWatcher.Event(path: root.path).path

    let atomicTemp = FileWatcher.Event(
      path: root.appendingPathComponent("watched.md.sb-52ab-x1Y2z3").path,
      flags: [.itemIsFile, .itemCreated, .itemRenamed])
    let hiddenTemp = FileWatcher.Event(
      path: root.appendingPathComponent(".watched.md.tmp").path, flags: .itemRenamed)
    let deepDSStore = FileWatcher.Event(path: root.appendingPathComponent("deep/.DS_Store").path)
    let nodeModules = FileWatcher.Event(
      path: root.appendingPathComponent("node_modules/pkg/index.md").path, flags: .itemModified)
    let unsupportedFile = FileWatcher.Event(
      path: root.appendingPathComponent("deep/shot.png").path,
      flags: [.itemIsFile, .itemModified])
    let visibleDoc = FileWatcher.Event(
      path: root.appendingPathComponent("deep/note.md").path,
      flags: [.itemIsFile, .itemModified])
    let unflaggedUnknown = FileWatcher.Event(
      path: root.appendingPathComponent("deep/mystery").path, flags: .itemCreated)
    let gitIgnore = FileWatcher.Event(
      path: root.appendingPathComponent(".gitignore").path, flags: [.itemIsFile, .itemModified])
    let droppedUnderHidden = FileWatcher.Event(
      path: root.appendingPathComponent(".git/HEAD").path, flags: .kernelDropped)
    let outsideRoot = FileWatcher.Event(
      path: sandbox.root.appendingPathComponent("elsewhere.md").path)

    let visible = harness.manager.scannerVisibleWatcherEvents(
      [
        atomicTemp, hiddenTemp, deepDSStore, nodeModules, unsupportedFile, visibleDoc,
        unflaggedUnknown, gitIgnore, droppedUnderHidden, outsideRoot,
      ],
      rootPaths: [rootPath]
    )

    XCTAssertEqual(
      visible, [visibleDoc, unflaggedUnknown, gitIgnore, droppedUnderHidden, outsideRoot])
  }

  func testHiddenTempSiblingEventsScheduleNoScan() async throws {
    let sandbox = try makeSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    let note = root.appendingPathComponent("watched.md")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "body".write(to: note, atomically: true, encoding: .utf8)

    let tracker = FileWatcherSourceTracker()
    let harness = try makeHarness(in: sandbox.support, sourceTracker: tracker)
    let appState = AppState()
    harness.manager.open(url: root, into: appState)
    await settleOpen(harness)
    let source = try XCTUnwrap(tracker.latestSource)
    let callsAfterOpen = harness.scanProbe.callCount

    source.emit([
      .init(
        path: root.appendingPathComponent(".watched.md.sb-1f9a").path,
        flags: [.itemCreated, .itemRenamed]),
      .init(path: root.appendingPathComponent(".DS_Store").path, flags: .itemModified),
    ])
    await yieldWatcherDelivery()
    await settleWatcher(harness)

    XCTAssertEqual(
      harness.scanProbe.callCount, callsAfterOpen,
      "scanner-invisible churn must not schedule a scan")
  }

  /// A walk that is already enumerating cannot be stopped by re-arming the refresh, so an event
  /// source faster than one walk used to add a full-tree walk per surviving batch — bounded only
  /// by the event rate. Everything that arrives while a walk is running must collapse into ONE
  /// follow-up pass, and no two walks may ever overlap.
  func testEventBurstDuringWalkCollapsesIntoOneFollowUpWalk() async throws {
    let sandbox = try makeSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    let note = root.appendingPathComponent("note.md")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "body".write(to: note, atomically: true, encoding: .utf8)

    let tracker = FileWatcherSourceTracker()
    let gate = WatcherWalkGate()
    let harness = try makeHarness(in: sandbox.support, sourceTracker: tracker, walkGate: gate)
    let appState = AppState()
    harness.manager.open(url: root, into: appState)
    await settleOpen(harness)
    let source = try XCTUnwrap(tracker.latestSource)
    let callsAfterOpen = harness.scanProbe.callCount

    gate.close()
    let parkedWalk = gate.expectationForWalk(1)
    source.emit([.init(path: note.path, flags: .itemModified)])
    await yieldWatcherDelivery()
    await fulfillment(of: [parkedWalk], timeout: 10)

    for index in 0..<5 {
      source.emit([
        .init(
          path: root.appendingPathComponent("burst-\(index).md").path,
          flags: [.itemIsFile, .itemCreated])
      ])
      await settleDebounce()
    }
    XCTAssertEqual(
      gate.enteredWalks, 1,
      "a running walk must absorb the burst, not be joined by one walk per batch")

    gate.open()
    await settleWatcher(harness)

    XCTAssertEqual(gate.peakConcurrentWalks, 1, "watcher refresh walks must never overlap")
    XCTAssertEqual(
      harness.scanProbe.callCount, callsAfterOpen + 2,
      "a burst during a walk buys exactly one follow-up walk")
  }

  /// The other half of the coalescing contract: absorbing a burst must not swallow it. A change the
  /// parked walk provably could not have enumerated still has to reach the tree and the index —
  /// through exactly one follow-up pass, not zero and not one per event.
  func testExternalChangeDuringWalkLandsInExactlyOneFollowUpWalk() async throws {
    let sandbox = try makeSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    let note = root.appendingPathComponent("note.md")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "body".write(to: note, atomically: true, encoding: .utf8)

    let tracker = FileWatcherSourceTracker()
    let gate = WatcherWalkGate()
    let harness = try makeHarness(in: sandbox.support, sourceTracker: tracker, walkGate: gate)
    let appState = AppState()
    harness.manager.open(url: root, into: appState)
    await settleOpen(harness)
    let source = try XCTUnwrap(tracker.latestSource)
    let callsAfterOpen = harness.scanProbe.callCount

    gate.close()
    let parkedWalk = gate.expectationForWalk(1)
    source.emit([.init(path: note.path, flags: .itemModified)])
    await yieldWatcherDelivery()
    await fulfillment(of: [parkedWalk], timeout: 10)

    // Created strictly after the parked walk finished enumerating, so only a follow-up pass can
    // possibly see it.
    let external = root.appendingPathComponent("external.md")
    try "external-during-walk-token".write(to: external, atomically: true, encoding: .utf8)
    source.emit([.init(path: external.path, flags: [.itemIsFile, .itemCreated])])
    await settleDebounce()

    gate.open()
    await settleWatcher(harness)

    XCTAssertEqual(
      harness.scanProbe.callCount, callsAfterOpen + 2,
      "an external change during a walk must produce exactly one follow-up walk")
    XCTAssertTrue(containsNode(at: external, in: appState.workspaceTree))
    XCTAssertEqual(
      harness.indexDatabase.search(
        query: "external-during-walk-token", documents: appState.allDocuments
      ).count,
      1
    )
  }

  func testRealFSEventsReportsDepthTwoCreateRenameDeleteAcrossTwoRoots() async throws {
    let sandbox = try makeSandbox()
    let rootA = sandbox.root.appendingPathComponent("Real-A", isDirectory: true)
    let rootB = sandbox.root.appendingPathComponent("Real-B", isDirectory: true)
    try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)

    let watcher = FileWatcher()
    let probe = FileWatcherEventProbe()
    try watcher.start(watching: [rootA, rootB]) { events in
      let trace = events.map { "\($0.path):\($0.flags.rawValue)" }.joined(separator: ",")
      print("[pensieve-trace] fsevents \(trace)")
      probe.record(events)
    }
    defer { watcher.stop() }

    let deepA = rootA.appendingPathComponent("a/b", isDirectory: true)
    let deepB = rootB.appendingPathComponent("c/d", isDirectory: true)
    let deepAPath = FileWatcher.Event(path: deepA.path).path
    let deepBPath = FileWatcher.Event(path: deepB.path).path
    let createA = probe.expectation(description: "depth-2 create in root A") { event in
      event.path == deepAPath && event.flags.contains(.itemCreated)
    }
    let createB = probe.expectation(description: "depth-2 create in root B") { event in
      event.path == deepBPath && event.flags.contains(.itemCreated)
    }
    try FileManager.default.createDirectory(at: deepA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: deepB, withIntermediateDirectories: true)
    await fulfillment(of: [createA, createB], timeout: 6)

    let renamedA = deepA.deletingLastPathComponent().appendingPathComponent(
      "renamed-b", isDirectory: true)
    let renamedB = deepB.deletingLastPathComponent().appendingPathComponent(
      "renamed-d", isDirectory: true)
    let rootAPath = FileWatcher.Event(path: rootA.path).path
    let rootBPath = FileWatcher.Event(path: rootB.path).path
    let renameA = probe.expectation(description: "depth-2 rename in root A") { event in
      event.path.hasPrefix(rootAPath + "/") && event.flags.contains(.itemRenamed)
    }
    let renameB = probe.expectation(description: "depth-2 rename in root B") { event in
      event.path.hasPrefix(rootBPath + "/") && event.flags.contains(.itemRenamed)
    }
    try FileManager.default.moveItem(at: deepA, to: renamedA)
    try FileManager.default.moveItem(at: deepB, to: renamedB)
    await fulfillment(of: [renameA, renameB], timeout: 6)

    let renamedAPath = FileWatcher.Event(path: renamedA.path).path
    let renamedBPath = FileWatcher.Event(path: renamedB.path).path
    let removeA = probe.expectation(description: "depth-2 delete in root A") { event in
      event.path == renamedAPath && event.flags.contains(.itemRemoved)
    }
    let removeB = probe.expectation(description: "depth-2 delete in root B") { event in
      event.path == renamedBPath && event.flags.contains(.itemRemoved)
    }
    try FileManager.default.removeItem(at: renamedA)
    try FileManager.default.removeItem(at: renamedB)
    await fulfillment(of: [removeA, removeB], timeout: 6)

    XCTAssertFalse(probe.mainThreadSamples.isEmpty)
    XCTAssertTrue(probe.mainThreadSamples.allSatisfy { !$0 })
  }

  private struct Sandbox {
    let root: URL
    let support: URL
  }

  private func makeSandbox() throws -> Sandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PensieveFileWatcherRecursive-\(UUID().uuidString)", isDirectory: true)
    let support = root.appendingPathComponent("Support", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return Sandbox(root: root, support: support)
  }

  private func makeHarness(
    in support: URL,
    sourceTracker: FileWatcherSourceTracker = FileWatcherSourceTracker(),
    walkGate: WatcherWalkGate? = nil
  ) throws -> WatcherRefreshHarness {
    let metadataStore = WorkspaceMetadataStore(
      metadataURL: support.appendingPathComponent("workspace.json"))
    let searchWrites = WatcherSearchWriteRecorder()
    let indexDatabase = IndexDatabase(
      databaseURL: support.appendingPathComponent("index.db"),
      searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { searchWrites.record($0) }
    )
    let bookmarkStore = BookmarkStore(
      defaults: makeEphemeralDefaults(prefix: "PensieveFileWatcherBookmarks"))
    let cacheStore = WorkspaceCacheStore(
      baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true))
    let scanProbe = WatcherScanProbe()
    let watcher = FileWatcher(sourceFactory: { @Sendable in sourceTracker.makeSource() })
    let manager = FolderManager(
      metadataStore: metadataStore,
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceBuilder: { roots, exclusions in
        scanProbe.record(isMainThread: Thread.isMainThread)
        let scans = WorkspaceScanner.defaultBuilder(roots, exclusions)
        // Parked AFTER the enumeration, so a walk holds its refresh open with an already-stale
        // tree — the state a live workspace is in whenever its walk outlasts the next event.
        walkGate?.holdAfterWalk()
        return scans
      },
      workspaceSubstrate: WorkspaceSubstrate(store: cacheStore),
      watcher: watcher,
      watcherDebounceMilliseconds: 1
    )
    return WatcherRefreshHarness(
      manager: manager,
      indexDatabase: indexDatabase,
      scanProbe: scanProbe,
      searchWrites: searchWrites
    )
  }

  private func yieldWatcherDelivery() async {
    for _ in 0..<5 {
      await Task.yield()
    }
  }

  /// Injected delay, not load: long enough for the 1 ms debounce of a freshly armed pass to expire
  /// and reach its walk, so "no second walk started" is a measured absence rather than a race.
  private func settleDebounce() async {
    await yieldWatcherDelivery()
    try? await Task.sleep(nanoseconds: 20_000_000)
  }

  private func settleOpen(_ harness: WatcherRefreshHarness) async {
    await harness.manager.waitForPendingWorkspaceBuild()
    await harness.manager.waitForPendingIndexUpdate()
    await harness.manager.waitForPendingWorkspaceIndexWrite()
    await harness.indexDatabase.waitForPendingReindex()
  }

  private func settleWatcher(_ harness: WatcherRefreshHarness) async {
    await harness.manager.waitForPendingWatcherRefresh()
    await harness.manager.waitForPendingIndexUpdate()
    await harness.manager.waitForPendingWorkspaceIndexWrite()
    await harness.indexDatabase.waitForPendingReindex()
  }

  private func settleForced(_ harness: WatcherRefreshHarness) async {
    await harness.manager.waitForPendingForcedRefresh()
    await harness.manager.waitForPendingIndexUpdate()
    await harness.manager.waitForPendingWorkspaceIndexWrite()
    await harness.indexDatabase.waitForPendingReindex()
  }

  private func containsNode(at url: URL, in nodes: [WorkspaceNode]) -> Bool {
    let path = url.standardizedFileURL.path
    return nodes.contains { node in
      node.url?.standardizedFileURL.path == path
        || containsNode(at: url, in: node.children ?? [])
    }
  }
}

@MainActor
private struct WatcherRefreshHarness {
  let manager: FolderManager
  let indexDatabase: IndexDatabase
  let scanProbe: WatcherScanProbe
  let searchWrites: WatcherSearchWriteRecorder
}

private final class WatcherScanProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var samples: [Bool] = []

  func record(isMainThread: Bool) {
    lock.lock()
    samples.append(isMainThread)
    lock.unlock()
  }

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return samples.count
  }

  func mainThreadSamples(after count: Int) -> [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return Array(samples.dropFirst(count))
  }
}

/// Holds injected workspace walks open so refresh-pass overlap is observable as logic instead of
/// CPU. A closed gate parks each walk on a condition (with its own deadline, so a regression fails
/// the assertion rather than hanging the suite) and records how many walks were in flight at once.
private final class WatcherWalkGate: @unchecked Sendable {
  private static let holdTimeout: TimeInterval = 10

  private let condition = NSCondition()
  private var isOpen = true
  private var entered = 0
  private var inFlight = 0
  private var peak = 0
  private var entryExpectations: [(index: Int, expectation: XCTestExpectation)] = []

  /// Arms the gate and restarts the counters, so an open flow's own walk is not mistaken for a
  /// watcher pass.
  func close() {
    condition.lock()
    isOpen = false
    entered = 0
    peak = 0
    condition.unlock()
  }

  func open() {
    condition.lock()
    isOpen = true
    condition.broadcast()
    condition.unlock()
  }

  /// Fulfilled when the `index`-th walk since `close()` has enumerated and parked.
  func expectationForWalk(_ index: Int) -> XCTestExpectation {
    let expectation = XCTestExpectation(description: "workspace walk #\(index) parked on the gate")
    condition.lock()
    let alreadyEntered = entered >= index
    if !alreadyEntered {
      entryExpectations.append((index, expectation))
    }
    condition.unlock()
    if alreadyEntered { expectation.fulfill() }
    return expectation
  }

  func holdAfterWalk() {
    condition.lock()
    entered += 1
    inFlight += 1
    peak = max(peak, inFlight)
    var reached: [XCTestExpectation] = []
    entryExpectations.removeAll { entry in
      guard entry.index <= entered else { return false }
      reached.append(entry.expectation)
      return true
    }
    let parked = !isOpen
    condition.unlock()
    for expectation in reached { expectation.fulfill() }

    condition.lock()
    if parked {
      let deadline = Date().addingTimeInterval(Self.holdTimeout)
      while !isOpen, Date() < deadline {
        condition.wait(until: deadline)
      }
    }
    inFlight -= 1
    condition.unlock()
  }

  var enteredWalks: Int {
    condition.lock()
    defer { condition.unlock() }
    return entered
  }

  var peakConcurrentWalks: Int {
    condition.lock()
    defer { condition.unlock() }
    return peak
  }
}

private final class WatcherSearchWriteRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var batchSizes: [Int] = []

  func record(_ count: Int) {
    lock.lock()
    batchSizes.append(count)
    lock.unlock()
  }

  var totalRecords: Int {
    lock.lock()
    defer { lock.unlock() }
    return batchSizes.reduce(0, +)
  }
}

private final class FileWatcherEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var batches: [[FileWatcher.Event]] = []

  func record(_ events: [FileWatcher.Event]) {
    lock.lock()
    batches.append(events)
    lock.unlock()
  }

  var batchCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return batches.count
  }
}

private final class FileWatcherSourceTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var sources: [InjectedFileWatcherEventSource] = []
  private var active = 0
  private var maximumActive = 0

  func makeSource() -> any FileWatcherEventSource {
    let source = InjectedFileWatcherEventSource(tracker: self)
    lock.lock()
    sources.append(source)
    lock.unlock()
    return source
  }

  func didStart() {
    lock.lock()
    active += 1
    maximumActive = max(maximumActive, active)
    lock.unlock()
  }

  func didStop() {
    lock.lock()
    active -= 1
    lock.unlock()
  }

  var latestSource: InjectedFileWatcherEventSource? {
    lock.lock()
    defer { lock.unlock() }
    return sources.last
  }

  var activeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return active
  }

  var maximumActiveCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return maximumActive
  }
}

private final class InjectedFileWatcherEventSource: FileWatcherEventSource, @unchecked Sendable {
  private weak var tracker: FileWatcherSourceTracker?
  private let lock = NSLock()
  private var onEvents: (@Sendable ([FileWatcherEvent]) -> Void)?
  private var started = false
  private(set) var paths: [String] = []

  init(tracker: FileWatcherSourceTracker) {
    self.tracker = tracker
  }

  func start(
    paths: [String],
    onEvents: @escaping @Sendable ([FileWatcherEvent]) -> Void
  ) throws {
    lock.lock()
    self.paths = paths
    self.onEvents = onEvents
    started = true
    lock.unlock()
    tracker?.didStart()
  }

  func stop() {
    lock.lock()
    let wasStarted = started
    started = false
    lock.unlock()
    if wasStarted { tracker?.didStop() }
  }

  /// Deliberately invokes the captured callback even after stop. FileWatcher's generation fence,
  /// not a cooperative fake, must prove that stale source delivery cannot escape a restart.
  func emit(_ events: [FileWatcherEvent]) {
    lock.lock()
    let callback = onEvents
    lock.unlock()
    callback?(events)
  }
}

private final class FileWatcherEventProbe: @unchecked Sendable {
  private struct Rule {
    let predicate: @Sendable (FileWatcher.Event) -> Bool
    let expectation: XCTestExpectation
  }

  private let lock = NSLock()
  private var rules: [Rule] = []
  private var threadSamples: [Bool] = []

  func expectation(
    description: String,
    predicate: @escaping @Sendable (FileWatcher.Event) -> Bool
  ) -> XCTestExpectation {
    let expectation = XCTestExpectation(description: description)
    lock.lock()
    rules.append(Rule(predicate: predicate, expectation: expectation))
    lock.unlock()
    return expectation
  }

  func record(_ events: [FileWatcher.Event]) {
    var fulfilled: [XCTestExpectation] = []
    lock.lock()
    threadSamples.append(Thread.isMainThread)
    rules.removeAll { rule in
      guard events.contains(where: rule.predicate) else { return false }
      fulfilled.append(rule.expectation)
      return true
    }
    lock.unlock()
    for expectation in fulfilled {
      expectation.fulfill()
    }
  }

  var mainThreadSamples: [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return threadSamples
  }
}
