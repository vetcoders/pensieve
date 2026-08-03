import AppKit
import XCTest

@testable import Pensieve

/// Closing a DOCUMENT retires it from Open Files. Closing a WINDOW does not.
///
/// Operator decision, 2026-08-03, which REVERSES the previous contract ("a
/// window is a view of a file, so closing it leaves the file in the working
/// set"): ⌘W / File ▸ Close and a tab's "×" take the file out of the session
/// for good — it leaves the list and the next launch does not bring it back.
///
/// Two carve-outs, and they are the whole reason this file exists rather than a
/// single line in `finishClose`:
///
/// - a WINDOW close takes every tab in it down at once, which is a decision
///   about the window and not about its files, so the working set survives it;
/// - termination (quit, logout) tears every window down the same way, and the
///   working set is exactly what the next launch restores from — see
///   `ClosedFileStaysClosedTests` for the relaunch half.
@MainActor
final class ClosingADocumentRetiresItTests: XCTestCase {

  // MARK: - ⌘W / File ▸ Close: the single-document close

  func testCommandCloseRetiresTheFileFromOpenFilesAndItsBookmark() throws {
    let harness = try makeHarness()
    let noteURL = try harness.openInWindow(named: "note.md", contents: "body")
    XCTAssertEqual(harness.appState.openFiles.map(\.url), [noteURL])

    harness.controller.closeActiveDocument()

    XCTAssertTrue(
      harness.appState.openFiles.isEmpty,
      "⌘W is the explicit close of THIS document — the row has to go with it")
    XCTAssertFalse(
      harness.restoredFilePaths().contains(noteURL.path),
      "the bookmark outlives the process, so a close that leaves it behind is a close the next"
        + " launch undoes")
  }

