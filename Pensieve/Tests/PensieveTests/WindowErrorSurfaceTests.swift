import AppKit
import XCTest

@testable import Pensieve

/// GAP 2: `lastError` was written from ~35 sites across the app and rendered by
/// nothing. Every failure the app knew about — including a crash-recovery draft
/// that could not be written, which is the only copy of an unsaved document —
/// was recorded into a field no view read.
///
/// These pins drive REAL production paths (a save whose write throws, an
/// unwritable recovery directory, a document creation with no workspace open)
/// and assert what the window chrome resolves to afterwards. Nothing here
/// hand-feeds a `WindowError`: the severity under test is the one the write site
/// actually chose.
final class WindowErrorSurfaceTests: XCTestCase {

  // MARK: - A recorded error reaches the chrome, in the RIGHT window

  /// The headline pin. A failing save is a real production path; afterwards the
  /// window that took the failure must resolve to a visible banner — and the
  /// window beside it, working on something else, must not.
  @MainActor
  func testAFailedSaveShowsABannerInThatWindowAndNoOtherWindow() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("umowa.md")
    try "on disk".write(to: noteURL, atomically: true, encoding: .utf8)

    let failing = AppState()
    let bystander = AppState()
    let store = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      writeDocument: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    failing.documentSession.load(
      document: DocumentRef(id: noteURL.standardizedFileURL), text: "on disk")
    failing.activeDocumentText = "an edit that cannot reach disk"
    failing.documentSession.isDirty = true

    store.save(appState: failing)

