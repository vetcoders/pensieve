import XCTest

@testable import Pensieve

/// Relaunch restore, driven exactly like the operator's report: a real file in
/// one window, an unsaved "Recovered Untitled" draft in another, quit, relaunch.
/// The previous session's document must come back — the crash draft must not be
/// what the restored window shows.
@MainActor
final class WindowRestorationTests: XCTestCase {

  func testRelaunchRestoresTheActiveDocumentInsteadOfTheRecoveryDraft() throws {
    let environment = try makeRestoreEnvironment()

    // ── Previous session ──────────────────────────────────────────────────
    // Window A reads a real file; window B holds an unsaved draft that the
    // close/quit pass stashes as a recovery draft.
    let previousDocumentState = AppState()
    let previousDocumentStore = makeStore(in: environment)
    previousDocumentStore.load(
      ref: DocumentRef(id: environment.documentURL, isAdHoc: true),
      into: previousDocumentState)
    XCTAssertEqual(previousDocumentState.documentSession.text, "the document the user was reading")

    let previousDraftState = AppState()
    let previousDraftStore = makeStore(in: environment)
    previousDraftState.documentSession.createUntitled(title: "Untitled.md")
    previousDraftState.activeDocumentText = "unsaved crash draft"
    previousDraftStore.documentDidChange(appState: previousDraftState)
    XCTAssertTrue(previousDraftStore.savePendingChangesOnClose(appState: previousDraftState))

    // ── Relaunch ──────────────────────────────────────────────────────────
    // Fresh stores over the SAME persisted defaults and recovery directory:
    // both single-handout claims start unused, as they do in a new process.
    let relaunch = environment.relaunched()

    var draftWindowRequests = 0
    let restoredState = AppState()
    let restoredController = makeController(in: relaunch, appState: restoredState)
    restoredController.requestOpenRecoveredDraftWindow = { draftWindowRequests += 1 }
    restoredController.start(restoringWorkspace: true)

    XCTAssertEqual(
      restoredState.documentSession.url?.standardizedFileURL,
      environment.documentURL.standardizedFileURL,
      "the restored window shows the recovery draft instead of the document the previous "
        + "session had active — the real file window was dropped")
    XCTAssertEqual(restoredState.documentSession.text, "the document the user was reading")
    XCTAssertFalse(restoredState.documentSession.isDirty)
    XCTAssertFalse(restoredState.documentSession.isUntitled)

    // The draft is not lost either: it is still pending and a window was asked
    // for so it can come back beside the document.
    XCTAssertEqual(draftWindowRequests, 1, "no window was requested for the pending crash draft")
    XCTAssertTrue(relaunch.documentStoreProbe.hasPendingRecoveryDraft)

    // That second window adopts the draft — and does NOT reopen the document
    // the first window already claimed.
    let draftState = AppState()
    let draftController = makeController(in: relaunch, appState: draftState)
    draftController.start(restoringWorkspace: true)

    XCTAssertTrue(draftState.documentSession.isUntitled)
    XCTAssertEqual(draftState.documentSession.text, "unsaved crash draft")
    XCTAssertNil(draftState.documentSession.url)
  }

  /// With no document to restore the draft keeps the launch window: the
  /// previous behaviour is exactly right when nothing competes for it.
  func testRelaunchWithoutAnActiveDocumentStillRestoresTheRecoveryDraft() throws {
    let environment = try makeRestoreEnvironment()

    let previousDraftState = AppState()
    let previousDraftStore = makeStore(in: environment)
    previousDraftState.documentSession.createUntitled(title: "Untitled.md")
    previousDraftState.activeDocumentText = "unsaved crash draft"
    previousDraftStore.documentDidChange(appState: previousDraftState)
    XCTAssertTrue(previousDraftStore.savePendingChangesOnClose(appState: previousDraftState))

    let relaunch = environment.relaunched()
    var draftWindowRequests = 0
    let restoredState = AppState()
    let restoredController = makeController(in: relaunch, appState: restoredState)
    restoredController.requestOpenRecoveredDraftWindow = { draftWindowRequests += 1 }
    restoredController.start(restoringWorkspace: true)

    XCTAssertTrue(restoredState.documentSession.isUntitled)
    XCTAssertEqual(restoredState.documentSession.text, "unsaved crash draft")
    XCTAssertEqual(draftWindowRequests, 0, "an extra window was opened for a draft already shown")
  }