  func testCommandCloseWithSaveWritesTheFileAndRetiresIt() throws {
    let harness = try makeHarness(autoSaveEnabled: false)
    let noteURL = try harness.openInWindow(named: "note.md", contents: "original")
    harness.recorder.answer = .save
    harness.appState.activeDocumentText = "edited"
    harness.appState.activeDocumentDirty = true

    var didClose: Bool?
    harness.controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, true)
    XCTAssertEqual(harness.recorder.prompts, [.savePathed])
    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "edited", "Save writes")
    XCTAssertTrue(harness.appState.openFiles.isEmpty, "and the saved file still leaves the list")
  }

  func testCommandCloseWithDontSaveRetiresTheFileWithoutWriting() throws {
    let harness = try makeHarness(autoSaveEnabled: false)
    let noteURL = try harness.openInWindow(named: "note.md", contents: "original")
    harness.recorder.answer = .discard
    harness.appState.activeDocumentText = "dropped on purpose"
    harness.appState.activeDocumentDirty = true

    var didClose: Bool?
    harness.controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, true)
    XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "original")
    XCTAssertTrue(harness.appState.openFiles.isEmpty)
    XCTAssertFalse(harness.restoredFilePaths().contains(noteURL.path))
  }

  /// Cancel means the close never happened, so it may not cost the user a row.
  /// The retirement hangs off the settled close for exactly this reason.
  func testCancellingTheCloseRetiresNothing() throws {
    let harness = try makeHarness(autoSaveEnabled: false)
    let noteURL = try harness.openInWindow(named: "note.md", contents: "original")
    harness.recorder.answer = .cancel
    harness.appState.activeDocumentText = "still being written"
    harness.appState.activeDocumentDirty = true

    var didClose: Bool?
    harness.controller.closeActiveDocument { didClose = $0 }

    XCTAssertEqual(didClose, false)
    XCTAssertEqual(
      harness.appState.openFiles.map(\.url), [noteURL],
      "a refused close forgets nothing — the document is still open")
    XCTAssertTrue(harness.restoredFilePaths().contains(noteURL.path))
    XCTAssertTrue(harness.appState.documentSession.isDirty, "and its buffer is untouched")
  }

  // MARK: - The window route: one tab leaving vs the whole window going down

  /// A tab's "×" removes ONE document from a window that stays open. AppKit
  /// reports it as this window closing, so the scope is read back once the
  /// close has settled: a sibling tab is still registered, therefore a tab
  /// closed, therefore its file retires — and only its file.
  func testClosingOneTabRetiresOnlyThatTabsFile() throws {
    let harness = try makeHarness()
    let keptURL = try harness.registerOpenFileWithoutAWindow(named: "kept.md")
    let closedURL = try harness.openInWindow(named: "closed.md", contents: "body")

    let closingWindow = harness.makeRegisteredWindow()
    let survivingTab = harness.makeRegisteredWindow()
    harness.tabGroup.windows = [closingWindow, survivingTab]

    XCTAssertTrue(harness.controller.windowShouldClose(closingWindow))
    harness.tearDown(closingWindow)
    harness.settleCloses()

    XCTAssertEqual(
      harness.appState.openFiles.map(\.url), [keptURL],
      "the closed tab's file leaves the working set; every other row stays")
    XCTAssertFalse(harness.restoredFilePaths().contains(closedURL.path))
    XCTAssertTrue(harness.restoredFilePaths().contains(keptURL.path))
  }

  /// Same route, this time with the Save / Don't Save sheet in between: the
  /// retirement is reported by the SETTLED close, so it carries the location the
  /// close ended on rather than the one it started with.
  func testClosingOneTabAfterDontSaveRetiresThatTabsFile() throws {
    let harness = try makeHarness(autoSaveEnabled: false)
    let closedURL = try harness.openInWindow(named: "closed.md", contents: "original")
    harness.recorder.answer = .discard
    harness.appState.activeDocumentText = "dropped on purpose"
    harness.appState.activeDocumentDirty = true

    let closingWindow = harness.makeRegisteredWindow()
    let survivingTab = harness.makeRegisteredWindow()
    harness.tabGroup.windows = [closingWindow, survivingTab]

    XCTAssertFalse(
      harness.controller.windowShouldClose(closingWindow),
      "the sheet vetoes the immediate teardown; the window closes on the answer")
    harness.tearDown(closingWindow)
    harness.settleCloses()

    XCTAssertTrue(harness.appState.openFiles.isEmpty)
    XCTAssertEqual(try String(contentsOf: closedURL, encoding: .utf8), "original")
  }

  /// THE CARVE-OUT. The red button takes the whole tab group down, so every tab
  /// tears down in the same pass and nothing survives to prove a tab closed.
  /// That is a window decision, not a decision about three files: all three stay
  /// in the working set, bookmarks included, and come back on the next launch.
  func testClosingTheWholeWindowKeepsEveryFileItHeld() throws {
    let harness = try makeHarness()
    let alphaURL = try harness.registerOpenFileWithoutAWindow(named: "alpha.md")
    let betaURL = try harness.registerOpenFileWithoutAWindow(named: "beta.md")
    let gammaURL = try harness.openInWindow(named: "gamma.md", contents: "body")

    let closingWindow = harness.makeRegisteredWindow()
    let secondTab = harness.makeRegisteredWindow()
    let thirdTab = harness.makeRegisteredWindow()
    harness.tabGroup.windows = [closingWindow, secondTab, thirdTab]

    XCTAssertTrue(harness.controller.windowShouldClose(closingWindow))
    for window in [closingWindow, secondTab, thirdTab] { harness.tearDown(window) }
    harness.settleCloses()

    XCTAssertEqual(
      harness.appState.openFiles.map(\.url), [alphaURL, betaURL, gammaURL],
      "closing a window is not the user deciding anything about the files it held")
    for url in [alphaURL, betaURL, gammaURL] {
      XCTAssertTrue(
        harness.restoredFilePaths().contains(url.path),
        "\(url.lastPathComponent) must still be restorable after the window closed")
    }
  }

  /// A window with no tab siblings IS the window: closing it is a window close,
  /// answered without waiting for anything, and its file stays.
  func testClosingALoneDocumentWindowKeepsItsFile() throws {
    let harness = try makeHarness()
    let noteURL = try harness.openInWindow(named: "note.md", contents: "body")

    let window = harness.makeRegisteredWindow()
    harness.tabGroup.windows = [window]

    XCTAssertTrue(harness.controller.windowShouldClose(window))
    XCTAssertTrue(
      harness.hasNothingPending,
      "a window with no siblings needs no settling turn — it cannot be a tab close")
    harness.tearDown(window)
    harness.settleCloses()

    XCTAssertEqual(harness.appState.openFiles.map(\.url), [noteURL])
    XCTAssertTrue(harness.restoredFilePaths().contains(noteURL.path))
  }

  /// THE TRAP. Quit tears every window down, tab siblings and all. Reading that
  /// as "the user closed these documents" would empty the working set the next
  /// launch restores from — quitting with files open would lose them.
  func testWindowCloseWhileTerminatingRetiresNothing() throws {
    let harness = try makeHarness()
    let noteURL = try harness.openInWindow(named: "note.md", contents: "body")

    let closingWindow = harness.makeRegisteredWindow()
    let survivingTab = harness.makeRegisteredWindow()
    harness.tabGroup.windows = [closingWindow, survivingTab]

    harness.registry.beginTermination()
    XCTAssertTrue(harness.controller.windowShouldClose(closingWindow))
    harness.tearDown(closingWindow)
    harness.settleCloses()

    XCTAssertEqual(
      harness.appState.openFiles.map(\.url), [noteURL],
      "a teardown during termination is process shutdown, not a close")
    XCTAssertTrue(harness.restoredFilePaths().contains(noteURL.path))
  }

  /// The same trap seen from the other end, across a simulated relaunch: quit
  /// with three files open and the next launch brings all three back. This is
  /// the pin the retirement had to be carved around — a quit that retired would
  /// leave the user with an empty session and no way to notice until restart.
  func testQuittingWithOpenTabsRestoresThemOnTheNextLaunch() throws {
    let harness = try makeHarness()
    let alphaURL = try harness.registerOpenFileWithoutAWindow(named: "alpha.md")
    let betaURL = try harness.registerOpenFileWithoutAWindow(named: "beta.md")
    let gammaURL = try harness.openInWindow(named: "gamma.md", contents: "body")

    let windows = [
      harness.makeRegisteredWindow(), harness.makeRegisteredWindow(),
      harness.makeRegisteredWindow(),
    ]
    harness.tabGroup.windows = windows

    // Quit: every window goes down in one pass, through both teardown routes —
    // the flush hook and the window's own close guard.
    harness.registry.beginTermination()
    for window in windows {
      harness.controller.windowShouldClose(window)
      harness.controller.savePendingChangesOnClose()
      harness.tearDown(window)
    }
    harness.settleCloses()

    let restored = try harness.relaunch()
    let restoredPaths = Set(restored.openFiles.map(\.url.standardizedFileURL.path))
    XCTAssertFalse(
      restoredPaths.isEmpty, "quitting with tabs open must not restore an empty session")
    for url in [alphaURL, betaURL, gammaURL] {
      XCTAssertTrue(
        restoredPaths.contains(url.path),
        "\(url.lastPathComponent) was open at quit and has to come back")
    }
  }

  // MARK: - Harness

  private func makeHarness(
    autoSaveEnabled: Bool = true,
    savePanelURL: URL? = nil
  ) throws -> RetirementHarness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PensieveClosingADocumentRetiresIt-\(UUID().uuidString)", isDirectory: true)
    let support = root.appendingPathComponent("Support", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }

    let defaults = makeEphemeralDefaults(prefix: "PensieveClosingADocumentRetiresIt")
    let bookmarkStore = BookmarkStore(defaults: defaults)
    let indexDatabase = IndexDatabase(
      databaseURL: support.appendingPathComponent("index-\(UUID().uuidString).db"))
    let folderManager = FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: support.appendingPathComponent("workspace.json")),
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true))))
    let documentStore = makeTestDocumentStore(
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      savingSettings: makeAutoSaveSettings(enabled: autoSaveEnabled),
      savePanelURLProvider: { _ in savePanelURL })

    let pending = PendingCloseSettlements()
    let tabGroup = TabGroupStub()
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { pending.work.append($0) },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      applicationWindows: { [] },
      closeWindow: { _ in },
      tabGroupWindows: { window in
        tabGroup.windows.contains(where: { $0 === window }) ? tabGroup.windows : [window]
      })

    let recorder = SaveChangesRecorder()
    let appState = AppState()
    let controller = AppController(
      appState: appState,
      folderManager: folderManager,
      documentStore: documentStore,
      indexDatabase: indexDatabase,
      documentWindowRegistry: registry,
      confirmSaveChanges: recorder.confirmation())

    return RetirementHarness(
      root: root,
      support: support,
      defaults: defaults,
      appState: appState,
      folderManager: folderManager,
      documentStore: documentStore,
      controller: controller,
      registry: registry,
      recorder: recorder,
      pending: pending,
      tabGroup: tabGroup)
  }
}

