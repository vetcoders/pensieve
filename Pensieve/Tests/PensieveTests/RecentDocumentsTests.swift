import AppKit
import XCTest

@testable import Pensieve

/// In-memory stand-in for `NSDocumentController` mimicking its observable
/// behavior: newest-first ordering, move-to-front dedupe, whole-list clear.
private final class FakeRecentDocumentsController: RecentDocumentsControlling {
  private(set) var urls: [URL]
  private(set) var noteCalls: [URL] = []
  private(set) var clearCallCount = 0

  init(urls: [URL] = []) {
    self.urls = urls
  }

  var recentDocumentURLs: [URL] { urls }

  func noteNewRecentDocumentURL(_ url: URL) {
    noteCalls.append(url)
    let standardized = url.standardizedFileURL
    urls.removeAll { $0.standardizedFileURL == standardized }
    urls.insert(standardized, at: 0)
  }

  func clearRecentDocuments(_ sender: Any?) {
    clearCallCount += 1
    urls.removeAll()
  }
}

@MainActor
final class RecentDocumentsTests: XCTestCase {

  // MARK: - Store over the system authority

  func testStoreMirrorsControllerNewestFirstAndDeduplicates() {
    let fake = FakeRecentDocumentsController()
    let store = RecentDocumentsStore(controller: fake, fileExists: { _ in true })

    let alpha = URL(fileURLWithPath: "/tmp/alpha.md")
    let beta = URL(fileURLWithPath: "/tmp/beta.md")
    store.noteOpened(alpha)
    store.noteOpened(beta)
    store.noteOpened(alpha)

    XCTAssertEqual(store.recentDocuments, [alpha.standardizedFileURL, beta.standardizedFileURL])
    XCTAssertEqual(fake.noteCalls.count, 3)
  }

  func testStoreSkipsVanishedFilesFromDisplay() {
    let alive = URL(fileURLWithPath: "/tmp/alive.md").standardizedFileURL
    let gone = URL(fileURLWithPath: "/tmp/gone.md").standardizedFileURL
    let fake = FakeRecentDocumentsController(urls: [gone, alive])
    let store = RecentDocumentsStore(
      controller: fake,
      fileExists: { $0.path == alive.path }
    )

    XCTAssertEqual(store.recentDocuments, [alive])
  }

  func testClearEmptiesTheNativeList() {
    let fake = FakeRecentDocumentsController(urls: [URL(fileURLWithPath: "/tmp/alpha.md")])
    let store = RecentDocumentsStore(controller: fake, fileExists: { _ in true })

    store.clear()

    XCTAssertEqual(fake.clearCallCount, 1)
    XCTAssertTrue(store.recentDocuments.isEmpty)
    XCTAssertTrue(fake.recentDocumentURLs.isEmpty)
  }

  func testMenuTitleAbbreviatesHomeDirectoryPaths() {
    let homeFile = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("notes.md")
    XCTAssertEqual(RecentDocumentsStore.menuTitle(for: homeFile), "~/notes.md")
    XCTAssertEqual(
      RecentDocumentsStore.menuTitle(for: URL(fileURLWithPath: "/tmp/x.md")), "/tmp/x.md")
  }

  // MARK: - Route matrix: every successful open records exactly once

  func testOpenFileInCurrentWindowRecordsExactlyOnce() throws {
    let harness = try makeRouteHarness()
    defer { harness.cleanup() }
    let alpha = try harness.makeFile("alpha.md")

    harness.controller.openFileInCurrentWindow(url: alpha)

    XCTAssertEqual(harness.appState.documentSession.url?.standardizedFileURL, alpha)
    XCTAssertEqual(harness.fake.noteCalls, [alpha])
    XCTAssertEqual(harness.store.recentDocuments, [alpha])
  }

  func testOpenFileLoadsInEmptyWindowAndRecordsOnce() throws {
    let harness = try makeRouteHarness()
    defer { harness.cleanup() }
    let alpha = try harness.makeFile("alpha.md")

    harness.controller.openFile(url: alpha)

    XCTAssertEqual(harness.appState.selectedDocumentID, alpha)
    XCTAssertEqual(harness.fake.noteCalls, [alpha])
  }

