import XCTest

@testable import Pensieve

/// The restore matrix: intent × does it rebuild the workspace × does it claim
/// the crash draft.
///
/// The behaviour under test is the end of restoration-absorption. Closing the
/// last document used to look like a no-op: the app put a launcher back and the
/// launcher ran the full cold-launch restore. Picking a document is no longer
/// part of that matrix at all — restoration re-selects only what a window
/// already showed, on EVERY intent (`selectRestoredDocument`), so the axis that
/// remains here is workspace vs draft.
final class LaunchIntentTests: XCTestCase {

  // MARK: - Policy matrix (pure)

  func testColdLaunchIsTheOnlyIntentThatRestoresTheWholeSession() {
    XCTAssertTrue(LaunchIntent.coldLaunch.restoresWorkspace)
    XCTAssertTrue(LaunchIntent.coldLaunch.adoptsRecoveredDraft)
  }

  func testMidSessionLaunchersRestoreTheWorkspaceButNoDocument() {
    for intent: LaunchIntent in [.dockReopen, .newUntitledTab] {
      XCTAssertTrue(intent.restoresWorkspace, "\(intent) should still rebuild the sidebar")
      XCTAssertFalse(
        intent.adoptsRecoveredDraft,
        "\(intent) must not claim the crash draft — the close already asked about that work")
    }
  }

  func testExplicitDocumentLaunchRestoresNothingAroundItsDocument() {
    XCTAssertFalse(LaunchIntent.explicitDocument.restoresWorkspace)
    XCTAssertFalse(LaunchIntent.explicitDocument.adoptsRecoveredDraft)
  }

  // MARK: - start(intent:) — workspace and selection

  /// Cold launch rebuilds the workspace and NOTHING beyond it. The app picking a
  /// document for the user was retired on `main` (`LaunchOpensNothingTests`);
  /// what the user left open comes back from the file bookmarks, not from a
  /// guess at `documents.first`.
  @MainActor
  func testColdLaunchRestoresTheWorkspaceWithoutPickingADocument() async throws {
    let harness = try makeRestoreHarness(documentNames: ["alpha.md", "zebra.md"])

    harness.controller.start(intent: .coldLaunch)
    await harness.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(harness.appState.workspaceRoots.map(\.url), [harness.folder.standardizedFileURL])
    XCTAssertFalse(harness.appState.documents.isEmpty, "cold launch must rebuild the sidebar")
    XCTAssertNil(
      harness.appState.selectedDocumentID,
      "no intent may pick a document for the user — not even a cold launch")
  }

  @MainActor
  func testDockReopenRestoresTheWorkspaceWithoutSelectingADocument() async throws {
    let harness = try makeRestoreHarness(documentNames: ["alpha.md", "zebra.md"])

    harness.controller.start(intent: .dockReopen)
    await harness.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(
      harness.appState.workspaceRoots.map(\.url), [harness.folder.standardizedFileURL],
      "the sidebar/workspace still comes back — only the document does not")
    XCTAssertFalse(harness.appState.documents.isEmpty)
    XCTAssertNil(
      harness.appState.selectedDocumentID,
      "clicking the Dock icon after closing everything must not re-open a document")
    XCTAssertFalse(harness.appState.documentSession.hasEditableBuffer)
  }

  @MainActor
  func testNewUntitledTabRestoresTheWorkspaceWithoutSelectingADocument() async throws {
    let harness = try makeRestoreHarness(documentNames: ["alpha.md", "zebra.md"])

    harness.controller.start(intent: .newUntitledTab)
    await harness.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertFalse(harness.appState.documents.isEmpty)
    XCTAssertNil(
      harness.appState.selectedDocumentID,
      "the tab bar's + must produce an EMPTY tab, not the first document of the workspace")
  }

  @MainActor
  func testExplicitDocumentLaunchDoesNotRestoreTheWorkspaceAtAll() async throws {
    let harness = try makeRestoreHarness(documentNames: ["alpha.md"])

    harness.controller.start(intent: .explicitDocument)
    await harness.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertTrue(harness.appState.workspaceRoots.isEmpty)
    XCTAssertTrue(harness.appState.documents.isEmpty)
    XCTAssertNil(harness.appState.selectedDocumentID)
  }

  // MARK: - start(intent:) — crash-recovery draft

