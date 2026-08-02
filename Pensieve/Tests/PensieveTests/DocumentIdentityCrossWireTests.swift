import Foundation
import XCTest

@testable import Pensieve

/// Pins for the document-identity cross-wire: the ways an edit, an import, or a
/// close could be attributed to a session other than the one the user is
/// looking at.
@MainActor
final class DocumentIdentityCrossWireTests: XCTestCase {

  // MARK: - Import must respect tab routing

  /// An import REPLACES the window's session wholesale (`restoreUntitled`), so
  /// running it against a window that already shows a document threw that
  /// document away: the file stayed on disk untouched while its tab now held an
  /// untitled draft of the converted source, still wearing the old title. Every
  /// other open path routes to a new tab in this situation; the import path
  /// must too.
  func testImportingIntoAWindowThatAlreadyHasADocumentRoutesToANewTab() throws {
    let root = try makeTemporaryDirectory()
    let source = root.appendingPathComponent("session-export.pdf")
    try Data("%PDF-1.4".utf8).write(to: source)

    let appState = AppState()
    let controller = makeController(appState: appState)

    // The window already shows work.
    appState.documentSession.createUntitled(title: "CLAUDE.md")
    appState.documentSession.text = "the document the user is looking at"
    XCTAssertTrue(appState.documentSession.hasEditableBuffer)

    var routed: [DocumentRef] = []
    controller.requestOpenDocumentWindow = { routed.append($0) }

    controller.openFile(url: source)

    XCTAssertEqual(
      routed.map(\.id.lastPathComponent), ["session-export.pdf"],
      "an importable file must route to its own tab when this window is occupied")
    XCTAssertEqual(
      appState.documentSession.text, "the document the user is looking at",
      "the occupied window's buffer must survive an import of another file")
    XCTAssertEqual(appState.documentSession.displayTitle, "CLAUDE.md")
  }

  /// The empty-window case is unchanged: with nothing to lose, the import runs
  /// in place rather than spawning a second window.
  func testImportingIntoAnEmptyWindowStillRunsInPlace() throws {
    let root = try makeTemporaryDirectory()
    let source = root.appendingPathComponent("export.pdf")
    try Data("%PDF-1.4".utf8).write(to: source)

    let appState = AppState()
    let controller = makeController(appState: appState)
    XCTAssertFalse(appState.documentSession.hasEditableBuffer)

    var routed: [DocumentRef] = []
    controller.requestOpenDocumentWindow = { routed.append($0) }

    controller.openFile(url: source)

    XCTAssertTrue(routed.isEmpty, "an empty window imports in place, it does not open a tab")
  }

  /// An empty launcher handed SEVERAL files at once — a Finder multi-select, a
  /// Dock drop, `open -a` with a list — sees them one URL at a time. The first,
  /// a DOCX, converts off the main actor, so this window's session is still
  /// empty when the second URL arrives and the routing question answered "empty,
  /// import in place" a second time: `importDocument` cancelled the first
  /// conversion and the user's first file vanished without a word. Pending
  /// import work occupies this window exactly as an editable buffer does.
  func testASecondImportDuringAnInFlightOneGetsItsOwnTab() async throws {
    let root = try makeTemporaryDirectory()
    let first = root.appendingPathComponent("umowa.docx")
    try DocumentTransfer.docxData(fromHTML: "<h1>Umowa</h1>", baseURL: nil)
      .write(to: first, options: .atomic)
    let second = root.appendingPathComponent("zalacznik.docx")
    try DocumentTransfer.docxData(fromHTML: "<h1>Zalacznik</h1>", baseURL: nil)
      .write(to: second, options: .atomic)

    let appState = AppState()
    let controller = makeController(appState: appState)
    var routed: [DocumentRef] = []
    controller.requestOpenDocumentWindow = { routed.append($0) }

    controller.openFile(url: first)
    XCTAssertTrue(
      controller.hasPendingImportWork,
      "the conversion already finished, so this pin is not exercising an in-flight import")
    XCTAssertTrue(routed.isEmpty, "the first file belongs in the empty launcher")

    controller.openFile(url: second)

    XCTAssertEqual(
      routed.map(\.id.lastPathComponent), ["zalacznik.docx"],
      "the second source must get its own tab instead of cancelling the conversion running here")

    try await waitForImportToSettle(controller)
    XCTAssertTrue(
      appState.documentSession.text.contains("Umowa"),
      "the first file's conversion was dropped by the second open")
  }

