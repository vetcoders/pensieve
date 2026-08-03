import AppKit
import XCTest

@testable import Pensieve

@MainActor
final class TrashConfirmationTests: XCTestCase {
  func testFileRequestSkipsFolderConfirmation() async throws {
    let fixture = try TrashTestFixture.make()
    let fileURL = fixture.root.appendingPathComponent("file.md").standardizedFileURL
    try "# File".write(to: fileURL, atomically: true, encoding: .utf8)
    let harness = try makeTrashHarness(root: fixture.root)
    defer {
      harness.closeWorkspace()
      fixture.cleanup()
    }

    let operation = harness.requestTrash(fileURL)
    await harness.waitForRecycleRequest()

    XCTAssertTrue(harness.confirmationProbe.requests.isEmpty)
    harness.completeRecycle()
    let didTrash = await operation.value
    XCTAssertTrue(didTrash)
  }

  func testFolderRequestConfirmsExactlyOnce() async throws {
    let fixture = try TrashTestFixture.make()
    let folderURL = fixture.root.appendingPathComponent("folder", isDirectory: true)
      .standardizedFileURL
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    let harness = try makeTrashHarness(root: fixture.root)
    defer {
      harness.closeWorkspace()
      fixture.cleanup()
    }

    let operation = harness.requestTrash(folderURL)
    await harness.waitForRecycleRequest()

    XCTAssertEqual(harness.confirmationProbe.requests, [folderURL])
    harness.completeRecycle()
    let didTrash = await operation.value
    XCTAssertTrue(didTrash)
    XCTAssertEqual(harness.confirmationProbe.requests, [folderURL])
  }

  func testFolderCancellationConfirmsOnceAndNeverRequestsRecycle() async throws {
    let fixture = try TrashTestFixture.make()
    let folderURL = fixture.root.appendingPathComponent("folder", isDirectory: true)
      .standardizedFileURL
    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
    let harness = try makeTrashHarness(root: fixture.root, confirmationResult: false)
    defer {
      harness.closeWorkspace()
      fixture.cleanup()
    }

    let didTrash = await harness.controller.moveItemToTrash(url: folderURL)
    XCTAssertFalse(didTrash)
    XCTAssertEqual(harness.confirmationProbe.requests, [folderURL])
    XCTAssertTrue(harness.recycleProbe.requests.isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: folderURL.path))
  }
}

@MainActor
final class TrashTestHarness {
  let root: URL
  let appState: AppState
  let indexDatabase: IndexDatabase
  let documentStore: DocumentStore
  let folderManager: FolderManager
  let registry: DocumentWindowRegistry
  let controller: AppController
  let recycleProbe: TrashRecycleProbe
  let confirmationProbe: TrashConfirmationProbe
  let indexBatchCounter: LockedCounter