  /// The window the user is looking at owns the restore record. Switching back
  /// to an older tab before quitting must restore THAT document, not the file
  /// that happened to be opened last.
  func testFrontmostWindowOwnsTheRestoredDocument() throws {
    let environment = try makeRestoreEnvironment()
    let secondURL = environment.folder.appendingPathComponent("opened-later.md")
    try "opened later".write(to: secondURL, atomically: true, encoding: .utf8)

    let firstWindowState = AppState()
    let firstWindowStore = makeStore(in: environment)
    firstWindowStore.load(
      ref: DocumentRef(id: environment.documentURL, isAdHoc: true), into: firstWindowState)

    let secondWindowState = AppState()
    let secondWindowStore = makeStore(in: environment)
    secondWindowStore.load(ref: DocumentRef(id: secondURL, isAdHoc: true), into: secondWindowState)

    // The user switches back to the first window before quitting.
    let firstWindowController = makeController(
      in: environment, appState: firstWindowState, documentStore: firstWindowStore)
    firstWindowController.noteWindowBecameKey()

    let relaunch = environment.relaunched()
    let restoredState = AppState()
    makeController(in: relaunch, appState: restoredState).start(restoringWorkspace: true)

    XCTAssertEqual(
      restoredState.documentSession.url?.standardizedFileURL,
      environment.documentURL.standardizedFileURL,
      "restore reopened the last document OPENED instead of the one that was frontmost")
  }

  /// Switching documents INSIDE one window is the ordinary way the operator
  /// moves around (Open Files / Workspace click). The restore record must
  /// follow the selection, not stay on the first file the window ever showed.
  func testSelectingAnotherDocumentInTheSameWindowMovesTheRestoreRecord() throws {
    let environment = try makeRestoreEnvironment()
    let secondURL = environment.folder.appendingPathComponent("opened-later.md")
    try "the document the user switched to".write(to: secondURL, atomically: true, encoding: .utf8)

    let windowState = AppState()
    let windowStore = makeStore(in: environment)
    windowStore.load(
      ref: DocumentRef(id: environment.documentURL, isAdHoc: true), into: windowState)
    XCTAssertTrue(
      windowStore.select(ref: DocumentRef(id: secondURL, isAdHoc: true), into: windowState))

    let relaunch = environment.relaunched()
    let restoredState = AppState()
    makeController(in: relaunch, appState: restoredState).start(restoringWorkspace: true)

    XCTAssertEqual(
      restoredState.documentSession.url?.standardizedFileURL,
      secondURL.standardizedFileURL,
      "restore reopened the document the window started on instead of the one the user "
        + "switched to")
  }

