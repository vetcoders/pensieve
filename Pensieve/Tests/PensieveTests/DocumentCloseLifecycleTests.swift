import XCTest

@testable import Pensieve

/// Records the save question a close asks and answers it on a script, so the
/// whole conscious-close lifecycle is exercised without ever showing a sheet.
@MainActor
final class SaveChangesRecorder {
  private(set) var prompts: [DocumentClosePrompt] = []
  private(set) var titles: [String] = []
  /// Answer handed back for every prompt while `holdsResponse` is false.
  var answer: SaveChangesResponse = .cancel
  /// Keeps the question open (as a real sheet would) until `answerPending`.
  var holdsResponse = false
  private var pendingRespond: (@MainActor (SaveChangesResponse) -> Void)?

  var promptCount: Int { prompts.count }

  func confirmation() -> AppController.SaveChangesConfirmation {
    { [weak self] prompt, session, _, respond in
      guard let self else { return }
      self.prompts.append(prompt)
      self.titles.append(session.displayTitle)
      if self.holdsResponse {
        self.pendingRespond = respond
      } else {
        respond(self.answer)
      }
    }
  }

  func answerPending(_ response: SaveChangesResponse) {
    let respond = pendingRespond
    pendingRespond = nil
    respond?(response)
  }
}

final class DocumentCloseLifecycleTests: XCTestCase {

  // MARK: - Decision layer (pure, no UI)

  @MainActor
  func testEmptySessionClosesWithoutPrompting() {
    XCTAssertEqual(DocumentCloseDecision.resolve(for: .empty), .closeWithoutPrompting)
  }

  @MainActor
  func testUntouchedUntitledClosesWithoutPrompting() {
    XCTAssertEqual(DocumentCloseDecision.resolve(for: .untitled()), .closeWithoutPrompting)
  }

  @MainActor
  func testCleanFileBackedDocumentClosesWithoutPrompting() {
    let session = DocumentSession(
      document: DocumentRef(id: URL(fileURLWithPath: "/tmp/note.md")),
      text: "body",
      isDirty: false)
    XCTAssertEqual(DocumentCloseDecision.resolve(for: session), .closeWithoutPrompting)
  }

  @MainActor
  func testDirtyUntitledAsksToSaveAs() {
    var session = DocumentSession.untitled()
    session.text = "draft body"
    session.isDirty = true
    XCTAssertEqual(DocumentCloseDecision.resolve(for: session), .confirm(.saveAsUntitled))
  }

  @MainActor
  func testDirtyFileBackedDocumentAsksToSave() {
    let session = DocumentSession(
      document: DocumentRef(id: URL(fileURLWithPath: "/tmp/note.md")),
      text: "edited",
      isDirty: true)
    XCTAssertEqual(DocumentCloseDecision.resolve(for: session), .confirm(.savePathed))
  }

  /// W2-E seam: once auto-save owns documents that already have a location,
  /// their close flushes instead of asking — "Don't Save" would be a lie.
  @MainActor
  func testAutoSaveSeamSkipsThePromptForFileBackedDocumentsOnly() {
    let pathed = DocumentSession(
      document: DocumentRef(id: URL(fileURLWithPath: "/tmp/note.md")),
      text: "edited",
      isDirty: true)
    XCTAssertEqual(
      DocumentCloseDecision.resolve(for: pathed, autoSavesPathedDocuments: true),
      .saveWithoutPrompting)

    var untitled = DocumentSession.untitled()
    untitled.text = "draft body"
    untitled.isDirty = true
    XCTAssertEqual(
      DocumentCloseDecision.resolve(for: untitled, autoSavesPathedDocuments: true),
      .confirm(.saveAsUntitled))
  }

  // MARK: - ⌘W on an untitled draft

