import XCTest

@testable import Pensieve

/// W2-E: the auto-save setting and the contract it owns.
///
/// The matrix under test is (auto-save ON/OFF) × (file-backed/untitled) ×
/// (dirty/clean) → write / prompt / silence, plus the two invariants that must
/// hold in BOTH states: an untitled draft always asks where to save, and crash
/// recovery never depends on the setting.
final class AutoSaveSettingTests: XCTestCase {

  // MARK: - The stored preference

  @MainActor
  func testAutoSaveIsOnForAFirstLaunch() {
    let settings = DocumentSavingSettings(
      defaults: makeEphemeralDefaults(prefix: "PensieveAutoSaveDefaultTests"))

    XCTAssertTrue(
      settings.autoSavesPathedDocuments,
      "an untouched install must auto-save documents that already have a location")
    XCTAssertTrue(DocumentSavingSettings.autoSavesPathedDocumentsDefault)
  }

  /// An absent key means "never chosen", which is the default — not `false`. The
  /// UI binds to the stored value, so reading a missing key as off would ship the
  /// opposite contract without anyone touching the toggle.
  @MainActor
  func testTheChosenStateSurvivesRelaunch() {
    let defaults = makeEphemeralDefaults(prefix: "PensieveAutoSavePersistenceTests")

    DocumentSavingSettings(defaults: defaults).autoSavesPathedDocuments = false
    XCTAssertFalse(DocumentSavingSettings(defaults: defaults).autoSavesPathedDocuments)

    DocumentSavingSettings(defaults: defaults).autoSavesPathedDocuments = true
    XCTAssertTrue(DocumentSavingSettings(defaults: defaults).autoSavesPathedDocuments)
  }

  // MARK: - Close decision matrix

  @MainActor
  func testCloseDecisionsWithAutoSaveOn() throws {
    let folder = try makeTemporaryFolder()
    let store = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      savingSettings: makeAutoSaveSettings(enabled: true))
    let appState = AppState()

    // dirty + file-backed -> flush, no question: "Don't Save" could not undo
    // the writes auto-save already made.
    appState.documentSession.load(
      document: DocumentRef(id: folder.appendingPathComponent("note.md")), text: "body")
    appState.documentSession.isDirty = true
    XCTAssertEqual(store.closeDecision(appState: appState), .saveWithoutPrompting)

    // clean + file-backed -> silence.
    appState.documentSession.isDirty = false
    XCTAssertEqual(store.closeDecision(appState: appState), .closeWithoutPrompting)

    // dirty + untitled -> still asks: there is no location to auto-save into.
    appState.documentSession.createUntitled()
    appState.documentSession.text = "draft"
    appState.documentSession.isDirty = true
    XCTAssertEqual(store.closeDecision(appState: appState), .confirm(.saveAsUntitled))

