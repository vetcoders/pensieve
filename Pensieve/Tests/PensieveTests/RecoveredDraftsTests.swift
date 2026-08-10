import AppKit
import CoreText
import XCTest

@testable import Pensieve

final class RecoveredDraftsPaginationTests: XCTestCase {
  func testAFullPageContainsFiveDrafts() {
    let pagination = RecoveredDraftsPagination(itemCount: 146, requestedPageIndex: 0)

    XCTAssertEqual(pagination.pageCount, 30)
    XCTAssertEqual(pagination.itemRange, 0..<5)
    XCTAssertEqual(pagination.itemRangeLabel, "1–5 of 146")
  }

  func testTheLastPageContainsTheRemainder() {
    let pagination = RecoveredDraftsPagination(itemCount: 146, requestedPageIndex: 29)

    XCTAssertEqual(pagination.itemRange, 145..<146)
    XCTAssertEqual(pagination.itemRangeLabel, "146–146 of 146")
  }

  func testARequestedPageIsClampedAfterDraftsAreRemoved() {
    let pagination = RecoveredDraftsPagination(itemCount: 4, requestedPageIndex: 29)

    XCTAssertEqual(pagination.pageIndex, 0)
    XCTAssertEqual(pagination.pageCount, 1)
    XCTAssertEqual(pagination.itemRange, 0..<4)
  }