  init(
    root: URL,
    bookmarkDefaults: UserDefaults,
    confirmationResult: Bool = true,
    workspaceBuilder: WorkspaceScanner.Builder? = nil
  ) throws {
    self.root = root.standardizedFileURL
    self.appState = AppState()
    self.recycleProbe = TrashRecycleProbe()
    self.confirmationProbe = TrashConfirmationProbe(result: confirmationResult)
    self.indexBatchCounter = LockedCounter()

    let indexDatabase = IndexDatabase(
      databaseURL: root.appendingPathComponent("index.db"),
      searchIndexBatchSize: 1,
      didInsertSearchIndexBatch: { [indexBatchCounter] count in
        indexBatchCounter.add(count)
      }
    )
    self.indexDatabase = indexDatabase

    let bookmarkStore = BookmarkStore(defaults: bookmarkDefaults)
    let metadataStore = WorkspaceMetadataStore(
      metadataURL: root.appendingPathComponent("workspace.json", isDirectory: false)
    )
    let substrate = WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: root))
    let documentStore = DocumentStore(
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      recoveryStore: RecoveryStore(
        directoryURL: root.appendingPathComponent("Recovery", isDirectory: true)
      )
    )
    self.documentStore = documentStore

    let recycleProbe = self.recycleProbe
    let folderManager = FolderManager(
      metadataStore: metadataStore,
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceBuilder: workspaceBuilder,
      workspaceSubstrate: substrate,
      recycleItems: { urls, completion in
        recycleProbe.recordRequest(urls, completion: completion)
      }
    )
    self.folderManager = folderManager

    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { $0() },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      closeWindow: { window in
        recycleProbe.recordClose(window)
      }
    )
    self.registry = registry

    let confirmationProbe = self.confirmationProbe
    self.controller = AppController(
      appState: appState,
      folderManager: folderManager,
      documentStore: documentStore,
      indexDatabase: indexDatabase,
      documentWindowRegistry: registry,
      confirmFolderTrash: { url in
        confirmationProbe.confirm(url)
      }
    )
  }

  func openWorkspace() async {
    folderManager.openInBackground(url: root, into: appState)
    await folderManager.waitForPendingWorkspaceBuild()
    await folderManager.waitForPendingWorkspaceIndexWrite()
    await indexDatabase.waitForPendingReindex()
  }

  func closeWorkspace() {
    folderManager.closeWorkspace(into: appState)
  }

  func requestTrash(_ url: URL) -> Task<Bool, Never> {
    Task { await controller.moveItemToTrash(url: url) }
  }

  func waitForRecycleRequest() async {
    for _ in 0..<10_000 {
      if recycleProbe.hasPendingCompletion { return }
      await Task.yield()
    }
    XCTFail("Timed out waiting for the injected recycle request")
  }

  func completeRecycle(error: Error? = nil) {
    recycleProbe.complete(error: error)
  }

  func captureState() async -> TrashStateSnapshot {
    let rootPaths = appState.workspaceRoots.map { $0.url.standardizedFileURL.path }
    let indexedCount = await indexDatabase.indexedDocumentCountInBackground(
      forRootPaths: rootPaths,
      appState: appState
    )
    return TrashStateSnapshot(
      workspaceTree: appState.workspaceTree,
      documents: appState.documents.map(\.url).sorted(by: Self.pathOrder),
      openFiles: appState.openFiles.map(\.url).sorted(by: Self.pathOrder),
      selectedDocumentID: appState.selectedDocumentID,
      documentSession: appState.documentSession,
      searchResultDocuments: appState.workspaceSearchResults.map(\.document.url)
        .sorted(by: Self.pathOrder),
      openWindowDocumentIDs: registry.openTabDocumentIDs.sorted(by: Self.pathOrder),
      indexedDocumentCount: indexedCount
    )
  }

  func register(_ window: NSWindow, documentID: URL) {
    recycleProbe.register(window, documentID: documentID)
    registry.attach(window, documentID: documentID)
  }

  static func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    return window
  }

  private static func pathOrder(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.standardizedFileURL.path < rhs.standardizedFileURL.path
  }
}

extension XCTestCase {
  /// Builds a `TrashTestHarness` whose `BookmarkStore` lives in an ephemeral
  /// `UserDefaults` suite; the suite and its backing plist are removed on test
  /// teardown so runs never strand plists in `~/Library/Preferences`.
  @MainActor
  func makeTrashHarness(
    root: URL,
    confirmationResult: Bool = true,
    workspaceBuilder: WorkspaceScanner.Builder? = nil
  ) throws -> TrashTestHarness {
    try TrashTestHarness(
      root: root,
      bookmarkDefaults: makeEphemeralDefaults(prefix: "PensieveWorkspaceTrashTests"),
      confirmationResult: confirmationResult,
      workspaceBuilder: workspaceBuilder
    )
  }
}

@MainActor
final class TrashConfirmationProbe {
  var result: Bool
  private(set) var requests: [URL] = []

  init(result: Bool) {
    self.result = result
  }

