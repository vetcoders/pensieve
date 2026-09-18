import Foundation
import Synchronization
import XCTest

@testable import Pensieve

/// W1-03: the workspace walk that feeds `applyRefresh`, and the GRDB FTS apply it
/// arms, are not MainActor UI work. A stale search index for a moment is legal;
/// treating ~4 GB RSS as "index warming" on the main actor is not.
///
/// `MainActor.assumeIsolated` traps when it is *false*, so it cannot be a boolean
/// probe by itself. The equivalent here is: if the walk or FTS batch *can* enter
/// `assumeIsolated`, the test fails. Off-main samples never call it.
@MainActor
final class IndexApplyOffMainTests: XCTestCase {
  func testRefreshWalkAndIndexApplyStayOffMainActor() async throws {
    let harness = try makeHarness()
    let note = harness.root.appendingPathComponent("alpha.md")
    try "alpha-body".write(to: note, atomically: true, encoding: .utf8)

    let appState = AppState()
    harness.manager.open(url: harness.root, into: appState)
    await settleOpen(harness)
    XCTAssertEqual(appState.documents.count, 1, "precondition: cold open published the tree")

    let walksAfterOpen = harness.walkProbe.callCount
    let batchesAfterOpen = harness.indexProbe.callCount
    XCTAssertGreaterThan(
      batchesAfterOpen, 0, "precondition: cold open armed an FTS write we can observe")

    try "beta-body".write(
      to: harness.root.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8)
    harness.manager.refresh(into: appState, force: true)
    await settleForced(harness)

    let refreshWalks = harness.walkProbe.samples(after: walksAfterOpen)
    XCTAssertFalse(refreshWalks.isEmpty, "forced refresh must walk the workspace once")
    XCTAssertTrue(
      refreshWalks.allSatisfy { !$0.assumedMainActor },
      "applyRefresh's walk ran inside MainActor.assumeIsolated — the scan is UI work")

    let refreshBatches = harness.indexProbe.samples(after: batchesAfterOpen)
    XCTAssertFalse(refreshBatches.isEmpty, "forced refresh must apply an FTS batch")
    XCTAssertTrue(
      refreshBatches.allSatisfy { !$0.assumedMainActor },
      "index apply ran inside MainActor.assumeIsolated — GRDB is UI work")

    XCTAssertEqual(
      appState.documents.count, 2,
      "refresh published the new snapshot without waiting")
    XCTAssertNil(
      appState.selectedDocumentID,
      "refresh still opens nothing it did not already have")
  }

  func testForcedRefreshReturnsBeforeIndexApplyFinishes() async throws {
    let harness = try makeHarness()
    try "alpha-body".write(
      to: harness.root.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)

    let appState = AppState()
    harness.manager.open(url: harness.root, into: appState)
    await settleOpen(harness)

    harness.indexProbe.armHold()
    try "beta-body".write(
      to: harness.root.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8)
    harness.manager.refresh(into: appState, force: true)
    await harness.manager.waitForPendingForcedRefresh()

    XCTAssertEqual(
      appState.documents.count, 2,
      "the in-memory snapshot is ready while FTS is still inside its write")
    try await waitUntilHolding(harness.indexProbe)

    harness.indexProbe.releaseHold()
    await settleForced(harness)
    XCTAssertGreaterThan(harness.indexProbe.callCount, 0)
  }

  // MARK: - Harness

  private struct Harness {
    let root: URL
    let manager: FolderManager
    let indexDatabase: IndexDatabase
    let walkProbe: IsolationProbe
    let indexProbe: IsolationProbe
  }

  private func makeHarness() throws -> Harness {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PensieveIndexApplyOffMain-\(UUID().uuidString)", isDirectory: true)
    let root = container.appendingPathComponent("Workspace", isDirectory: true)
    let support = container.appendingPathComponent("Support", isDirectory: true)
    for directory in [root, support] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    addTeardownBlock { try? FileManager.default.removeItem(at: container) }

    let walkProbe = IsolationProbe()
    let indexProbe = IsolationProbe()
    let indexDatabase = IndexDatabase(
      databaseURL: support.appendingPathComponent("index.db"),
      searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { _ in indexProbe.enter() }
    )
    let manager = FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: support.appendingPathComponent("workspace.json")),
      indexDatabase: indexDatabase,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveIndexApplyOffMain")),
      workspaceBuilder: { roots, exclusions in
        walkProbe.enter()
        return WorkspaceScanner.defaultBuilder(roots, exclusions)
      },
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true))),
      watcher: FileWatcher(sourceFactory: { @Sendable in SilentIndexApplyWatcher() })
    )
    return Harness(
      root: root,
      manager: manager,
      indexDatabase: indexDatabase,
      walkProbe: walkProbe,
      indexProbe: indexProbe
    )
  }

  private func settleOpen(_ harness: Harness) async {
    await harness.manager.waitForPendingWorkspaceBuild()
    await harness.manager.waitForPendingIndexUpdate()
    await harness.manager.waitForPendingWorkspaceIndexWrite()
    await harness.indexDatabase.waitForPendingReindex()
  }

  private func settleForced(_ harness: Harness) async {
    await harness.manager.waitForPendingForcedRefresh()
    await harness.manager.waitForPendingIndexUpdate()
    await harness.manager.waitForPendingWorkspaceIndexWrite()
    await harness.indexDatabase.waitForPendingReindex()
  }

  private func waitUntilHolding(_ probe: IsolationProbe) async throws {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if probe.isHolding { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("index apply never entered the parked FTS batch")
  }
}

/// Records whether a Sendable callback could enter `MainActor.assumeIsolated`.
/// Parking (`armHold`) is only used by the "refresh does not wait for FTS" pin.
private final class IsolationProbe: Sendable {
  struct Sample: Sendable {
    let assumedMainActor: Bool
  }

  private struct State: Sendable {
    var samples: [Sample] = []
    var holding = false
    var isHolding = false
  }

  private let state = Mutex(State())
  private let gate = DispatchSemaphore(value: 0)

  var callCount: Int { state.withLock { state in state.samples.count } }
  var isHolding: Bool { state.withLock { state in state.isHolding } }

  func samples(after count: Int) -> [Sample] {
    state.withLock { state in Array(state.samples.dropFirst(count)) }
  }

  func armHold() {
    state.withLock { state in state.holding = true }
  }

  func releaseHold() {
    state.withLock { state in
      state.holding = false
      state.isHolding = false
    }
    gate.signal()
  }

  func enter() {
    let assumedMainActor = IsolationProbe.wouldAssumeMainActorIsolated()
    let shouldHold: Bool = state.withLock { state in
      state.samples.append(Sample(assumedMainActor: assumedMainActor))
      if state.holding {
        state.isHolding = true
        return true
      }
      return false
    }
    if shouldHold {
      _ = gate.wait(timeout: .now() + 10)
    }
  }

  /// Equivalent of "does `MainActor.assumeIsolated` succeed here?"
  /// Calling `assumeIsolated` off the main actor traps, so the probe only
  /// enters it when that call would succeed — and that success is the failure.
  static func wouldAssumeMainActorIsolated() -> Bool {
    guard Thread.isMainThread else { return false }
    return MainActor.assumeIsolated { true }
  }
}

private final class SilentIndexApplyWatcher: FileWatcherEventSource, Sendable {
  func start(
    paths: [String],
    onEvents: @escaping @Sendable ([FileWatcherEvent]) -> Void
  ) throws {}

  func stop() {}
}