  @MainActor
  func testColdLaunchAdoptsThePendingRecoveryDraft() throws {
    let harness = try makeRestoreHarness(documentNames: [])
    _ = try harness.recoveryStore.saveDraft(id: nil, title: "Untitled.md", text: "crash draft")

    harness.controller.start(intent: .coldLaunch)

    XCTAssertTrue(harness.appState.documentSession.isUntitled)
    XCTAssertEqual(harness.appState.activeDocumentText, "crash draft")
  }

  @MainActor
  func testMidSessionLaunchersLeaveThePendingRecoveryDraftUnclaimed() throws {
    for intent: LaunchIntent in [.dockReopen, .newUntitledTab, .explicitDocument] {
      let harness = try makeRestoreHarness(documentNames: [])
      _ = try harness.recoveryStore.saveDraft(id: nil, title: "Untitled.md", text: "crash draft")

      harness.controller.start(intent: intent)

      XCTAssertFalse(
        harness.appState.documentSession.hasEditableBuffer,
        "\(intent) hijacked the window with the recovery draft")
      XCTAssertEqual(
        harness.recoveryStore.claimDraftForRestore()?.text, "crash draft",
        "\(intent) consumed the draft — a later cold launch would find nothing to recover")
    }
  }

  // MARK: - No restoration may reverse a conscious close

  /// The workspace validation tail lands after an off-main walk. If the user
  /// closes the document while that walk is running, the tail used to select a
  /// document straight back into the window it had just emptied — ⌘W on the
  /// last document appeared to do nothing.
  @MainActor
  func testCloseDuringAnInFlightRestoreIsNotReversedByItsTail() async throws {
    let scanStarted = DispatchSemaphore(value: 0)
    let releaseScan = DispatchSemaphore(value: 0)
    let harness = try makeRestoreHarness(
      documentNames: ["alpha.md", "zebra.md"],
      workspaceBuilder: { rootURLs, exclusions in
        scanStarted.signal()
        _ = releaseScan.wait(timeout: .now() + 5)
        return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
      })

    // The window shows a document when the restore starts, so the tail has both
    // a previous selection AND a first document it could fall back to.
    let openedURL = harness.folder.appendingPathComponent("alpha.md").standardizedFileURL
    harness.documentStore.load(ref: DocumentRef(id: openedURL), into: harness.appState)
    XCTAssertEqual(harness.appState.selectedDocumentID, openedURL)

    harness.folderManager.restoreLastFolderInBackground(into: harness.appState)
    XCTAssertEqual(scanStarted.wait(timeout: .now() + 2), .success)

    // ⌘W while the walk is still running. The document is clean, so the close
    // completes without asking anything.
    var didClose: Bool?
    harness.controller.closeActiveDocument { didClose = $0 }
    XCTAssertEqual(didClose, true)
    XCTAssertNil(harness.appState.selectedDocumentID)

    releaseScan.signal()
    await harness.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertNil(
      harness.appState.selectedDocumentID,
      "the restore tail re-opened a document into a window the user had just closed")
    XCTAssertFalse(harness.appState.documentSession.hasEditableBuffer)
    XCTAssertFalse(
      harness.appState.documents.isEmpty,
      "the workspace itself still finished restoring — only the selection stood down")
  }

  /// The guard is a generation, not a latch. A flow that was ALREADY walking
  /// when the user closed stands down; one that STARTS after the close carries
  /// the new generation and restores normally. A flag would have blocked both.
  ///
  /// Pinned on the context itself rather than through a second workspace open:
  /// restoration never picks a document for the user any more
  /// (`selectRestoredDocument`), so the two outcomes are indistinguishable from
  /// the outside once the selection is empty either way.
  @MainActor
  func testTheCloseGuardBlocksOnlyTheFlowThatWasAlreadyRunning() throws {
    let harness = try makeRestoreHarness(documentNames: ["alpha.md"])
    let openedURL = harness.folder.appendingPathComponent("alpha.md").standardizedFileURL
    harness.documentStore.load(ref: DocumentRef(id: openedURL), into: harness.appState)

    let alreadyRunning = WorkspaceSelectionContext.capture(from: harness.appState)
    harness.controller.closeActiveDocument { _ in }
    XCTAssertNil(harness.appState.selectedDocumentID)
    let startedAfterTheClose = WorkspaceSelectionContext.capture(from: harness.appState)

    XCTAssertFalse(
      alreadyRunning.survivesConsciousClose(in: harness.appState),
      "a flow in flight when the user closed must not select a document back in")
    XCTAssertTrue(
      startedAfterTheClose.survivesConsciousClose(in: harness.appState),
      "the guard is a generation, not a latch — the NEXT flow must restore normally")
  }