  /// The operator's report: the SAME file comes back every launch, whatever she
  /// worked on. Quit tears every window down, and each close hands key status to
  /// a surviving sibling — a `didBecomeKey` cascade nobody triggered. The window
  /// that dies last is the oldest one, i.e. the window the previous launch
  /// restored, so an ungated key handler re-pins the same document forever.
  func testQuitTeardownKeepsTheDocumentTheUserWasOnInsteadOfTheOldestWindow() throws {
    let environment = try makeRestoreEnvironment()
    let workedOnURL = environment.folder.appendingPathComponent("what-she-was-working-on.md")
    try "the document the user was on at quit"
      .write(to: workedOnURL, atomically: true, encoding: .utf8)

    // Window A is the one the previous launch restored; window B is the file
    // the user opened afterwards and left frontmost.
    let restoredWindowState = AppState()
    let restoredWindowStore = makeStore(in: environment)
    restoredWindowStore.load(
      ref: DocumentRef(id: environment.documentURL, isAdHoc: true), into: restoredWindowState)
    let restoredWindowController = makeController(
      in: environment, appState: restoredWindowState, documentStore: restoredWindowStore)

    let workedOnState = AppState()
    let workedOnStore = makeStore(in: environment)
    workedOnStore.load(ref: DocumentRef(id: workedOnURL, isAdHoc: true), into: workedOnState)
    let workedOnController = makeController(
      in: environment, appState: workedOnState, documentStore: workedOnStore)
    workedOnController.noteWindowBecameKey()

    // ── Quit ──────────────────────────────────────────────────────────────
    // `applicationWillTerminate` first, then the teardown cascade: B closes,
    // AppKit promotes A to key, A closes too.
    environment.windowRegistryProbe.beginTermination()
    workedOnController.noteWindowWillClose()
    restoredWindowController.noteWindowBecameKey()
    restoredWindowController.noteWindowWillClose()

    let relaunch = environment.relaunched()
    let restoredState = AppState()
    makeController(in: relaunch, appState: restoredState).start(restoringWorkspace: true)

    XCTAssertEqual(
      restoredState.documentSession.url?.standardizedFileURL,
      workedOnURL.standardizedFileURL,
      "the quit teardown rewrote the restore record with the window that died last — the "
        + "previous launch's document comes back instead of the one the user was on")
  }

  /// Closing the active document (⌘W, "Close from Open Files") retires it: a
  /// relaunch must not drag it back.
  func testClosingTheActiveDocumentStopsItComingBackOnRelaunch() throws {
    let environment = try makeRestoreEnvironment()

    let windowState = AppState()
    let windowStore = makeStore(in: environment)
    windowStore.load(
      ref: DocumentRef(id: environment.documentURL, isAdHoc: true), into: windowState)
    XCTAssertTrue(windowStore.select(ref: nil, into: windowState))

    let relaunch = environment.relaunched()
    let restoredState = AppState()
    makeController(in: relaunch, appState: restoredState).start(restoringWorkspace: true)

    XCTAssertNil(
      restoredState.documentSession.url,
      "the document the user closed before quitting was restored anyway")
    XCTAssertFalse(restoredState.documentSession.hasEditableBuffer)
  }

  /// Same for closing the WINDOW that shows it — outside termination that is
  /// the user retiring the document, not teardown.
  func testClosingADocumentWindowDropsItsRestoreRecord() throws {
    let environment = try makeRestoreEnvironment()

    let windowState = AppState()
    let windowStore = makeStore(in: environment)
    windowStore.load(
      ref: DocumentRef(id: environment.documentURL, isAdHoc: true), into: windowState)
    makeController(in: environment, appState: windowState, documentStore: windowStore)
      .noteWindowWillClose()

    let relaunch = environment.relaunched()
    let restoredState = AppState()
    makeController(in: relaunch, appState: restoredState).start(restoringWorkspace: true)

    XCTAssertNil(
      restoredState.documentSession.url,
      "closing the document window left it as the document the next launch reopens")
  }

