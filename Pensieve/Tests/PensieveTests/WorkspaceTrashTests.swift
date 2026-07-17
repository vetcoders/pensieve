import AppKit
import XCTest

@testable import Pensieve

@MainActor
final class WorkspaceTrashTests: XCTestCase {
  func testSuccessfulFolderTrashMutatesOnlyAfterRecycleThenRemovesFTSRow() async throws {
    let fixture = try TrashTestFixture.make()
    let folderURL = fixture.root.appendingPathComponent("notes", isDirectory: true)
      .standardizedFileURL
    let fileURL = folderURL.appendingPathComponent("nested.md").standardizedFileURL
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    try "# Nested unique-trash-token".write(to: fileURL, atomically: true, encoding: .utf8)
    let harness = try TrashTestHarness(root: fixture.root)
    defer {
      harness.closeWorkspace()
      fixture.cleanup()
    }

    await harness.openWorkspace()
    let indexedCountBeforeTrash = await indexedCount(in: harness)
    XCTAssertEqual(indexedCountBeforeTrash, 1)
    let ref = try XCTUnwrap(harness.appState.documents.first { $0.url == fileURL })
    harness.documentStore.load(ref: ref, into: harness.appState)
    let window = TrashTestHarness.makeWindow()
    defer { window.close() }
    harness.register(window, documentID: fileURL)

    let operation = harness.requestTrash(folderURL)
    await harness.waitForRecycleRequest()

    XCTAssertEqual(harness.confirmationProbe.requests, [folderURL])
    XCTAssertEqual(harness.appState.selectedDocumentID, fileURL)
    XCTAssertTrue(treeContains(harness.appState.workspaceTree, url: folderURL))
    XCTAssertEqual(harness.recycleProbe.events, ["request:\(folderURL.path)"])

    harness.completeRecycle()
    let didTrash = await operation.value
    XCTAssertTrue(didTrash)

    XCTAssertFalse(treeContains(harness.appState.workspaceTree, url: folderURL))
    XCTAssertTrue(harness.appState.documents.allSatisfy { $0.url != fileURL })
    XCTAssertTrue(harness.appState.openFiles.allSatisfy { $0.url != fileURL })
    XCTAssertNil(harness.appState.selectedDocumentID)
    XCTAssertFalse(harness.appState.documentSession.hasEditableBuffer)
    let indexedCountAfterTrash = await indexedCount(in: harness)
    XCTAssertEqual(indexedCountAfterTrash, 0)
    XCTAssertEqual(
      harness.recycleProbe.events,
      ["request:\(folderURL.path)", "completion:\(folderURL.path)", "close:\(fileURL.path)"]
    )
  }

  func testRecycleFailurePreservesTreeOpenSelectionSessionWindowsAndFTS() async throws {
    let fixture = try TrashTestFixture.make()
    let folderURL = fixture.root.appendingPathComponent("notes", isDirectory: true)
      .standardizedFileURL
    let fileURL = folderURL.appendingPathComponent("nested.md").standardizedFileURL
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    try "# Failure preservation".write(to: fileURL, atomically: true, encoding: .utf8)
    let harness = try TrashTestHarness(root: fixture.root)
    defer {
      harness.closeWorkspace()
      fixture.cleanup()
    }

    await harness.openWorkspace()
    let ref = try XCTUnwrap(harness.appState.documents.first { $0.url == fileURL })
    harness.documentStore.load(ref: ref, into: harness.appState)
    harness.appState.documentSession.text = "unsaved body"
    harness.appState.documentSession.isDirty = true
    harness.appState.workspaceSearchResults = harness.indexDatabase.search(
      query: "preservation",
      documents: harness.appState.allDocuments,
      appState: harness.appState
    )
    let window = TrashTestHarness.makeWindow()
    defer { window.close() }
    harness.register(window, documentID: fileURL)
    let before = await harness.captureState()

    let operation = harness.requestTrash(folderURL)
    await harness.waitForRecycleRequest()
    harness.completeRecycle(error: CocoaError(.fileWriteNoPermission))

    let didTrash = await operation.value
    let after = await harness.captureState()
    XCTAssertFalse(didTrash)
    XCTAssertEqual(after, before)
    XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
    XCTAssertEqual(
      harness.recycleProbe.events,
      ["request:\(folderURL.path)", "completion:\(folderURL.path)"]
    )
    XCTAssertTrue(harness.appState.lastError?.contains("Trash") == true)
  }

