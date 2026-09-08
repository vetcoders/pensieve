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
    let recoveryStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))

    let appState = AppState()
    var writeCount = 0
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 60),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore,
      savingSettings: makeAutoSaveSettings(enabled: false),
      writeDocument: { text, url in
        writeCount += 1
        try text.write(to: url, atomically: true, encoding: .utf8)
      })
    appState.documentSession.load(
      document: DocumentRef(id: noteURL.standardizedFileURL), text: "initial")
    appState.activeDocumentText = "edited with auto-save off"
    store.documentDidChange(appState: appState)

    try await waitUntil {
      recoveryStore.loadDrafts().first?.text == "edited with auto-save off"
    }

    XCTAssertEqual(writeCount, 0, "auto-save off must not write the user's file on its own")
    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "initial")
    XCTAssertTrue(
      appState.documentSession.isDirty,
      "the edit stays unsaved, which is what makes the close question honest")
    let recovery = try XCTUnwrap(recoveryStore.loadDrafts().first)
    XCTAssertEqual(recovery.sourceURL, noteURL.standardizedFileURL)
    XCTAssertEqual(recovery.displayTitle, "Unsaved changes — off.md")
    XCTAssertEqual(
      recoveryStore.loadDrafts().count, 1,
      "one live file-backed buffer must own exactly one recovery record")
  }

  @MainActor
  func testExplicitSaveFailureFallsBackToRecoveryAndLaterSuccessRetiresIt() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("explicit-save.md")
    try "on disk".write(to: noteURL, atomically: true, encoding: .utf8)
    let recoveryStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))
    let appState = AppState()
    var originalWriteShouldFail = true
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore,
      savingSettings: makeAutoSaveSettings(enabled: false),
      writeDocument: { text, url in
        if originalWriteShouldFail {
          throw CocoaError(.fileWriteNoPermission)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
      })
    appState.documentSession.load(
      document: DocumentRef(id: noteURL.standardizedFileURL), text: "on disk")
    appState.activeDocumentText = "protected edit"
    appState.documentSession.isDirty = true

    store.save(appState: appState)

    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "on disk")
    XCTAssertEqual(recoveryStore.loadDrafts().map(\.text), ["protected edit"])
    XCTAssertTrue(appState.documentSession.isDirty, "the original is still stale")
    XCTAssertNil(appState.unresolvedDataLoss, "the recovery copy made the bytes durable")
    XCTAssertTrue(
      appState.currentError?.message.contains("Could not save explicit-save.md") == true)
    XCTAssertTrue(appState.currentError?.message.contains("recovery copy is safe") == true)
    XCTAssertNotNil(appState.documentSession.pendingOriginalSaveFailure)
    let recoveryID = try XCTUnwrap(appState.documentSession.recoveryID)

    originalWriteShouldFail = false
    store.save(appState: appState)

    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "protected edit")
    XCTAssertFalse(appState.documentSession.isDirty)
    XCTAssertTrue(recoveryStore.loadDrafts().isEmpty)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("Recovery/\(recoveryID.uuidString).md").path))
    XCTAssertNil(appState.documentSession.recoveryID)
    XCTAssertNil(appState.documentSession.pendingOriginalSaveFailure)
    XCTAssertNil(appState.currentError)
  }

  @MainActor
  func testAutoSaveOffRecoveryTickKeepsTheOriginalFailureSeparateFromRecoveryFailure()
    async throws
  {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("stale-original.md")
    try "on disk".write(to: noteURL, atomically: true, encoding: .utf8)
    let blockedRecoveryURL = folder.appendingPathComponent("Recovery", isDirectory: false)
    try Data("not a directory".utf8).write(to: blockedRecoveryURL, options: .atomic)
    let recoveryStore = RecoveryStore(directoryURL: blockedRecoveryURL)
    let appState = AppState()
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore,
      savingSettings: makeAutoSaveSettings(enabled: false),
      writeDocument: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    appState.documentSession.load(
      document: DocumentRef(id: noteURL.standardizedFileURL), text: "on disk")
    appState.activeDocumentText = "unsafe edit"
    appState.documentSession.isDirty = true

    store.save(appState: appState)
    let compoundFailure = try XCTUnwrap(appState.unresolvedDataLoss?.message)
    XCTAssertTrue(compoundFailure.contains("Could not save stale-original.md"))
    XCTAssertTrue(compoundFailure.contains("Could not write recovery copy"))
    XCTAssertTrue(
      appState.documentSession.pendingOriginalSaveFailure?.contains(
        "Could not save stale-original.md") == true)
    XCTAssertFalse(
      appState.documentSession.pendingOriginalSaveFailure?.contains(
        "Could not write recovery copy") == true,
      "the buffer stored the compound banner as if it were the original failure")

    try FileManager.default.removeItem(at: blockedRecoveryURL)

    appState.activeDocumentText = "unsafe edit, now recovered"
    store.documentDidChange(appState: appState)
    try await waitUntil {
      recoveryStore.loadDrafts().first?.text == "unsafe edit, now recovered"
    }

    XCTAssertNil(
      appState.unresolvedDataLoss,
      "durable recovery bytes left the buffer classified as memory-only data loss")
    XCTAssertEqual(appState.currentError?.severity, .status)
    XCTAssertTrue(
      appState.currentError?.message.contains("Could not save stale-original.md") == true)
    XCTAssertTrue(appState.currentError?.message.contains("recovery copy is safe") == true)
    XCTAssertTrue(
      appState.currentError?.message.contains("original file was not overwritten") == true)
    XCTAssertFalse(
      appState.currentError?.message.contains("Could not write recovery copy") == true,
      "a resolved recovery failure was copied into the stale-original status")
    XCTAssertFalse(
      appState.currentError?.message.contains("window will stay open") == true,
      "the success status still claimed the recovery write had failed")
    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "on disk")

    appState.documentSession.createUntitled(title: "A different buffer.md")
    XCTAssertNil(
      appState.documentSession.pendingOriginalSaveFailure,
      "a replacement buffer inherited the previous file's failure identity")
  }

  @MainActor
  func testAutoSaveOffRecoveryOnlyFailureResolvesToNeutralSafeStatus() async throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("recovery-only.md")
    try "on disk".write(to: noteURL, atomically: true, encoding: .utf8)
    let blockedRecoveryURL = folder.appendingPathComponent("Recovery", isDirectory: false)
    try Data("not a directory".utf8).write(to: blockedRecoveryURL, options: .atomic)
    let recoveryStore = RecoveryStore(directoryURL: blockedRecoveryURL)
    let appState = AppState()
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore,
      savingSettings: makeAutoSaveSettings(enabled: false))
    appState.documentSession.load(
      document: DocumentRef(id: noteURL.standardizedFileURL), text: "on disk")

    appState.activeDocumentText = "first edit"
    store.documentDidChange(appState: appState)
    try await waitUntil {
      appState.unresolvedDataLoss?.message.contains("Could not write recovery copy") == true
    }
    XCTAssertNil(appState.documentSession.pendingOriginalSaveFailure)

    try FileManager.default.removeItem(at: blockedRecoveryURL)
    appState.activeDocumentText = "second edit"
    store.documentDidChange(appState: appState)
    try await waitUntil { recoveryStore.loadDrafts().first?.text == "second edit" }

    XCTAssertNil(appState.unresolvedDataLoss)
    XCTAssertEqual(
      appState.currentError?.message,
      "A recovery copy is safe; the original file was not overwritten.")
    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "on disk")
  }

  @MainActor
  func testAutoSaveOffRecoveryTickDoesNotClearAnUnrelatedStatus() async throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("status.md")
    try "on disk".write(to: noteURL, atomically: true, encoding: .utf8)
    let recoveryStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))
    let appState = AppState()
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore,
      savingSettings: makeAutoSaveSettings(enabled: false))
    appState.documentSession.load(
      document: DocumentRef(id: noteURL.standardizedFileURL), text: "on disk")
    appState.lastError = "A separate workspace warning"

    appState.activeDocumentText = "recovered edit"
    store.documentDidChange(appState: appState)
    try await waitUntil { recoveryStore.loadDrafts().first?.text == "recovered edit" }

    XCTAssertEqual(appState.lastError, "A separate workspace warning")
    XCTAssertNil(appState.unresolvedDataLoss)
  }

  @MainActor
  func testFailedAutoSaveFallsBackToARecoveryCopyWithoutOverwritingTheOriginal() async throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("removed-before-autosave.md")
    try "initial".write(to: noteURL, atomically: true, encoding: .utf8)
    let recoveryStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))

    let appState = AppState()
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 60),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore,
      savingSettings: makeAutoSaveSettings(enabled: true))
    appState.documentSession.load(
      document: DocumentRef(id: noteURL.standardizedFileURL), text: "initial")
    try FileManager.default.removeItem(at: noteURL)

    appState.activeDocumentText = "edit protected by fallback"
    store.documentDidChange(appState: appState)

    try await waitUntil {
      recoveryStore.loadDrafts().first?.text == "edit protected by fallback"
    }

    XCTAssertFalse(FileManager.default.fileExists(atPath: noteURL.path))
    XCTAssertTrue(appState.documentSession.isDirty, "the original file is still stale")
    XCTAssertNil(
      appState.unresolvedDataLoss,
      "a durable recovery copy means the failed original write is status, not data loss")
    XCTAssertEqual(appState.currentError?.severity, .status)
    XCTAssertTrue(appState.currentError?.message.contains("recovery copy is safe") == true)
    let recovery = try XCTUnwrap(recoveryStore.loadDrafts().first)
    XCTAssertEqual(recovery.sourceURL, noteURL.standardizedFileURL)
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

  // MARK: - Teardown close never writes behind the user's back (#15 P1-01/03)

  /// P1-01: a file-backed buffer whose WINDOW tears down with auto-save OFF (a
  /// raw close with no veto point left) must not have its file written behind the
  /// user's back. The edit is preserved as a recovery draft instead — zero bytes
  /// reach the file, and nothing is lost.
  @MainActor
  func testTeardownCloseWithAutoSaveOffWritesNoBytesAndKeepsARecoveryDraft() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("untouched.md")
    try "on disk".write(to: noteURL, atomically: true, encoding: .utf8)
    let recoveryStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))

    var writeCount = 0
    let appState = AppState()
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore,
      savingSettings: makeAutoSaveSettings(enabled: false),
      writeDocument: { text, url in
        writeCount += 1
        try text.write(to: url, atomically: true, encoding: .utf8)
      })
    appState.documentSession.load(
      document: DocumentRef(id: noteURL.standardizedFileURL), text: "on disk")
    appState.activeDocumentText = "edited but never told to save"
    appState.documentSession.isDirty = true

    XCTAssertTrue(store.savePendingChangesOnClose(appState: appState))

    XCTAssertEqual(
      writeCount, 0, "auto-save off must not write the user's file on a teardown close")
    XCTAssertEqual(
      try String(contentsOf: noteURL, encoding: .utf8), "on disk",
      "the file must be byte-for-byte what it was before the close")
    XCTAssertEqual(
      recoveryStore.loadDrafts().map(\.text), ["edited but never told to save"],
      "the unsaved edit must survive as a recovery draft")
  }

  /// P1-03: when the close-path save of a FILE-BACKED document FAILS (auto-save
  /// on, but the write throws), the buffer must not die with the window — it is
  /// stashed as a recovery draft AND the write error stays surfaced, so a named
  /// file whose save fails on close is never silently lost.
  @MainActor
  func testFailedCloseSaveOfAPathedDocumentLeavesARecoveryDraftAndSurfacesTheError() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("fails.md")
    try "on disk".write(to: noteURL, atomically: true, encoding: .utf8)
    let recoveryStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))

    let appState = AppState()
    let store = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore,
      savingSettings: makeAutoSaveSettings(enabled: true),
      writeDocument: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    appState.documentSession.load(
      document: DocumentRef(id: noteURL.standardizedFileURL), text: "on disk")
    appState.activeDocumentText = "edit that cannot reach disk"
    appState.documentSession.isDirty = true

    XCTAssertTrue(store.savePendingChangesOnClose(appState: appState))

    XCTAssertEqual(
      recoveryStore.loadDrafts().map(\.text), ["edit that cannot reach disk"],
      "a failed close-save must fall back to a recovery draft, not lose the edit")
    let recovery = try XCTUnwrap(recoveryStore.loadDrafts().first)
    XCTAssertFalse(
      recoveryStore.isDraftOpen(id: recovery.id),
      "the dying window kept its fallback claimed and hid it from the launcher")
    XCTAssertNotNil(
      appState.lastError, "the save failure must stay surfaced, not be masked by the draft write")
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

  @MainActor
  private func waitUntil(
    timeout: TimeInterval = 2,
    condition: @escaping @MainActor () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for condition")
  }
}
