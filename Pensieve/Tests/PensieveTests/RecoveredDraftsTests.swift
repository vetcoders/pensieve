import AppKit
import CoreText
import XCTest

@testable import Pensieve

/// W2-D: recovery stops being magic.
///
/// Two properties are under test, both provable on the FILESYSTEM rather than
/// in memory — a draft is a file, and "kept" or "gone" only means anything on
/// disk:
///   * persistence — a draft survives everything except a decision the user
///     made about it. Age does not retire it, volume does not retire it, and
///     launching the app does not retire it (Monika, 04.08: they don't
///     disappear without her decision — retiring the old 30-day sweep and
///     20-draft cap);
///   * the three launcher actions (Open / Save As… / Discard), each of which
///     may retire a draft only when the work is safely elsewhere.
final class RecoveredDraftsTests: XCTestCase {

  // MARK: - A draft outlives everything but a decision

  /// Writing a NEW draft used to evict the oldest one on the spot, to hold a
  /// 20-draft ceiling. The arrival of newer work is not a decision the user made
  /// about the older draft, so nothing falls out.
  @MainActor
  func testWritingANewDraftEvictsNothing() throws {
    let store = try makeRecoveryStore()
    var seeded: [RecoveryDraft] = []
    for index in 0..<20 {
      seeded.append(
        try seedDraft(in: store, text: "draft \(index)", ageInDays: Double(20 - index)))
    }
    XCTAssertEqual(store.loadDrafts().count, 20)

    let newest = try store.saveDraft(id: nil, title: "Untitled.md", text: "one draft too many")

    XCTAssertEqual(store.loadDrafts().count, 21, "writing the 21st draft evicted an older one")
    for draft in seeded {
      XCTAssertTrue(fileExists(draft.url), "a draft was deleted to make room for a newer one")
    }
    XCTAssertTrue(fileExists(newest.url))
  }

  /// Re-saving the SAME draft is the autosave hot path: it must not evict
  /// anything, because the list did not grow.
  @MainActor
  func testResavingAnExistingDraftEvictsNothing() throws {
    let store = try makeRecoveryStore()
    var seeded: [RecoveryDraft] = []
    for index in 0..<20 {
      seeded.append(
        try seedDraft(in: store, text: "draft \(index)", ageInDays: Double(20 - index)))
    }

    let live = try XCTUnwrap(seeded.last)
    _ = try store.saveDraft(id: live.id, title: "Untitled.md", text: "still typing")

    XCTAssertEqual(store.loadDrafts().count, 20)
    for draft in seeded {
      XCTAssertTrue(fileExists(draft.url))
    }
  }

  // MARK: - The LAUNCH path

