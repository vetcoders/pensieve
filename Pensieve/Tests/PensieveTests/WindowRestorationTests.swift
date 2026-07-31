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
      folderManager: FolderManager(
        metadataStore: WorkspaceMetadataStore(
          metadataURL: environment.folder.appendingPathComponent(
            "workspace-\(UUID().uuidString).json")),
        indexDatabase: indexDatabase,
        bookmarkStore: environment.bookmarkStore
      ),
      documentStore: documentStore ?? makeStore(in: environment),
      indexDatabase: indexDatabase
    )
  }
}