  func testFolderCancellationPreservesFullStateSnapshot() async throws {
    let fixture = try TrashTestFixture.make()
    let folderURL = fixture.root.appendingPathComponent("notes", isDirectory: true)
      .standardizedFileURL
    let fileURL = folderURL.appendingPathComponent("nested.md").standardizedFileURL
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    try "# Cancel preservation".write(to: fileURL, atomically: true, encoding: .utf8)
    let harness = try TrashTestHarness(root: fixture.root, confirmationResult: false)
    defer {
      harness.closeWorkspace()
      fixture.cleanup()
    }

    await harness.openWorkspace()
    let ref = try XCTUnwrap(harness.appState.documents.first { $0.url == fileURL })
    harness.documentStore.load(ref: ref, into: harness.appState)
    harness.appState.documentSession.text = "dirty cancel body"
    harness.appState.documentSession.isDirty = true
    harness.appState.lastError = "keep-existing-error"
    let before = await harness.captureState()

    let didTrash = await harness.controller.moveItemToTrash(url: folderURL)
    let after = await harness.captureState()
    XCTAssertFalse(didTrash)

    XCTAssertEqual(after, before)
    XCTAssertEqual(harness.appState.lastError, "keep-existing-error")
    XCTAssertEqual(harness.confirmationProbe.requests, [folderURL])
    XCTAssertTrue(harness.recycleProbe.requests.isEmpty)
  }

  func testTreePruneLandsUnder100MillisecondsWhileReconcileIsBlockedOffMain() async throws {
    let fixture = try TrashTestFixture.make()
    let folderURL = fixture.root.appendingPathComponent("target", isDirectory: true)
      .standardizedFileURL
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    let blocker = BlockingWorkspaceBuilder()
    let harness = try TrashTestHarness(root: fixture.root, workspaceBuilder: blocker.builder)
    defer {
      blocker.releaseScan()
      harness.closeWorkspace()
      fixture.cleanup()
    }

    let unrelatedNodes = (0..<6_000).map { index in
      WorkspaceNode(
        id: "document:\(fixture.root.path)/unrelated-\(index).md",
        name: "unrelated-\(index)",
        kind: .document,
        url: fixture.root.appendingPathComponent("unrelated-\(index).md"),
        children: nil
      )
    }
    let targetNode = WorkspaceNode(
      id: "folder:\(folderURL.path)",
      name: "target",
      kind: .folder,
      url: folderURL,
      children: []
    )
    harness.appState.workspaceRoots = [WorkspaceRoot(id: fixture.root)]
    harness.appState.folderURL = fixture.root
    harness.appState.workspaceTree = [
      WorkspaceNode(
        id: "root:\(fixture.root.path)",
        name: fixture.root.lastPathComponent,
        kind: .folder,
        url: fixture.root,
        children: [targetNode] + unrelatedNodes
      )
    ]

    let operation = harness.requestTrash(folderURL)
    await harness.waitForRecycleRequest()
    let completionStartedAt = DispatchTime.now().uptimeNanoseconds
    harness.completeRecycle()
    await waitUntil { !self.treeContains(harness.appState.workspaceTree, url: folderURL) }
    let pruneObservedAt = DispatchTime.now().uptimeNanoseconds
    let completionToPruneMilliseconds = Double(pruneObservedAt - completionStartedAt) / 1_000_000

    XCTAssertLessThan(completionToPruneMilliseconds, 100)
    XCTAssertEqual(harness.appState.workspaceTree.first?.children?.count, unrelatedNodes.count)

    var heartbeatRan = false
    let heartbeat = Task { @MainActor in heartbeatRan = true }
    await heartbeat.value
    XCTAssertTrue(
      heartbeatRan, "The main actor must remain responsive while the scanner is blocked")

    blocker.releaseScan()
    let didTrash = await operation.value
    XCTAssertTrue(didTrash)
  }

  func testEmptyFolderDisappearsWithoutFTSBatchWrite() async throws {
    try await assertFolderOnlyTrashDoesNotWriteFTS(unsupportedFileName: nil)
  }

  func testUnsupportedOnlyFolderDisappearsWithoutFTSBatchWrite() async throws {
    try await assertFolderOnlyTrashDoesNotWriteFTS(unsupportedFileName: "diagram.pdf")
  }