    guard case .banner(let error) = WindowErrorSurface.resolve(for: failing.currentError) else {
      return XCTFail("a failed save left the window with nothing to show")
    }
    XCTAssertTrue(error.message.contains("umowa.md"), "the banner does not name the document")
    XCTAssertEqual(
      WindowErrorSurface.resolve(for: bystander.currentError), .none,
      "one window's failure showed up in another window's chrome")
    XCTAssertNil(
      bystander.unresolvedDataLoss,
      "one window's failure latched a data loss onto another window")
  }

  /// The banner's dismiss button, which is the only way a passive line goes away
  /// on its own. `dismissVisibleError()` is exactly what the button calls.
  @MainActor
  func testDismissingTheBannerClearsIt() throws {
    let folder = try makeTemporaryFolder()
    let appState = AppState()
    let controller = makeController(in: folder, appState: appState)

    // A real refusal: creating a document with no workspace open.
    XCTAssertNil(controller.createDocument(in: nil))
    XCTAssertTrue(
      WindowErrorSurface.resolve(for: appState.currentError).showsBanner,
      "a refused action recorded nothing for the chrome to show")

    appState.dismissVisibleError()

    XCTAssertEqual(WindowErrorSurface.resolve(for: appState.currentError), .none)
  }

  // MARK: - Data loss latches; status does not

  /// An ordinary refusal is a passive line and nothing more. It latches nothing:
  /// the moment it is put away the window is quiet again.
  @MainActor
  func testAnOrdinaryFailureShowsABannerAndLatchesNothing() throws {
    let folder = try makeTemporaryFolder()
    let appState = AppState()
    let controller = makeController(in: folder, appState: appState)

    XCTAssertNil(controller.createDocument(in: nil))

    XCTAssertEqual(appState.currentError?.severity, .status)
    XCTAssertTrue(WindowErrorSurface.resolve(for: appState.currentError).showsBanner)
    XCTAssertNil(
      appState.unresolvedDataLoss,
      "a refused action latched a data loss it did not earn")
  }

  /// …and a recovery-draft write that fails IS data loss: the untitled buffer is
  /// the only copy of that text, so the window latches it.
  @MainActor
  func testAFailedRecoveryDraftWriteLatchesTheDataLoss() throws {
    let folder = try makeTemporaryFolder()
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: try makeUnwritableRecoveryStore(in: folder))
    let appState = AppState()
    appState.documentSession.restoreUntitled(
      title: "Board Resolution.md", text: "# Prokurent", recoveryID: UUID())

    store.savePendingChangesOnClose(appState: appState)

    XCTAssertEqual(
      appState.currentError?.severity, .dataLoss,
      "the only copy of an unsaved document failed to persist and was filed as routine")
    XCTAssertTrue(WindowErrorSurface.resolve(for: appState.currentError).showsBanner)
    let latched = try XCTUnwrap(
      appState.unresolvedDataLoss, "losing the only copy of the text latched nothing")
    XCTAssertTrue(latched.message.contains("recovery draft"))
  }

  // MARK: - The three latch rules

  /// RULE 1 — a routine message may not displace an unresolved data loss.
  ///
  /// These arrive in this order all the time: the recovery write fails, and the
  /// next thing the user does produces an ordinary refusal. If the second one
  /// took the line, the window would stop saying the thing that actually costs
  /// work while it is still true.
  @MainActor
  func testAnOrdinaryStatusDoesNotDisplaceAnUnresolvedDataLoss() throws {
    let folder = try makeTemporaryFolder()
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: try makeUnwritableRecoveryStore(in: folder))
    let appState = AppState()
    appState.documentSession.restoreUntitled(
      title: "Board Resolution.md", text: "# Prokurent", recoveryID: UUID())

    store.savePendingChangesOnClose(appState: appState)
    XCTAssertEqual(appState.currentError?.severity, .dataLoss, "fixture precondition")

    // Something entirely routine happens next.
    appState.lastError = "Could not open Kancelaria: no such directory"

    XCTAssertEqual(
      appState.currentError?.severity, .dataLoss,
      "a routine message took the line away from an unresolved data loss")
    XCTAssertNotNil(appState.unresolvedDataLoss, "the latch was cleared by a status write")
    XCTAssertTrue(
      try XCTUnwrap(appState.currentError).message.contains("recovery draft"),
      "the window is showing the routine message instead of the loss")
  }

  /// …and neither may a routine CLEAR. Roughly a dozen sites assign
  /// `lastError = nil` on their own unrelated success, and none of them know
  /// anything about a buffer whose content reached no disk.
  @MainActor
  func testAnUnrelatedSuccessClearingLastErrorDoesNotResolveTheLoss() {
    let appState = AppState()
    appState.reportDataLoss("Could not save umowa.md: no space left on device")

    appState.lastError = nil

    XCTAssertNotNil(
      appState.unresolvedDataLoss,
      "an unrelated operation reporting success retired somebody else's data loss")
    XCTAssertTrue(WindowErrorSurface.resolve(for: appState.currentError).showsBanner)
  }

  /// RULE 2 — dismissing the banner must not re-arm on an identical retry.
  ///
  /// A full volume does not fail once: the armed autosave retries every 1.5 s
  /// and fails with the same message every time. If putting the banner away
  /// reset the condition, each retry would read as news and the banner the user
  /// just closed would come straight back, indefinitely.
  @MainActor
  func testDismissingADataLossBannerSurvivesAnIdenticalRetry() throws {
    let folder = try makeTemporaryFolder()
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: try makeUnwritableRecoveryStore(in: folder))
    let appState = AppState()
    appState.documentSession.restoreUntitled(
      title: "Board Resolution.md", text: "# Prokurent", recoveryID: UUID())

    store.savePendingChangesOnClose(appState: appState)
    appState.dismissVisibleError()
    XCTAssertEqual(
      WindowErrorSurface.resolve(for: appState.currentError), .none, "fixture precondition")

    // The same write fails the same way on the next tick.
    store.savePendingChangesOnClose(appState: appState)

    XCTAssertEqual(
      WindowErrorSurface.resolve(for: appState.currentError), .none,
      "an identical retry resurrected the banner the user had put away")
    XCTAssertNotNil(
      appState.unresolvedDataLoss,
      "dismissing the banner made the app forget the work is still unsafe")
  }

  /// RULE 3 — once the loss is RESOLVED, the same problem happening again is
  /// news, and the window says so. This is the boundary of rule 2: the dedupe
  /// must be scoped to one unresolved condition, not to a message string
  /// forever.
  @MainActor
  func testAFreshOccurrenceAfterResolutionArmsTheSurfaceAgain() {
    let appState = AppState()
    let message = "Could not save umowa.md: no space left on device"

    appState.reportDataLoss(message)
    appState.dismissVisibleError()
    // The user freed some space and saved: a durable write landed.
    appState.resolveError()
    XCTAssertNil(appState.unresolvedDataLoss, "fixture precondition: the loss is resolved")

    // The disk fills up again.
    appState.reportDataLoss(message)

    XCTAssertTrue(
      WindowErrorSurface.resolve(for: appState.currentError).showsBanner,
      "a fresh occurrence after a resolved one stayed silent")
    XCTAssertEqual(appState.currentError?.severity, .dataLoss)
  }

  /// A genuinely DIFFERENT failure arriving while the first is still unresolved
  /// is also news — the dedupe keys on the condition, not on "some loss is
  /// already latched".
  @MainActor
  func testADifferentDataLossReplacesTheLatchAndShowsAgain() {
    let appState = AppState()

    appState.reportDataLoss("Could not save a.md: disk full")
    appState.dismissVisibleError()
    appState.reportDataLoss("Could not save b.md: permission denied")

    XCTAssertTrue(
      WindowErrorSurface.resolve(for: appState.currentError).showsBanner,
      "a second, different loss was swallowed by the dedupe")
    XCTAssertEqual(appState.unresolvedDataLoss?.message, "Could not save b.md: permission denied")
  }

  // MARK: - The default stays quiet

  /// Every one of the ~35 plain `lastError` writes keeps the passive class it
  /// had. This is what makes the loud class opt-in: a new error has to be argued
  /// INTO `reportDataLoss`, never fall into it.
  @MainActor
  func testAPlainLastErrorAssignmentIsPassive() {
    let appState = AppState()

    appState.lastError = "Could not open folder: no such directory"

    XCTAssertEqual(appState.currentError?.severity, .status)
    XCTAssertNil(appState.unresolvedDataLoss)
    XCTAssertEqual(appState.lastError, "Could not open folder: no such directory")
  }

  /// The chrome is driven by the window's error alone — no open buffer required.
  /// `EditorStatusBar` is gated on `documentHasEditableBuffer`, and the failures
  /// that most need saying (a workspace that will not open, a file that has
  /// moved) land in a window showing nothing, so the banner must not inherit
  /// that gate.
  @MainActor
  func testTheBannerResolvesWithNoDocumentOpen() throws {
    let folder = try makeTemporaryFolder()
    let appState = AppState()
    let controller = makeController(in: folder, appState: appState)

    XCTAssertFalse(appState.documentHasEditableBuffer, "fixture precondition: an empty window")
    XCTAssertNil(controller.createDocument(in: nil))

    XCTAssertTrue(
      WindowErrorSurface.resolve(for: appState.currentError).showsBanner,
      "an empty window had nowhere to show its error")
  }

  // MARK: - Helpers

  @MainActor
  private func makeController(in folder: URL, appState: AppState) -> AppController {
    let indexDatabase = temporaryIndexDatabase(in: folder)
    return AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: WorkspaceMetadataStore(
          metadataURL: folder.appendingPathComponent("workspace.json", isDirectory: false)),
        indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase)
  }

  /// A `RecoveryStore` whose directory can never exist: a regular FILE sits on
  /// its path, so `createDirectory(withIntermediateDirectories:)` throws on every
  /// `saveDraft`. Deterministic without root, permission bits or timing, and
  /// confined to the test's own temporary folder.
  private func makeUnwritableRecoveryStore(in folder: URL) throws -> RecoveryStore {
    let blocked = folder.appendingPathComponent("Recovery", isDirectory: false)
    try Data("not a directory".utf8).write(to: blocked, options: .atomic)
    return RecoveryStore(directoryURL: blocked)
  }

  private func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveWindowErrorSurface-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    return folder
  }

  @MainActor
  private func temporaryIndexDatabase(in folder: URL) -> IndexDatabase {
    IndexDatabase(databaseURL: folder.appendingPathComponent("index.db", isDirectory: false))
  }
}