/// Deferred main-actor work the registry parked, run on demand so the "one
/// runloop turn later" the close scope is resolved on is explicit in the test
/// rather than a sleep.
private final class PendingCloseSettlements {
  var work: [DocumentWindowRegistry.DeferredMainWork] = []
}

/// The native tab group, which cannot be built in a headless test bundle.
private final class TabGroupStub {
  var windows: [NSWindow] = []
}

@MainActor
private struct RetirementHarness {
  let root: URL
  let support: URL
  let defaults: UserDefaults
  let appState: AppState
  let folderManager: FolderManager
  let documentStore: DocumentStore
  let controller: AppController
  let registry: DocumentWindowRegistry
  let recorder: SaveChangesRecorder
  let pending: PendingCloseSettlements
  let tabGroup: TabGroupStub

  var hasNothingPending: Bool { pending.work.isEmpty }

  /// A file this window is showing: it joins the working set (list + bookmark)
  /// and becomes the session document, exactly as an open does.
  @discardableResult
  func openInWindow(named name: String, contents: String) throws -> URL {
    let url = try write(named: name, contents: contents)
    controller.openFile(url: url)
    return url
  }

  /// A file in the working set that this window is NOT showing — the other rows
  /// a close must leave alone.
  @discardableResult
  func registerOpenFileWithoutAWindow(named name: String) throws -> URL {
    let url = try write(named: name, contents: name)
    XCTAssertNotNil(folderManager.registerOpenFile(url: url, into: appState))
    return url
  }

