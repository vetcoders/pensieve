import Foundation
import XCTest

@testable import Pensieve

/// Regression coverage for the watcher-scan pile-up behind the 154 GB footprint peak on 0.4.2
/// (2026-07-24, /Library/Logs/DiagnosticReports/Pensieve_2026-07-23-*): watcher events landing
/// while a scan walk is already in flight must coalesce into exactly one trailing rescan, and
/// cancelling a refresh must reach the detached walk itself — otherwise sustained filesystem
/// churn keeps spawning concurrent uncancellable full-tree walks, each holding a complete
/// workspace snapshot in memory.
@MainActor
final class WatcherRefreshCoalescingTests: XCTestCase {
  private struct Sandbox {
    let root: URL
    let support: URL
  }

  private struct Harness {
    let manager: FolderManager
    let probe: BlockingScanProbe
  }

  func testWatcherEventsDuringInFlightScanCoalesceIntoSingleTrailingRescan() async throws {
    let sandbox = try makeSandbox()
    let root = try makeFixture(in: sandbox)
    let harness = try makeHarness(in: sandbox.support)
    let appState = AppState()

    harness.manager.open(url: root, into: appState)
    await harness.manager.waitForPendingWorkspaceBuild()
    await harness.manager.waitForPendingWatcherRefresh()
    let baselineCalls = harness.probe.callCount

    harness.probe.armBlocking()
    harness.manager.scheduleWatcherRefresh(into: appState)
    try await waitUntilScanEntered(harness.probe)

    // A burst of watcher events while the walk is still running. Each of these used to
    // cancel only the debounce task and then spawn ANOTHER detached walk next to the
    // still-running one.
    harness.manager.scheduleWatcherRefresh(into: appState)
    harness.manager.scheduleWatcherRefresh(into: appState)
    harness.manager.scheduleWatcherRefresh(into: appState)
    // Give any (buggy) concurrent walk time to pass its debounce and enter the builder.
    try await Task.sleep(nanoseconds: 100_000_000)

    harness.probe.releaseAll()
    await harness.manager.waitForPendingWatcherRefresh()

    XCTAssertEqual(
      harness.probe.maxConcurrentScans, 1,
      "watcher walks must never overlap — overlapping walks are the 154 GB pile-up")
    XCTAssertEqual(
      harness.probe.callCount, baselineCalls + 2,
      "a burst during one walk coalesces into exactly one trailing rescan")
  }

  func testExplicitRefreshCancelsInFlightWatcherWalk() async throws {
    let sandbox = try makeSandbox()
    let root = try makeFixture(in: sandbox)
    let harness = try makeHarness(in: sandbox.support)
    let appState = AppState()

    harness.manager.open(url: root, into: appState)
    await harness.manager.waitForPendingWorkspaceBuild()
    await harness.manager.waitForPendingWatcherRefresh()

    harness.probe.armCancellationWatch()
    harness.manager.scheduleWatcherRefresh(into: appState)
    try await waitUntilScanEntered(harness.probe)

    // Explicit one-shot refresh (create/save/move/trash path) cancels the watcher task; the
    // cancellation must reach the detached walk, not just the awaiting wrapper.
    harness.manager.refresh(into: appState)
    await harness.manager.waitForPendingForcedRefresh()
    await harness.manager.waitForPendingWatcherRefresh()

    XCTAssertTrue(
      harness.probe.sawCancellation,
      "cancelling the watcher refresh must propagate into the detached scanner walk")
  }

  // MARK: - Harness

  private func makeSandbox() throws -> Sandbox {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveWatcherCoalescing-\(UUID().uuidString)", isDirectory: true)
    let support = root.appendingPathComponent("Support", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return Sandbox(root: root, support: support)
  }

  private func makeFixture(in sandbox: Sandbox) throws -> URL {
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    let docs = root.appendingPathComponent("docs", isDirectory: true)
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    try "alpha".write(to: docs.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
    return root
  }

  private func makeHarness(in support: URL) throws -> Harness {
    let metadataStore = WorkspaceMetadataStore(
      metadataURL: support.appendingPathComponent("workspace.json"))
    let indexDatabase = IndexDatabase(
      databaseURL: support.appendingPathComponent("index.db"))
    let bookmarkStore = BookmarkStore(
      defaults: makeEphemeralDefaults(prefix: "PensieveWatcherCoalescingBookmarks"))
    let cacheStore = WorkspaceCacheStore(
      baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true))
    let probe = BlockingScanProbe()
    let manager = FolderManager(
      metadataStore: metadataStore,
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceBuilder: { roots, exclusions in
        probe.enter()
        defer { probe.exit() }
        return WorkspaceScanner.defaultBuilder(roots, exclusions)
      },
      workspaceSubstrate: WorkspaceSubstrate(store: cacheStore),
      // Watcher refreshes are driven manually; a live FSEvents stream would add
      // machine-timing-dependent scans to the exact counts asserted here.
      watcher: FileWatcher(sourceFactory: { @Sendable in CoalescingInertEventSource() }),
      watcherDebounceMilliseconds: 1
    )
    return Harness(manager: manager, probe: probe)
  }

  private func waitUntilScanEntered(_ probe: BlockingScanProbe) async throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if probe.blockedScanEntered { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("scanner walk never entered the builder")
  }
}

/// Thread-safe builder probe. `armBlocking` makes the next walks park inside the builder until
/// `releaseAll`, so the test can inject watcher events while a walk is provably in flight.
/// `armCancellationWatch` makes the next walk spin until it observes task cancellation (or a
/// deadline), recording whether cancellation ever reached the walk's task.
private final class BlockingScanProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let gate = DispatchSemaphore(value: 0)
  private var _callCount = 0
  private var _active = 0
  private var _maxActive = 0
  private var _blocking = false
  private var _watchingCancellation = false
  private var _blockedScanEntered = false
  private var _sawCancellation = false

  var callCount: Int { lock.withLock { _callCount } }
  var maxConcurrentScans: Int { lock.withLock { _maxActive } }
  var blockedScanEntered: Bool { lock.withLock { _blockedScanEntered } }
  var sawCancellation: Bool { lock.withLock { _sawCancellation } }

  func armBlocking() {
    lock.withLock { _blocking = true }
  }

  func armCancellationWatch() {
    lock.withLock { _watchingCancellation = true }
  }

  func releaseAll() {
    lock.withLock { _blocking = false }
    for _ in 0..<16 { gate.signal() }
  }

  func enter() {
    let (shouldBlock, shouldWatchCancellation): (Bool, Bool) = lock.withLock {
      _callCount += 1
      _active += 1
      _maxActive = max(_maxActive, _active)
      if _blocking || _watchingCancellation { _blockedScanEntered = true }
      return (_blocking, _watchingCancellation)
    }
    if shouldWatchCancellation {
      lock.withLock { _watchingCancellation = false }
      let deadline = Date().addingTimeInterval(5)
      while Date() < deadline {
        if Task.isCancelled {
          lock.withLock { _sawCancellation = true }
          return
        }
        usleep(5_000)
      }
      return
    }
    if shouldBlock {
      _ = gate.wait(timeout: .now() + 10)
    }
  }

  func exit() {
    lock.withLock { _active -= 1 }
  }
}

private final class CoalescingInertEventSource: FileWatcherEventSource, @unchecked Sendable {
  func start(
    paths: [String],
    onEvents: @escaping @Sendable ([FileWatcherEvent]) -> Void
  ) throws {}

  func stop() {}
}
