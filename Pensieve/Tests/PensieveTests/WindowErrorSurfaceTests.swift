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
      bystander.pendingDataLossAlert,
      "one window's failure raised an alert over another window")
  }

  /// The banner's dismiss button, which is the only way a passive line goes away
  /// on its own. `clearError()` is exactly what the button calls.
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

    appState.clearError()

    XCTAssertEqual(WindowErrorSurface.resolve(for: appState.currentError), .none)
  }

  // MARK: - Only data loss gets to interrupt

  /// An ordinary refusal is a passive line and nothing more — no modal.
  @MainActor
  func testAnOrdinaryFailureShowsABannerAndRaisesNoAlert() throws {
    let folder = try makeTemporaryFolder()
    let appState = AppState()
    let controller = makeController(in: folder, appState: appState)

    XCTAssertNil(controller.createDocument(in: nil))

    XCTAssertEqual(appState.currentError?.severity, .status)
    XCTAssertTrue(WindowErrorSurface.resolve(for: appState.currentError).showsBanner)
    XCTAssertNil(
      appState.pendingDataLossAlert,
      "a refused action interrupted the user with a modal it did not earn")
  }

  /// …and a recovery-draft write that fails IS data loss: the untitled buffer is
  /// the only copy of that text, so it earns both the banner and the alert.
  @MainActor
  func testAFailedRecoveryDraftWriteRaisesTheDataLossAlert() throws {
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
    let alert = try XCTUnwrap(
      appState.pendingDataLossAlert, "losing the only copy of the text asked the user nothing")
    XCTAssertTrue(alert.message.contains("recovery draft"))
  }

  /// The storm guard. A full volume does not fail once — an armed autosave
  /// retries and fails again with the SAME message. The banner keeps standing,
  /// but the modal is asked once, not once per attempt.
  @MainActor
  func testARepeatedIdenticalDataLossFailureAsksOnce() throws {
    let folder = try makeTemporaryFolder()
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: try makeUnwritableRecoveryStore(in: folder))
    let appState = AppState()
    appState.documentSession.restoreUntitled(
      title: "Board Resolution.md", text: "# Prokurent", recoveryID: UUID())

    store.savePendingChangesOnClose(appState: appState)
    // The user answered the first alert.
    appState.pendingDataLossAlert = nil
    // …and the next attempt fails exactly the same way.
    store.savePendingChangesOnClose(appState: appState)

    XCTAssertNil(
      appState.pendingDataLossAlert,
      "the same failure asked twice — a failing autosave would bury the app in modals")
    XCTAssertTrue(
      WindowErrorSurface.resolve(for: appState.currentError).showsBanner,
      "the standing reminder that the work is unsafe disappeared with the answered alert")
  }

  /// A NEW data-loss condition after an answered one does ask again — the guard
  /// above must dedupe identical failures, not silence the second problem.
  @MainActor
  func testADifferentDataLossFailureAsksAgain() throws {
    let appState = AppState()

    appState.reportDataLoss("Could not save a.md: disk full")
    appState.pendingDataLossAlert = nil
    appState.reportDataLoss("Could not save b.md: permission denied")

    XCTAssertNotNil(
      appState.pendingDataLossAlert, "a second, different loss was swallowed by the dedupe")
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
    XCTAssertNil(appState.pendingDataLossAlert)
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