  /// …but a close only retires the record it OWNS. Closing an older window must
  /// not erase the document another window is still frontmost with.
  func testClosingAnotherWindowKeepsTheFrontmostDocumentsRestoreRecord() throws {
    let environment = try makeRestoreEnvironment()
    let frontmostURL = environment.folder.appendingPathComponent("still-frontmost.md")
    try "still frontmost".write(to: frontmostURL, atomically: true, encoding: .utf8)

    let olderState = AppState()
    let olderStore = makeStore(in: environment)
    olderStore.load(ref: DocumentRef(id: environment.documentURL, isAdHoc: true), into: olderState)

    let frontmostState = AppState()
    let frontmostStore = makeStore(in: environment)
    frontmostStore.load(ref: DocumentRef(id: frontmostURL, isAdHoc: true), into: frontmostState)

    makeController(in: environment, appState: olderState, documentStore: olderStore)
      .noteWindowWillClose()

    let relaunch = environment.relaunched()
    let restoredState = AppState()
    makeController(in: relaunch, appState: restoredState).start(restoringWorkspace: true)

    XCTAssertEqual(
      restoredState.documentSession.url?.standardizedFileURL,
      frontmostURL.standardizedFileURL,
      "closing a background window cleared the record the frontmost window owned")
  }

  /// A document deleted between sessions must not strand the launch window:
  /// the pending draft takes it instead of nothing being restored at all.
  func testDeletedActiveDocumentFallsBackToTheRecoveryDraft() throws {
    let environment = try makeRestoreEnvironment()

    let previousState = AppState()
    let previousStore = makeStore(in: environment)
    previousStore.load(
      ref: DocumentRef(id: environment.documentURL, isAdHoc: true), into: previousState)

    let draftState = AppState()
    draftState.documentSession.createUntitled(title: "Untitled.md")
    draftState.activeDocumentText = "unsaved crash draft"
    let draftStore = makeStore(in: environment)
    draftStore.documentDidChange(appState: draftState)
    XCTAssertTrue(draftStore.savePendingChangesOnClose(appState: draftState))

    try FileManager.default.removeItem(at: environment.documentURL)

    let relaunch = environment.relaunched()
    let restoredState = AppState()
    makeController(in: relaunch, appState: restoredState).start(restoringWorkspace: true)

    XCTAssertTrue(restoredState.documentSession.isUntitled)
    XCTAssertEqual(restoredState.documentSession.text, "unsaved crash draft")
  }

  /// End to end over the REAL restore path: persisted workspace roots plus the
  /// persisted active document. The background workspace rebuild runs its own
  /// `selectRestoredDocument` pass, which must leave the document the window
  /// already restored alone instead of jumping to the first file in the tree.
  func testWorkspaceRestoreKeepsTheDocumentTheWindowAlreadyRestored() async throws {
    let environment = try makeRestoreEnvironment()
    // Sorts before the restored document, so a stomp is unmistakable.
    let decoyURL = environment.folder.appendingPathComponent("AAA-first-in-tree.md")
    try "not what the user was reading".write(to: decoyURL, atomically: true, encoding: .utf8)

    let previousState = AppState()
    let previousStore = makeStore(in: environment)
    try environment.bookmarkStore.replaceWorkspace(
      rootURLs: [environment.folder], fileURLs: [], into: previousState)
    previousStore.load(
      ref: DocumentRef(id: environment.documentURL, isAdHoc: false), into: previousState)

    let relaunch = environment.relaunched()
    let restoredState = AppState()
    let restoredController = makeController(in: relaunch, appState: restoredState)
    restoredController.start(restoringWorkspace: true)
    await relaunch.folderManagerProbe.waitForPendingWorkspaceBuild()

    XCTAssertEqual(
      restoredState.documentSession.url?.standardizedFileURL,
      environment.documentURL.standardizedFileURL,
      "the workspace rebuild replaced the restored document with the first file in the tree")
    XCTAssertTrue(
      restoredState.allDocuments.contains { $0.url.lastPathComponent == "AAA-first-in-tree.md" },
      "the workspace did not actually restore, so the assertion above proves nothing")
  }

  // MARK: - Harness

