import XCTest

@testable import Pensieve

/// Auto-save may UPDATE the user's file. It may not bring one back.
///
/// A document open in Pensieve can leave the disk behind the app's back —
/// dragged to the Trash in Finder, deleted by a script, removed by a sync
/// client. The buffer stays on screen either way, and the next unattended write
/// used to go to the path the session still remembered, which RECREATED the
/// file the user had just thrown away. Nobody asked for that write, so nothing
/// on screen explained the file coming back, and the copy in the Trash stayed
/// there beside it.
///
/// The line drawn here is who asked:
///
/// - the auto-save debounce and the window-teardown flush are UNATTENDED — they
///   may write a file that is still there and must refuse to create one that is
///   not, keeping the work as a recovery draft instead;
/// - ⌘S and Save As are EXPLICIT — the user asked for this exact write, and
///   recreating the file is the thing they asked for.
final class AutoSaveResurrectionTests: XCTestCase {

  // MARK: - The bug: an unattended write must not create its target

  /// THE PIN. Everything else in this file is a boundary around it.
  @MainActor
  func testAutoSaveDoesNotRecreateAFileThatVanishedFromDisk() async throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("trashed.md").standardizedFileURL
    try "on disk".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    var writeCount = 0
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 60),
      indexDatabase: temporaryIndexDatabase(in: folder),
      savingSettings: makeAutoSaveSettings(enabled: true),
      writeDocument: { text, url in
        writeCount += 1
        try text.write(to: url, atomically: true, encoding: .utf8)
      })
    appState.documentSession.load(document: DocumentRef(id: noteURL), text: "on disk")

    // Finder, behind the app's back. The session keeps the path it was opened at.
    try FileManager.default.removeItem(at: noteURL)

    appState.activeDocumentText = "typed after the file was thrown away"
    store.documentDidChange(appState: appState)

    // Long enough for the debounced write to betray itself.
    try await Task.sleep(nanoseconds: 250_000_000)

    XCTAssertEqual(
      writeCount, 0,
      "auto-save wrote a file nobody asked it to create")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: noteURL.path),
      "the thrown-away file came back on disk, beside its own copy in the Trash")
  }

  /// Refusing the write must not cost the user a single character. The buffer
  /// stays exactly as typed and stays DIRTY, which is what keeps the close
  /// question honest and the tab's unsaved marker truthful.
  @MainActor
  func testARefusedAutoSaveKeepsTheBufferAliveAndDirty() async throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("kept.md").standardizedFileURL
    try "on disk".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 60),
      indexDatabase: temporaryIndexDatabase(in: folder),
      savingSettings: makeAutoSaveSettings(enabled: true))
    appState.documentSession.load(document: DocumentRef(id: noteURL), text: "on disk")

    try FileManager.default.removeItem(at: noteURL)

    appState.activeDocumentText = "work that must not evaporate"
    store.documentDidChange(appState: appState)
    try await Task.sleep(nanoseconds: 250_000_000)

    XCTAssertEqual(
      appState.documentSession.text, "work that must not evaporate",
      "the refused write must leave the buffer untouched")
    XCTAssertTrue(
      appState.documentSession.isDirty,
      "a write that did not happen must not report itself as saved")
    XCTAssertTrue(
      appState.documentSession.hasEditableBuffer,
      "the document stays open and editable — the file left, the work did not")
  }

  /// A refused write writes NOTHING, anywhere — not the file, and not a draft
  /// per debounce tick either.
  ///
  /// Stashing on every tick was the obvious reaction and it is wrong here: a
  /// FILE-BACKED session cannot carry a draft id (`DocumentSession.recoveryID`
  /// is defined for untitled sessions only), so each stash mints a NEW draft and
  /// a minute of typing buries the user in copies. Durability for this buffer is
  /// owned by the teardown guard, one draft at the moment the buffer would
  /// otherwise die — pinned below.
  @MainActor
  func testARefusedAutoSaveDoesNotPileUpADraftPerTick() async throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("repeat.md").standardizedFileURL
    try "on disk".write(to: noteURL, atomically: true, encoding: .utf8)

    let recoveryStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))
    let appState = AppState()
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 60),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore,
      savingSettings: makeAutoSaveSettings(enabled: true))
    appState.documentSession.load(document: DocumentRef(id: noteURL), text: "on disk")
    try FileManager.default.removeItem(at: noteURL)

    for text in ["first", "second", "third"] {
      appState.activeDocumentText = text
      store.documentDidChange(appState: appState)
      try await Task.sleep(nanoseconds: 80_000_000)
    }

    XCTAssertTrue(
      recoveryStore.loadDrafts().isEmpty,
      "the live buffer is the copy while the window holds it; drafts are for when it dies")
    XCTAssertEqual(appState.documentSession.text, "third")
    XCTAssertTrue(appState.documentSession.isDirty)
  }

  /// The conscious close (⌘W) of a document whose file went missing, with
  /// auto-save ON. Auto-save answers the save question for the user, so this
  /// close is an unattended write — it must not put the file back. A close whose
  /// save does not happen is REFUSED and the window goes on holding the text,
  /// which is the shipped behaviour for a save that fails (see
  /// `testCloseActiveDocumentRefusesWhenDirtySaveFails`); this cut adds a reason
  /// to refuse, not a new way to close.
  @MainActor
  func testAConsciousCloseKeepsTheWorkWhenTheFileIsGone() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("closed.md").standardizedFileURL
    try "on disk".write(to: noteURL, atomically: true, encoding: .utf8)

    let recoveryStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))
    let appState = AppState()
    var writeCount = 0
    let store = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore,
      savingSettings: makeAutoSaveSettings(enabled: true),
      writeDocument: { text, url in
        writeCount += 1
        try text.write(to: url, atomically: true, encoding: .utf8)
      })
    appState.documentSession.load(document: DocumentRef(id: noteURL), text: "on disk")
    appState.documentSession.text = "typed before ⌘W"
    appState.documentSession.isDirty = true

    try FileManager.default.removeItem(at: noteURL)

    XCTAssertFalse(
      store.finishClose(decision: .saveWithoutPrompting, response: nil, appState: appState),
      "a close whose save did not happen must not drop the session")
    XCTAssertEqual(writeCount, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: noteURL.path))
    XCTAssertEqual(
      appState.documentSession.text, "typed before ⌘W",
      "the window must go on holding the only copy of the text")
    XCTAssertTrue(appState.documentSession.isDirty)
    XCTAssertEqual(appState.selectedDocumentID, appState.documentSession.id)
  }

  /// The window-teardown flush is the same kind of write — nobody asked for it —
  /// and it had the same escape hatch already: a save that does not happen falls
  /// through to the recovery stash.
  @MainActor
  func testTheCloseFlushDoesNotRecreateAVanishedFileAndStashesInstead() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("closing.md").standardizedFileURL
    try "on disk".write(to: noteURL, atomically: true, encoding: .utf8)

    let recoveryStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))
    let appState = AppState()
    var writeCount = 0
    let store = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore,
      savingSettings: makeAutoSaveSettings(enabled: true),
      writeDocument: { text, url in
        writeCount += 1
        try text.write(to: url, atomically: true, encoding: .utf8)
      })
    appState.documentSession.load(document: DocumentRef(id: noteURL), text: "on disk")
    appState.documentSession.text = "unsaved at close"
    appState.documentSession.isDirty = true

    try FileManager.default.removeItem(at: noteURL)

    XCTAssertTrue(store.savePendingChangesOnClose(appState: appState))

    XCTAssertEqual(writeCount, 0, "closing a window must not recreate the file either")
    XCTAssertFalse(FileManager.default.fileExists(atPath: noteURL.path))
    XCTAssertEqual(
      recoveryStore.loadDrafts().map(\.text), ["unsaved at close"],
      "the buffer must not die with the window just because its file left first")
  }

  // MARK: - Controls: what must NOT change

  /// The ordinary case, which is the whole point of auto-save. A file that is
  /// still there is still written, on the same debounce as before.
  @MainActor
  func testAutoSaveStillWritesAFileThatIsStillThere() async throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("healthy.md").standardizedFileURL
    try "initial".write(to: noteURL, atomically: true, encoding: .utf8)

    let recoveryStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))
    let appState = AppState()
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 60),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore,
      savingSettings: makeAutoSaveSettings(enabled: true))
    appState.documentSession.load(document: DocumentRef(id: noteURL), text: "initial")

    appState.activeDocumentText = "edited with the file in place"
    store.documentDidChange(appState: appState)

    try await waitUntil {
      (try? String(contentsOf: noteURL, encoding: .utf8)) == "edited with the file in place"
    }
    XCTAssertFalse(appState.documentSession.isDirty)
    XCTAssertTrue(
      recoveryStore.loadDrafts().isEmpty,
      "a healthy save owes no recovery draft — the file IS the durable copy")
  }

  /// ⌘S is the user asking for this exact write. A file that vanished is theirs
  /// to put back, and refusing here would strand the buffer with no way to
  /// write it to the path it belongs to.
  @MainActor
  func testAnExplicitSaveStillWritesEvenWhenTheFileVanished() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("asked-for.md").standardizedFileURL
    try "on disk".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let store = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      savingSettings: makeAutoSaveSettings(enabled: true))
    appState.documentSession.load(document: DocumentRef(id: noteURL), text: "on disk")
    appState.documentSession.text = "put it back where it was"
    appState.documentSession.isDirty = true

    try FileManager.default.removeItem(at: noteURL)

    store.save(appState: appState)

    XCTAssertEqual(
      try String(contentsOf: noteURL, encoding: .utf8), "put it back where it was",
      "an explicit save must still be able to write the path the user chose")
    XCTAssertFalse(appState.documentSession.isDirty)
  }

  /// Save As writes wherever the user pointed it, including over a location that
  /// holds nothing yet. Untouched by the guard.
  @MainActor
  func testSaveAsStillWritesToItsTarget() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("origin.md").standardizedFileURL
    try "on disk".write(to: noteURL, atomically: true, encoding: .utf8)
    let targetURL = folder.appendingPathComponent("elsewhere.md").standardizedFileURL

    let appState = AppState()
    let store = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      savingSettings: makeAutoSaveSettings(enabled: true))
    appState.documentSession.load(document: DocumentRef(id: noteURL), text: "on disk")
    appState.documentSession.text = "saved under a new name"
    appState.documentSession.isDirty = true

    try FileManager.default.removeItem(at: noteURL)

    XCTAssertTrue(store.saveAs(appState: appState, to: targetURL))
    XCTAssertEqual(
      try String(contentsOf: targetURL, encoding: .utf8), "saved under a new name")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: noteURL.path),
      "Save As writes the target, never the abandoned origin")
  }

  /// An untitled draft has no file to lose, so the guard must not reach it: its
  /// auto-save has always gone to the recovery store and still does.
  @MainActor
  func testAnUntitledDraftStillAutoSavesToRecovery() async throws {
    let folder = try makeTemporaryFolder()
    let recoveryStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))
    let appState = AppState()
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 60),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore,
      savingSettings: makeAutoSaveSettings(enabled: true))

    appState.documentSession.createUntitled(title: "Untitled.md")
    appState.activeDocumentText = "never had a file"
    store.documentDidChange(appState: appState)

    try await waitUntil { recoveryStore.loadDrafts().first?.text == "never had a file" }
  }

  // MARK: - Fixtures

  private func makeTemporaryFolder() throws -> URL {
    let name = "PensieveAutoSaveResurrectionTests-\(UUID().uuidString)"
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: folder)
    }
    return folder
  }

  @MainActor
  private func temporaryIndexDatabase(in folder: URL) -> IndexDatabase {
    IndexDatabase(databaseURL: folder.appendingPathComponent("index.db", isDirectory: false))
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