  func makeRegisteredWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: .zero)
    registry.registerController(controller, for: window)
    return window
  }

  /// What the document root does on `NSWindow.willCloseNotification`: the window
  /// is gone, so its controller registration goes with it.
  func tearDown(_ window: NSWindow) {
    registry.unregisterController(for: window)
    tabGroup.windows.removeAll { $0 === window }
  }

  /// The turn on which the close has settled and the surviving tabs can be
  /// counted.
  func settleCloses() {
    let work = pending.work
    pending.work = []
    for item in work { item() }
  }

  /// The next launch: brand-new stores over the same persisted defaults, with
  /// nothing carried over in memory.
  func relaunch() throws -> AppState {
    let relaunched = AppState()
    FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: support.appendingPathComponent("workspace.json")),
      indexDatabase: IndexDatabase(
        databaseURL: support.appendingPathComponent("index-\(UUID().uuidString).db")),
      bookmarkStore: BookmarkStore(defaults: defaults),
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true)))
    ).restoreLastFolder(into: relaunched)
    return relaunched
  }

  /// What the NEXT launch would resolve out of the persisted bookmarks — the
  /// only half of a retirement that outlives the process.
  func restoredFilePaths() -> Set<String> {
    let restored = BookmarkStore(defaults: defaults).restoreWorkspace(into: AppState())
    return Set(restored.fileURLs.map(\.standardizedFileURL.path))
  }

  private func write(named name: String, contents: String) throws -> URL {
    let url = root.appendingPathComponent(name).standardizedFileURL
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
  }
}
