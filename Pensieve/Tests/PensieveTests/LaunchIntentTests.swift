import XCTest

@testable import Pensieve

/// The restore matrix: intent × does it rebuild the workspace × does it select
/// a document. Claiming the crash draft is deliberately absent — no intent does
/// that any more (W2-D moved recovery to the launcher's Recovered Drafts
/// section).
///
/// The behaviour under test is the end of restoration-absorption. Closing the
/// last document used to look like a no-op: the app put a launcher back, the
/// launcher ran the full cold-launch restore, and the restore selected
/// `documents.first` — not even the document that was closed. Only a cold
/// launch may do that now.
final class LaunchIntentTests: XCTestCase {

  // MARK: - Policy matrix (pure)

  func testColdLaunchIsTheOnlyIntentThatRestoresTheWholeSession() {
    XCTAssertTrue(LaunchIntent.coldLaunch.restoresWorkspace)
    XCTAssertTrue(LaunchIntent.coldLaunch.selectsRestoredDocument)
  }

  func testMidSessionLaunchersRestoreTheWorkspaceButNoDocument() {
    for intent: LaunchIntent in [.dockReopen, .newUntitledTab] {
      XCTAssertTrue(intent.restoresWorkspace, "\(intent) should still rebuild the sidebar")
      XCTAssertFalse(
        intent.selectsRestoredDocument,
        "\(intent) must not pick a document — that is restoration reversing a conscious close")
    }
  }

  func testExplicitDocumentLaunchRestoresNothingAroundItsDocument() {
    XCTAssertFalse(LaunchIntent.explicitDocument.restoresWorkspace)
    XCTAssertFalse(LaunchIntent.explicitDocument.selectsRestoredDocument)
  }

  // MARK: - start(intent:) — workspace and selection