  func testFailedUnsupportedOpenDoesNotRecord() throws {
    let harness = try makeRouteHarness()
    defer { harness.cleanup() }
    let image = try harness.makeFile("picture.png", contents: "not markdown")

    harness.controller.openFileInCurrentWindow(url: image)

    XCTAssertNotNil(harness.appState.lastError)
    XCTAssertTrue(harness.fake.noteCalls.isEmpty)
  }

  func testFolderOpenDoesNotRecordARecentDocument() throws {
    let harness = try makeRouteHarness()
    defer { harness.cleanup() }
    let folder = harness.root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    harness.controller.openFile(url: folder)

    XCTAssertTrue(harness.fake.noteCalls.isEmpty)
  }

  func testImportSourceFileDoesNotRecordARecentDocument() throws {
    let harness = try makeRouteHarness()
    defer { harness.cleanup() }
    let word = try harness.makeFile("report.docx", contents: "fake word bytes")

    harness.controller.openFile(url: word)

    XCTAssertTrue(harness.fake.noteCalls.isEmpty)
  }

  func testRegistryRoutedOpenDoesNotRecordInTheOriginatingWindow() throws {
    let harness = try makeRouteHarness()
    defer { harness.cleanup() }
    let alpha = try harness.makeFile("alpha.md")
    let beta = try harness.makeFile("beta.md")

    harness.controller.openFileInCurrentWindow(url: alpha)
    XCTAssertEqual(harness.fake.noteCalls, [alpha])

    var routedRefs: [DocumentRef] = []
    harness.controller.requestOpenDocumentWindow = { routedRefs.append($0) }

    harness.controller.openFile(url: beta)

    // The destination window records during its own load; the originating
    // window must not, or the same open would enter history twice.
    XCTAssertEqual(routedRefs.map(\.id), [beta])
    XCTAssertEqual(harness.fake.noteCalls, [alpha])
  }

  func testSidebarSelectionRecordsAfterSuccessfulLoad() throws {
    let harness = try makeRouteHarness()
    defer { harness.cleanup() }
    let alpha = try harness.makeFile("alpha.md")
    let beta = try harness.makeFile("beta.md")

    harness.controller.openFileInCurrentWindow(url: alpha)
    harness.controller.openFileInCurrentWindow(url: beta)
    XCTAssertEqual(harness.fake.noteCalls, [alpha, beta])

    harness.controller.selectDocument(id: alpha)

    XCTAssertEqual(harness.appState.selectedDocumentID, alpha)
    XCTAssertEqual(harness.fake.noteCalls, [alpha, beta, alpha])
    XCTAssertEqual(harness.store.recentDocuments, [alpha, beta])
  }

  func testSelectionOfUnreadableDocumentDoesNotRecord() throws {
    let harness = try makeRouteHarness()
    defer { harness.cleanup() }
    let ghost = harness.root.appendingPathComponent("ghost.md").standardizedFileURL
    harness.appState.openFiles = [DocumentRef(id: ghost, isAdHoc: true)]

    harness.controller.selectDocument(id: ghost)

    XCTAssertNotNil(harness.appState.lastError)
    XCTAssertTrue(harness.fake.noteCalls.isEmpty)
  }

  func testLaunchIntentOpenRecordsExactlyOnce() async throws {
    let harness = try makeRouteHarness()
    defer { harness.cleanup() }
    let alpha = try harness.makeFile("alpha.md")

    // Production wires window routing before launch intents settle
    // (DocumentWindowRootView.configureDocumentRouting); an unwired controller
    // would also trigger the coordinator's headless selectDocument fallback,
    // which is not the path a packaged launch takes.
    harness.controller.requestOpenDocumentWindow = { _ in }
    let coordinator = LaunchIntentCoordinator()
    coordinator.handle(urls: [alpha])
    coordinator.startWhenLaunchIntentsSettle(controller: harness.controller)
    await coordinator.waitForStartupDecision()

    XCTAssertEqual(harness.appState.selectedDocumentID, alpha)
    XCTAssertEqual(harness.fake.noteCalls, [alpha])
  }

