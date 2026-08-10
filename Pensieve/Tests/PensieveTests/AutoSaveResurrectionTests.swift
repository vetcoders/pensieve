import Darwin
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

  /// THE OTHER PIN: the race the fast-path check cannot win.
  ///
  /// A preflight `fileExists` proves nothing about the write that follows it —
  /// the file can go in between, and a plain atomic write recreates it. This
  /// reproduces that window deterministically: the seam deletes the target
  /// AFTER the check has already passed, and then hands the bytes to the
  /// SHIPPED write layer. The guarantee has to come from that layer, so the
  /// file must stay gone.
  @MainActor
  func testAWriteLosingItsTargetMidFlightStillDoesNotRecreateIt() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("raced.md").standardizedFileURL
    try "on disk".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    var attempts = 0
    let store = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      savingSettings: makeAutoSaveSettings(enabled: true),
      replaceExistingDocument: { text, url in
        attempts += 1
        // The deletion the check above cannot see, landing in the window
        // between the check and the write.
        try FileManager.default.removeItem(at: url)
        try DocumentStore.replaceExistingItem(text, at: url)
      })
    appState.documentSession.load(document: DocumentRef(id: noteURL), text: "on disk")
    appState.documentSession.text = "typed into the race"
    appState.documentSession.isDirty = true

    XCTAssertTrue(store.savePendingChangesOnClose(appState: appState))

    XCTAssertEqual(attempts, 1, "the fast path must let this write reach the write layer")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: noteURL.path),
      "the file came back: the write layer created what the check had cleared")
  }

  /// The same guarantee stated at the write layer directly, without a store
  /// around it — a missing target is refused by the publishing step itself.
  func testTheReplaceOnlyWriteRefusesAMissingTargetAndKeepsAnExistingOne() throws {
    let folder = try makeTemporaryFolder()
    let missing = folder.appendingPathComponent("never-there.md")

    XCTAssertThrowsError(try DocumentStore.replaceExistingItem("body", at: missing))
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

    let present = folder.appendingPathComponent("there.md")
    try "old".write(to: present, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o644))], ofItemAtPath: present.path)

    try DocumentStore.replaceExistingItem("new", at: present)

    XCTAssertEqual(try String(contentsOf: present, encoding: .utf8), "new")
    XCTAssertEqual(
      (try FileManager.default.attributesOfItem(atPath: present.path))[.posixPermissions]
        as? NSNumber, NSNumber(value: Int16(0o644)),
      "swapping inodes must not silently change the note's mode")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: folder.path).filter {
        $0.hasPrefix(".pensieve-save-")
      }, [], "the temporary file must not survive the write")
  }

  /// `RENAME_SWAP` publishes a different inode. The anti-resurrection guarantee
  /// is not allowed to buy atomic bytes by stripping the metadata attached to
  /// the user's original file on every autosave.
  func testTheReplaceOnlyWritePreservesExtendedMetadataAndAdvancesModificationTime() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("tagged.md")
    try "old".write(to: noteURL, atomically: true, encoding: .utf8)
    let oldModificationDate = Date(timeIntervalSince1970: 1_600_000_000)
    try FileManager.default.setAttributes(
      [
        .posixPermissions: NSNumber(value: Int16(0o640)),
        .modificationDate: oldModificationDate,
      ],
      ofItemAtPath: noteURL.path)
    let attributeName = "com.vetcoders.pensieve.autosave-test"
    let attributeValue = Data("keep this metadata".utf8)
    try setExtendedAttribute(attributeName, value: attributeValue, at: noteURL)

    try DocumentStore.replaceExistingItem("new", at: noteURL)

    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "new")
    XCTAssertEqual(try extendedAttribute(attributeName, at: noteURL), attributeValue)
    let attributes = try FileManager.default.attributesOfItem(atPath: noteURL.path)
    XCTAssertEqual(
      attributes[.posixPermissions] as? NSNumber, NSNumber(value: Int16(0o640)))
    XCTAssertGreaterThan(
      try XCTUnwrap(attributes[.modificationDate] as? Date), oldModificationDate,
      "copying metadata restored the old mtime and hid the content update")
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

  /// A refused original-file write falls back on every debounce tick, but one
  /// live buffer owns one recovery identity. Repeated failures update that
  /// record instead of burying the user in copies.
  @MainActor
  func testARefusedAutoSaveUpdatesOneRecoveryCopyAcrossTicks() async throws {
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
      try await waitUntil { recoveryStore.loadDrafts().first?.text == text }
      XCTAssertEqual(
        recoveryStore.loadDrafts().count, 1,
        "every debounce tick must update the buffer's one recovery identity")
    }

    let recovery = try XCTUnwrap(recoveryStore.loadDrafts().first)
    XCTAssertEqual(recoveryStore.loadDrafts().count, 1)
    XCTAssertEqual(recovery.text, "third")
    XCTAssertEqual(recovery.sourceURL, noteURL)
    XCTAssertEqual(appState.documentSession.text, "third")
    XCTAssertTrue(appState.documentSession.isDirty)
  }

  /// The conscious close (⌘W) of a document whose file went missing, with
  /// auto-save ON. Auto-save answers the save question for the user, so this
  /// close is an unattended write — it must not put the file back. RecoveryStore
  /// is the required second destination: once that fallback succeeds the bytes
  /// are durable and close may proceed without recreating the original.
  @MainActor
  func testAConsciousCloseFallsBackToRecoveryWhenTheFileIsGone() throws {
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

    XCTAssertTrue(
      store.finishClose(decision: .saveWithoutPrompting, response: nil, appState: appState),
      "a durable recovery fallback should allow an unattended close")
    XCTAssertEqual(writeCount, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: noteURL.path))
    let recovery = try XCTUnwrap(recoveryStore.loadDrafts().first)
    XCTAssertEqual(recovery.text, "typed before ⌘W")
    XCTAssertEqual(recovery.sourceURL, noteURL)
    XCTAssertFalse(appState.documentSession.hasEditableBuffer)
    XCTAssertNil(appState.unresolvedDataLoss)
    XCTAssertTrue(appState.lastError?.contains("recovery copy is safe") == true)
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

  private func setExtendedAttribute(_ name: String, value: Data, at url: URL) throws {
    var failure: Int32 = 0
    let result = value.withUnsafeBytes { bytes in
      url.withUnsafeFileSystemRepresentation { path in
        name.withCString { attributeName in
          guard let path else {
            failure = EINVAL
            return Int32(-1)
          }
          let result = setxattr(
            path, attributeName, bytes.baseAddress, bytes.count, 0, 0)
          failure = errno
          return result
        }
      }
    }
    guard result != 0 else { return }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
  }

  private func extendedAttribute(_ name: String, at url: URL) throws -> Data {
    var failure: Int32 = 0
    let size = url.withUnsafeFileSystemRepresentation { path in
      name.withCString { attributeName in
        guard let path else {
          failure = EINVAL
          return Int(-1)
        }
        let result = getxattr(path, attributeName, nil, 0, 0, 0)
        failure = errno
        return result
      }
    }
    guard size >= 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
    }
    var data = Data(count: size)
    let read = data.withUnsafeMutableBytes { bytes in
      url.withUnsafeFileSystemRepresentation { path in
        name.withCString { attributeName in
          guard let path else {
            failure = EINVAL
            return Int(-1)
          }
          let result = getxattr(path, attributeName, bytes.baseAddress, bytes.count, 0, 0)
          failure = errno
          return result
        }
      }
    }
    guard read >= 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
    }
    data.count = read
    return data
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
