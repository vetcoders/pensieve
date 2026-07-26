import XCTest

@testable import Pensieve

/// W2-D: recovery stops being magic.
///
/// Two properties are under test, both provable on the FILESYSTEM rather than
/// in memory — a draft is a file, and "kept" or "gone" only means anything on
/// disk:
///   * retention — 30-day sweep, 20-draft cap, and an absolute exemption for
///     the draft a window is editing right now;
///   * the three launcher actions (Open / Save As… / Discard), each of which
///     may retire a draft only when the work is safely elsewhere.
final class RecoveredDraftsTests: XCTestCase {

  // MARK: - Retention

  @MainActor
  func testSweepDropsDraftsPastTheRetentionWindowAndKeepsTheRest() throws {
    let store = try makeRecoveryStore()
    let stale = try seedDraft(in: store, text: "forty days old", ageInDays: 40)
    let borderline = try seedDraft(in: store, text: "thirty-one days old", ageInDays: 31)
    let fresh = try seedDraft(in: store, text: "five days old", ageInDays: 5)

    let removed = store.pruneDrafts()

    XCTAssertEqual(Set(removed), [stale.id, borderline.id])
    XCTAssertFalse(fileExists(stale.url), "a 40-day-old draft survived the sweep")
    XCTAssertFalse(fileExists(borderline.url), "a 31-day-old draft survived the sweep")
    XCTAssertTrue(fileExists(fresh.url), "the sweep deleted a draft inside the retention window")
    XCTAssertEqual(store.loadDrafts().map(\.text), ["five days old"])
  }

  /// The one rule retention may never break: the draft a window is editing is
  /// the ONLY copy of that work.
  @MainActor
  func testSweepNeverDropsADraftThatIsOpenInAWindow() throws {
    let store = try makeRecoveryStore()
    let openDraft = try seedDraft(
      in: store, text: "being edited right now", ageInDays: 100, keepOpen: true)

    let removed = store.pruneDrafts()

    XCTAssertTrue(removed.isEmpty)
    XCTAssertTrue(fileExists(openDraft.url), "the sweep deleted the draft a window is editing")
  }

  @MainActor
  func testSweepTrimsToTheDraftCapOldestFirst() throws {
    let store = try makeRecoveryStore()
    // All open while seeding, so the write-time cap cannot evict mid-loop and
    // the sweep is what the assertion measures.
    var seeded: [RecoveryDraft] = []
    for index in 0..<25 {
      seeded.append(
        try seedDraft(
          in: store, text: "draft \(index)", ageInDays: Double(25 - index), keepOpen: true))
    }
    for draft in seeded { store.markDraftClosed(id: draft.id) }

    let removed = store.pruneDrafts()

    XCTAssertEqual(removed.count, 5)
    XCTAssertEqual(store.loadDrafts().count, RecoveryStore.maximumDraftCount)
    // Oldest five (the ones seeded first) are the ones that fell out.
    for dropped in seeded.prefix(5) {
      XCTAssertFalse(fileExists(dropped.url), "the cap kept a draft older than the survivors")
    }
    for kept in seeded.suffix(20) {
      XCTAssertTrue(fileExists(kept.url), "the cap dropped one of the 20 newest drafts")
    }
  }

  @MainActor
  func testTheCapNeverEvictsAnOpenDraft() throws {
    let store = try makeRecoveryStore()
    var seeded: [RecoveryDraft] = []
    for index in 0..<25 {
      seeded.append(
        try seedDraft(
          in: store, text: "draft \(index)", ageInDays: Double(25 - index), keepOpen: true))
    }

    XCTAssertTrue(store.pruneDrafts().isEmpty)
    XCTAssertEqual(store.loadDrafts().count, 25, "the cap evicted drafts held open by a window")
    for draft in seeded {
      XCTAssertTrue(fileExists(draft.url))
    }
  }

