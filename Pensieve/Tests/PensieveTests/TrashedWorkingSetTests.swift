import Foundation
import XCTest

@testable import Pensieve

/// The Trash half of working-set hygiene.
///
/// A security-scoped bookmark tracks the FILE, so throwing a document away does
/// not break it — the bookmark simply starts resolving to the item's new home
/// under a Trash folder. Everything that decided "this is still an open
/// document" by resolving a bookmark and checking existence therefore said YES
/// about files the user had deleted, and the app restored them as live,
/// editable documents.
///
/// Every test here works against a SIMULATED Trash injected into
/// `BookmarkStore`, so the suite never moves anything into the real
/// `~/.Trash`. The real predicate is covered separately by
/// `TrashLocationTests`, which does one genuine round trip and puts it back.
@MainActor
final class TrashedWorkingSetTests: XCTestCase {
  private var fixtureRoot: URL!
  private var workspace: URL!
  private var outside: URL!
  private var fakeTrash: URL!
  private var defaults: UserDefaults!

  override func setUp() async throws {
    defaults = makeEphemeralDefaults(prefix: "PensieveTrashedWorkingSetTests")
    fixtureRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("TrashedWorkingSetTests-\(UUID().uuidString)", isDirectory: true)
    workspace = fixtureRoot.appendingPathComponent("Workspace", isDirectory: true)
    outside = fixtureRoot.appendingPathComponent("Outside", isDirectory: true)
    fakeTrash = fixtureRoot.appendingPathComponent("Trash", isDirectory: true)
    for directory in [workspace, outside, fakeTrash] {
      try FileManager.default.createDirectory(at: directory!, withIntermediateDirectories: true)
    }
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: fixtureRoot)
  }

  /// `BookmarkStore` over the shared ephemeral suite, told that the fixture's
  /// `Trash/` directory is a Trash.
  private func makeBookmarkStore() -> BookmarkStore {
    let fakeTrashPath = fakeTrash.standardizedFileURL.path
    return BookmarkStore(defaults: defaults) { url in
      let path = url.standardizedFileURL.path
      return path == fakeTrashPath || path.hasPrefix(fakeTrashPath + "/")
    }
  }

  /// Moves `url` into the simulated Trash the way the system does: a plain move,
  /// which leaves the security-scoped bookmark perfectly resolvable — pointing at
  /// the new location.
  @discardableResult
  private func trash(_ url: URL) throws -> URL {
    let destination = fakeTrash.appendingPathComponent(url.lastPathComponent)
    try FileManager.default.moveItem(at: url, to: destination)
    return destination.standardizedFileURL
  }

  private func writeNote(_ name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name).standardizedFileURL
    try "# \(name)".write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func restoredFileURLs() -> [URL] {
    makeBookmarkStore().restoreWorkspace(into: AppState()).fileURLs
      .map(\.standardizedFileURL)
  }

  // MARK: - (a) Restore

  /// The reported defect: a document moved to the Trash came back on the next
  /// launch, with its content, because its bookmark still resolved and the file
  /// it resolved to still existed.
  func testRestoreDropsAWorkingSetEntryThatNowLivesInTheTrash() throws {
    let noteURL = try writeNote("trashed.md", in: outside)
    try makeBookmarkStore().persistFile(url: noteURL, into: AppState())
    XCTAssertEqual(
      restoredFileURLs(), [noteURL],
      "precondition: the working set restores this file before it is thrown away")

    let trashedURL = try trash(noteURL)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: trashedURL.path),
      "precondition: the file still exists — being in the Trash is the ONLY thing wrong with it")

    XCTAssertTrue(
      restoredFileURLs().isEmpty,
      "a bookmark resolving into the Trash must be treated as dead, like one that cannot resolve")
  }

  /// Negative control for the test above: the drop must be about Trash
  /// membership, not about the file having moved. A document renamed or moved
  /// anywhere else keeps its place in the working set.
  func testRestoreKeepsAnEntryThatMovedSomewhereOtherThanTheTrash() throws {
    let noteURL = try writeNote("moved.md", in: outside)
    try makeBookmarkStore().persistFile(url: noteURL, into: AppState())

    let elsewhere = workspace.appendingPathComponent("moved.md").standardizedFileURL
    try FileManager.default.moveItem(at: noteURL, to: elsewhere)

    XCTAssertEqual(
      restoredFileURLs(), [elsewhere],
      "a bookmark that followed its file to a live location still describes an open document")
  }

  /// Trashing one document must not cost the others their place.
  func testRestoreKeepsLiveEntriesAlongsideATrashedOne() throws {
    let keepURL = try writeNote("keep.md", in: outside)
    let dropURL = try writeNote("drop.md", in: outside)
    let store = makeBookmarkStore()
    try store.persistFile(url: keepURL, into: AppState())
    try store.persistFile(url: dropURL, into: AppState())

    try trash(dropURL)

    XCTAssertEqual(restoredFileURLs(), [keepURL])
  }

  /// §3.3 guard: a file that is truly gone — not trashed — keeps behaving exactly
  /// as before, dropped by the existing resolution/existence failure.
  func testRestoreStillDropsAnExternallyDeletedEntry() throws {
    let noteURL = try writeNote("deleted.md", in: outside)
    try makeBookmarkStore().persistFile(url: noteURL, into: AppState())

    try FileManager.default.removeItem(at: noteURL)

    XCTAssertTrue(restoredFileURLs().isEmpty)
  }

  /// The persisted blob dies too, so the prune is not re-run on every launch:
  /// `pruneTrashedFiles` rewrites the stored set, and unresolvable blobs are
  /// deliberately left for the restore path to handle.
  func testPruningTrashedFilesRewritesThePersistedWorkingSet() throws {
    let keepURL = try writeNote("keep.md", in: outside)
    let dropURL = try writeNote("drop.md", in: outside)
    let store = makeBookmarkStore()
    try store.persistFile(url: keepURL, into: AppState())
    try store.persistFile(url: dropURL, into: AppState())
    let trashedURL = try trash(dropURL)

    XCTAssertEqual(store.pruneTrashedFiles(), [trashedURL])
    XCTAssertEqual(restoredFileURLs(), [keepURL])
    XCTAssertTrue(
      store.pruneTrashedFiles().isEmpty,
      "a healthy working set reports nothing to prune, so no defaults write happens")
  }

  // MARK: - (b) Live working set

  /// Pensieve's own `Move to Trash`. The in-memory row was already dropped by
  /// `removeReferences`; the bookmark behind it was not, and it cannot be matched
  /// by the path just trashed — it now resolves into the Trash.
  func testTrashingAnOpenFileThroughTheAppRemovesItFromTheWorkingSet() async throws {
    _ = try writeNote("root-note.md", in: workspace)
    let adHocURL = try writeNote("ad-hoc.md", in: outside)
    let harness = try makeHarness()

    await harness.openWorkspace()
    XCTAssertNotNil(harness.folderManager.registerOpenFile(url: adHocURL, into: harness.appState))
    XCTAssertEqual(harness.openFileURLs, [adHocURL], "precondition: the file is in Open Files")
    XCTAssertEqual(restoredFileURLs(), [adHocURL], "precondition: and in the persisted working set")

    let didTrash = await harness.folderManager.moveToTrash(url: adHocURL, into: harness.appState)

    XCTAssertTrue(didTrash)
    XCTAssertTrue(harness.openFileURLs.isEmpty, "a trashed document leaves Open Files")
    XCTAssertTrue(
      restoredFileURLs().isEmpty,
      "and leaves the persisted working set, so the next launch cannot resurrect it")
  }

  /// Trashed in Finder, behind the app's back. The next scan commit — here the
  /// explicit refresh, in the app the debounced watcher refresh — is where the
  /// live working set finds out.
  func testTrashingAnOpenFileExternallyRemovesItOnTheNextRefresh() async throws {
    _ = try writeNote("root-note.md", in: workspace)
    let adHocURL = try writeNote("ad-hoc.md", in: outside)
    let harness = try makeHarness()

    await harness.openWorkspace()
    XCTAssertNotNil(harness.folderManager.registerOpenFile(url: adHocURL, into: harness.appState))
    XCTAssertEqual(harness.openFileURLs, [adHocURL])

    try trash(adHocURL)
    harness.folderManager.refresh(into: harness.appState, force: true)
    await harness.folderManager.waitForPendingForcedRefresh()

    XCTAssertTrue(harness.openFileURLs.isEmpty)
    XCTAssertTrue(restoredFileURLs().isEmpty)
  }

  /// A refresh that finds nothing wrong must leave the working set exactly as it
  /// was — the reconcile is a guard, not a sweep.
  func testRefreshLeavesAHealthyWorkingSetUntouched() async throws {
    _ = try writeNote("root-note.md", in: workspace)
    let adHocURL = try writeNote("ad-hoc.md", in: outside)
    let harness = try makeHarness()

    await harness.openWorkspace()
    XCTAssertNotNil(harness.folderManager.registerOpenFile(url: adHocURL, into: harness.appState))

    harness.folderManager.refresh(into: harness.appState, force: true)
    await harness.folderManager.waitForPendingForcedRefresh()

    XCTAssertEqual(harness.openFileURLs, [adHocURL])
    XCTAssertEqual(restoredFileURLs(), [adHocURL])
  }

  /// Opening is refused outright, so no route can put a trashed file back into
  /// the working set — or mint it a fresh bookmark.
  func testOpeningAFileFromTheTrashIsRefused() throws {
    let noteURL = try writeNote("refused.md", in: outside)
    let trashedURL = try trash(noteURL)
    let harness = try makeHarness()

    XCTAssertNil(harness.folderManager.registerOpenFile(url: trashedURL, into: harness.appState))
    XCTAssertTrue(harness.openFileURLs.isEmpty)
    XCTAssertTrue(restoredFileURLs().isEmpty)
    XCTAssertEqual(
      harness.appState.lastError,
      "refused.md is in the Trash. Put it back to open it.")
  }

  /// The render-side guard. A trashed file reads perfectly, so without this the
  /// app would present a deleted note as an ordinary editable document — which
  /// is exactly what the operator saw.
  func testSelectingATrashedDocumentRefusesToRenderItAndDropsIt() throws {
    let noteURL = try writeNote("shown.md", in: outside)
    let store = makeBookmarkStore()
    try store.persistFile(url: noteURL, into: AppState())
    let trashedURL = try trash(noteURL)

    let harness = try makeHarness(bookmarkStore: store)
    let ref = DocumentRef(id: trashedURL, isAdHoc: true)
    harness.appState.openFiles = [ref]

    _ = harness.documentStore.select(ref: ref, into: harness.appState)

    XCTAssertFalse(
      harness.appState.documentSession.hasEditableBuffer,
      "the content of a thrown-away file must never reach the editor")
    XCTAssertTrue(harness.openFileURLs.isEmpty)
    XCTAssertTrue(restoredFileURLs().isEmpty)
    XCTAssertEqual(harness.appState.lastError, "shown.md is in the Trash.")
  }

  // MARK: - Harness

  private func makeHarness(bookmarkStore: BookmarkStore? = nil) throws -> TrashedWorkingSetHarness {
    try TrashedWorkingSetHarness(
      workspace: workspace,
      support: fixtureRoot.appendingPathComponent("Support", isDirectory: true),
      bookmarkStore: bookmarkStore ?? makeBookmarkStore(),
      trashDirectory: fakeTrash
    )
  }
}