  func testSavingADraftRecordsTheSavedDocument() throws {
    let harness = try makeRouteHarness()
    defer { harness.cleanup() }

    XCTAssertTrue(harness.controller.createUntitledDocument())
    harness.appState.documentSession.text = "# Draft"
    let target = harness.root.appendingPathComponent("saved.md")

    XCTAssertTrue(harness.controller.saveActiveDocument(as: target))

    XCTAssertEqual(harness.fake.noteCalls, [target.standardizedFileURL])
  }

  // MARK: - Open Recent selection

  func testOpenRecentDocumentReopensInCurrentWindow() throws {
    let harness = try makeRouteHarness()
    defer { harness.cleanup() }
    let alpha = try harness.makeFile("alpha.md")

    harness.controller.openRecentDocument(url: alpha)

    XCTAssertEqual(harness.appState.selectedDocumentID, alpha)
    XCTAssertEqual(harness.fake.noteCalls, [alpha])
  }

  func testOpenRecentMissingFileFailsClearlyAndDropsFromDisplay() throws {
    let harness = try makeRouteHarness()
    defer { harness.cleanup() }
    let alpha = try harness.makeFile("alpha.md")
    let ghost = harness.root.appendingPathComponent("ghost.md").standardizedFileURL
    harness.fake.noteNewRecentDocumentURL(alpha)
    harness.fake.noteNewRecentDocumentURL(ghost)
    harness.store.refresh()
    XCTAssertEqual(harness.store.recentDocuments, [alpha])

    harness.controller.openRecentDocument(url: ghost)

    let lastError = try XCTUnwrap(harness.appState.lastError)
    XCTAssertTrue(lastError.contains("ghost.md"), "error names the file: \(lastError)")
    XCTAssertNil(harness.appState.selectedDocumentID)
    XCTAssertEqual(harness.store.recentDocuments, [alpha])
  }

  // MARK: - Harness

  private func makeRouteHarness() throws -> RouteHarness {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveRecentDocumentsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let indexDatabase = IndexDatabase(databaseURL: root.appendingPathComponent("index.db"))
    let suiteName = "PensieveRecentDocumentsTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(
      UserDefaults(suiteName: suiteName),
      "Expected UserDefaults suite \(suiteName) to be creatable")
    defaults.removePersistentDomain(forName: suiteName)
    let bookmarkStore = BookmarkStore(defaults: defaults)
    let metadataStore = WorkspaceMetadataStore(
      metadataURL: root.appendingPathComponent("workspace.json", isDirectory: false))
    let substrate = WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: root))
    let recoveryStore = RecoveryStore(
      directoryURL: root.appendingPathComponent("Recovery", isDirectory: true))
    let documentStore = DocumentStore(
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      recoveryStore: recoveryStore
    )
    let folderManager = FolderManager(
      metadataStore: metadataStore,
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceSubstrate: substrate
    )
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { $0() },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      closeWindow: { _ in }
    )
    let appState = AppState()
    let fake = FakeRecentDocumentsController()
    let store = RecentDocumentsStore(controller: fake)
    let controller = AppController(
      appState: appState,
      folderManager: folderManager,
      documentStore: documentStore,
      indexDatabase: indexDatabase,
      documentWindowRegistry: registry,
      recentDocuments: store
    )
    return RouteHarness(
      root: root,
      appState: appState,
      controller: controller,
      fake: fake,
      store: store
    )
  }
}

@MainActor
private struct RouteHarness {
  let root: URL
  let appState: AppState
  let controller: AppController
  let fake: FakeRecentDocumentsController
  let store: RecentDocumentsStore

  func makeFile(_ name: String, contents: String = "# Fixture") throws -> URL {
    let url = root.appendingPathComponent(name).standardizedFileURL
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  func cleanup() {
    try? FileManager.default.removeItem(at: root)
  }
}