  func confirm(_ url: URL) -> Bool {
    requests.append(url.standardizedFileURL)
    return result
  }
}

final class TrashRecycleProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storedRequests: [[URL]] = []
  private var storedCompletion: (@Sendable ([URL: URL], Error?) -> Void)?
  private var storedEvents: [String] = []
  private var windowDocumentIDs: [ObjectIdentifier: URL] = [:]

  var requests: [[URL]] {
    lock.withLock { storedRequests }
  }

  var events: [String] {
    lock.withLock { storedEvents }
  }

  var hasPendingCompletion: Bool {
    lock.withLock { storedCompletion != nil }
  }

  func recordRequest(
    _ urls: [URL],
    completion: @escaping @Sendable ([URL: URL], Error?) -> Void
  ) {
    lock.withLock {
      storedRequests.append(urls)
      storedCompletion = completion
      storedEvents.append("request:\(urls.map(\.path).joined(separator: ","))")
    }
  }

  func complete(error: Error?) {
    let payload: ((@Sendable ([URL: URL], Error?) -> Void), [URL])? = lock.withLock {
      guard let storedCompletion, let urls = storedRequests.last else { return nil }
      self.storedCompletion = nil
      storedEvents.append("completion:\(urls.map(\.path).joined(separator: ","))")
      return (storedCompletion, urls)
    }
    guard let (completion, urls) = payload else {
      XCTFail("No recycle completion is pending")
      return
    }
    if error == nil {
      for url in urls {
        try? FileManager.default.removeItem(at: url)
      }
    }
    completion([:], error)
  }

  func register(_ window: NSWindow, documentID: URL) {
    lock.withLock {
      windowDocumentIDs[ObjectIdentifier(window)] = documentID.standardizedFileURL
    }
  }

  func recordClose(_ window: NSWindow) {
    lock.withLock {
      let documentID = windowDocumentIDs[ObjectIdentifier(window)]
      storedEvents.append("close:\(documentID?.path ?? "<unknown>")")
    }
  }
}

final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var value: Int {
    lock.withLock { storage }
  }

  func add(_ amount: Int) {
    lock.withLock { storage += amount }
  }

  func reset() {
    lock.withLock { storage = 0 }
  }
}

/// Counts scanner walks, which is how a test proves a workspace producer did — or did NOT — arm.
/// Every refresh path (`scheduleExplicitRefresh`, `performWatcherRefresh`, the open-flow build) runs
/// its walk through the injected builder, so an invocation is the arming made observable; asserting
/// on the count is what turns "no refresh armed after quiescence" into a measurement instead of a
/// claim about a private task handle.
final class CountingWorkspaceBuilder: @unchecked Sendable {
  private let counter = LockedCounter()

  var invocations: Int { counter.value }

  func reset() { counter.reset() }

  lazy var builder: WorkspaceScanner.Builder = { [counter] roots, exclusions in
    counter.add(1)
    return WorkspaceScanner.build(rootURLs: roots, exclusions: exclusions)
  }
}

final class BlockingWorkspaceBuilder: @unchecked Sendable {
  private let release = DispatchSemaphore(value: 0)

  lazy var builder: WorkspaceScanner.Builder = { [self] roots, exclusions in
    release.wait()
    return WorkspaceScanner.build(rootURLs: roots, exclusions: exclusions)
  }

  func releaseScan() {
    release.signal()
  }
}

struct TrashStateSnapshot: Equatable {
  let workspaceTree: [WorkspaceNode]
  let documents: [URL]
  let openFiles: [URL]
  let selectedDocumentID: URL?
  let documentSession: DocumentSession
  let searchResultDocuments: [URL]
  let openWindowDocumentIDs: [URL]
  let indexedDocumentCount: Int
}

struct TrashTestFixture {
  let root: URL

  static func make() throws -> TrashTestFixture {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveWorkspaceTrashTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return TrashTestFixture(root: root.standardizedFileURL)
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}
