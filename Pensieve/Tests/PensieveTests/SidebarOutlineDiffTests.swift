import Foundation
import XCTest

@testable import Pensieve

/// Pins W1-01: the sidebar publishes a flattened snapshot of the workspace tree
/// computed OFF the main actor. A 5k-node republish must never run the flatten
/// under `MainActor.assumeIsolated` — the probe seam below records every flatten
/// invocation the same way `OpenFileFastPathTests` probes `standardizeFileURL`.
/// A stale tree for a moment is legal; a beachball is not.
@MainActor
final class SidebarOutlineDiffTests: XCTestCase {
  func testPublishDoesNotFlattenUnderMainActorAssumeIsolated() throws {
    let probe = FlattenProbe()
    let store = WorkspaceTreeSnapshotStore(flatten: probe.flatten)
    let fixture = makeExpandedTree(folderCount: 50, documentsPerFolder: 100)

    let start = ContinuousClock.now
    store.publish(
      tree: fixture.tree,
      expandedNodeIDs: fixture.expandedNodeIDs,
      includeForeignFiles: false
    )
    let elapsed = ContinuousClock.now - start

    XCTAssertEqual(
      probe.callCount,
      0,
      "publish must only record the request; flattening inline is the outline-diff beachball"
    )
    XCTAssertEqual(
      probe.mainActorAssumeIsolatedCallCount,
      0,
      "flatten ran under MainActor.assumeIsolated during publish — the walk is back on main"
    )
    XCTAssertLessThan(
      elapsed,
      .milliseconds(50),
      "5k-node publish must stay a store-and-trigger on the caller; elapsed \(elapsed)"
    )
  }

  func testFiveThousandNodeRepublishFlattensOffMainActor() async throws {
    let probe = FlattenProbe()
    let store = WorkspaceTreeSnapshotStore(flatten: probe.flatten)
    let fixture = makeExpandedTree(folderCount: 50, documentsPerFolder: 100)
    let expectedRowCount = 50 + 5_000

    store.publish(
      tree: fixture.tree,
      expandedNodeIDs: fixture.expandedNodeIDs,
      includeForeignFiles: false
    )

    try await waitForSnapshot(store, expectedRowCount: expectedRowCount)

    XCTAssertGreaterThan(probe.callCount, 0, "the republish must reach the flatten seam")
    XCTAssertEqual(
      probe.mainActorAssumeIsolatedCallCount,
      0,
      "flatten ran under MainActor.assumeIsolated \(probe.mainActorAssumeIsolatedCallCount)x "
        + "during a 5k-node republish — the outline-diff beachball is back"
    )
    XCTAssertEqual(
      store.rows,
      flattenWorkspaceTree(fixture.tree, expandedNodeIDs: fixture.expandedNodeIDs),
      "the published snapshot must equal the deterministic flatten of the republished tree"
    )
    print(
      "[pensieve-trace] sidebar-outline-diff nodes=\(expectedRowCount) "
        + "flattenCalls=\(probe.callCount) "
        + "mainActorAssumeIsolatedCalls=\(probe.mainActorAssumeIsolatedCallCount)"
    )
  }

  func testBackToBackRepublishesCoalesceToLatestTree() async throws {
    let probe = FlattenProbe()
    let store = WorkspaceTreeSnapshotStore(flatten: probe.flatten)
    let stale = makeExpandedTree(folderCount: 50, documentsPerFolder: 100)
    let latest = makeExpandedTree(folderCount: 2, documentsPerFolder: 3)

    // No suspension between the two publishes: the pump can only take a request
    // after the main actor yields, so latest-wins must collapse the stale 5k
    // republish entirely instead of flattening it on the way to the new tree.
    store.publish(
      tree: stale.tree,
      expandedNodeIDs: stale.expandedNodeIDs,
      includeForeignFiles: false
    )
    store.publish(
      tree: latest.tree,
      expandedNodeIDs: latest.expandedNodeIDs,
      includeForeignFiles: false
    )

    try await waitForSnapshot(store, expectedRowCount: 2 + 6)

    XCTAssertEqual(probe.callCount, 1, "the superseded republish must never be flattened")
    XCTAssertEqual(probe.mainActorAssumeIsolatedCallCount, 0)
    XCTAssertEqual(
      store.rows,
      flattenWorkspaceTree(latest.tree, expandedNodeIDs: latest.expandedNodeIDs)
    )
  }