  func testWorkspaceRootTrashIsRejectedBeforeConfirmationOrRecycle() async throws {
    let fixture = try TrashTestFixture.make()
    let harness = try TrashTestHarness(root: fixture.root)
    defer {
      harness.closeWorkspace()
      fixture.cleanup()
    }
    await harness.openWorkspace()
    let before = await harness.captureState()

    let didTrash = await harness.controller.moveItemToTrash(url: fixture.root)
    let after = await harness.captureState()
    XCTAssertFalse(didTrash)

    XCTAssertEqual(after, before)
    XCTAssertTrue(harness.confirmationProbe.requests.isEmpty)
    XCTAssertTrue(harness.recycleProbe.requests.isEmpty)
    XCTAssertTrue(harness.appState.lastError?.contains("Workspace roots") == true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.path))
  }

  func testPureTreePruneRemovesOnlyTargetSubtree() {
    let root = URL(fileURLWithPath: "/tmp/workspace")
    let target = root.appendingPathComponent("target")
    let survivor = root.appendingPathComponent("survivor.md")
    let tree = [
      WorkspaceNode(
        id: "root:\(root.path)",
        name: "workspace",
        kind: .folder,
        url: root,
        children: [
          WorkspaceNode(
            id: "folder:\(target.path)",
            name: "target",
            kind: .folder,
            url: target,
            children: [
              WorkspaceNode(
                id: "document:\(target.path)/nested.md",
                name: "nested",
                kind: .document,
                url: target.appendingPathComponent("nested.md"),
                children: nil
              )
            ]
          ),
          WorkspaceNode(
            id: "document:\(survivor.path)",
            name: "survivor",
            kind: .document,
            url: survivor,
            children: nil
          ),
        ]
      )
    ]

    let pruned = FolderManager.prunedWorkspaceTree(tree, removing: target)

    XCTAssertFalse(treeContains(pruned, url: target))
    XCTAssertTrue(treeContains(pruned, url: survivor))
    XCTAssertEqual(pruned.first?.children?.count, 1)
  }

  private func assertFolderOnlyTrashDoesNotWriteFTS(unsupportedFileName: String?) async throws {
    let fixture = try TrashTestFixture.make()
    let folderURL = fixture.root.appendingPathComponent("folder", isDirectory: true)
      .standardizedFileURL
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    if let unsupportedFileName {
      try Data("not indexed".utf8).write(to: folderURL.appendingPathComponent(unsupportedFileName))
    }
    let harness = try TrashTestHarness(root: fixture.root)
    defer {
      harness.closeWorkspace()
      fixture.cleanup()
    }

    await harness.openWorkspace()
    XCTAssertTrue(treeContains(harness.appState.workspaceTree, url: folderURL))
    harness.indexBatchCounter.reset()

    let operation = harness.requestTrash(folderURL)
    await harness.waitForRecycleRequest()
    harness.completeRecycle()
    let didTrash = await operation.value
    XCTAssertTrue(didTrash)

    XCTAssertFalse(treeContains(harness.appState.workspaceTree, url: folderURL))
    XCTAssertEqual(harness.indexBatchCounter.value, 0)
    let indexedCountAfterTrash = await indexedCount(in: harness)
    XCTAssertEqual(indexedCountAfterTrash, 0)
  }

  private func indexedCount(in harness: TrashTestHarness) async -> Int {
    await harness.indexDatabase.indexedDocumentCountInBackground(
      forRootPaths: harness.appState.workspaceRoots.map { $0.url.path },
      appState: harness.appState
    )
  }

  // Raw-path comparison keeps this probe cheap enough that the timing window in
  // the 100 ms test measures the product prune, not the observation walk. Node
  // URLs are standardized at construction (scanner and fixtures alike).
  private func treeContains(_ nodes: [WorkspaceNode], url: URL) -> Bool {
    treeContains(nodes, path: url.standardizedFileURL.path)
  }

  private func treeContains(_ nodes: [WorkspaceNode], path: String) -> Bool {
    nodes.contains { node in
      node.url?.path == path || treeContains(node.children ?? [], path: path)
    }
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<10_000 {
      if condition() { return }
      await Task.yield()
    }
    XCTFail("Timed out waiting for main-actor state")
  }
}