/// Minimal live-app slice: a workspace on disk, a `FolderManager` whose recycler
/// really moves items into the fixture's simulated Trash (so bookmarks follow
/// their files exactly as they do on a real trashing), and every store pointed at
/// the fixture directory.
@MainActor
final class TrashedWorkingSetHarness {
  let appState = AppState()
  let folderManager: FolderManager
  let documentStore: DocumentStore
  private let workspace: URL

  init(workspace: URL, support: URL, bookmarkStore: BookmarkStore, trashDirectory: URL) throws {
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    self.workspace = workspace.standardizedFileURL

    let indexDatabase = IndexDatabase(
      databaseURL: support.appendingPathComponent("index.db", isDirectory: false))
    self.documentStore = DocumentStore(
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      recoveryStore: RecoveryStore(
        directoryURL: support.appendingPathComponent("Recovery", isDirectory: true))
    )
    self.folderManager = FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: support.appendingPathComponent("workspace.json", isDirectory: false)),
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceSubstrate: WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: support)),
      recycleItems: { urls, completion in
        var moved: [URL: URL] = [:]
        for url in urls {
          let destination = trashDirectory.appendingPathComponent(url.lastPathComponent)
          do {
            try FileManager.default.moveItem(at: url, to: destination)
            moved[url] = destination
          } catch {
            completion(moved, error)
            return
          }
        }
        completion(moved, nil)
      }
    )
  }

  var openFileURLs: [URL] {
    appState.openFiles.map(\.url).map(\.standardizedFileURL)
  }

  func openWorkspace() async {
    folderManager.openInBackground(url: workspace, into: appState)
    await folderManager.waitForPendingWorkspaceBuild()
    await folderManager.waitForPendingWorkspaceIndexWrite()
  }
}