  /// Status quo pin. Cold-launch policy is deliberately UNCHANGED by this cut:
  /// starting the process still brings back the workspace AND opens a document.
  @MainActor
  func testColdLaunchRestoresWorkspaceAndSelectsADocument() async throws {
    let harness = try makeRestoreHarness(documentNames: ["alpha.md", "zebra.md"])

    harness.controller.start(intent: .coldLaunch)
    await harness.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(harness.appState.workspaceRoots.map(\.url), [harness.folder.standardizedFileURL])
    XCTAssertFalse(harness.appState.documents.isEmpty, "cold launch must rebuild the sidebar")
    XCTAssertNotNil(
      harness.appState.selectedDocumentID,
      "cold launch still opens a document — this cut does not change cold-launch policy")
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

  /// The guard is a generation, not a latch: an open the user performs AFTER a
  /// close is their new intent and must select normally.
  @MainActor
  func testAnOpenAfterACloseStillSelectsItsDocument() async throws {
    let harness = try makeRestoreHarness(documentNames: ["alpha.md"])
    let openedURL = harness.folder.appendingPathComponent("alpha.md").standardizedFileURL
    harness.documentStore.load(ref: DocumentRef(id: openedURL), into: harness.appState)
    harness.controller.closeActiveDocument { _ in }
    XCTAssertNil(harness.appState.selectedDocumentID)

    harness.controller.openFolder(url: harness.folder)
    await harness.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(
      harness.appState.selectedDocumentID, openedURL,
      "a folder the user opened after a close must still show a document")
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
    XCTAssertNotNil(later.appState.selectedDocumentID)
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

  /// The split contract (W9). The toggle OFF gates ONLY the open-files working
  /// set: a cold launch still restores the workspace roots (configuration, not
  /// session) and shows the tree, but reopens NO files and displays NO document.
  /// Proves acceptance #1 — workspace restored AND open files not restored.
  @MainActor
  func testColdLaunchWithRestoreSessionOffRestoresWorkspaceButNotOpenFiles() async throws {
    let harness = try makeRestoreHarness(
      documentNames: ["alpha.md", "zebra.md"],
      persistsOpenFiles: ["outside.md"],
      restoreSessionOnLaunch: false)

    harness.controller.start(intent: .coldLaunch)
    await harness.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(
      harness.appState.workspaceRoots.map(\.url), [harness.folder.standardizedFileURL],
      "the workspace roots are configuration — they restore on every cold launch")
    XCTAssertFalse(
      harness.appState.documents.isEmpty,
      "the workspace tree must be visible even with the session toggle off")
    XCTAssertTrue(
      harness.appState.openFiles.isEmpty,
      "the toggle is off — the open-files working set must NOT be restored")
    XCTAssertNil(
      harness.appState.selectedDocumentID,
      "no document may be auto-selected or displayed when the toggle is off")
    XCTAssertFalse(harness.appState.documentSession.hasEditableBuffer)
  }

  /// The mirror of the split: with the toggle ON the persisted open-files
  /// working set comes back alongside the workspace roots, and a document is
  /// displayed — the pre-W9 cold-launch behavior, unchanged.
  @MainActor
  func testColdLaunchWithRestoreSessionOnRestoresTheOpenFilesWorkingSet() async throws {
    let harness = try makeRestoreHarness(
      documentNames: ["alpha.md", "zebra.md"],
      persistsOpenFiles: ["outside.md"],
      restoreSessionOnLaunch: true)

    harness.controller.start(intent: .coldLaunch)
    await harness.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(
      harness.appState.openFiles.map { $0.url.standardizedFileURL }, harness.openFileURLs,
      "toggle on must bring the open-files working set back")
    XCTAssertNotNil(
      harness.appState.selectedDocumentID,
      "toggle on still displays a restored document — cold-launch policy is unchanged")
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

  /// Acceptance #5: the toggle never clears persisted bookmarks. A cold launch
  /// with it off skips ONLY the open-files working set — the file bookmark
  /// survives, so a subsequent explicit full restore still finds it.
  @MainActor
  func testRestoreSessionOffDoesNotClearThePersistedBookmarks() async throws {
    let harness = try makeRestoreHarness(
      documentNames: ["alpha.md"],
      persistsOpenFiles: ["outside.md"],
      restoreSessionOnLaunch: false)

    harness.controller.start(intent: .coldLaunch)
    await harness.folderManager.waitForPendingWorkspaceBuild()
    XCTAssertTrue(
      harness.appState.openFiles.isEmpty,
      "the working set is skipped while the toggle is off")

    // An explicit full restore (restoresOpenFiles defaults to true) still finds
    // both bookmarks — the skipped cold-launch working-set restore cleared none.
    harness.folderManager.restoreLastFolderInBackground(into: harness.appState)
    await harness.folderManager.waitForPendingWorkspaceBuild()

    XCTAssertEqual(
      harness.appState.workspaceRoots.map(\.url), [harness.folder.standardizedFileURL],
      "the root bookmark must survive a skipped working-set restore")
    XCTAssertEqual(
      harness.appState.openFiles.map { $0.url.standardizedFileURL }, harness.openFileURLs,
      "the file bookmark must survive too — the toggle only skipped the auto-invoke")
  }

  /// Turning the toggle back ON restores the displayed document on the next
  /// cold launch (a fresh `AppController`, modeling the next process launch).
  /// The first launch (off) already shows the tree but no document.
  @MainActor
  func testRestoreSessionBackOnRestoresOnTheNextColdLaunch() async throws {
    let harness = try makeRestoreHarness(
      documentNames: ["alpha.md", "zebra.md"], restoreSessionOnLaunch: false)
    harness.controller.start(intent: .coldLaunch)
    await harness.folderManager.waitForPendingWorkspaceBuild()
    XCTAssertNil(
      harness.appState.selectedDocumentID,
      "toggle off displays no document on this launch")

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
    XCTAssertNotNil(nextAppState.selectedDocumentID)
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
    persistsOpenFiles: [String] = [],
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
    // Persist an open-files working set so its restore can be observed
    // independently of the workspace-roots restore (the launch toggle splits
    // these two: roots always come back, the working set is gated). The files
    // live OUTSIDE the workspace root — an in-workspace file is dropped from the
    // working set by the scan tail (it is already the tree's row), so only an
    // ad-hoc external file survives to prove the working-set restore either way.
    var openFileURLs: [URL] = []
    if !persistsOpenFiles.isEmpty {
      let externalFolder = try makeTemporaryFolder("external-open-files")
      for name in persistsOpenFiles {
        let url = externalFolder.appendingPathComponent(name).standardizedFileURL
        try "body of \(name)".write(to: url, atomically: true, encoding: .utf8)
        try bookmarkStore.persistFile(url: url, into: AppState())
        openFileURLs.append(url)
      }
    }

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
      openFileURLs: openFileURLs,
      appState: appState,
      folderManager: folderManager,
      documentStore: documentStore,
      bookmarkStore: bookmarkStore,
      recoveryStore: recoveryStore,
      launchSettings: launchSettings,
      controller: controller)
  }
}

@MainActor
private struct RestoreHarness {
  let folder: URL
  let openFileURLs: [URL]
  let appState: AppState
  let folderManager: FolderManager
  let documentStore: DocumentStore
  let bookmarkStore: BookmarkStore
  let recoveryStore: RecoveryStore
  let launchSettings: LaunchSettings
  let controller: AppController
}