  func testAnEmptyCollectionHasNoPagesOrRange() {
    let pagination = RecoveredDraftsPagination(itemCount: 0, requestedPageIndex: 3)

    XCTAssertEqual(pagination.pageIndex, 0)
    XCTAssertEqual(pagination.pageCount, 0)
    XCTAssertTrue(pagination.itemRange.isEmpty)
    XCTAssertEqual(pagination.itemRangeLabel, "0 of 0")
  }
}

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
  func testFileBackedRecoveryMetadataSurvivesReloadAndMakesTheEntryUnambiguous() throws {
    let folder = try makeTemporaryFolder()
    let sourceURL = folder.appendingPathComponent("umowa.md")
    let store = try makeRecoveryStore(in: folder)
    let saved = try store.saveDraft(
      id: nil,
      title: "umowa.md",
      text: "unsaved revision",
      sourceURL: sourceURL)
    store.markDraftClosed(id: saved.id)

    let reloadedStore = RecoveryStore(directoryURL: folder.appendingPathComponent("Recovery"))
    let reloaded = try XCTUnwrap(reloadedStore.loadDrafts().first)

    XCTAssertEqual(reloaded.id, saved.id)
    XCTAssertEqual(reloaded.sourceURL, sourceURL.standardizedFileURL)
    XCTAssertEqual(reloaded.displayTitle, "Unsaved changes — umowa.md")
    XCTAssertEqual(reloaded.text, "unsaved revision")
  }

  @MainActor
  func testAFileBackedRecoveryIsNotDiscoverableWhenItsSourceMetadataCannotBeWritten() throws {
    let folder = try makeTemporaryFolder()
    let recoveryDirectory = folder.appendingPathComponent("Recovery", isDirectory: true)
    try FileManager.default.createDirectory(
      at: recoveryDirectory, withIntermediateDirectories: true)
    let id = UUID()
    // A non-empty directory at the exact sidecar path makes the required atomic
    // metadata write fail while the recovery directory itself remains writable.
    let blockedSidecar = recoveryDirectory.appendingPathComponent(id.uuidString + ".source")
    try FileManager.default.createDirectory(
      at: blockedSidecar,
      withIntermediateDirectories: false)
    try Data("occupied".utf8).write(to: blockedSidecar.appendingPathComponent("blocker"))
    let store = RecoveryStore(directoryURL: recoveryDirectory)

    XCTAssertThrowsError(
      try store.saveDraft(
        id: id,
        title: "umowa.md",
        text: "must not become an ambiguous ghost",
        sourceURL: folder.appendingPathComponent("umowa.md")))

    XCTAssertTrue(
      store.loadDrafts().isEmpty,
      "a file-backed recovery became visible without the metadata that identifies its original")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: recoveryDirectory.appendingPathComponent(id.uuidString + ".md").path))
  }

  @MainActor
  func testOpeningFileBackedRecoveryNeverOverwritesTheOriginalUntilSave() throws {
    let folder = try makeTemporaryFolder()
    let sourceURL = folder.appendingPathComponent("umowa.md")
    try "original on disk".write(to: sourceURL, atomically: true, encoding: .utf8)
    let store = try makeRecoveryStore(in: folder)
    let draft = try store.saveDraft(
      id: nil,
      title: "umowa.md",
      text: "recovered unsaved revision",
      sourceURL: sourceURL)
    store.markDraftClosed(id: draft.id)
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder), recoveryStore: store)
    let appState = AppState()

    XCTAssertTrue(documentStore.openRecoveredDraft(draft, into: appState))

    XCTAssertTrue(appState.documentSession.isUntitled)
    XCTAssertTrue(appState.documentSession.isDirty)
    XCTAssertEqual(appState.documentSession.recoverySourceURL, sourceURL.standardizedFileURL)
    XCTAssertEqual(appState.documentSession.displayTitle, "Unsaved changes — umowa.md")
    XCTAssertEqual(
      documentStore.closeDecision(appState: appState),
      .confirm(.saveRecoveredFile))
    XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "original on disk")
  }

  @MainActor
  func testSaveToOriginalFromRecoveredBufferIsExplicitAndRetiresRecovery() throws {
    let folder = try makeTemporaryFolder()
    let sourceURL = folder.appendingPathComponent("umowa.md")
    try "original on disk".write(to: sourceURL, atomically: true, encoding: .utf8)
    let store = try makeRecoveryStore(in: folder)
    let draft = try store.saveDraft(
      id: nil,
      title: "umowa.md",
      text: "recovered unsaved revision",
      sourceURL: sourceURL)
    store.markDraftClosed(id: draft.id)
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder), recoveryStore: store)
    let appState = AppState()
    XCTAssertTrue(documentStore.openRecoveredDraft(draft, into: appState))

    XCTAssertTrue(
      documentStore.finishClose(
        decision: .confirm(.saveRecoveredFile),
        response: .save,
        appState: appState))

    XCTAssertEqual(
      try String(contentsOf: sourceURL, encoding: .utf8), "recovered unsaved revision")
    XCTAssertTrue(store.loadDrafts().isEmpty)
    XCTAssertFalse(appState.documentSession.hasEditableBuffer)
  }

  @MainActor
  func testFailedCmdSSaveToOriginalRefreshesTheSameDraftAndLaterSuccessRetiresIt()
    async throws
  {
    let folder = try makeTemporaryFolder()
    let sourceURL = folder.appendingPathComponent("umowa.md")
    try "original on disk".write(to: sourceURL, atomically: true, encoding: .utf8)
    let recoveryStore = try makeRecoveryStore(in: folder)
    let draft = try recoveryStore.saveDraft(
      id: nil,
      title: "umowa.md",
      text: "recovered revision",
      sourceURL: sourceURL)
    recoveryStore.markDraftClosed(id: draft.id)
    var originalWriteShouldFail = true
    let documentStore = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 20, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore,
      writeDocument: { text, url in
        if originalWriteShouldFail {
          throw CocoaError(.fileWriteNoPermission)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
      })
    let appState = AppState()
    XCTAssertTrue(documentStore.openRecoveredDraft(draft, into: appState))
    appState.activeDocumentText = "latest recovered edit"
    appState.activeDocumentDirty = true

    documentStore.save(appState: appState)

    let draftsAfterFailedSave = recoveryStore.loadDrafts()
    XCTAssertEqual(draftsAfterFailedSave.count, 1)
    let refreshedDraft = try XCTUnwrap(draftsAfterFailedSave.first)
    XCTAssertEqual(refreshedDraft.id, draft.id)
    XCTAssertEqual(refreshedDraft.text, "latest recovered edit")
    XCTAssertEqual(refreshedDraft.sourceURL, sourceURL.standardizedFileURL)
    XCTAssertEqual(appState.documentSession.recoveryID, draft.id)
    XCTAssertEqual(appState.documentSession.recoverySourceURL, sourceURL.standardizedFileURL)
    XCTAssertTrue(appState.documentSession.isDirty)
    XCTAssertNil(appState.unresolvedDataLoss)
    XCTAssertTrue(appState.currentError?.message.contains("recovery copy is safe") == true)
    XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "original on disk")

    appState.activeDocumentText = "newest edit after failed original save"
    documentStore.documentDidChange(appState: appState)
    try await waitUntilDrafts(
      in: recoveryStore,
      contain: "newest edit after failed original save")

    let draftsAfterRecoveryTick = recoveryStore.loadDrafts()
    XCTAssertEqual(draftsAfterRecoveryTick.count, 1)
    let tickDraft = try XCTUnwrap(draftsAfterRecoveryTick.first)
    XCTAssertEqual(tickDraft.id, draft.id)
    XCTAssertEqual(tickDraft.sourceURL, sourceURL.standardizedFileURL)
    XCTAssertEqual(appState.documentSession.recoveryID, draft.id)
    XCTAssertEqual(appState.documentSession.recoverySourceURL, sourceURL.standardizedFileURL)
    XCTAssertTrue(appState.documentSession.isDirty)
    XCTAssertNil(appState.unresolvedDataLoss)
    XCTAssertTrue(appState.currentError?.message.contains("Could not save umowa.md") == true)
    XCTAssertTrue(appState.currentError?.message.contains("recovery copy is safe") == true)
    XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "original on disk")

    originalWriteShouldFail = false
    documentStore.save(appState: appState)

    XCTAssertEqual(
      try String(contentsOf: sourceURL, encoding: .utf8),
      "newest edit after failed original save")
    XCTAssertTrue(recoveryStore.loadDrafts().isEmpty)
    XCTAssertEqual(appState.documentSession.url, sourceURL.standardizedFileURL)
    XCTAssertNil(appState.documentSession.recoveryID)
    XCTAssertNil(appState.documentSession.recoverySourceURL)
    XCTAssertFalse(appState.documentSession.isDirty)
    XCTAssertNil(appState.currentError)
  }

  @MainActor
  func testCloseVetoesFailedSaveToOriginalAfterRefreshingTheSameDraft() throws {
    let folder = try makeTemporaryFolder()
    let sourceURL = folder.appendingPathComponent("close-original.md")
    try "original on disk".write(to: sourceURL, atomically: true, encoding: .utf8)
    let recoveryStore = try makeRecoveryStore(in: folder)
    let draft = try recoveryStore.saveDraft(
      id: nil,
      title: "close-original.md",
      text: "recovered revision",
      sourceURL: sourceURL)
    recoveryStore.markDraftClosed(id: draft.id)
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: recoveryStore,
      writeDocument: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    let appState = AppState()
    XCTAssertTrue(documentStore.openRecoveredDraft(draft, into: appState))
    appState.activeDocumentText = "latest edit before close"
    appState.activeDocumentDirty = true

    XCTAssertFalse(
      documentStore.finishClose(
        decision: .confirm(.saveRecoveredFile),
        response: .save,
        appState: appState))

    let draftsAfterFailedClose = recoveryStore.loadDrafts()
    XCTAssertEqual(draftsAfterFailedClose.count, 1)
    let refreshedDraft = try XCTUnwrap(draftsAfterFailedClose.first)
    XCTAssertEqual(refreshedDraft.id, draft.id)
    XCTAssertEqual(refreshedDraft.text, "latest edit before close")
    XCTAssertEqual(refreshedDraft.sourceURL, sourceURL.standardizedFileURL)
    XCTAssertEqual(appState.documentSession.recoveryID, draft.id)
    XCTAssertEqual(appState.documentSession.recoverySourceURL, sourceURL.standardizedFileURL)
    XCTAssertTrue(appState.documentSession.isDirty)
    XCTAssertTrue(appState.currentError?.message.contains("recovery copy is safe") == true)
    XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "original on disk")
  }

  @MainActor
  func testQuitVetoesFailedSaveToOriginalAfterRefreshingTheSameDraft() throws {
    let folder = try makeTemporaryFolder()
    let sourceURL = folder.appendingPathComponent("quit-original.md")
    try "original on disk".write(to: sourceURL, atomically: true, encoding: .utf8)
    let recoveryStore = try makeRecoveryStore(in: folder)
    let draft = try recoveryStore.saveDraft(
      id: nil,
      title: "quit-original.md",
      text: "recovered revision",
      sourceURL: sourceURL)
    recoveryStore.markDraftClosed(id: draft.id)
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let documentStore = makeTestDocumentStore(
      indexDatabase: indexDatabase,
      recoveryStore: recoveryStore,
      writeDocument: { _, _ in throw CocoaError(.fileWriteNoPermission) },
      dirtySessionPrompt: { _ in .save })
    let appState = AppState()
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(in: folder), indexDatabase: indexDatabase),
      documentStore: documentStore,
      indexDatabase: indexDatabase,
      documentWindowRegistry: DocumentWindowRegistry(canMutateWindowTabs: { true }))
    XCTAssertTrue(documentStore.openRecoveredDraft(draft, into: appState))
    appState.activeDocumentText = "latest edit before quit"
    appState.activeDocumentDirty = true

    XCTAssertFalse(controller.applicationShouldTerminate())

    let draftsAfterFailedQuit = recoveryStore.loadDrafts()
    XCTAssertEqual(draftsAfterFailedQuit.count, 1)
    let refreshedDraft = try XCTUnwrap(draftsAfterFailedQuit.first)
    XCTAssertEqual(refreshedDraft.id, draft.id)
    XCTAssertEqual(refreshedDraft.text, "latest edit before quit")
    XCTAssertEqual(refreshedDraft.sourceURL, sourceURL.standardizedFileURL)
    XCTAssertEqual(appState.documentSession.recoveryID, draft.id)
    XCTAssertEqual(appState.documentSession.recoverySourceURL, sourceURL.standardizedFileURL)
    XCTAssertTrue(appState.documentSession.isDirty)
    XCTAssertTrue(appState.currentError?.message.contains("recovery copy is safe") == true)
    XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), "original on disk")
  }

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

    XCTAssertNotNil(documentStore.saveRecoveredDraftAs(draft, into: adopting))
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

  // MARK: - A failed draft write is never reported as a success

  // These drive the teardown backstop directly on a live `AppState`: they pin
  // the truthful return value and buffer state after a failed write. Real red-X
  // and quit flows consume the same result earlier, at their veto point; the
  // controller-level pins live in `DocumentCloseLifecycleTests` and the quit
  // lifecycle tests.

  /// P0. The old recovery writer caught its error, set `appState.lastError` and
  /// returned NOTHING, and the untitled branch of `savePendingChangesOnClose`
  /// answered `true` regardless. The one caller whose buffer SURVIVES that flush —
  /// `importDocument` — read that `true` as "the work is safe" and cleared the
  /// error on top of it. The flush now reports the write it actually made.
  @MainActor
  func testACloseFlushReportsAFailedUntitledDraftWriteInsteadOfSuccess() throws {
    let folder = try makeTemporaryFolder()
    let store = try makeUnwritableRecoveryStore(in: folder)
    let documentStore = makeTestDocumentStore(
      // Long enough that only this explicit flush can persist anything.
      autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: store)
    let appState = AppState()
    appState.documentSession.restoreUntitled(
      title: "Board Resolution.md", text: "# Prokurent\n\napproval required", recoveryID: UUID())

    XCTAssertFalse(
      documentStore.savePendingChangesOnClose(appState: appState, releasesDraftClaim: false),
      "a draft write that failed was reported as work persisted")

    XCTAssertNotNil(appState.lastError, "the write failure was not surfaced")
    XCTAssertTrue(
      appState.documentSession.hasEditableBuffer,
      "the buffer holding the only copy of the text was torn down")
    XCTAssertTrue(appState.documentSession.isDirty, "the buffer was marked clean over unsaved text")
    XCTAssertEqual(appState.documentSession.text, "# Prokurent\n\napproval required")
    XCTAssertTrue(store.loadDrafts().isEmpty, "a draft was advertised that is not on disk")
  }

  /// The same report for the FILE-BACKED half: this branch is reached precisely
  /// because the file on disk is stale (auto-save off, or a save that threw), so a
  /// stash that fails leaves the edit in memory only.
  @MainActor
  func testACloseFlushReportsAFailedStashOfAFileBackedBuffer() throws {
    let folder = try makeTemporaryFolder()
    let noteURL = folder.appendingPathComponent("umowa.md")
    try "on disk".write(to: noteURL, atomically: true, encoding: .utf8)
    let store = try makeUnwritableRecoveryStore(in: folder)
    let documentStore = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: store,
      savingSettings: makeAutoSaveSettings(enabled: false))
    let appState = AppState()
    appState.documentSession.load(
      document: DocumentRef(id: noteURL.standardizedFileURL), text: "on disk")
    appState.activeDocumentText = "edited but never told to save"
    appState.documentSession.isDirty = true

    XCTAssertFalse(
      documentStore.savePendingChangesOnClose(appState: appState),
      "a stash that failed was reported as work persisted")

    XCTAssertNotNil(appState.lastError)
    XCTAssertEqual(
      try String(contentsOf: noteURL, encoding: .utf8), "on disk",
      "the failed stash wrote the user's file behind their back")
    XCTAssertTrue(appState.documentSession.isDirty)
    XCTAssertTrue(store.loadDrafts().isEmpty)
  }

  /// The user-facing shape of the same defect. A Word/PDF import converts fine and
  /// publishes an untitled buffer; its recovery write then fails, and the import
  /// path cleared `lastError` unconditionally on the next line. The user saw a
  /// successful import with no error and no draft — the conversion existed only in
  /// memory, so a crash before Save As… took it.
  @MainActor
  func testAnImportWhoseRecoveryWriteFailsKeepsTheErrorAndTheBuffer() async throws {
    let folder = try makeTemporaryFolder()
    // A real PDF: `importMarkdown` rejects anything that is not `.docx`/`.pdf`,
    // and a rejected conversion would make this test pass for the wrong reason.
    let sourceURL = folder.appendingPathComponent("Board Resolution.pdf")
    try makeTextPDF("Prokurent approval is required.").write(to: sourceURL, options: .atomic)
    let store = try makeUnwritableRecoveryStore(in: folder)
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let documentStore = makeTestDocumentStore(
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
    try await waitForPublishedImportBuffer(in: appState)

    // 1) the conversion itself succeeded — the text is in the buffer…
    XCTAssertTrue(appState.documentSession.text.contains("Prokurent"))
    // 2) …3) …and the failed draft write is visible rather than cleared.
    XCTAssertNotNil(
      appState.lastError,
      "the import cleared the recovery-write failure and looked like a success")
    XCTAssertTrue(
      try XCTUnwrap(appState.lastError).contains("Board Resolution.pdf"),
      "the message does not say WHICH converted text has no safe copy")
    // 4) the buffer stays open and dirty, so the work is still reachable…
    XCTAssertTrue(appState.documentSession.hasEditableBuffer)
    XCTAssertTrue(appState.documentSession.isDirty)
    // 5) …and nothing pretends a draft exists.
    XCTAssertTrue(store.loadDrafts().isEmpty)
    XCTAssertTrue(documentStore.recoveredDrafts().isEmpty)
  }

  /// The same failure, followed one step further: it now reaches the operator.
  ///
  /// 45.1 made the failed import RECORD its error; the field it recorded into
  /// had no renderer, so nothing said it out loud. This pins the whole chain on
  /// the real production path — convert, fail to write the draft, and end up
  /// with a window showing a standing banner for an unresolved loss, because
  /// the converted text exists in exactly one place and that place is volatile.
  ///
  /// The severity matters as much as the message: `importDocument` composes its
  /// own sentence on top of the write error, and doing that through a plain
  /// `lastError` assignment would silently demote the failure to a passive
  /// notice on the way.
  @MainActor
  func testAnImportWhoseRecoveryWriteFailsSurfacesAsDataLoss() async throws {
    let folder = try makeTemporaryFolder()
    let sourceURL = folder.appendingPathComponent("Board Resolution.pdf")
    try makeTextPDF("Prokurent approval is required.").write(to: sourceURL, options: .atomic)
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let documentStore = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
      indexDatabase: indexDatabase,
      recoveryStore: try makeUnwritableRecoveryStore(in: folder))
    let appState = AppState()
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(in: folder), indexDatabase: indexDatabase),
      documentStore: documentStore,
      indexDatabase: indexDatabase)

    controller.importDocument(url: sourceURL)
    try await waitForPublishedImportBuffer(in: appState)

    XCTAssertEqual(
      appState.currentError?.severity, .dataLoss,
      "the only copy of the converted text is the buffer, and the window filed that as routine")
    XCTAssertTrue(
      WindowErrorSurface.resolve(for: appState.currentError).showsBanner,
      "the failed import left the window with nothing to show")
    let latched = try XCTUnwrap(
      appState.unresolvedDataLoss, "the failed import latched no unresolved loss")
    XCTAssertTrue(
      latched.message.contains("Board Resolution.pdf"),
      "the report does not say WHICH converted text has no safe copy: \(latched.message)")
  }

  /// Control: with a writable recovery directory the import path is unchanged —
  /// the draft lands, the error is cleared, and the buffer keeps its claim.
  @MainActor
  func testAnImportWhoseRecoveryWriteSucceedsClearsTheError() async throws {
    let folder = try makeTemporaryFolder()
    let sourceURL = folder.appendingPathComponent("Board Resolution.pdf")
    try makeTextPDF("Prokurent approval is required.").write(to: sourceURL, options: .atomic)
    let store = try makeRecoveryStore(in: folder)
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let documentStore = makeTestDocumentStore(
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

    XCTAssertNil(appState.lastError, "a successful import left an error on screen")
    XCTAssertEqual(appState.documentSession.recoveryID, draft.id)
    XCTAssertTrue(appState.documentSession.isDirty)
    XCTAssertTrue(
      documentStore.recoveredDrafts().isEmpty,
      "the live import buffer's draft was released to the launcher")
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

    XCTAssertNotNil(documentStore.saveRecoveredDraftAs(draft, into: AppState()))

    XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "recovered body")
    XCTAssertFalse(fileExists(draft.url), "the draft outlived a successful Save As…")
    XCTAssertTrue(store.loadDrafts().isEmpty)
  }

  @MainActor
  func testLauncherSaveAsRegistersWorkingSetWithoutOpeningTheSavedFile() throws {
    let folder = try makeTemporaryFolder()
    let targetURL = folder.appendingPathComponent("recovered-working-set.md")
    let store = try makeRecoveryStore(in: folder)
    let defaults = makeEphemeralDefaults(prefix: "PensieveRecoveredDraftSaveAs")
    let bookmarkStore = BookmarkStore(defaults: defaults)
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      bookmarkStore: bookmarkStore,
      recoveryStore: store,
      savePanelURLProvider: { _ in targetURL })
    let draft = try seedDraft(in: store, text: "recovered body", ageInDays: 0)
    let appState = AppState()

    let savedURL = documentStore.saveRecoveredDraftAs(draft, into: appState)

    XCTAssertEqual(savedURL?.standardizedFileURL, targetURL.standardizedFileURL)
    XCTAssertEqual(
      appState.openFiles.map(\.url.standardizedFileURL), [targetURL.standardizedFileURL])
    XCTAssertNil(appState.selectedDocumentID, "launcher Save As selected the saved document")
    XCTAssertFalse(
      appState.documentSession.hasEditableBuffer,
      "launcher Save As adopted the saved document into the empty window")

    let restored = BookmarkStore(defaults: defaults).restoreWorkspace(into: AppState())
    XCTAssertEqual(restored.fileURLs.map(\.standardizedFileURL), [targetURL.standardizedFileURL])
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

    XCTAssertNil(documentStore.saveRecoveredDraftAs(draft, into: AppState()))

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

    XCTAssertNotNil(documentStore.saveRecoveredDraftAs(draft, into: appState))

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

  // MARK: - Claim handoff when a buffer is replaced

  @MainActor
  func testSwitchingAfterRecoveryFallbackReleasesTheAbandonedDraftClaim() throws {
    let folder = try makeTemporaryFolder()
    let originalURL = folder.appendingPathComponent("original.md")
    let nextURL = folder.appendingPathComponent("next.md")
    try "old bytes".write(to: originalURL, atomically: true, encoding: .utf8)
    try "next bytes".write(to: nextURL, atomically: true, encoding: .utf8)
    let store = try makeRecoveryStore(in: folder)
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: store,
      savingSettings: makeAutoSaveSettings(enabled: true),
      replaceExistingDocument: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    let appState = AppState()
    appState.documentSession.load(
      document: DocumentRef(id: originalURL.standardizedFileURL), text: "old bytes")
    appState.activeDocumentText = "edit protected by recovery"
    appState.documentSession.isDirty = true

    documentStore.load(
      ref: DocumentRef(id: nextURL.standardizedFileURL), into: appState)

    let abandoned = try XCTUnwrap(store.loadDrafts().first)
    XCTAssertEqual(appState.documentSession.url, nextURL.standardizedFileURL)
    XCTAssertEqual(appState.activeDocumentText, "next bytes")
    XCTAssertFalse(
      store.isDraftOpen(id: abandoned.id),
      "the replaced buffer kept its recovery claim after it stopped existing")
    XCTAssertEqual(documentStore.recoveredDrafts().map(\.id), [abandoned.id])
  }

  @MainActor
  func testFailedSynchronousSwitchKeepsTheSurvivingBuffersDraftClaimed() throws {
    let folder = try makeTemporaryFolder()
    let originalURL = folder.appendingPathComponent("original.md")
    let missingURL = folder.appendingPathComponent("missing.md")
    try "old bytes".write(to: originalURL, atomically: true, encoding: .utf8)
    let store = try makeRecoveryStore(in: folder)
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: store,
      savingSettings: makeAutoSaveSettings(enabled: true),
      replaceExistingDocument: { _, _ in throw CocoaError(.fileWriteNoPermission) })
    let appState = AppState()
    appState.documentSession.load(
      document: DocumentRef(id: originalURL.standardizedFileURL), text: "old bytes")
    appState.activeDocumentText = "still-live edit"
    appState.documentSession.isDirty = true

    documentStore.load(
      ref: DocumentRef(id: missingURL.standardizedFileURL), into: appState)

    let surviving = try XCTUnwrap(store.loadDrafts().first)
    XCTAssertEqual(appState.documentSession.url, originalURL.standardizedFileURL)
    XCTAssertEqual(appState.activeDocumentText, "still-live edit")
    XCTAssertEqual(appState.documentSession.recoveryID, surviving.id)
    XCTAssertTrue(
      store.isDraftOpen(id: surviving.id),
      "a failed replacement released the claim of the buffer still on screen")
    XCTAssertTrue(documentStore.recoveredDrafts().isEmpty)
  }

  @MainActor
  func testRekeyingALiveBufferPreservesOneRecoveryIdentity() throws {
    let folder = try makeTemporaryFolder()
    let originalURL = folder.appendingPathComponent("before.md")
    let movedURL = folder.appendingPathComponent("after.md")
    try "on disk".write(to: originalURL, atomically: true, encoding: .utf8)
    let store = try makeRecoveryStore(in: folder)
    let documentStore = makeTestDocumentStore(
      autosaver: Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000),
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: store,
      savingSettings: makeAutoSaveSettings(enabled: false))
    let appState = AppState()
    appState.documentSession.load(
      document: DocumentRef(id: originalURL.standardizedFileURL), text: "on disk")
    appState.activeDocumentText = "unsaved edit"
    appState.documentSession.isDirty = true
    XCTAssertTrue(
      documentStore.savePendingChangesOnClose(
        appState: appState, releasesDraftClaim: false))
    let first = try XCTUnwrap(store.loadDrafts().first)

    // Rename/move re-keys this SAME live buffer through the document setter.
    appState.documentSession.document = DocumentRef(id: movedURL.standardizedFileURL)
    XCTAssertEqual(appState.documentSession.recoveryID, first.id)
    XCTAssertTrue(
      documentStore.savePendingChangesOnClose(
        appState: appState, releasesDraftClaim: false))

    let drafts = store.loadDrafts()
    XCTAssertEqual(drafts.map(\.id), [first.id])
    XCTAssertEqual(drafts.first?.sourceURL, movedURL.standardizedFileURL)
    XCTAssertTrue(store.isDraftOpen(id: first.id))
  }

  @MainActor
  func testStaleLauncherCannotSaveAsADraftClaimedByAnotherWindow() throws {
    let folder = try makeTemporaryFolder()
    let targetURL = folder.appendingPathComponent("must-not-exist.md")
    let store = try makeRecoveryStore(in: folder)
    let draft = try seedDraft(
      in: store, text: "live recovered work", ageInDays: 0, keepOpen: true)
    var pickerCalls = 0
    let documentStore = makeTestDocumentStore(
      indexDatabase: temporaryIndexDatabase(in: folder),
      recoveryStore: store,
      savePanelURLProvider: { _ in
        pickerCalls += 1
        return targetURL
      })
    let staleLauncher = AppState()

    XCTAssertNil(documentStore.saveRecoveredDraftAs(draft, into: staleLauncher))

    XCTAssertEqual(pickerCalls, 0, "the stale launcher reached a destructive save panel")
    XCTAssertFalse(fileExists(targetURL))
    XCTAssertTrue(fileExists(draft.url))
    XCTAssertTrue(store.isDraftOpen(id: draft.id))
  }

  @MainActor
  func testStaleLauncherCannotDiscardADraftClaimedByAnotherWindow() throws {
    let store = try makeRecoveryStore()
    let draft = try seedDraft(
      in: store, text: "live recovered work", ageInDays: 0, keepOpen: true)
    let documentStore = makeTestDocumentStore(recoveryStore: store)

    XCTAssertFalse(documentStore.discardRecoveredDraft(draft))

    XCTAssertTrue(fileExists(draft.url))
    XCTAssertTrue(store.isDraftOpen(id: draft.id))
  }

  func testUntitledRewriteFailsClosedWhenAStaleSourceAssociationCannotBeRemoved() throws {
    let folder = try makeTemporaryFolder()
    let recoveryDirectory = folder.appendingPathComponent("Recovery", isDirectory: true)
    let sourceURL = folder.appendingPathComponent("source.md")
    let id = UUID()
    let store = RecoveryStore(
      directoryURL: recoveryDirectory,
      removeItem: { url in
        if url.pathExtension == "source" {
          throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: url)
      })
    _ = try store.saveDraft(
      id: id, title: "Unsaved changes — source.md", text: "old protected text",
      sourceURL: sourceURL)
    store.markDraftClosed(id: id)

    XCTAssertThrowsError(
      try store.saveDraft(id: id, title: "Untitled.md", text: "unrelated untitled text"))

    let surviving = try XCTUnwrap(store.loadDrafts().first)
    XCTAssertEqual(surviving.id, id)
    XCTAssertEqual(surviving.text, "old protected text")
    XCTAssertEqual(surviving.sourceURL, sourceURL.standardizedFileURL)
  }

  func testDeleteDraftFailureKeepsTheVisiblePayloadClaimAndSidecars() throws {
    let folder = try makeTemporaryFolder()
    let recoveryDirectory = folder.appendingPathComponent("Recovery", isDirectory: true)
    let sourceURL = folder.appendingPathComponent("source.md")
    let id = UUID()
    let payloadURL = recoveryDirectory.appendingPathComponent(id.uuidString + ".md")
    let titleURL = recoveryDirectory.appendingPathComponent(id.uuidString + ".title")
    let sourceSidecarURL = recoveryDirectory.appendingPathComponent(id.uuidString + ".source")
    let store = RecoveryStore(
      directoryURL: recoveryDirectory,
      removeItem: { url in
        if url.pathExtension == "md" {
          throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: url)
      })
    _ = try store.saveDraft(
      id: id,
      title: "source.md",
      text: "protected recovery bytes",
      sourceURL: sourceURL)

    XCTAssertTrue(fileExists(payloadURL))
    XCTAssertTrue(fileExists(titleURL))
    XCTAssertTrue(fileExists(sourceSidecarURL))

    XCTAssertFalse(store.deleteDraft(id: id))

    XCTAssertTrue(fileExists(payloadURL))
    XCTAssertTrue(fileExists(titleURL))
    XCTAssertTrue(fileExists(sourceSidecarURL))
    XCTAssertTrue(store.isDraftOpen(id: id))
    XCTAssertEqual(store.loadDrafts().map(\.id), [id])
  }

  func testDeleteDraftSuccessRetiresTheVisibleDraftEvenWhenSidecarCleanupFails() throws {
    let folder = try makeTemporaryFolder()
    let recoveryDirectory = folder.appendingPathComponent("Recovery", isDirectory: true)
    let sourceURL = folder.appendingPathComponent("source.md")
    let id = UUID()
    let payloadURL = recoveryDirectory.appendingPathComponent(id.uuidString + ".md")
    let titleURL = recoveryDirectory.appendingPathComponent(id.uuidString + ".title")
    let sourceSidecarURL = recoveryDirectory.appendingPathComponent(id.uuidString + ".source")
    let store = RecoveryStore(
      directoryURL: recoveryDirectory,
      removeItem: { url in
        if url.pathExtension == "title" || url.pathExtension == "source" {
          throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: url)
      })
    _ = try store.saveDraft(
      id: id,
      title: "source.md",
      text: "protected recovery bytes",
      sourceURL: sourceURL)

    XCTAssertTrue(fileExists(payloadURL))
    XCTAssertTrue(fileExists(titleURL))
    XCTAssertTrue(fileExists(sourceSidecarURL))

    XCTAssertTrue(store.deleteDraft(id: id))

    XCTAssertFalse(fileExists(payloadURL))
    XCTAssertTrue(fileExists(titleURL))
    XCTAssertTrue(fileExists(sourceSidecarURL))
    XCTAssertFalse(store.isDraftOpen(id: id))
    XCTAssertTrue(store.loadDrafts().isEmpty)
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

  /// Waits for an import to PUBLISH its conversion into the window's session. The
  /// publication is what both the success and the failure path share, so a pin on
  /// what happens afterwards can wait for it without assuming either outcome.
  @MainActor
  private func waitForPublishedImportBuffer(
    in appState: AppState,
    timeout: TimeInterval = 10,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if appState.documentSession.hasEditableBuffer, !appState.documentSession.text.isEmpty {
        return
      }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("the import never published a buffer", file: file, line: line)
  }

  /// A `RecoveryStore` whose directory can never exist: a regular FILE sits on its
  /// path, so `createDirectory(withIntermediateDirectories:)` throws
  /// `NSFileWriteFileExists` on every `saveDraft`. Deterministic in a way a
  /// permission bit or a full volume is not — no root, no timing, no sandbox
  /// assumptions — and it stays inside the test's own temporary folder, never
  /// touching the real recovery directory.
  private func makeUnwritableRecoveryStore(in folder: URL) throws -> RecoveryStore {
    let blocked = folder.appendingPathComponent("Recovery", isDirectory: false)
    try Data("not a directory".utf8).write(to: blocked, options: .atomic)
    return RecoveryStore(directoryURL: blocked)
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