  /// One simulated installation: a defaults domain, a recovery directory and a
  /// document on disk. `relaunched()` rebuilds the stores over the same
  /// persisted state, which is what a new process sees.
  private struct RestoreEnvironment {
    let folder: URL
    let documentURL: URL
    let defaults: UserDefaults
    let recoveryDirectory: URL
    let bookmarkStore: BookmarkStore
    let recoveryStore: RecoveryStore
    let documentStoreProbe: DocumentStore
    /// Shared like `FolderManager.shared` in production: every window's
    /// controller drives the SAME workspace restore.
    let folderManagerProbe: FolderManager
    /// Shared like `DocumentWindowRegistry.shared`: one per simulated process,
    /// so `beginTermination()` reaches every window's controller.
    let windowRegistryProbe: DocumentWindowRegistry
    let makeRelaunch: @MainActor () -> RestoreEnvironment

    @MainActor
    func relaunched() -> RestoreEnvironment {
      makeRelaunch()
    }
  }

  private func makeRestoreEnvironment() throws -> RestoreEnvironment {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveWindowRestoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

    let documentURL = folder.appendingPathComponent("DPA_Zalacznik.md")
    try "the document the user was reading"
      .write(to: documentURL, atomically: true, encoding: .utf8)

    let defaults = makeEphemeralDefaults(prefix: "PensieveWindowRestoreTests")
    let recoveryDirectory = folder.appendingPathComponent("Recovery", isDirectory: true)

    func build() -> RestoreEnvironment {
      let bookmarkStore = BookmarkStore(defaults: defaults)
      let recoveryStore = RecoveryStore(directoryURL: recoveryDirectory)
      return RestoreEnvironment(
        folder: folder,
        documentURL: documentURL,
        defaults: defaults,
        recoveryDirectory: recoveryDirectory,
        bookmarkStore: bookmarkStore,
        recoveryStore: recoveryStore,
        documentStoreProbe: DocumentStore(
          indexDatabase: IndexDatabase(
            databaseURL: folder.appendingPathComponent("index-\(UUID().uuidString).db")),
          bookmarkStore: bookmarkStore,
          recoveryStore: recoveryStore),
        folderManagerProbe: FolderManager(
          metadataStore: WorkspaceMetadataStore(
            metadataURL: folder.appendingPathComponent("workspace-\(UUID().uuidString).json")),
          indexDatabase: IndexDatabase(
            databaseURL: folder.appendingPathComponent("index-\(UUID().uuidString).db")),
          bookmarkStore: bookmarkStore),
        windowRegistryProbe: DocumentWindowRegistry(
          canMutateWindowTabs: { false },
          scheduleDeferredMainWork: { _ in },
          scheduleLauncherWindowSweep: { _ in },
          mergeWindowIntoTabs: { _, _ in },
          orderAndActivateWindow: { _ in },
          currentMergeTarget: { nil },
          applicationWindows: { [] },
          closeWindow: { _ in }
        ),
        makeRelaunch: { build() }
      )
    }
    return build()
  }

  /// A per-window store: production gives every window its own `DocumentStore`
  /// over the SHARED bookmark and recovery stores.
  private func makeStore(in environment: RestoreEnvironment) -> DocumentStore {
    DocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 100),
      indexDatabase: IndexDatabase(
        databaseURL: environment.folder.appendingPathComponent("index-\(UUID().uuidString).db")),
      bookmarkStore: environment.bookmarkStore,
      recoveryStore: environment.recoveryStore,
      writeDocument: { text, url in try text.write(to: url, atomically: true, encoding: .utf8) },
      indexDocument: { _, _, _ in }
    )
  }

  @discardableResult
  private func makeController(
    in environment: RestoreEnvironment,
    appState: AppState,
    documentStore: DocumentStore? = nil
  ) -> AppController {
    let indexDatabase = IndexDatabase(
      databaseURL: environment.folder.appendingPathComponent("index-\(UUID().uuidString).db"))
    return AppController(
      appState: appState,
      folderManager: environment.folderManagerProbe,
      documentStore: documentStore ?? makeStore(in: environment),
      indexDatabase: indexDatabase,
      documentWindowRegistry: environment.windowRegistryProbe
    )
  }
}