    // clean + untitled, and an empty window -> silence.
    appState.documentSession.isDirty = false
    XCTAssertEqual(store.closeDecision(appState: appState), .closeWithoutPrompting)
    appState.documentSession.clear()
    XCTAssertEqual(store.closeDecision(appState: appState), .closeWithoutPrompting)
  }

  @MainActor
  func testCloseDecisionsWithAutoSaveOff() throws {
    let folder = try makeTemporaryFolder()
    let store = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      savingSettings: makeAutoSaveSettings(enabled: false))
    let appState = AppState()

    // dirty + file-backed -> the full W2-A question.
    appState.documentSession.load(
      document: DocumentRef(id: folder.appendingPathComponent("note.md")), text: "body")
    appState.documentSession.isDirty = true
    XCTAssertEqual(store.closeDecision(appState: appState), .confirm(.savePathed))

    appState.documentSession.isDirty = false
    XCTAssertEqual(store.closeDecision(appState: appState), .closeWithoutPrompting)

    appState.documentSession.createUntitled()
    appState.documentSession.text = "draft"
    appState.documentSession.isDirty = true
    XCTAssertEqual(store.closeDecision(appState: appState), .confirm(.saveAsUntitled))

    appState.documentSession.isDirty = false
    XCTAssertEqual(store.closeDecision(appState: appState), .closeWithoutPrompting)
  }

  /// Flipping the toggle must reach the app that is already running.
  @MainActor
  func testFlippingTheSettingChangesTheNextCloseWithoutARelaunch() throws {
    let folder = try makeTemporaryFolder()
    let settings = makeAutoSaveSettings(enabled: true)
    let store = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      savingSettings: settings)
    let appState = AppState()
    appState.documentSession.load(
      document: DocumentRef(id: folder.appendingPathComponent("note.md")), text: "body")
    appState.documentSession.isDirty = true

    XCTAssertEqual(store.closeDecision(appState: appState), .saveWithoutPrompting)
    settings.autoSavesPathedDocuments = false
    XCTAssertEqual(store.closeDecision(appState: appState), .confirm(.savePathed))
    settings.autoSavesPathedDocuments = true
    XCTAssertEqual(store.closeDecision(appState: appState), .saveWithoutPrompting)
  }

  // MARK: - Editing: what reaches disk while typing

  @MainActor
  func testAutoSaveOnWritesTheFileAfterTheDebounce() async throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("on.md")
    try "initial".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 60),
      indexDatabase: temporaryIndexDatabase(in: folder),
      savingSettings: makeAutoSaveSettings(enabled: true))
    appState.documentSession.load(
      document: DocumentRef(id: noteURL.standardizedFileURL), text: "initial")
    appState.activeDocumentText = "edited with auto-save on"
    store.documentDidChange(appState: appState)

    try await waitUntil {
      (try? String(contentsOf: noteURL, encoding: .utf8)) == "edited with auto-save on"
    }
    XCTAssertFalse(appState.documentSession.isDirty)
  }

  @MainActor
  func testAutoSaveOffLeavesTheFileAloneWhileEditing() async throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("off.md")
    try "initial".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    var writeCount = 0
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 60),
      indexDatabase: temporaryIndexDatabase(in: folder),
      savingSettings: makeAutoSaveSettings(enabled: false),
      writeDocument: { text, url in
        writeCount += 1
        try text.write(to: url, atomically: true, encoding: .utf8)
      })
    appState.documentSession.load(
      document: DocumentRef(id: noteURL.standardizedFileURL), text: "initial")
    appState.activeDocumentText = "edited with auto-save off"
    store.documentDidChange(appState: appState)

    // Long enough for the (cancelled) write to betray itself.
    try await Task.sleep(nanoseconds: 200_000_000)

    XCTAssertEqual(writeCount, 0, "auto-save off must not write the user's file on its own")
    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "initial")
    XCTAssertTrue(
      appState.documentSession.isDirty,
      "the edit stays unsaved, which is what makes the close question honest")
  }

  /// The setting is read when the debounce FIRES, so switching auto-save off also
  /// stops the write already scheduled by the keystroke before the flip.
  @MainActor
  func testTurningAutoSaveOffCancelsAnAlreadyPendingWrite() async throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("pending.md")
    try "initial".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let settings = makeAutoSaveSettings(enabled: true)
    var writeCount = 0
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 120, indexDelayMilliseconds: 400),
      indexDatabase: temporaryIndexDatabase(in: folder),
      savingSettings: settings,
      writeDocument: { text, url in
        writeCount += 1
        try text.write(to: url, atomically: true, encoding: .utf8)
      })
    appState.documentSession.load(
      document: DocumentRef(id: noteURL.standardizedFileURL), text: "initial")
    appState.activeDocumentText = "typed while auto-save was still on"
    store.documentDidChange(appState: appState)

    settings.autoSavesPathedDocuments = false
    try await Task.sleep(nanoseconds: 300_000_000)

    XCTAssertEqual(writeCount, 0)
    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "initial")
  }

  // MARK: - Crash recovery is not governed by the setting

  @MainActor
  func testUntitledDraftsReachTheRecoveryStoreInBothStates() async throws {
    for autoSaveEnabled in [true, false] {
      let folder = try makeTemporaryFolder()
      let recoveryStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))
      let appState = AppState()
      let store = makeTestDocumentStore(
        autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 60),
        indexDatabase: temporaryIndexDatabase(in: folder),
        recoveryStore: recoveryStore,
        savingSettings: makeAutoSaveSettings(enabled: autoSaveEnabled))

      appState.documentSession.createUntitled(title: "Untitled.md")
      appState.activeDocumentText = "crash candidate"
      store.documentDidChange(appState: appState)

      try await waitUntil {
        recoveryStore.loadDrafts().first?.text == "crash candidate"
      }
      XCTAssertEqual(
        recoveryStore.loadDrafts().map(\.text), ["crash candidate"],
        "auto-save \(autoSaveEnabled ? "on" : "off") must not change crash recovery")
    }
  }

  /// The close-time recovery write (the teardown guard) is likewise unconditional.
  @MainActor
  func testTheCloseTimeRecoveryWriteIgnoresTheSetting() throws {
    for autoSaveEnabled in [true, false] {
      let folder = try makeTemporaryFolder()
      let recoveryStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))
      let appState = AppState()
      let store = makeTestDocumentStore(
        // A debounce long enough that only an explicit flush can persist anything.
        autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
        indexDatabase: temporaryIndexDatabase(in: folder),
        recoveryStore: recoveryStore,
        savingSettings: makeAutoSaveSettings(enabled: autoSaveEnabled))

      appState.documentSession.createUntitled(title: "Untitled.md")
      appState.activeDocumentText = "unsaved when the window went away"
      appState.documentSession.isDirty = true

      XCTAssertTrue(store.savePendingChangesOnClose(appState: appState))
      XCTAssertEqual(
        recoveryStore.loadDrafts().map(\.text), ["unsaved when the window went away"],
        "auto-save \(autoSaveEnabled ? "on" : "off") must not change crash recovery")
    }
  }

  // MARK: - Closing through the real controller (disk proof)

  /// ON: the close writes the pending edit to the file and asks nothing. The
  /// debounce is set to a minute, so a file that changed can only have changed
  /// through the close flush.
  @MainActor
  func testClosingAFileBackedDocumentWithAutoSaveOnFlushesToDiskWithoutAsking() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("flushed.md")
    try "initial".write(to: noteURL, atomically: true, encoding: .utf8)

    let recorder = SaveChangesRecorder()
    let appState = AppState()
    let controller = makeController(
      appState: appState,
      in: folder,
      autoSaveEnabled: true,
      recorder: recorder)

    let ref = DocumentRef(id: noteURL.standardizedFileURL)
    appState.documents = [ref]
    appState.documentSession.load(document: ref, text: "initial")
    appState.selectedDocumentID = ref.id
    appState.activeDocumentText = "flushed by the close"
    controller.documentDidChange()

    var didClose: Bool?
    controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, true)
    XCTAssertEqual(recorder.promptCount, 0, "auto-save on must not ask about a file it owns")
    XCTAssertEqual(
      try String(contentsOf: noteURL, encoding: .utf8), "flushed by the close",
      "the edit must be ON DISK after the close, not only in the buffer")
    XCTAssertFalse(appState.documentSession.hasEditableBuffer)
    XCTAssertNil(appState.selectedDocumentID)
  }

  /// OFF: full W2-A behaviour — the question is asked, and "Don't Save" leaves the
  /// file exactly as it was.
  @MainActor
  func testClosingAFileBackedDocumentWithAutoSaveOffAsksAndCanDiscard() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("asked.md")
    try "initial".write(to: noteURL, atomically: true, encoding: .utf8)

    let recorder = SaveChangesRecorder()
    recorder.answer = .discard
    let appState = AppState()
    let controller = makeController(
      appState: appState,
      in: folder,
      autoSaveEnabled: false,
      recorder: recorder)

    let ref = DocumentRef(id: noteURL.standardizedFileURL)
    appState.documents = [ref]
    appState.documentSession.load(document: ref, text: "initial")
    appState.selectedDocumentID = ref.id
    appState.activeDocumentText = "dropped on purpose"
    controller.documentDidChange()

    var didClose: Bool?
    controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, true)
    XCTAssertEqual(recorder.prompts, [.savePathed])
    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "initial")
    XCTAssertFalse(appState.documentSession.hasEditableBuffer)
  }

  /// OFF + `Save`: the answer is honoured, so the file does change — through the
  /// user's decision rather than on its own.
  @MainActor
  func testClosingAFileBackedDocumentWithAutoSaveOffCanStillSave() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("confirmed.md")
    try "initial".write(to: noteURL, atomically: true, encoding: .utf8)

    let recorder = SaveChangesRecorder()
    recorder.answer = .save
    let appState = AppState()
    let controller = makeController(
      appState: appState,
      in: folder,
      autoSaveEnabled: false,
      recorder: recorder)

    let ref = DocumentRef(id: noteURL.standardizedFileURL)
    appState.documents = [ref]
    appState.documentSession.load(document: ref, text: "initial")
    appState.selectedDocumentID = ref.id
    appState.activeDocumentText = "saved by answering the question"
    controller.documentDidChange()

    var didClose: Bool?
    controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, true)
    XCTAssertEqual(recorder.prompts, [.savePathed])
    XCTAssertEqual(
      try String(contentsOf: noteURL, encoding: .utf8), "saved by answering the question")
  }

  // MARK: - Switching documents (the other route a buffer is replaced)

  /// With auto-save off, clicking another document must not write the file the
  /// user just told Pensieve not to touch — it asks, like Close does.
  @MainActor
  func testSwitchingDocumentsWithAutoSaveOffAsksBeforeWriting() throws {
    let folder = try makeTemporaryFolder()
    let firstURL = folder.appendingPathComponent("first.md")
    let secondURL = folder.appendingPathComponent("second.md")
    try "first initial".write(to: firstURL, atomically: true, encoding: .utf8)
    try "second body".write(to: secondURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    var prompts = 0
    let store = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      savingSettings: makeAutoSaveSettings(enabled: false),
      dirtySessionPrompt: { _ in
        prompts += 1
        return .discard
      })

    let firstRef = DocumentRef(id: firstURL.standardizedFileURL)
    appState.documentSession.load(document: firstRef, text: "first initial")
    appState.documentSession.text = "edited, then abandoned"
    appState.documentSession.isDirty = true

    XCTAssertTrue(
      store.select(ref: DocumentRef(id: secondURL.standardizedFileURL), into: appState))

    XCTAssertEqual(prompts, 1)
    XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), "first initial")
    XCTAssertEqual(appState.documentSession.text, "second body")
  }

  /// With auto-save on, the same switch flushes silently — keeping that file
  /// current is Pensieve's job, so there is nothing to ask about.
  @MainActor
  func testSwitchingDocumentsWithAutoSaveOnSavesSilently() throws {
    let folder = try makeTemporaryFolder()
    let firstURL = folder.appendingPathComponent("first.md")
    let secondURL = folder.appendingPathComponent("second.md")
    try "first initial".write(to: firstURL, atomically: true, encoding: .utf8)
    try "second body".write(to: secondURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    var prompts = 0
    let store = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      savingSettings: makeAutoSaveSettings(enabled: true),
      dirtySessionPrompt: { _ in
        prompts += 1
        return .cancel
      })

    let firstRef = DocumentRef(id: firstURL.standardizedFileURL)
    appState.documentSession.load(document: firstRef, text: "first initial")
    appState.documentSession.text = "edited and kept"
    appState.documentSession.isDirty = true

    XCTAssertTrue(
      store.select(ref: DocumentRef(id: secondURL.standardizedFileURL), into: appState))

    XCTAssertEqual(prompts, 0)
    XCTAssertEqual(try String(contentsOf: firstURL, encoding: .utf8), "edited and kept")
    XCTAssertEqual(appState.documentSession.text, "second body")
  }

  /// An untitled draft asks on a switch in BOTH states: the setting only ever
  /// speaks about files that already have a location.
  @MainActor
  func testSwitchingAwayFromAnUntitledDraftAsksInBothStates() throws {
    for autoSaveEnabled in [true, false] {
      let folder = try makeTemporaryFolder()
      let noteURL = folder.appendingPathComponent("target.md")
      try "target body".write(to: noteURL, atomically: true, encoding: .utf8)

      let appState = AppState()
      var prompts = 0
      let store = makeTestDocumentStore(
        indexDatabase: temporaryIndexDatabase(in: folder),
        savingSettings: makeAutoSaveSettings(enabled: autoSaveEnabled),
        dirtySessionPrompt: { _ in
          prompts += 1
          return .cancel
        })

      appState.documentSession.createUntitled()
      appState.documentSession.text = "draft body"
      appState.documentSession.isDirty = true

      XCTAssertFalse(
        store.select(ref: DocumentRef(id: noteURL.standardizedFileURL), into: appState))
      XCTAssertEqual(
        prompts, 1, "auto-save \(autoSaveEnabled ? "on" : "off") must not silence a draft")
      XCTAssertTrue(appState.documentSession.isUntitled)
    }
  }

  // MARK: - Helpers

  @MainActor
  private func makeController(
    appState: AppState,
    in folder: URL,
    autoSaveEnabled: Bool,
    recorder: SaveChangesRecorder
  ) -> AppController {
    let indexDatabase = temporaryIndexDatabase(in: folder)
    return AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(
        // A minute-long debounce: anything that lands on disk during these tests
        // got there through an explicit flush, never through the timer.
        autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
        indexDatabase: indexDatabase,
        bookmarkStore: temporaryBookmarkStore(),
        savingSettings: makeAutoSaveSettings(enabled: autoSaveEnabled)),
      indexDatabase: indexDatabase,
      confirmSaveChanges: recorder.confirmation()
    )
  }

  private func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveAutoSaveTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: folder)
    }
    return folder
  }

  private func temporaryMetadataStore() -> WorkspaceMetadataStore {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveAutoSaveMetadata-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: folder)
    }
    return WorkspaceMetadataStore(
      metadataURL: folder.appendingPathComponent("workspace.json", isDirectory: false))
  }

  @MainActor
  private func temporaryIndexDatabase(in folder: URL) -> IndexDatabase {
    IndexDatabase(databaseURL: folder.appendingPathComponent("index.db", isDirectory: false))
  }

  @MainActor
  private func temporaryBookmarkStore() -> BookmarkStore {
    BookmarkStore(defaults: makeEphemeralDefaults(prefix: "PensieveAutoSaveBookmarkTests"))
  }

  private func waitUntil(
    timeout: TimeInterval = 2,
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await MainActor.run(body: condition) { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for condition")
  }
}
