import AppKit
import XCTest

@testable import Pensieve

@MainActor
final class WorkspaceTrashTests: XCTestCase {
  func testMoveOpenWorkspaceFileToTrashClosesDocumentWindowBeforeRecycle() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }

    let fileURL = fixture.root.appendingPathComponent("alpha.md").standardizedFileURL
    try "# Alpha".write(to: fileURL, atomically: true, encoding: .utf8)

    let harness = try makeHarness(root: fixture.root)
    let window = Self.makeWindow()
    defer { window.close() }

    let ref = DocumentRef(id: fileURL)
    harness.documentStore.load(ref: ref, into: harness.appState)
    XCTAssertEqual(harness.appState.selectedDocumentID, fileURL)
    harness.windowDocumentIDs[ObjectIdentifier(window)] = fileURL
    harness.registry.attach(window, documentID: fileURL)

    XCTAssertTrue(harness.controller.moveItemToTrash(url: fileURL))

    XCTAssertEqual(harness.events, ["close:\(fileURL.path)", "recycle:\(fileURL.path)"])
    XCTAssertNil(harness.appState.selectedDocumentID)
    XCTAssertFalse(harness.appState.documentSession.hasEditableBuffer)
    XCTAssertEqual(harness.recycleRequests, [[fileURL]])
  }

  func testMoveClosedWorkspaceFileToTrashDoesNotCloseAnyDocumentWindow() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }

    let fileURL = fixture.root.appendingPathComponent("closed.md").standardizedFileURL
    try "# Closed".write(to: fileURL, atomically: true, encoding: .utf8)

    let harness = try makeHarness(root: fixture.root)

    XCTAssertTrue(harness.controller.moveItemToTrash(url: fileURL))

    XCTAssertEqual(harness.events, ["recycle:\(fileURL.path)"])
    XCTAssertEqual(harness.recycleRequests, [[fileURL]])
  }

  func testMoveWorkspaceFolderToTrashClosesDescendantDocumentWindow() throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }

    let folderURL = fixture.root.appendingPathComponent("notes", isDirectory: true)
      .standardizedFileURL
    let fileURL = folderURL.appendingPathComponent("nested.md").standardizedFileURL
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    try "# Nested".write(to: fileURL, atomically: true, encoding: .utf8)

    let harness = try makeHarness(root: fixture.root)
    let window = Self.makeWindow()
    defer { window.close() }

    harness.documentStore.load(ref: DocumentRef(id: fileURL), into: harness.appState)
    XCTAssertEqual(harness.appState.selectedDocumentID, fileURL)
    harness.windowDocumentIDs[ObjectIdentifier(window)] = fileURL
    harness.registry.attach(window, documentID: fileURL)

    XCTAssertTrue(harness.controller.moveItemToTrash(url: folderURL))

    XCTAssertEqual(harness.events, ["close:\(fileURL.path)", "recycle:\(folderURL.path)"])
    XCTAssertNil(harness.appState.selectedDocumentID)
    XCTAssertFalse(harness.appState.documentSession.hasEditableBuffer)
    XCTAssertEqual(harness.recycleRequests, [[folderURL]])
  }

  func testRecycleSuccessCompletionRemovesOpenFileReference() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }

    let fileURL = fixture.root.appendingPathComponent("alpha.md").standardizedFileURL
    try "# Alpha".write(to: fileURL, atomically: true, encoding: .utf8)

    let harness = try makeHarness(root: fixture.root)
    harness.appState.openFiles = [DocumentRef(id: fileURL, isAdHoc: true)]

    XCTAssertTrue(harness.controller.moveItemToTrash(url: fileURL))
    XCTAssertEqual(harness.appState.openFiles.map(\.id), [fileURL])

    let completion = try XCTUnwrap(harness.recycleCompletion)
    completion([:], nil)
    await Self.drainMainActor(until: { harness.appState.openFiles.isEmpty })

    XCTAssertTrue(harness.appState.openFiles.isEmpty)
    XCTAssertNil(harness.appState.lastError)
  }

  func testRecycleFailureCompletionSurfacesErrorAndKeepsOpenFileReference() async throws {
    let fixture = try makeFixture()
    defer { fixture.cleanup() }

    let fileURL = fixture.root.appendingPathComponent("alpha.md").standardizedFileURL
    try "# Alpha".write(to: fileURL, atomically: true, encoding: .utf8)

    let harness = try makeHarness(root: fixture.root)
    harness.appState.openFiles = [DocumentRef(id: fileURL, isAdHoc: true)]

    XCTAssertTrue(harness.controller.moveItemToTrash(url: fileURL))

    let completion = try XCTUnwrap(harness.recycleCompletion)
    completion([:], CocoaError(.fileWriteNoPermission))
    await Self.drainMainActor(until: { harness.appState.lastError != nil })

    let lastError = try XCTUnwrap(harness.appState.lastError)
    XCTAssertTrue(lastError.contains("alpha.md"), "error names the file: \(lastError)")
    XCTAssertTrue(lastError.contains("Trash"), "error names the operation: \(lastError)")
    // The file is still on disk after a failed recycle, so its sidebar reference must survive.
    XCTAssertEqual(harness.appState.openFiles.map(\.id), [fileURL])
  }

  /// The recycle completion hops through `Task { @MainActor in ... }`; yield the main
  /// actor until the hop lands (bounded so a regression fails fast instead of hanging).
  private static func drainMainActor(until condition: @MainActor () -> Bool) async {
    for _ in 0..<500 {
      if condition() { return }
      await Task.yield()
    }
  }

  private func makeHarness(root: URL) throws -> TrashHarness {
    let appState = AppState()
    let indexDatabase = IndexDatabase(databaseURL: root.appendingPathComponent("index.db"))
    let bookmarkStore = try temporaryBookmarkStore()
    let metadataStore = WorkspaceMetadataStore(
      metadataURL: root.appendingPathComponent("workspace.json", isDirectory: false))
    let substrate = WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: root))
    let documentStore = DocumentStore(
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore
    )
    let harness = TrashHarness()
    let folderManager = FolderManager(
      metadataStore: metadataStore,
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceSubstrate: substrate,
      recycleItems: { urls, completion in
        harness.recycleRequests.append(urls)
        harness.recycleCompletion = completion
        harness.events.append("recycle:\(urls.map(\.path).joined(separator: ","))")
      }
    )
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { $0() },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      closeWindow: { window in
        if let documentID = harness.windowDocumentIDs[ObjectIdentifier(window)] {
          harness.events.append("close:\(documentID.path)")
        } else {
          harness.events.append("close:<unknown>")
        }
      }
    )
    harness.registry = registry
    harness.appState = appState
    harness.documentStore = documentStore
    harness.controller = AppController(
      appState: appState,
      folderManager: folderManager,
      documentStore: documentStore,
      indexDatabase: indexDatabase,
      documentWindowRegistry: registry
    )
    return harness
  }

  private func makeFixture() throws -> TrashFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveWorkspaceTrashTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return TrashFixture(root: root)
  }

  private func temporaryBookmarkStore() throws -> BookmarkStore {
    let suiteName = "PensieveWorkspaceTrashTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(
      UserDefaults(suiteName: suiteName),
      "Expected UserDefaults suite \(suiteName) to be creatable")
    defaults.removePersistentDomain(forName: suiteName)
    return BookmarkStore(defaults: defaults)
  }

  private static func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    return window
  }
}

@MainActor
private final class TrashHarness {
  var appState: AppState!
  var documentStore: DocumentStore!
  var controller: AppController!
  var registry: DocumentWindowRegistry!
  var recycleRequests: [[URL]] = []
  var recycleCompletion: (@Sendable ([URL: URL], Error?) -> Void)?
  var events: [String] = []
  var windowDocumentIDs: [ObjectIdentifier: URL] = [:]
}

private struct TrashFixture {
  let root: URL

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}