  /// The other half of the same race: a MARKDOWN URL arriving during the
  /// conversion loaded straight into the session the import was about to
  /// overwrite, so the file the user could see for a moment was replaced by the
  /// conversion the instant it landed.
  func testAMarkdownOpenDuringAnInFlightImportGetsItsOwnTab() async throws {
    let root = try makeTemporaryDirectory()
    let source = root.appendingPathComponent("umowa.docx")
    try DocumentTransfer.docxData(fromHTML: "<h1>Umowa</h1>", baseURL: nil)
      .write(to: source, options: .atomic)
    let note = root.appendingPathComponent("note.md")
    try "the file the user opened second".write(to: note, atomically: true, encoding: .utf8)

    let appState = AppState()
    let controller = makeController(appState: appState)
    var routed: [DocumentRef] = []
    controller.requestOpenDocumentWindow = { routed.append($0) }

    controller.openFile(url: source)
    XCTAssertTrue(controller.hasPendingImportWork)

    controller.openFile(url: note)

    XCTAssertEqual(
      routed.map(\.id.lastPathComponent), ["note.md"],
      "a document opened during a conversion must not land in the window the conversion owns")

    try await waitForImportToSettle(controller)
    XCTAssertTrue(appState.documentSession.text.contains("Umowa"), appState.documentSession.text)
  }

  /// CONTROL: occupancy ends when the import does. A window whose conversion has
  /// settled is the ordinary occupied window — and one that never had an import
  /// at all still opens in place.
  func testAWindowIsFreeAgainOnceTheImportSettles() async throws {
    let root = try makeTemporaryDirectory()
    let source = root.appendingPathComponent("umowa.docx")
    try DocumentTransfer.docxData(fromHTML: "<h1>Umowa</h1>", baseURL: nil)
      .write(to: source, options: .atomic)
    let note = root.appendingPathComponent("note.md")
    try "opened after the conversion".write(to: note, atomically: true, encoding: .utf8)

    let appState = AppState()
    let controller = makeController(appState: appState)
    controller.openFile(url: source)
    try await waitForImportToSettle(controller)
    XCTAssertFalse(controller.hasPendingImportWork)
    XCTAssertTrue(appState.documentSession.hasEditableBuffer)

    var routed: [DocumentRef] = []
    controller.requestOpenDocumentWindow = { routed.append($0) }
    controller.openFile(url: note)
    XCTAssertEqual(
      routed.map(\.id.lastPathComponent), ["note.md"],
      "the settled conversion is an ordinary document — the next open is a tab")
  }