  @MainActor
  func testClosingDirtyUntitledSavesAsToChosenLocation() throws {
    let folder = try makeTemporaryFolder()
    let targetURL = folder.appendingPathComponent("saved-draft.md")
    let recoveryStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))
    let recorder = SaveChangesRecorder()
    recorder.answer = .save

    let appState = AppState()
    let controller = makeController(
      appState: appState,
      in: folder,
      recoveryStore: recoveryStore,
      savePanelURL: targetURL,
      recorder: recorder)

    XCTAssertTrue(controller.createUntitledDocument())
    appState.activeDocumentText = "draft body"
    appState.activeDocumentDirty = true
    let draft = try recoveryStore.saveDraft(id: nil, title: "Untitled.md", text: "draft body")
    appState.documentSession.recoveryID = draft.id

    var didClose: Bool?
    controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, true)
    XCTAssertEqual(recorder.prompts, [.saveAsUntitled])
    XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "draft body")
    XCTAssertNil(appState.documentSession.document)
    XCTAssertNil(appState.selectedDocumentID)
    XCTAssertFalse(appState.documentSession.hasEditableBuffer)
    // A saved draft is no longer a crash candidate.
    XCTAssertTrue(recoveryStore.loadDrafts().isEmpty)
  }

  @MainActor
  func testClosingDirtyUntitledWithDontSaveDiscardsTheRecoveryDraft() throws {
    let folder = try makeTemporaryFolder()
    let recoveryStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))
    let recorder = SaveChangesRecorder()
    recorder.answer = .discard

    let appState = AppState()
    let controller = makeController(
      appState: appState,
      in: folder,
      recoveryStore: recoveryStore,
      savePanelURL: folder.appendingPathComponent("never-used.md"),
      recorder: recorder)

    XCTAssertTrue(controller.createUntitledDocument())
    appState.activeDocumentText = "throwaway"
    appState.activeDocumentDirty = true
    let draft = try recoveryStore.saveDraft(id: nil, title: "Untitled.md", text: "throwaway")
    appState.documentSession.recoveryID = draft.id
    XCTAssertEqual(recoveryStore.loadDrafts().count, 1)

    var didClose: Bool?
    controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, true)
    XCTAssertEqual(recorder.prompts, [.saveAsUntitled])
    XCTAssertFalse(appState.documentSession.hasEditableBuffer)
    XCTAssertNil(appState.selectedDocumentID)
    // Don't Save is a conscious throw-away: recovery must not resurrect it.
    XCTAssertTrue(recoveryStore.loadDrafts().isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("never-used.md").path))
  }

  @MainActor
  func testCancellingCloseKeepsDirtyUntitledDocumentAndItsDraft() throws {
    let folder = try makeTemporaryFolder()
    let recoveryStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))
    let recorder = SaveChangesRecorder()
    recorder.answer = .cancel

    let appState = AppState()
    let controller = makeController(
      appState: appState,
      in: folder,
      recoveryStore: recoveryStore,
      savePanelURL: folder.appendingPathComponent("never-used.md"),
      recorder: recorder)

    XCTAssertTrue(controller.createUntitledDocument())
    appState.activeDocumentText = "keep me"
    appState.activeDocumentDirty = true
    let draft = try recoveryStore.saveDraft(id: nil, title: "Untitled.md", text: "keep me")
    appState.documentSession.recoveryID = draft.id

    var didClose: Bool?
    controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, false)
    XCTAssertTrue(appState.documentSession.isUntitled)
    XCTAssertTrue(appState.documentSession.isDirty)
    XCTAssertEqual(appState.documentSession.text, "keep me")
    XCTAssertEqual(recoveryStore.loadDrafts().count, 1)
  }

  /// Backing out of the save panel is not a decision to lose the draft.
  @MainActor
  func testCancellingTheSavePanelLeavesTheDraftOpen() throws {
    let folder = try makeTemporaryFolder()
    let recoveryStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))
    let recorder = SaveChangesRecorder()
    recorder.answer = .save

    let appState = AppState()
    let controller = makeController(
      appState: appState,
      in: folder,
      recoveryStore: recoveryStore,
      savePanelURL: nil,
      recorder: recorder)

    XCTAssertTrue(controller.createUntitledDocument())
    appState.activeDocumentText = "still mine"
    appState.activeDocumentDirty = true

    var didClose: Bool?
    controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, false)
    XCTAssertTrue(appState.documentSession.isUntitled)
    XCTAssertTrue(appState.documentSession.isDirty)
    XCTAssertEqual(appState.documentSession.text, "still mine")
  }

  @MainActor
  func testUntouchedUntitledClosesWithoutAskingAnything() throws {
    let folder = try makeTemporaryFolder()
    let recorder = SaveChangesRecorder()
    let appState = AppState()
    let controller = makeController(
      appState: appState,
      in: folder,
      recoveryStore: RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery")),
      savePanelURL: nil,
      recorder: recorder)

    XCTAssertTrue(controller.createUntitledDocument())

    var didClose: Bool?
    controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, true)
    XCTAssertEqual(recorder.promptCount, 0)
    XCTAssertFalse(appState.documentSession.hasEditableBuffer)
  }

  // MARK: - ⌘W on a document that already has a file

  @MainActor
  func testClosingDirtyFileBackedDocumentSavesInPlace() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("note.md")
    try "original".write(to: noteURL, atomically: true, encoding: .utf8)

    let recorder = SaveChangesRecorder()
    recorder.answer = .save
    let appState = AppState()
    let controller = makeController(appState: appState, in: folder, recorder: recorder)
    controller.openFolder(url: folder)
    controller.selectDocument(id: noteURL.standardizedFileURL)
    appState.activeDocumentText = "edited before close"
    appState.activeDocumentDirty = true

    var didClose: Bool?
    controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, true)
    XCTAssertEqual(recorder.prompts, [.savePathed])
    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "edited before close")
    XCTAssertNil(appState.documentSession.document)
    XCTAssertNil(appState.selectedDocumentID)
  }

  @MainActor
  func testClosingDirtyFileBackedDocumentWithDontSaveLeavesDiskUntouched() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("note.md")
    try "original".write(to: noteURL, atomically: true, encoding: .utf8)

    let recorder = SaveChangesRecorder()
    recorder.answer = .discard
    let appState = AppState()
    let controller = makeController(appState: appState, in: folder, recorder: recorder)
    controller.openFolder(url: folder)
    controller.selectDocument(id: noteURL.standardizedFileURL)
    appState.activeDocumentText = "edited before close"
    appState.activeDocumentDirty = true

    var didClose: Bool?
    controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, true)
    XCTAssertEqual(recorder.prompts, [.savePathed])
    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "original")
    XCTAssertNil(appState.documentSession.document)
    XCTAssertNil(appState.selectedDocumentID)
  }

  @MainActor
  func testCancellingCloseKeepsDirtyFileBackedDocumentSelected() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("note.md")
    try "original".write(to: noteURL, atomically: true, encoding: .utf8)

    let recorder = SaveChangesRecorder()
    recorder.answer = .cancel
    let appState = AppState()
    let controller = makeController(appState: appState, in: folder, recorder: recorder)
    controller.openFolder(url: folder)
    controller.selectDocument(id: noteURL.standardizedFileURL)
    appState.activeDocumentText = "edited before close"
    appState.activeDocumentDirty = true

    var didClose: Bool?
    controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, false)
    XCTAssertEqual(recorder.prompts, [.savePathed])
    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "original")
    XCTAssertEqual(appState.documentSession.text, "edited before close")
    XCTAssertTrue(appState.documentSession.isDirty)
    XCTAssertEqual(
      appState.selectedDocumentID?.standardizedFileURL, noteURL.standardizedFileURL)
  }

  @MainActor
  func testClosingCleanFileBackedDocumentAsksNothing() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("note.md")
    try "original".write(to: noteURL, atomically: true, encoding: .utf8)

    let recorder = SaveChangesRecorder()
    let appState = AppState()
    let controller = makeController(appState: appState, in: folder, recorder: recorder)
    controller.openFolder(url: folder)
    controller.selectDocument(id: noteURL.standardizedFileURL)

    var didClose: Bool?
    controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, true)
    XCTAssertEqual(recorder.promptCount, 0)
    XCTAssertNil(appState.documentSession.document)
    XCTAssertNil(appState.selectedDocumentID)
  }

  /// The question is per document: a second ⌘W arriving while the sheet is
  /// still up must not stack another one on the same buffer.
  @MainActor
  func testSecondCloseWhileTheQuestionIsOpenDoesNotAskTwice() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("note.md")
    try "original".write(to: noteURL, atomically: true, encoding: .utf8)

    let recorder = SaveChangesRecorder()
    recorder.holdsResponse = true
    let appState = AppState()
    let controller = makeController(appState: appState, in: folder, recorder: recorder)
    controller.openFolder(url: folder)
    controller.selectDocument(id: noteURL.standardizedFileURL)
    appState.activeDocumentText = "edited before close"
    appState.activeDocumentDirty = true

    var outcomes: [Bool] = []
    controller.closeActiveDocument { outcomes.append($0) }
    controller.closeActiveDocument { outcomes.append($0) }

    XCTAssertEqual(recorder.promptCount, 1)
    XCTAssertEqual(outcomes, [false])

    recorder.answerPending(.discard)

    XCTAssertEqual(outcomes, [false, true])
    XCTAssertNil(appState.documentSession.document)

    // The window is answerable again once the question is resolved.
    XCTAssertTrue(controller.createUntitledDocument())
    appState.activeDocumentText = "next draft"
    appState.activeDocumentDirty = true
    controller.closeActiveDocument { _ in }
    XCTAssertEqual(recorder.promptCount, 2)
    recorder.answerPending(.cancel)
  }

  // MARK: - Store layer, auto-save seam

  @MainActor
  func testSaveWithoutPromptingFlushesAndCloses() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("note.md")
    try "original".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    appState.documents = [DocumentRef(id: noteURL.standardizedFileURL)]
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: temporaryBookmarkStore())
    documentStore.load(ref: DocumentRef(id: noteURL.standardizedFileURL), into: appState)
    appState.activeDocumentText = "auto-saved tail"
    appState.activeDocumentDirty = true

    XCTAssertTrue(
      documentStore.finishClose(
        decision: .saveWithoutPrompting, response: nil, appState: appState))

    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "auto-saved tail")
    XCTAssertNil(appState.documentSession.document)
    XCTAssertNil(appState.selectedDocumentID)
  }

  // MARK: - Open Files working set

  /// Open Files means "open right now", not "opened at some point": ⌘W takes
  /// the document off the list. The file itself is untouched — it stays in the
  /// workspace tree and can be opened again.
  @MainActor
  func testClosingDocumentRemovesItFromOpenFiles() throws {
    let harness = try makeOpenFilesHarness()
    let ref = try harness.openAdHocFile(named: "ad-hoc.md", contents: "body")
    XCTAssertEqual(harness.appState.openFiles, [ref])

    var didClose: Bool?
    harness.controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, true)
    XCTAssertEqual(harness.recorder.promptCount, 0)
    XCTAssertTrue(harness.appState.openFiles.isEmpty)
    // Closing is not deleting: the file is still there to be reopened.
    XCTAssertTrue(FileManager.default.fileExists(atPath: ref.url.path))
  }

  /// Reopening puts it back exactly once — the dedup guard in
  /// `registerOpenFile` still owns the list's shape.
  @MainActor
  func testReopeningAfterCloseAddsExactlyOneEntry() throws {
    let harness = try makeOpenFilesHarness()
    let ref = try harness.openAdHocFile(named: "ad-hoc.md", contents: "body")
    harness.controller.closeActiveDocument { _ in }
    XCTAssertTrue(harness.appState.openFiles.isEmpty)

    let reopened = try XCTUnwrap(harness.reopen(ref))
    XCTAssertEqual(harness.appState.openFiles, [reopened])

    // Opening something already open must not stack a second row either.
    XCTAssertEqual(harness.reopen(ref), reopened)
    XCTAssertEqual(harness.appState.openFiles, [reopened])
  }

  /// Cancel means the close did not happen, so nothing leaves the list.
  @MainActor
  func testCancellingCloseKeepsTheDocumentInOpenFiles() throws {
    let harness = try makeOpenFilesHarness()
    harness.recorder.answer = .cancel
    let ref = try harness.openAdHocFile(named: "ad-hoc.md", contents: "body")
    harness.appState.activeDocumentText = "edited"
    harness.appState.activeDocumentDirty = true

    var didClose: Bool?
    harness.controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, false)
    XCTAssertEqual(harness.recorder.prompts, [.savePathed])
    XCTAssertEqual(harness.appState.openFiles, [ref])
    XCTAssertEqual(harness.appState.documentSession.url, ref.url)
  }

  /// Closing the tab/window (the "×", the red button) is a close like any
  /// other — the same list has to reflect it.
  @MainActor
  func testClosingTheTabRemovesTheDocumentFromOpenFiles() throws {
    let harness = try makeOpenFilesHarness()
    _ = try harness.openAdHocFile(named: "ad-hoc.md", contents: "body")

    harness.controller.documentWindowWillClose()

    XCTAssertTrue(harness.appState.openFiles.isEmpty)
  }

  /// Quit tears every window down at once. That is process shutdown, not the
  /// user closing documents, so the working set must survive it — otherwise
  /// quitting would silently empty the list the next launch restores.
  @MainActor
  func testWindowTeardownDuringTerminationKeepsTheWorkingSet() throws {
    let harness = try makeOpenFilesHarness()
    let ref = try harness.openAdHocFile(named: "ad-hoc.md", contents: "body")

    harness.registry.beginTermination()
    harness.controller.documentWindowWillClose()

    XCTAssertEqual(harness.appState.openFiles, [ref])
  }

  /// A draft only earns a location when it is saved, so the entry that leaves
  /// the working set is the one "Save As…" just created — not a stale nil.
  @MainActor
  func testClosingDraftViaSaveAsDoesNotLeaveItInOpenFiles() throws {
    let folder = try makeTemporaryFolder()
    let targetURL = folder.appendingPathComponent("saved-draft.md")
    let recorder = SaveChangesRecorder()
    recorder.answer = .save

    let appState = AppState()
    let controller = makeController(
      appState: appState,
      in: folder,
      savePanelURL: targetURL,
      recorder: recorder)

    XCTAssertTrue(controller.createUntitledDocument())
    appState.activeDocumentText = "draft body"
    appState.activeDocumentDirty = true

    var didClose: Bool?
    controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, true)
    XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "draft body")
    XCTAssertTrue(appState.openFiles.isEmpty)
  }

  // MARK: - Helpers

  private func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveCloseLifecycleTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: folder)
    }
    return folder
  }

  @MainActor
  private func makeController(
    appState: AppState,
    in folder: URL,
    documentStore: DocumentStore? = nil,
    recoveryStore: RecoveryStore? = nil,
    savePanelURL: URL? = nil,
    recorder: SaveChangesRecorder
  ) -> AppController {
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let resolvedStore =
      documentStore
      ?? makeTestDocumentStore(
        indexDatabase: indexDatabase,
        bookmarkStore: temporaryBookmarkStore(),
        recoveryStore: recoveryStore,
        savePanelURLProvider: { _ in savePanelURL })
    return AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: resolvedStore,
      indexDatabase: indexDatabase,
      confirmSaveChanges: recorder.confirmation()
    )
  }

  private func temporaryMetadataStore() -> WorkspaceMetadataStore {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveCloseMetadataTests-\(UUID().uuidString)", isDirectory: true)
    return WorkspaceMetadataStore(
      metadataURL: folder.appendingPathComponent("workspace.json", isDirectory: false))
  }

  @MainActor
  private func temporaryIndexDatabase(in folder: URL) -> IndexDatabase {
    IndexDatabase(databaseURL: folder.appendingPathComponent("index.db", isDirectory: false))
  }

  @MainActor
  private func temporaryBookmarkStore() -> BookmarkStore {
    BookmarkStore(defaults: makeEphemeralDefaults(prefix: "PensieveCloseBookmarkTests"))
  }

  /// A window with its own store, folder manager and window registry, all
  /// pointed at throwaway state — so the Open Files working set can be driven
  /// through the real open/close routes without touching the shared singletons.
  @MainActor
  private func makeOpenFilesHarness() throws -> OpenFilesHarness {
    let folder = try makeTemporaryFolder()
    let support = folder.appendingPathComponent("Support", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

    let indexDatabase = temporaryIndexDatabase(in: folder)
    let folderManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true))))
    let documentStore = makeTestDocumentStore(
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore())
    let registry = DocumentWindowRegistry(canMutateWindowTabs: { true })
    let recorder = SaveChangesRecorder()
    let appState = AppState()
    let controller = AppController(
      appState: appState,
      folderManager: folderManager,
      documentStore: documentStore,
      indexDatabase: indexDatabase,
      documentWindowRegistry: registry,
      confirmSaveChanges: recorder.confirmation())

    return OpenFilesHarness(
      folder: folder,
      appState: appState,
      folderManager: folderManager,
      documentStore: documentStore,
      controller: controller,
      registry: registry,
      recorder: recorder)
  }
}

/// The two halves of "open a file that lives outside any workspace root":
/// register it in the working set, then load it into the session — exactly
/// what `FolderManager.openFile` does, minus the shared-singleton load.
@MainActor
private struct OpenFilesHarness {
  let folder: URL
  let appState: AppState
  let folderManager: FolderManager
  let documentStore: DocumentStore
  let controller: AppController
  let registry: DocumentWindowRegistry
  let recorder: SaveChangesRecorder

  @discardableResult
  func openAdHocFile(named name: String, contents: String) throws -> DocumentRef {
    let url = folder.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    let ref = try XCTUnwrap(folderManager.registerOpenFile(url: url, into: appState))
    documentStore.load(ref: ref, into: appState)
    return ref
  }

  @discardableResult
  func reopen(_ ref: DocumentRef) -> DocumentRef? {
    guard let reopened = folderManager.registerOpenFile(url: ref.url, into: appState) else {
      return nil
    }
    documentStore.load(ref: reopened, into: appState)
    return reopened
  }
}