  // MARK: - Which intent each window route asks for

  @MainActor
  func testRegistryRoutesCarryTheirOwnIntent() throws {
    let documentWindow = Self.makeWindow()
    let launcherWindow = Self.makeWindow()
    defer {
      documentWindow.close()
      launcherWindow.close()
    }

    var requestedIntents: [LaunchIntent] = []
    var deferredWork: [() -> Void] = []
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { deferredWork.append($0) },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      applicationWindows: { [] },
      makeDocumentWindow: { ref, intent in
        requestedIntents.append(intent)
        return ref == nil ? launcherWindow : documentWindow
      }
    )

    registry.open(DocumentRef(id: URL(fileURLWithPath: "/tmp/pensieve-intent.md")))
    XCTAssertEqual(requestedIntents, [.explicitDocument])

    // Closing the last document window puts a launcher back — as a mid-session
    // reopen, NOT as a cold launch that would absorb a document straight back.
    registry.handleDocumentWindowClosed(documentWindow)
    XCTAssertEqual(deferredWork.count, 1)
    for work in deferredWork { work() }
    XCTAssertEqual(requestedIntents, [.explicitDocument, .dockReopen])

    registry.newUntitledTab(from: launcherWindow)
    XCTAssertEqual(requestedIntents, [.explicitDocument, .dockReopen, .newUntitledTab])
  }

  // MARK: - Helpers

  @MainActor
  private static func makeWindow(title: String = "Pensieve") -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true)
    window.isReleasedWhenClosed = false
    window.title = title
    return window
  }

  private func makeTemporaryFolder(_ label: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveLaunchIntentTests-\(label)-\(UUID().uuidString)",
        isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: folder)
    }
    return folder
  }

  /// A single window wired to throwaway state: its own workspace root persisted
  /// in an ephemeral bookmark store, its own index, cache and recovery
  /// directories. `start(intent:)` can then be driven through the real restore
  /// path without touching the shared singletons or the user's workspace.
  @MainActor
  private func makeRestoreHarness(
    documentNames: [String],
    workspaceBuilder: WorkspaceScanner.Builder? = nil
  ) throws -> RestoreHarness {
    let folder = try makeTemporaryFolder("workspace")
    for name in documentNames {
      try "body of \(name)".write(
        to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    let support = try makeTemporaryFolder("support")
    let indexDatabase = IndexDatabase(
      databaseURL: support.appendingPathComponent("index.db", isDirectory: false))
    let bookmarkStore = BookmarkStore(
      defaults: makeEphemeralDefaults(prefix: "PensieveLaunchIntentTests"))
    try bookmarkStore.persistRoot(url: folder, into: AppState())

    let folderManager = FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: support.appendingPathComponent("workspace.json", isDirectory: false)),
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceBuilder: workspaceBuilder ?? WorkspaceScanner.build,
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true)))
    )
    let recoveryStore = RecoveryStore(
      directoryURL: support.appendingPathComponent("Recovery", isDirectory: true))
    let documentStore = makeTestDocumentStore(
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      recoveryStore: recoveryStore)

    let appState = AppState()
    let controller = AppController(
      appState: appState,
      folderManager: folderManager,
      documentStore: documentStore,
      indexDatabase: indexDatabase,
      documentWindowRegistry: DocumentWindowRegistry(canMutateWindowTabs: { true }),
      importsFoldersInBackground: true
    )
    addTeardownBlock {
      Task { @MainActor in bookmarkStore.clear(into: appState) }
    }

    return RestoreHarness(
      folder: folder,
      appState: appState,
      folderManager: folderManager,
      documentStore: documentStore,
      recoveryStore: recoveryStore,
      controller: controller)
  }
}

@MainActor
private struct RestoreHarness {
  let folder: URL
  let appState: AppState
  let folderManager: FolderManager
  let documentStore: DocumentStore
  let recoveryStore: RecoveryStore
  let controller: AppController
}
