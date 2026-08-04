import XCTest

@testable import Pensieve

/// The restore matrix: intent × does it rebuild the workspace. Both other axes
/// are deliberately absent: no intent picks a document (restoration re-selects
/// only what a window already showed) and no intent claims the crash draft
/// (W2-D moved recovery to the launcher's Recovered Drafts section).
///
/// The behaviour under test is the end of restoration-absorption. Closing the
/// last document used to look like a no-op: the app put a launcher back and the
/// launcher ran the full cold-launch restore. Picking a document is no longer
/// part of that matrix at all — restoration re-selects only what a window
/// already showed, on EVERY intent (`selectRestoredDocument`), and a draft is
/// only ever opened because the user pointed at it.
final class LaunchIntentTests: XCTestCase {

  // MARK: - Policy matrix (pure)

  func testColdLaunchRebuildsTheWorkspace() {
    XCTAssertTrue(LaunchIntent.coldLaunch.restoresWorkspace)
  }

  func testMidSessionLaunchersStillRebuildTheWorkspace() {
    for intent: LaunchIntent in [.dockReopen, .newUntitledTab] {
      XCTAssertTrue(intent.restoresWorkspace, "\(intent) should still rebuild the sidebar")
    }
  }

  func testExplicitDocumentLaunchRestoresNothingAroundItsDocument() {
    XCTAssertFalse(LaunchIntent.explicitDocument.restoresWorkspace)
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

  /// No window claims a draft any more — not even a cold launch. Recovery is a
  /// decision the user makes in the launcher's Recovered Drafts section, so a
  /// starting window stays empty and the draft stays on disk, whatever the
  /// intent was.
  @MainActor
  func testNoLaunchIntentClaimsThePendingRecoveryDraft() throws {
    for intent: LaunchIntent in [.coldLaunch, .dockReopen, .newUntitledTab, .explicitDocument] {
      let harness = try makeRestoreHarness(documentNames: [])
      _ = try harness.recoveryStore.saveDraft(id: nil, title: "Untitled.md", text: "crash draft")

      harness.controller.start(intent: intent)

      XCTAssertFalse(
        harness.appState.documentSession.hasEditableBuffer,
        "\(intent) hijacked the window with the recovery draft")
      XCTAssertEqual(
        harness.recoveryStore.loadDrafts().first?.text, "crash draft",
        "\(intent) consumed the draft — the launcher would have nothing left to offer")
    }
  }

  /// The launcher must be able to SHOW what it may not adopt: starting a window
  /// fills the Recovered Drafts model from disk.
  @MainActor
  func testStartPublishesPendingDraftsToTheLauncher() throws {
    let harness = try makeRestoreHarness(documentNames: [])
    let seeded = try harness.recoveryStore.saveDraft(
      id: nil, title: "Untitled.md", text: "crash draft")
    // Writing a draft claims it for the buffer that produced it. A draft left
    // behind by a CRASH has no such buffer — the process died with the claim —
    // and only an unclaimed draft is offered on the launcher.
    harness.recoveryStore.markDraftClosed(id: seeded.id)

    harness.controller.start(intent: .coldLaunch)

    XCTAssertEqual(harness.controller.recoveredDrafts.map(\.text), ["crash draft"])
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

  // MARK: - A launch URL belongs to ONE launch

  /// A window that opens a file handed to it at launch shows that file and
  /// nothing else — no workspace restored around it, no document selected on
  /// top of it.
  @MainActor
  func testAFileLaunchStartsItsOwnWindowAsAnExplicitDocument() async throws {
    let harness = try makeRestoreHarness(documentNames: ["alpha.md"])
    let launchURL = harness.folder.appendingPathComponent("alpha.md").standardizedFileURL
    let coordinator = LaunchIntentCoordinator(settleDelayNanoseconds: 0)

    coordinator.handle(urls: [launchURL])
    coordinator.startWhenLaunchIntentsSettle(
      controller: harness.controller, intent: .coldLaunch)
    await coordinator.waitForStartupDecision()
    await harness.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(harness.appState.documentSession.url, launchURL)
    XCTAssertTrue(
      harness.appState.workspaceRoots.isEmpty,
      "a window opened for a launch file must not also restore the last workspace")
  }

  /// The regression the sticky `hasExplicitURLIntent` boolean caused: one
  /// Finder launch disabled workspace restore for EVERY later window in the
  /// process, so two identical-looking sessions behaved differently forever.
  @MainActor
  func testALaunchFileDoesNotChangeHowLaterWindowsStart() async throws {
    let launched = try makeRestoreHarness(documentNames: ["alpha.md"])
    let launchURL = launched.folder.appendingPathComponent("alpha.md").standardizedFileURL
    let coordinator = LaunchIntentCoordinator(settleDelayNanoseconds: 0)

    coordinator.handle(urls: [launchURL])
    coordinator.startWhenLaunchIntentsSettle(controller: launched.controller, intent: .coldLaunch)
    await coordinator.waitForStartupDecision()

    // A LATER window in the same process, started as its own cold launch.
    let later = try makeRestoreHarness(documentNames: ["beta.md"])
    coordinator.startWhenLaunchIntentsSettle(controller: later.controller, intent: .coldLaunch)
    await coordinator.waitForStartupDecision()
    await later.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(
      later.appState.workspaceRoots.map(\.url), [later.folder.standardizedFileURL],
      "an earlier file launch suppressed workspace restore for a later window")
    XCTAssertFalse(
      later.appState.documents.isEmpty,
      "…and its sidebar was rebuilt, which is what the suppressed restore used to cost")
  }

  /// And a mid-session launcher keeps its own policy after a file launch: the
  /// intent it was built with decides, not what happened earlier.
  @MainActor
  func testAFileLaunchDoesNotTurnALaterLauncherIntoAColdLaunch() async throws {
    let launched = try makeRestoreHarness(documentNames: ["alpha.md"])
    let coordinator = LaunchIntentCoordinator(settleDelayNanoseconds: 0)
    coordinator.handle(urls: [launched.folder.appendingPathComponent("alpha.md")])
    coordinator.startWhenLaunchIntentsSettle(controller: launched.controller, intent: .coldLaunch)
    await coordinator.waitForStartupDecision()

    let reopened = try makeRestoreHarness(documentNames: ["beta.md"])
    coordinator.startWhenLaunchIntentsSettle(controller: reopened.controller, intent: .dockReopen)
    await coordinator.waitForStartupDecision()
    await reopened.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertFalse(reopened.appState.documents.isEmpty)
    XCTAssertNil(
      reopened.appState.selectedDocumentID,
      "the Dock-reopen launcher must stay empty regardless of how the app was launched")
  }

  // MARK: - An external open reaches the focused window, never a dead ref

  /// W4-A. A Finder/`open`/Dock file open funnels through
  /// `application(_:open:)` → `LaunchIntentCoordinator.handle`. The coordinator's
  /// own `controller` is set ONLY by the cold-start settle path (launcher
  /// windows) and is a weak ref: once the original launcher window closed it
  /// went nil, and the open was routed at a released ref and SILENTLY DROPPED —
  /// the front window just kept showing the previously opened document. The
  /// open must instead land in the window the user is focused on (the same
  /// authority ⌘O resolves through), so the requested file is always shown.
  @MainActor
  func testExternalOpenReachesTheFocusedWindowWhenNoLauncherIsAttached() async throws {
    let focused = try makeRestoreHarness(documentNames: ["alpha.md"])
    let requested = focused.folder.appendingPathComponent("alpha.md").standardizedFileURL
    // No launcher controller is ever attached (its window closed): the
    // coordinator has only the focused document window to fall back on.
    let coordinator = LaunchIntentCoordinator(
      settleDelayNanoseconds: 0,
      focusedControllerProvider: { focused.controller })

    coordinator.handle(urls: [requested])
    await focused.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(
      focused.appState.selectedDocumentID, requested,
      "an external open with no launcher attached must still open into the focused window")
    XCTAssertEqual(focused.appState.documentSession.url, requested)
  }

  /// The attached launcher controller keeps priority while it is alive, so the
  /// focused fallback never diverts an open away from the window that is
  /// legitimately handling this launch. Here the launcher is attached FIRST
  /// (its own workspace empty, so its cold start selects nothing), then a file
  /// open arrives: it must land in the launcher, not in the unrelated focused
  /// window the provider points at.
  @MainActor
  func testAttachedLauncherKeepsPriorityOverTheFocusedFallback() async throws {
    let launcher = try makeRestoreHarness(documentNames: [])
    let other = try makeRestoreHarness(documentNames: ["beta.md"])
    let requested = launcher.folder.appendingPathComponent("gamma.md").standardizedFileURL
    try "# gamma".write(to: requested, atomically: true, encoding: .utf8)
    let coordinator = LaunchIntentCoordinator(
      settleDelayNanoseconds: 0,
      focusedControllerProvider: { other.controller })

    // Launcher attaches first (empty workspace → cold start selects nothing).
    coordinator.startWhenLaunchIntentsSettle(controller: launcher.controller, intent: .coldLaunch)
    await coordinator.waitForStartupDecision()

    // The file open arrives while the launcher is still the attached target.
    coordinator.handle(urls: [requested])
    await launcher.folderManager.waitForPendingWorkspaceBuild()
    await other.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(
      launcher.appState.selectedDocumentID, requested,
      "the attached launcher must be the window that opens the file")
    XCTAssertNil(
      other.appState.selectedDocumentID,
      "the file must not leak into an unrelated focused window while the launcher is attached")
  }

  // MARK: - Restore session on launch (S2-A)

  /// An absent key is a first launch, not "off" — the setting must default to
  /// today's behavior for every existing install.
  @MainActor
  func testRestoreSessionOnLaunchDefaultsToTrueWhenKeyAbsent() {
    let settings = LaunchSettings(
      defaults: makeEphemeralDefaults(prefix: "PensieveRestoreSessionDefaultTests"))

    XCTAssertTrue(settings.restoreSessionOnLaunch)
    XCTAssertTrue(LaunchSettings.restoreSessionOnLaunchDefault)
  }

  @MainActor
  func testRestoreSessionOnLaunchChoiceSurvivesRelaunch() {
    let defaults = makeEphemeralDefaults(prefix: "PensieveRestoreSessionPersistenceTests")

    LaunchSettings(defaults: defaults).restoreSessionOnLaunch = false
    XCTAssertFalse(LaunchSettings(defaults: defaults).restoreSessionOnLaunch)

    LaunchSettings(defaults: defaults).restoreSessionOnLaunch = true
    XCTAssertTrue(LaunchSettings(defaults: defaults).restoreSessionOnLaunch)
  }

  /// THE CONTRACT PIN for the toggle's OFF state (decision 26.07, W9):
  /// **workspace is configuration — it always comes back.** Off means the
  /// launcher opens NO file and selects nothing; it does not mean the user is
  /// dropped into an app that has forgotten which project she works in.
  ///
  /// The three claims are deliberately measured together, because the fracture
  /// this pin closes passed every one-sided assertion: `start` returned before
  /// `restoreLastFolderInBackground`, so "no files open" was true for the worst
  /// possible reason — there was no workspace left to open anything from.
  @MainActor
  func testColdLaunchWithRestoreSessionOffKeepsTheWorkspaceAndOpensNothing() async throws {
    let harness = try makeRestoreHarness(
      documentNames: ["alpha.md", "zebra.md"], restoreSessionOnLaunch: false)
    // A file left open at quit, OUTSIDE the root: the working set is what the
    // toggle governs, and a workspace document would prove nothing since the
    // tree brings those back by itself.
    let keptURL = try makeTemporaryFolder("loose").appendingPathComponent("kept.md")
    try "kept".write(to: keptURL, atomically: true, encoding: .utf8)
    XCTAssertNotNil(harness.folderManager.registerOpenFile(url: keptURL, into: AppState()))

    harness.controller.start(intent: .coldLaunch)
    await harness.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(
      harness.appState.workspaceRoots.map(\.url), [harness.folder.standardizedFileURL],
      "workspace is configuration: restore-session off must still rebuild the roots")
    XCTAssertFalse(
      harness.appState.documents.isEmpty,
      "the sidebar tree is part of the workspace, not of the session")
    XCTAssertNil(
      harness.appState.documentSession.url,
      "the working set must stay shut — a cold launch with the toggle off opens no file")
    XCTAssertNil(
      harness.appState.selectedDocumentID,
      "and it selects nothing: auto-select is the other half of what the toggle governs")
  }

  /// The toggle governs LAUNCH only — Dock reopen (and, by the same
  /// `intent.restoresWorkspace` gate, the tab bar's "+") must keep rebuilding
  /// the workspace they always did, whatever the setting says.
  @MainActor
  func testDockReopenIgnoresTheRestoreSessionOnLaunchSetting() async throws {
    let harness = try makeRestoreHarness(
      documentNames: ["alpha.md", "zebra.md"], restoreSessionOnLaunch: false)

    harness.controller.start(intent: .dockReopen)
    await harness.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(
      harness.appState.workspaceRoots.map(\.url), [harness.folder.standardizedFileURL],
      "Dock reopen must restore the workspace regardless of the launch-restore toggle")
    XCTAssertNil(harness.appState.selectedDocumentID)
  }

  /// A declined working-set reopen must not touch the persisted bookmarks. The
  /// toggle skips an ACTION, it does not forget anything: a fresh session
  /// restoring right afterwards still finds both the root and the file the user
  /// left open, which is what makes flipping the toggle back on reversible.
  @MainActor
  func testRestoreSessionOffDoesNotClearThePersistedBookmark() async throws {
    let harness = try makeRestoreHarness(
      documentNames: ["alpha.md"], restoreSessionOnLaunch: false)
    let keptURL = try makeTemporaryFolder("loose").appendingPathComponent("kept.md")
    try "kept".write(to: keptURL, atomically: true, encoding: .utf8)
    XCTAssertNotNil(harness.folderManager.registerOpenFile(url: keptURL, into: AppState()))

    harness.controller.start(intent: .coldLaunch)
    await harness.folderManager.waitForPendingWorkspaceBuild()
    XCTAssertNil(
      harness.appState.documentSession.url, "the declining launch must open no document")

    let nextSession = AppState()
    harness.folderManager.restoreLastFolderInBackground(into: nextSession)
    await harness.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(
      nextSession.workspaceRoots.map(\.url), [harness.folder.standardizedFileURL],
      "the root bookmark must survive a declined reopen — only the auto-invoke was skipped")
    XCTAssertEqual(
      nextSession.openFiles.map(\.id), [keptURL.standardizedFileURL],
      "and so must the file bookmarks: turning the setting back on has to bring them back")
  }

  /// Turning the toggle back ON restores the previous workspace on the next
  /// cold launch (a fresh `AppController`, modeling the next process launch).
  /// The workspace is the whole claim: picking a document is not part of the
  /// restore matrix on any intent, so the launcher still comes up unselected.
  @MainActor
  func testRestoreSessionBackOnRestoresOnTheNextColdLaunch() async throws {
    let harness = try makeRestoreHarness(
      documentNames: ["alpha.md", "zebra.md"], restoreSessionOnLaunch: false)
    harness.controller.start(intent: .coldLaunch)
    await harness.folderManager.waitForPendingWorkspaceBuild()
    XCTAssertNil(harness.appState.selectedDocumentID)

    harness.launchSettings.restoreSessionOnLaunch = true
    let nextAppState = AppState()
    let nextController = AppController(
      appState: nextAppState,
      folderManager: harness.folderManager,
      documentStore: harness.documentStore,
      launchSettings: harness.launchSettings,
      documentWindowRegistry: DocumentWindowRegistry(canMutateWindowTabs: { true }),
      importsFoldersInBackground: true
    )

    nextController.start(intent: .coldLaunch)
    await harness.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(
      nextAppState.workspaceRoots.map(\.url), [harness.folder.standardizedFileURL],
      "flipping the setting back on must restore the workspace on the next cold launch")
    XCTAssertFalse(nextAppState.documents.isEmpty, "the sidebar comes back with the workspace")
    XCTAssertNil(
      nextAppState.selectedDocumentID,
      "restoring the session is not picking a document — no intent does that")
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
    workspaceBuilder: WorkspaceScanner.Builder? = nil,
    restoreSessionOnLaunch: Bool = true
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

    let launchSettings = LaunchSettings(
      defaults: makeEphemeralDefaults(prefix: "PensieveLaunchIntentTestsLaunchSettings"))
    launchSettings.restoreSessionOnLaunch = restoreSessionOnLaunch

    let appState = AppState()
    let controller = AppController(
      appState: appState,
      folderManager: folderManager,
      documentStore: documentStore,
      indexDatabase: indexDatabase,
      launchSettings: launchSettings,
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
      launchSettings: launchSettings,
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
  let launchSettings: LaunchSettings
  let controller: AppController
}