  func testRepublishingAnEmptyTreeClearsTheSnapshot() async throws {
    let store = WorkspaceTreeSnapshotStore()
    let fixture = makeExpandedTree(folderCount: 2, documentsPerFolder: 3)

    store.publish(
      tree: fixture.tree,
      expandedNodeIDs: fixture.expandedNodeIDs,
      includeForeignFiles: false
    )
    try await waitForSnapshot(store, expectedRowCount: 2 + 6)

    store.publish(tree: [], expandedNodeIDs: [], includeForeignFiles: false)
    try await waitForSnapshot(store, expectedRowCount: 0)

    XCTAssertTrue(store.rows.isEmpty)
  }

  /// Waits for the asynchronously published snapshot. The store is
  /// latest-wins and hops through a detached task, so assertions poll with a
  /// deadline instead of assuming a fixed number of runloop turns.
  private func waitForSnapshot(
    _ store: WorkspaceTreeSnapshotStore,
    expectedRowCount: Int,
    timeout: Duration = .seconds(5)
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while store.rows.count != expectedRowCount {
      guard ContinuousClock.now < deadline else {
        XCTFail(
          "snapshot never published \(expectedRowCount) rows "
            + "(have \(store.rows.count)) within \(timeout)"
        )
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  /// A fully expanded forest of `folderCount` folders with
  /// `documentsPerFolder` markdown documents each, so every node is visible and
  /// the flatten walks the whole tree.
  private func makeExpandedTree(
    folderCount: Int,
    documentsPerFolder: Int
  ) -> (tree: [WorkspaceNode], expandedNodeIDs: Set<WorkspaceNode.ID>) {
    var expandedNodeIDs: Set<WorkspaceNode.ID> = []
    let tree: [WorkspaceNode] = (0..<folderCount).map { folderIndex in
      let folderID = "folder-\(folderIndex)"
      expandedNodeIDs.insert(folderID)
      let children: [WorkspaceNode] = (0..<documentsPerFolder).map { documentIndex in
        WorkspaceNode(
          id: "\(folderID)/doc-\(documentIndex)",
          name: "doc-\(documentIndex).md",
          kind: .document,
          url: URL(fileURLWithPath: "/workspace/\(folderID)/doc-\(documentIndex).md"),
          children: nil
        )
      }
      return WorkspaceNode(
        id: folderID,
        name: folderID,
        kind: .folder,
        url: URL(fileURLWithPath: "/workspace/\(folderID)"),
        children: children
      )
    }
    return (tree, expandedNodeIDs)
  }
}

/// Records how often and on which thread the snapshot store invokes its flatten
/// closure. `@unchecked` because the counters are NSLock-guarded and the probe
/// deliberately crosses the actor boundary the store is supposed to use.
private final class FlattenProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedCallCount = 0
  private var recordedMainActorAssumeIsolatedCallCount = 0

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return recordedCallCount
  }

  var mainActorAssumeIsolatedCallCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return recordedMainActorAssumeIsolatedCallCount
  }

  func flatten(
    _ roots: [WorkspaceNode],
    _ expandedNodeIDs: Set<WorkspaceNode.ID>,
    _ includeForeignFiles: Bool
  ) -> [FlattenedWorkspaceRow] {
    lock.lock()
    recordedCallCount += 1
    lock.unlock()
    // A1: the 5k-node walk must not be reachable via MainActor.assumeIsolated.
    // Thread.isMainThread is the cheap guard; assumeIsolated is the actual
    // isolation proof — it only succeeds when flatten is already on MainActor.
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        lock.lock()
        recordedMainActorAssumeIsolatedCallCount += 1
        lock.unlock()
      }
    }
    return flattenWorkspaceTree(
      roots,
      expandedNodeIDs: expandedNodeIDs,
      includeForeignFiles: includeForeignFiles
    )
  }
}