  /// Writing a NEW draft applies the cap immediately — otherwise a crash loop
  /// grows the list unbounded between launches.
  @MainActor
  func testWritingANewDraftAppliesTheCap() throws {
    let store = try makeRecoveryStore()
    var seeded: [RecoveryDraft] = []
    for index in 0..<RecoveryStore.maximumDraftCount {
      seeded.append(
        try seedDraft(in: store, text: "draft \(index)", ageInDays: Double(20 - index)))
    }
    XCTAssertEqual(store.loadDrafts().count, RecoveryStore.maximumDraftCount)

    let newest = try store.saveDraft(id: nil, title: "Untitled.md", text: "one draft too many")

    XCTAssertEqual(store.loadDrafts().count, RecoveryStore.maximumDraftCount)
    XCTAssertFalse(fileExists(try XCTUnwrap(seeded.first).url), "the oldest draft was not evicted")
    XCTAssertTrue(fileExists(newest.url))
  }

  /// Re-saving the SAME draft is the autosave hot path: it must not evict
  /// anything, because the list did not grow.
  @MainActor
  func testResavingAnExistingDraftEvictsNothing() throws {
    let store = try makeRecoveryStore()
    var seeded: [RecoveryDraft] = []
    for index in 0..<RecoveryStore.maximumDraftCount {
      seeded.append(
        try seedDraft(in: store, text: "draft \(index)", ageInDays: Double(20 - index)))
    }

    let live = try XCTUnwrap(seeded.last)
    _ = try store.saveDraft(id: live.id, title: "Untitled.md", text: "still typing")

    XCTAssertEqual(store.loadDrafts().count, RecoveryStore.maximumDraftCount)
    for draft in seeded {
      XCTAssertTrue(fileExists(draft.url))
    }
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
    XCTAssertTrue(store.isDraftOpen(id: draft.id), "the adopted draft is not protected from sweeps")
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

  /// The safety net that lets a new document stay off disk entirely: a draft
  /// the user never named still survives the window closing on it. Its content
  /// goes to the recovery store — never into the workspace folder — and comes
  /// back verbatim.
  @MainActor
  func testUnsavedUntitledContentRoundTripsThroughTheRecoveryStore() throws {
    let folder = try makeTemporaryFolder()
    let workspace = folder.appendingPathComponent("Workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let store = try makeRecoveryStore(in: folder)
    let indexDatabase = temporaryIndexDatabase(in: folder)
    let documentStore = makeTestDocumentStore(
      indexDatabase: indexDatabase, recoveryStore: store)
    let appState = AppState()
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: temporaryMetadataStore(in: folder), indexDatabase: indexDatabase),
      documentStore: documentStore,
      indexDatabase: indexDatabase)

    XCTAssertTrue(controller.createUntitledDocument(in: workspace))
    appState.activeDocumentText = "notes nobody named yet"
    appState.activeDocumentDirty = true

    XCTAssertTrue(controller.savePendingChangesOnClose())

    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: workspace.path), [],
      "closing an unnamed draft wrote into the workspace folder")
    let drafts = store.loadDrafts()
    XCTAssertEqual(drafts.map(\.text), ["notes nobody named yet"])

    let reopened = AppState()
    XCTAssertTrue(documentStore.openRecoveredDraft(try XCTUnwrap(drafts.first), into: reopened))
    XCTAssertEqual(reopened.activeDocumentText, "notes nobody named yet")
    XCTAssertTrue(reopened.documentSession.isUntitled)
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

  @MainActor
  func testDiscardDeletesTheDraftOnlyAfterConfirmation() throws {
    let folder = try makeTemporaryFolder()
    let store = try makeRecoveryStore(in: folder)
    let draft = try seedDraft(in: store, text: "throwaway", ageInDays: 0)

    let refusing = makeController(in: folder, recoveryStore: store, confirmsDiscard: false)
    XCTAssertFalse(refusing.discardRecoveredDraft(draft))
    XCTAssertTrue(fileExists(draft.url), "Cancel on the discard alert still deleted the draft")

    let accepting = makeController(in: folder, recoveryStore: store, confirmsDiscard: true)
    XCTAssertTrue(accepting.discardRecoveredDraft(draft))
    XCTAssertFalse(fileExists(draft.url), "a confirmed discard left the draft on disk")
    XCTAssertTrue(accepting.recoveredDrafts.isEmpty)
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
  /// retention is exercised through the same modification dates production
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
