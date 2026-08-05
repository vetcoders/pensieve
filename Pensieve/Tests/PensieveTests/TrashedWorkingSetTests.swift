import Foundation
import XCTest

@testable import Pensieve

/// The Trash half of working-set hygiene, on a LIVE app.
///
/// A security-scoped bookmark tracks the FILE, so throwing a document away does
/// not break it — the bookmark simply starts resolving to the item's new home
/// under a Trash folder. Launch restore already refuses such an entry
/// (`BookmarkStore.restoreFileURLs`); what it cannot do is tell a RUNNING app,
/// which kept a dead row in Open Files until the next relaunch, let a trashed
/// file be opened again through any route that still had its URL, and left the
/// bookmark of a file Pensieve itself trashed sitting in the persisted set.
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
    BookmarkStore(defaults: defaults, trashMembership: SimulatedTrash.membership(at: fakeTrash))
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

  /// How many bookmark blobs the working-set key still holds, read straight from
  /// the defaults suite. `restoreWorkspace` cannot answer this: it withholds a
  /// file that is missing today while KEEPING its blob, which is exactly the
  /// distinction the "vanished ≠ trashed" control has to make.
  private func persistedFileBookmarkCount() -> Int {
    (defaults.array(forKey: "Pensieve.workspace.fileBookmarks") as? [Data])?.count ?? 0
  }

  // MARK: - Landing-location prune

  /// The persisted blob has to die by where the bookmark LANDS, because the path
  /// it was trashed FROM no longer identifies it. Unresolvable blobs are
  /// deliberately left for the restore path.
  func testPruningTrashedFilesRewritesThePersistedWorkingSet() throws {
    let keepURL = try writeNote("keep.md", in: outside)
    let dropURL = try writeNote("drop.md", in: outside)
    let store = makeBookmarkStore()
    try store.persistFile(url: keepURL, into: AppState())
    try store.persistFile(url: dropURL, into: AppState())
    let trashedURL = try trash(dropURL)

    let pruned = store.pruneTrashedFiles()
    XCTAssertEqual(pruned.map(\.trashedURL), [trashedURL])
    XCTAssertEqual(
      pruned.compactMap(\.originURL).map(BookmarkStore.identityPath),
      [BookmarkStore.identityPath(dropURL)],
      "the prune reports both halves: where the bookmark landed, and the path it was MINTED for — "
        + "the only thing a live working-set row can be matched against")
    XCTAssertEqual(restoredFileURLs(), [keepURL])
    XCTAssertTrue(
      store.pruneTrashedFiles().isEmpty,
      "a healthy working set reports nothing to prune, so no defaults write happens")
  }

  /// The prune must be about Trash membership, not about the file having moved.
  /// A document renamed or moved anywhere else keeps its bookmark.
  func testPruningKeepsAnEntryThatMovedSomewhereOtherThanTheTrash() throws {
    let noteURL = try writeNote("moved.md", in: outside)
    let store = makeBookmarkStore()
    try store.persistFile(url: noteURL, into: AppState())

    let elsewhere = workspace.appendingPathComponent("moved.md").standardizedFileURL
    try FileManager.default.moveItem(at: noteURL, to: elsewhere)

    XCTAssertTrue(store.pruneTrashedFiles().isEmpty)
    XCTAssertEqual(
      restoredFileURLs(), [elsewhere],
      "a bookmark that followed its file to a live location still describes an open document")
  }

  // MARK: - Live working set

  /// Pensieve's own `Move to Trash`. The in-memory row is dropped by
  /// `removeReferences`; the bookmark behind it is not, and it cannot be matched
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
  /// live working set finds out, instead of carrying a dead row until relaunch.
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

  /// A file that merely VANISHED — deleted outright, not trashed — keeps its
  /// bookmark: an unplugged volume or a mid-replacement write must never cost the
  /// user a working-set entry. This is the negative control for the reconcile's
  /// two-signal rule.
  func testRefreshKeepsAnOpenFileThatVanishedWithoutTurningUpInTheTrash() async throws {
    _ = try writeNote("root-note.md", in: workspace)
    let adHocURL = try writeNote("ad-hoc.md", in: outside)
    let harness = try makeHarness()

    await harness.openWorkspace()
    XCTAssertNotNil(harness.folderManager.registerOpenFile(url: adHocURL, into: harness.appState))

    try FileManager.default.removeItem(at: adHocURL)
    harness.folderManager.refresh(into: harness.appState, force: true)
    await harness.folderManager.waitForPendingForcedRefresh()

    XCTAssertEqual(
      harness.openFileURLs, [adHocURL],
      "a missing file is not a trashed file — nothing proves the user threw it away")
    // Asserted on the stored blob rather than on `restoredFileURLs()`, which
    // deliberately withholds a file that is missing TODAY while keeping its
    // bookmark. What must not happen is the reconcile pruning that bookmark.
    XCTAssertEqual(
      persistedFileBookmarkCount(), 1,
      "the bookmark survives: a vanished file may be mid-replacement, or on an unplugged volume")
  }

  /// Two documents, one NAME. The one this app has open lives on a volume that
  /// went away; the one the user threw away is a different file entirely.
  ///
  /// This is the collision the two-signal rule used to lose: both halves fired
  /// on the same basename — "a `notes.md` vanished" and "a `notes.md` turned up
  /// in the Trash" — and the live external document was retired on the strength
  /// of a coincidence. The rule is about ONE file leaving ONE path, so the
  /// second signal has to be the dropped bookmark's own pre-trash path.
  func testRefreshKeepsAVanishedFileWhenItsNamesakeIsTheOneThatWasTrashed() async throws {
    _ = try writeNote("root-note.md", in: workspace)
    let elsewhere = fixtureRoot.appendingPathComponent("Elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    // Same name, different documents — and different bytes, so nothing but the
    // name could ever confuse the two.
    let vanishingURL = try writeNote("notes.md", in: outside)
    let trashedNamesakeURL = try writeNote("notes.md", in: elsewhere)
    let harness = try makeHarness()

    await harness.openWorkspace()
    XCTAssertNotNil(harness.folderManager.registerOpenFile(url: vanishingURL, into: harness.appState))
    XCTAssertNotNil(
      harness.folderManager.registerOpenFile(url: trashedNamesakeURL, into: harness.appState))
    XCTAssertEqual(harness.openFileURLs, [vanishingURL, trashedNamesakeURL])

    // The namesake is genuinely thrown away; the open document merely stops
    // being reachable, the way an unplugged volume takes a file with it.
    try trash(trashedNamesakeURL)
    try FileManager.default.removeItem(at: vanishingURL)

    harness.folderManager.refresh(into: harness.appState, force: true)
    await harness.folderManager.waitForPendingForcedRefresh()

    XCTAssertEqual(
      harness.openFileURLs, [vanishingURL],
      "a live document on a disconnected volume must not be retired because some OTHER file with "
        + "the same name was thrown away")
    XCTAssertEqual(
      persistedFileBookmarkCount(), 1,
      "…and it keeps its bookmark, so the volume coming back brings the document back with it")
  }

  // MARK: - Open route

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

  /// The render-side guard, for the window between a Finder trashing and the
  /// scan commit that retires the row. A trashed file reads perfectly, so without
  /// this the app would present a thrown-away note as an ordinary editable
  /// document.
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