  /// The launch path used to be the one place that deleted drafts on its own:
  /// past 30 days they went, and what survived was trimmed to the newest 20.
  /// Monika's decision of 04.08 retired both rules, and a decision is only worth
  /// anything if the code the user actually runs obeys it. This drives the
  /// application's own launch entry point — `PensieveAppDelegate`, the
  /// `@NSApplicationDelegateAdaptor` instance every launch goes through — and
  /// then reads the result back through the LAUNCHER surface
  /// (`AppController.recoveredDrafts`), which is where the user meets it.
  ///
  /// Both retired rules in one pass: drafts far past the old 30-day window, and
  /// a directory far past the old cap of 20, all still there afterwards.
  @MainActor
  func testTheLaunchPassKeepsAncientAndOverCapDraftsAlike() throws {
    let folder = try makeTemporaryFolder()
    let store = try makeRecoveryStore(in: folder)

    let ancient = try seedDraft(in: store, text: "four hundred days old", ageInDays: 400)
    let stale = try seedDraft(in: store, text: "forty days old", ageInDays: 40)
    let borderline = try seedDraft(in: store, text: "thirty-one days old", ageInDays: 31)
    // Oldest first, so the ones the retired cap would have dropped are the ones
    // seeded first.
    var overCap: [RecoveryDraft] = []
    for index in 0..<25 {
      overCap.append(
        try seedDraft(in: store, text: "draft \(index)", ageInDays: Double(25 - index)))
    }

    let delegate = PensieveAppDelegate()
    delegate.launchRecoveryStoreOverride = store
    let surveyed = Set(delegate.surveyRecoveredDraftsOnLaunch().map(\.id))

    let all = [ancient, stale, borderline] + overCap
    XCTAssertEqual(store.loadDrafts().count, all.count, "the launch pass deleted drafts")
    for draft in all {
      XCTAssertTrue(
        fileExists(draft.url),
        "launching the app deleted a draft nobody decided about — the only copy of that work")
      XCTAssertTrue(surveyed.contains(draft.id))
    }

    // A draft is two files — the `.md` and the `.title` sidecar holding its
    // name — and neither may be collected behind the user's back.
    let recoveryDirectory = ancient.url.deletingLastPathComponent()
    let sidecars = try FileManager.default
      .contentsOfDirectory(atPath: recoveryDirectory.path)
      .filter { $0.hasSuffix(".title") }
    XCTAssertEqual(
      Set(sidecars), Set(all.map { "\($0.id.uuidString).title" }),
      "the launch pass took a draft's title sidecar")

    // …and the launcher the user lands on offers every one of them.
    let controller = makeController(in: folder, recoveryStore: store, confirmsDiscard: false)
    controller.refreshRecoveredDrafts()
    XCTAssertEqual(Set(controller.recoveredDrafts.map(\.id)), Set(all.map(\.id)))
  }

  /// The draft a window is holding open is the only copy of live work. It is not
  /// "unhandled", so it drops off every other launcher surface — and the launch
  /// pass still leaves the file exactly where it is.
  @MainActor
  func testTheLaunchPassLeavesTheDraftAWindowIsEditingAlone() throws {
    let store = try makeRecoveryStore()
    let openDraft = try seedDraft(
      in: store, text: "being edited right now", ageInDays: 400, keepOpen: true)

    let delegate = PensieveAppDelegate()
    delegate.launchRecoveryStoreOverride = store
    delegate.surveyRecoveredDraftsOnLaunch()

    XCTAssertTrue(fileExists(openDraft.url), "the launch pass deleted a draft being edited")
    XCTAssertTrue(store.isDraftOpen(id: openDraft.id))
    XCTAssertTrue(store.unclaimedDrafts().isEmpty, "a claimed draft is not an unhandled one")
  }

  // MARK: - Open