  /// Waits for the conversion to settle. The import hops back to the main actor
  /// to publish its result, so this only has to give the main actor room.
  private func waitForImportToSettle(_ controller: AppController) async throws {
    for _ in 0..<400 {
      guard controller.hasPendingImportWork else { return }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTFail("the import never settled")
  }

  /// The reorder must not start accepting types Pensieve cannot open.
  func testAnUnsupportedTypeIsStillRefusedBeforeAnyRouting() throws {
    let root = try makeTemporaryDirectory()
    let source = root.appendingPathComponent("archive.zip")
    try Data("PK".utf8).write(to: source)

    let appState = AppState()
    let controller = makeController(appState: appState)
    appState.documentSession.createUntitled()

    var routed: [DocumentRef] = []
    controller.requestOpenDocumentWindow = { routed.append($0) }

    controller.openFile(url: source)

    XCTAssertTrue(routed.isEmpty)
    XCTAssertEqual(appState.lastError, WorkspaceScanner.unsupportedOpenMessage)
  }

  // MARK: - Cross-window close must find a real owner

  /// The registry's identity→window map is written from the COALESCED, async
  /// window accessor, so a live tab can exist with no registered controller.
  /// Falling back to `self` there ran the dirty guard against a session that
  /// does not hold the document: the guard sees a mismatched identity, reports
  /// "nothing to guard", and the close proceeds unguarded against the window
  /// that DID hold unsaved work. With no resolvable owner the close must
  /// refuse instead.
  func testAnUnownedIdentityRefusesTheCloseInsteadOfGuardingTheWrongSession() {
    let appState = AppState()
    let controller = makeController(appState: appState, registry: DocumentWindowRegistry())

    // This window holds its own unsaved work, and is NOT showing the target.
    appState.documentSession.createUntitled(title: "mine.md")
    appState.documentSession.text = "unsaved work in the calling window"
    appState.documentSession.isDirty = true

    let stranger = DocumentIdentity.file(
      URL(fileURLWithPath: "/tmp/pensieve-tests/never-registered.md"))

    XCTAssertFalse(
      controller.closeOpenDocument(identity: stranger),
      "an identity no window claims must not be closed through the caller's session")
    XCTAssertEqual(
      appState.documentSession.text, "unsaved work in the calling window",
      "the calling window's session must be untouched by a refused close")
    XCTAssertTrue(appState.documentSession.isDirty)
  }

  /// `self` remains a legitimate owner when this window genuinely shows the
  /// document — the refusal must not break the single-window case.
  func testTheCallingWindowStillOwnsTheDocumentItIsShowing() throws {
    let root = try makeTemporaryDirectory()
    let url = root.appendingPathComponent("owned.md").standardizedFileURL
    try "owned".write(to: url, atomically: true, encoding: .utf8)

    let appState = AppState()
    let controller = makeController(appState: appState, registry: DocumentWindowRegistry())
    appState.documentSession.load(document: DocumentRef(id: url), text: "owned")
    XCTAssertEqual(appState.windowModel.documentIdentity, .file(url))

    XCTAssertTrue(
      controller.closeOpenDocument(identity: .file(url)),
      "the window showing the document is its owner even with an empty registry")
  }

  // MARK: - Recovery drafts keep their name

  /// The draft title was passed to `saveDraft` and then thrown away: `loadDraft`
  /// hardcoded "Recovered Untitled.md". Every recovered draft therefore came
  /// back anonymous, which is why recovered work showed up under a generic tab
  /// name instead of the document it came from.
  func testADraftKeepsItsTitleAcrossAReload() throws {
    let root = try makeTemporaryDirectory()
    let store = RecoveryStore(directoryURL: root)

    let saved = try store.saveDraft(id: nil, title: "CLAUDE.md", text: "draft body")
    XCTAssertEqual(saved.title, "CLAUDE.md")

    let reloaded = try XCTUnwrap(RecoveryStore(directoryURL: root).loadDrafts().first)
    XCTAssertEqual(reloaded.id, saved.id)
    XCTAssertEqual(reloaded.text, "draft body")
    XCTAssertEqual(
      reloaded.title, "CLAUDE.md",
      "a reloaded draft must still know what it was called")
  }

  /// The sidecar must not be mistaken for a draft of its own.
  func testTheTitleSidecarIsNotListedAsASecondDraft() throws {
    let root = try makeTemporaryDirectory()
    let store = RecoveryStore(directoryURL: root)
    _ = try store.saveDraft(id: nil, title: "notes.md", text: "body")

    XCTAssertEqual(RecoveryStore(directoryURL: root).loadDrafts().count, 1)
  }

  /// Drafts written before the sidecar existed — including the ones already on
  /// disk when this shipped — still load, under the generic name.
  func testALegacyDraftWithoutASidecarStillLoads() throws {
    let root = try makeTemporaryDirectory()
    let id = UUID()
    try "legacy body".write(
      to: root.appendingPathComponent("\(id.uuidString).md"), atomically: true, encoding: .utf8)

    let loaded = try XCTUnwrap(RecoveryStore(directoryURL: root).loadDrafts().first)
    XCTAssertEqual(loaded.id, id)
    XCTAssertEqual(loaded.text, "legacy body")
    XCTAssertEqual(loaded.title, RecoveryStore.fallbackTitle)
  }

  /// Deleting a draft must not leave its name behind for the next draft that
  /// happens to reuse the id.
  func testDeletingADraftRemovesItsTitleSidecar() throws {
    let root = try makeTemporaryDirectory()
    let store = RecoveryStore(directoryURL: root)
    let saved = try store.saveDraft(id: nil, title: "gone.md", text: "body")

    store.deleteDraft(id: saved.id)

    XCTAssertTrue(RecoveryStore(directoryURL: root).loadDrafts().isEmpty)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: root.path), [],
      "no orphaned sidecar may survive the draft it named")
  }

  // MARK: - Helpers

  private func makeController(
    appState: AppState, registry: DocumentWindowRegistry? = nil
  ) -> AppController {
    AppController(
      appState: appState,
      folderManager: FolderManager.shared,
      documentStore: DocumentStore.shared,
      documentWindowRegistry: registry
    )
  }

  private func makeTemporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("pensieve-crosswire-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
}