  @MainActor
  func testOpenAdoptsTheDraftAndLeavesTheFileUntilItIsDecided() throws {
    let folder = try makeTemporaryFolder()
    let store = try makeRecoveryStore(in: folder)
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder), recoveryStore: store)
    let draft = try seedDraft(in: store, text: "crash text", ageInDays: 0)
    let appState = AppState()

    XCTAssertTrue(documentStore.openRecoveredDraft(draft, into: appState))

    XCTAssertTrue(appState.documentSession.isUntitled)
    XCTAssertEqual(appState.activeDocumentText, "crash text")
    XCTAssertTrue(appState.activeDocumentDirty)
    XCTAssertEqual(appState.documentSession.recoveryID, draft.id)
    // Opening is not deciding: the draft is still recoverable.
    XCTAssertTrue(fileExists(draft.url), "Open deleted the draft before it was saved or discarded")
    XCTAssertTrue(store.isDraftOpen(id: draft.id), "the adopted draft was not claimed")
  }

  @MainActor
  func testOpenRefusesAWindowThatAlreadyHoldsABuffer() throws {
    let folder = try makeTemporaryFolder()
    let store = try makeRecoveryStore(in: folder)
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder), recoveryStore: store)
    let draft = try seedDraft(in: store, text: "crash text", ageInDays: 0)
    let appState = AppState()
    appState.documentSession.createUntitled(title: "Untitled.md")
    appState.activeDocumentText = "work in progress"

    XCTAssertFalse(documentStore.openRecoveredDraft(draft, into: appState))

    XCTAssertEqual(appState.activeDocumentText, "work in progress")
    XCTAssertTrue(fileExists(draft.url))
  }

  // MARK: - One draft, one window

  /// Two empty launcher surfaces (a plain launcher window and a "+"-tab one)
  /// used to list — and both adopt — the same draft. The first adoption takes
  /// the draft off every other surface, and a surface still holding the stale
  /// row is refused instead of building a second buffer on the same file.
  @MainActor
  func testAdoptingADraftTakesItOffEveryOtherLauncherSurface() throws {
    let folder = try makeTemporaryFolder()
    let store = try makeRecoveryStore(in: folder)
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder), recoveryStore: store)
    let draft = try seedDraft(in: store, text: "crash text", ageInDays: 0)

    let adopting = AppState()
    XCTAssertTrue(documentStore.openRecoveredDraft(draft, into: adopting))

    XCTAssertTrue(
      documentStore.recoveredDrafts().isEmpty,
      "a draft another window is editing is still offered on the launcher")

    // The second surface renders from a list captured before the claim, so it
    // still has the row and can still press Open.
    let second = AppState()
    XCTAssertFalse(
      documentStore.openRecoveredDraft(draft, into: second),
      "a second window adopted a draft that is already open elsewhere")
    XCTAssertFalse(second.documentSession.hasEditableBuffer, "the refusal built a second buffer")
    XCTAssertEqual(second.activeDocumentText, "")
    // Refusing decides nothing: the window that owns the draft keeps it.
    XCTAssertEqual(adopting.activeDocumentText, "crash text")
    XCTAssertEqual(adopting.documentSession.recoveryID, draft.id)
    XCTAssertTrue(fileExists(draft.url), "the refusal deleted a draft that is being edited")
  }

  /// The immortal-draft half of the bug: the refused surface must not be able
  /// to write the retired recovery ID back to disk after the adopting window
  /// saved the work away.
  @MainActor
  func testARefusedSurfaceCannotResurrectADraftTheOwnerSavedAway() throws {
    let folder = try makeTemporaryFolder()
    let targetURL = folder.appendingPathComponent("rescued.md")
    let store = try makeRecoveryStore(in: folder)
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: store,
      savePanelURLProvider: { _ in targetURL })
    let draft = try seedDraft(in: store, text: "crash text", ageInDays: 0)

    let adopting = AppState()
    XCTAssertTrue(documentStore.openRecoveredDraft(draft, into: adopting))
    let refused = AppState()
    XCTAssertFalse(documentStore.openRecoveredDraft(draft, into: refused))

    XCTAssertTrue(documentStore.saveRecoveredDraftAs(draft, into: adopting))
    XCTAssertFalse(fileExists(draft.url))

    // The refused surface still holds the stale draft value. Nothing it can do
    // recreates that file, because it never got a buffer carrying the ID.
    refused.activeDocumentText = "typed into an empty window"
    documentStore.documentDidChange(appState: refused)
    XCTAssertFalse(documentStore.savePendingChangesOnClose(appState: refused))

    XCTAssertFalse(fileExists(draft.url), "the refused surface resurrected the saved-away draft")
    XCTAssertTrue(store.loadDrafts().isEmpty)
    XCTAssertTrue(documentStore.recoveredDrafts().isEmpty)
    XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "crash text")
  }

  /// The claim is a loan, not a consumption: a window that closes WITHOUT
  /// deciding hands the draft back, and the launcher may offer it again.
  @MainActor
  func testClosingWithoutDecidingReturnsTheDraftToTheLauncher() throws {
    let folder = try makeTemporaryFolder()
    let store = try makeRecoveryStore(in: folder)
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder), recoveryStore: store)
    let draft = try seedDraft(in: store, text: "crash text", ageInDays: 0)
    let adopting = AppState()
    XCTAssertTrue(documentStore.openRecoveredDraft(draft, into: adopting))
    XCTAssertTrue(documentStore.recoveredDrafts().isEmpty)

    // The window goes away with the draft still unnamed — the teardown flush
    // rewrites it and releases the claim.
    XCTAssertTrue(documentStore.savePendingChangesOnClose(appState: adopting))

    XCTAssertEqual(documentStore.recoveredDrafts().map(\.id), [draft.id])
    let reopened = AppState()
    XCTAssertTrue(
      documentStore.openRecoveredDraft(draft, into: reopened),
      "a released draft stayed unadoptable")
    XCTAssertEqual(reopened.activeDocumentText, "crash text")
  }

  /// …and the loan is NOT handed back by a caller whose window stays open.
  ///
  /// `importDocument` publishes its converted Word/PDF text as an untitled buffer
  /// and persists it through the close-time flush, so a crash cannot erase the
  /// handoff. That flush's default is a CLOSE — the buffer dies with the window,
  /// so its draft goes back on the launcher — and for this caller that is simply
  /// false: the window is on screen holding the buffer. Released, the draft was
  /// offered as unhandled work while a window was editing it, and adopting it
  /// from a second surface put two buffers on one recovery ID, autosaving over
  /// each other.
  @MainActor
  func testImportingADocumentKeepsItsDraftClaimedByTheWindowHoldingIt() async throws {
    let folder = try makeTemporaryFolder()
    // A real PDF: `importMarkdown` rejects anything that is not `.docx`/`.pdf`,
    // and a rejected conversion would make this test pass for the wrong reason.
    let sourceURL = folder.appendingPathComponent("Board Resolution.pdf")
    try makeTextPDF("Prokurent approval is required.").write(to: sourceURL, options: .atomic)
    let store = try makeRecoveryStore(in: folder)
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let documentStore = makeTestDocumentStore(
      // Long enough that only the import's own explicit flush can persist anything.
      autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
      indexDatabase: indexDatabase,
      recoveryStore: store)
    let appState = AppState()
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(in: folder), indexDatabase: indexDatabase),
      documentStore: documentStore,
      indexDatabase: indexDatabase)

    controller.importDocument(url: sourceURL)
    let draft = try await waitForSingleDraft(in: store)

    XCTAssertTrue(
      appState.documentSession.hasEditableBuffer,
      "fixture precondition: the importing window still holds the buffer that draft belongs to")
    XCTAssertEqual(appState.documentSession.recoveryID, draft.id)
    XCTAssertTrue(
      documentStore.recoveredDrafts().isEmpty,
      "the launcher offered the draft of a buffer a window is still editing")

    let second = AppState()
    XCTAssertFalse(
      documentStore.openRecoveredDraft(draft, into: second),
      "a second window adopted the live import buffer's draft — two buffers on one recovery ID")
    XCTAssertFalse(second.documentSession.hasEditableBuffer, "the refusal built a second buffer")
    XCTAssertTrue(fileExists(draft.url))
  }

  // MARK: - Save As…

  @MainActor
  func testSaveAsWritesTheDraftToDiskAndRetiresIt() throws {
    let folder = try makeTemporaryFolder()
    let targetURL = folder.appendingPathComponent("recovered.md")
    let store = try makeRecoveryStore(in: folder)
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: store,
      savePanelURLProvider: { _ in targetURL })
    let draft = try seedDraft(in: store, text: "recovered body", ageInDays: 0)

    XCTAssertTrue(documentStore.saveRecoveredDraftAs(draft, into: AppState()))

    XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "recovered body")
    XCTAssertFalse(fileExists(draft.url), "the draft outlived a successful Save As…")
    XCTAssertTrue(store.loadDrafts().isEmpty)
  }

  @MainActor
  func testCancellingTheSavePanelKeepsTheDraft() throws {
    let folder = try makeTemporaryFolder()
    let store = try makeRecoveryStore(in: folder)
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: store,
      savePanelURLProvider: { _ in nil })
    let draft = try seedDraft(in: store, text: "recovered body", ageInDays: 0)

    XCTAssertFalse(documentStore.saveRecoveredDraftAs(draft, into: AppState()))

    XCTAssertTrue(fileExists(draft.url), "Cancel dropped the draft")
    XCTAssertEqual(store.loadDrafts().map(\.text), ["recovered body"])
  }

  /// Save As… on a draft this window already adopted goes through the ordinary
  /// document save: the window ends up showing a real file, not a draft.
  @MainActor
  func testSaveAsOnAnAdoptedDraftTurnsTheWindowIntoAFileBackedDocument() throws {
    let folder = try makeTemporaryFolder()
    let targetURL = folder.appendingPathComponent("adopted.md")
    let store = try makeRecoveryStore(in: folder)
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: store,
      savePanelURLProvider: { _ in targetURL })
    let draft = try seedDraft(in: store, text: "adopted body", ageInDays: 0)
    let appState = AppState()
    XCTAssertTrue(documentStore.openRecoveredDraft(draft, into: appState))

    XCTAssertTrue(documentStore.saveRecoveredDraftAs(draft, into: appState))

    XCTAssertEqual(
      appState.documentSession.url?.standardizedFileURL, targetURL.standardizedFileURL)
    XCTAssertFalse(appState.documentSession.isDirty)
    XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "adopted body")
    XCTAssertFalse(fileExists(draft.url))
  }

  // MARK: - Discard

  /// Discard is now one of only three things that may retire a draft, so it is
  /// also the only place the two-file invariant can still be broken: a draft is
  /// its `.md` AND its `.title` sidecar, and removing only the first leaves an
  /// orphan the directory listing (which reads `.md` only) can never show and
  /// nothing ever collects.
  @MainActor
  func testDiscardDeletesTheDraftAndItsSidecarOnlyAfterConfirmation() throws {
    let folder = try makeTemporaryFolder()
    let store = try makeRecoveryStore(in: folder)
    let draft = try seedDraft(in: store, text: "throwaway", ageInDays: 0)
    let recoveryDirectory = draft.url.deletingLastPathComponent()
    let sidecars = {
      try FileManager.default.contentsOfDirectory(atPath: recoveryDirectory.path)
        .filter { $0.hasSuffix(".title") }
    }

    let refusing = makeController(in: folder, recoveryStore: store, confirmsDiscard: false)
    XCTAssertFalse(refusing.discardRecoveredDraft(draft))
    XCTAssertTrue(fileExists(draft.url), "Cancel on the discard alert still deleted the draft")
    XCTAssertEqual(try sidecars(), ["\(draft.id.uuidString).title"])

    let accepting = makeController(in: folder, recoveryStore: store, confirmsDiscard: true)
    XCTAssertTrue(accepting.discardRecoveredDraft(draft))
    XCTAssertFalse(fileExists(draft.url), "a confirmed discard left the draft on disk")
    XCTAssertTrue(accepting.recoveredDrafts.isEmpty)
    XCTAssertEqual(
      try sidecars(), [], "the discarded draft left its title sidecar behind as an orphan")
  }

  // MARK: - One buffer, one draft identity

  /// The live defect, at its smallest: ONE buffer persisted twice must land in
  /// ONE draft file. Nothing sweeps the recovery directory any more, so a writer
  /// that mints a fresh UUID per write does not merely churn — it grows the
  /// directory without bound (the operator's build 636 accumulated 95 byte-identical
  /// drafts of a single document).
  ///
  /// The untitled autosave path is the control half of the root cause: it always
  /// wrote its ID back into the session, so it converged.
  @MainActor
  func testTwoAutosaveTicksOnOneUntitledBufferWriteOneDraft() async throws {
    let folder = try makeTemporaryFolder()
    let store = try makeRecoveryStore(in: folder)
    let appState = AppState()
    let documentStore = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 60),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: store)
    appState.documentSession.createUntitled(title: "Untitled.md")

    appState.activeDocumentText = "# Umowa"
    documentStore.documentDidChange(appState: appState)
    try await waitUntilDrafts(in: store, contain: "# Umowa")
    let firstID = try XCTUnwrap(store.loadDrafts().first?.id)

    appState.activeDocumentText = "# Umowa\n\npara 1"
    documentStore.documentDidChange(appState: appState)
    try await waitUntilDrafts(in: store, contain: "# Umowa\n\npara 1")

    XCTAssertEqual(
      store.loadDrafts().map(\.id), [firstID],
      "a second autosave tick on the same buffer wrote a second draft file")
    XCTAssertEqual(appState.documentSession.recoveryID, firstID)
  }

  /// ROOT CAUSE. `recoveryID` used to live inside `DocumentSession.Kind.untitled`,
  /// so for a FILE-BACKED buffer the getter answered `nil` and the setter was a
  /// no-op. `stashClosingBufferAsRecoveryDraft` — the teardown path taken by every
  /// dirty file-backed buffer whose window dies without reaching disk (auto-save
  /// off, or a save that failed) — read `nil`, minted a fresh UUID, and threw the
  /// write-back away. Every close of the same document therefore produced ANOTHER
  /// draft file of the same text.
  @MainActor
  func testRepeatedTeardownStashesOfOneFileBackedBufferKeepOneDraft() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("umowa.md")
    try "".write(to: noteURL, atomically: true, encoding: .utf8)
    let store = try makeRecoveryStore(in: folder)
    let appState = AppState()
    let documentStore = makeTestDocumentStore(
      // Long enough that only the explicit teardown flush can persist anything.
      autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: store,
      savingSettings: makeAutoSaveSettings(enabled: false))
    appState.documentSession.load(
      document: DocumentRef(id: noteURL.standardizedFileURL), text: "")
    appState.activeDocumentText = "# Umowa"
    appState.documentSession.isDirty = true

    XCTAssertTrue(documentStore.savePendingChangesOnClose(appState: appState))
    let firstID = try XCTUnwrap(store.loadDrafts().first?.id)
    // The buffer is still dirty (nothing reached the file), so the next teardown
    // pass over the same session — a second window on the file, the quit flush
    // after a window close — stashes it again.
    XCTAssertTrue(documentStore.savePendingChangesOnClose(appState: appState))

    XCTAssertEqual(
      store.loadDrafts().map(\.id), [firstID],
      "the second stash of the same buffer minted a new draft UUID")
    XCTAssertEqual(store.loadDrafts().map(\.text), ["# Umowa"])
    XCTAssertEqual(
      appState.documentSession.recoveryID, firstID,
      "the stash did not record which draft this buffer owns")
  }

  /// Control: identity, not content, is what dedups. Two buffers that happen to
  /// hold the same text are two different pieces of work and keep two drafts.
  @MainActor
  func testTwoDifferentBuffersKeepTwoDraftsEvenWithIdenticalText() throws {
    let folder = try makeTemporaryFolder()
    let store = try makeRecoveryStore(in: folder)
    let documentStore = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: store,
      savingSettings: makeAutoSaveSettings(enabled: false))

    let first = AppState()
    first.documentSession.createUntitled(title: "Untitled.md")
    first.activeDocumentText = "# Umowa"
    first.documentSession.isDirty = true
    XCTAssertTrue(documentStore.savePendingChangesOnClose(appState: first))

    let second = AppState()
    second.documentSession.createUntitled(title: "Untitled 2.md")
    second.activeDocumentText = "# Umowa"
    second.documentSession.isDirty = true
    XCTAssertTrue(documentStore.savePendingChangesOnClose(appState: second))

    XCTAssertEqual(
      Set(store.loadDrafts().map(\.id)).count, 2,
      "two independent buffers were collapsed into one draft")
    XCTAssertNotEqual(first.documentSession.recoveryID, second.documentSession.recoveryID)
  }

  /// The SEVERING half of the same rule, and the reason the association is safe
  /// to keep across stashes: it is dropped the moment the buffer's IDENTITY
  /// changes. `createUntitled` replaces the buffer with a brand new document, so
  /// the draft the previous one wrote stays behind untouched and the next stash
  /// mints its OWN — a new document must not overwrite work the user has not
  /// decided about yet.
  @MainActor
  func testANewUntitledBufferDoesNotInheritTheDraftTheReplacedOneWrote() throws {
    let folder = try makeTemporaryFolder()
    let store = try makeRecoveryStore(in: folder)
    let appState = AppState()
    let documentStore = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: store,
      savingSettings: makeAutoSaveSettings(enabled: false))
    appState.documentSession.createUntitled(title: "Umowa.md")
    appState.activeDocumentText = "# Umowa"
    appState.documentSession.isDirty = true
    XCTAssertTrue(documentStore.savePendingChangesOnClose(appState: appState))
    let stashed = try XCTUnwrap(store.loadDrafts().first)
    XCTAssertEqual(appState.documentSession.recoveryID, stashed.id)

    appState.documentSession.createUntitled(title: "Untitled 2.md")

    XCTAssertNil(
      appState.documentSession.recoveryID,
      "a brand new buffer inherited the draft the buffer it replaced owns")
    appState.activeDocumentText = "# Aneks"
    appState.documentSession.isDirty = true
    XCTAssertTrue(documentStore.savePendingChangesOnClose(appState: appState))

    XCTAssertEqual(
      Set(store.loadDrafts().map(\.id)).count, 2,
      "the new buffer's stash overwrote the draft of the work it replaced")
    XCTAssertEqual(
      store.loadDrafts().first(where: { $0.id == stashed.id })?.text, "# Umowa",
      "the replaced buffer's draft was rewritten with text that is not its own")
  }

  /// A stash is recoverable work only until the work is safely on disk. Now that a
  /// file-backed buffer keeps its draft across closes, the save that publishes the
  /// same bytes has to retire it — otherwise the launcher would offer content the
  /// user already saved, forever, since nothing sweeps drafts.
  @MainActor
  func testSavingTheFileRetiresTheDraftItWasStashedInto() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("umowa.md")
    try "".write(to: noteURL, atomically: true, encoding: .utf8)
    let store = try makeRecoveryStore(in: folder)
    let appState = AppState()
    let documentStore = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: store,
      savingSettings: makeAutoSaveSettings(enabled: false))
    appState.documentSession.load(
      document: DocumentRef(id: noteURL.standardizedFileURL), text: "")
    appState.activeDocumentText = "# Umowa"
    appState.documentSession.isDirty = true
    XCTAssertTrue(documentStore.savePendingChangesOnClose(appState: appState))
    let stashed = try XCTUnwrap(store.loadDrafts().first)

    documentStore.save(appState: appState)

    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "# Umowa")
    XCTAssertFalse(
      fileExists(stashed.url), "the draft outlived the save that made it redundant")
    XCTAssertTrue(store.loadDrafts().isEmpty)
    XCTAssertNil(appState.documentSession.recoveryID)
  }

  // MARK: - Launcher model

  @MainActor
  func testRefreshPublishesUnhandledDraftsNewestFirst() throws {
    let folder = try makeTemporaryFolder()
    let store = try makeRecoveryStore(in: folder)
    _ = try seedDraft(in: store, text: "older", ageInDays: 3)
    _ = try seedDraft(in: store, text: "newer", ageInDays: 1)
    let controller = makeController(in: folder, recoveryStore: store, confirmsDiscard: false)

    controller.refreshRecoveredDrafts()

    XCTAssertEqual(controller.recoveredDrafts.map(\.text), ["newer", "older"])
  }

  func testPreviewSnippetSummarizesTheFirstMeaningfulLine() {
    let draft = RecoveryDraft(
      id: UUID(),
      url: URL(fileURLWithPath: "/tmp/draft.md"),
      title: "Recovered Untitled.md",
      text: "\n\n  # Meeting notes  \nbody\n",
      updatedAt: Date())
    XCTAssertEqual(draft.previewSnippet, "# Meeting notes")

    let blank = RecoveryDraft(
      id: UUID(),
      url: URL(fileURLWithPath: "/tmp/blank.md"),
      title: "Recovered Untitled.md",
      text: "   \n\n",
      updatedAt: Date())
    XCTAssertEqual(blank.previewSnippet, "Empty draft")
  }

  // MARK: - Helpers

  private func fileExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  /// Waits for the debounced autosave to land `text` in the recovery store.
  private func waitUntilDrafts(
    in store: RecoveryStore,
    contain text: String,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if store.loadDrafts().contains(where: { $0.text == text }) { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("no recovery draft holding \(text.debugDescription)", file: file, line: line)
  }

  /// Waits for the ONE draft an asynchronous path is expected to persist. Polls
  /// instead of sleeping a fixed amount, so a correct build waits only as long as
  /// the conversion actually takes.
  private func waitForSingleDraft(
    in store: RecoveryStore,
    timeout: TimeInterval = 10,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws -> RecoveryDraft {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let draft = store.loadDrafts().first { return draft }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("no recovery draft was persisted", file: file, line: line)
    throw XCTSkip("no recovery draft was persisted")
  }

  /// A one-page PDF with a real text layer, mirroring `DocumentTransferTests`'
  /// fixture: the import path only accepts `.docx`/`.pdf`, so a pin on what an
  /// import leaves behind needs a document that genuinely converts.
  private func makeTextPDF(_ text: String) throws -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
      throw CocoaError(.fileWriteUnknown)
    }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    context.beginPDFPage(nil)
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)]))
    context.textPosition = CGPoint(x: 72, y: 720)
    CTLineDraw(line, context)
    context.endPDFPage()
    context.closePDF()
    return data as Data
  }

  private func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveRecoveredDrafts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: folder)
    }
    return folder
  }

  private func makeRecoveryStore(in folder: URL? = nil) throws -> RecoveryStore {
    let root = try folder ?? makeTemporaryFolder()
    return RecoveryStore(directoryURL: root.appendingPathComponent("Recovery", isDirectory: true))
  }

  /// Seeds one draft with an explicit age. Ages are set on the file itself, so
  /// the age assertions run against the same modification dates production
  /// reads. `keepOpen` leaves the write-time claim in place (a window editing
  /// the draft); otherwise the claim is released, which is the state a draft
  /// left behind by a crash is actually in.
  @discardableResult
  private func seedDraft(
    in store: RecoveryStore,
    text: String,
    ageInDays: Double,
    keepOpen: Bool = false
  ) throws -> RecoveryDraft {
    let draft = try store.saveDraft(id: nil, title: "Untitled.md", text: text)
    if !keepOpen {
      store.markDraftClosed(id: draft.id)
    }
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-ageInDays * 86_400)],
      ofItemAtPath: draft.url.path)
    return draft
  }

  @MainActor
  private func makeController(
    in folder: URL,
    recoveryStore: RecoveryStore,
    confirmsDiscard: Bool
  ) -> AppController {
    let indexDatabase = temporaryIndexDatabase(in: folder)
    return AppController(
      appState: AppState(),
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(in: folder), indexDatabase: indexDatabase),
      documentStore: makeTestDocumentStore(
        indexDatabase: indexDatabase, recoveryStore: recoveryStore),
      indexDatabase: indexDatabase,
      confirmDiscardDraft: { _ in confirmsDiscard }
    )
  }

  private func temporaryMetadataStore(in folder: URL) -> WorkspaceMetadataStore {
    WorkspaceMetadataStore(
      metadataURL: folder.appendingPathComponent("workspace.json", isDirectory: false))
  }

  @MainActor
  private func temporaryIndexDatabase(in folder: URL) -> IndexDatabase {
    IndexDatabase(databaseURL: folder.appendingPathComponent("index.db", isDirectory: false))
  }
}
