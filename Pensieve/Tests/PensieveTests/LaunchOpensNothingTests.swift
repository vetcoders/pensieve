import AppKit
import Foundation
import XCTest

@testable import Pensieve

/// A launch must open exactly what the user left open — and nothing else.
///
/// Measured on the operator's machine, not argued. A file she had not touched in
/// two weeks reappeared as the one open document after a launch, with no
/// bookmark of its own in the working set: `fileBookmarks` held eight entries and
/// none of them was that file. The path is entirely internal to the restore:
///
///   `restoreLastFolder` → `openResolvedWorkspace` → `selectRestoredDocument`
///
/// and the last step ends in `else if let first = documents.first`. On a session
/// the user left empty there is no previous selection, so that branch runs and
/// loads a document nobody asked for.
///
/// "first" is not "most recent": the scan sorts folders before files and each
/// group alphabetically, then walks depth-first, so `documents.first` is the
/// first Markdown file inside the alphabetically-first folder chain — a stable,
/// arbitrary file that has nothing to do with what the user was reading.
@MainActor
final class LaunchOpensNothingTests: XCTestCase {
  /// THE REGRESSION PIN — the operator's cycle, minus the windows.
  ///
  /// Empty working set, a workspace root that still has documents in it. Before
  /// the fix this ends with a loaded document and a freshly written reopen
  /// record; after it, with nothing.
  func testALaunchWithNothingLeftOpenOpensNothing() throws {
    let harness = try makeHarness()
    _ = try harness.writeNote(named: "alpha.md", in: "Archive")
    _ = try harness.writeNote(named: "beta.md")
    try harness.openWorkspace()

    let relaunched = try harness.relaunch()

    XCTAssertNil(
      relaunched.appState.selectedDocumentID,
      "the launch selected a document the user never opened — `documents.first` is not a"
        + " session, it is whatever the scanner happened to reach first")
    XCTAssertNil(
      relaunched.appState.documentSession.url,
      "worse than selected: it was LOADED, so the window came back showing a file the user"
        + " had not opened")
    XCTAssertTrue(
      relaunched.appState.openFiles.isEmpty,
      "an empty working set must stay empty across a launch")
    XCTAssertTrue(
      relaunched.registry.openDocuments.isEmpty,
      "an empty session must open no window and no tab — reopening the working set must not"
        + " become a reason to manufacture documents nobody asked for")
  }

  /// THE CONTROL LEG. The same harness, one file actually left open — it MUST
  /// come back. A launch that restores nothing at all would pass the pin above
  /// and break the behaviour it is carved out of.
  ///
  /// The file lives OUTSIDE the workspace root on purpose: a file inside the
  /// root is already in the sidebar tree, and `applyWorkspaceScans` deliberately
  /// drops workspace documents from Open Files rather than listing them twice.
  /// Open Files is the ad-hoc working set, so that is what the control has to
  /// exercise.
  /// The `openFiles` half of this leg passed for a long time while the user saw
  /// nothing come back — because `openFiles` is a MODEL list, and the Open Files
  /// sidebar renders from `windowRegistry.openDocuments`. `prepareWorkspaceShell`
  /// filled the model and stopped; the only production caller of
  /// `DocumentWindowRegistry.open` is `requestOpenDocumentWindow`, which the
  /// launch path never invoked. So the assertion below was pinning exactly the
  /// broken state. The registry assertion is what makes it a real control leg.
  func testAFileLeftOpenAtQuitStillComesBack() throws {
    let harness = try makeHarness()
    let keptURL = try harness.writeLooseNote(named: "kept.md")
    try harness.openWorkspace()

    let session = AppState()
    XCTAssertNotNil(harness.manager.registerOpenFile(url: keptURL, into: session))

    let relaunched = try harness.relaunch()
    XCTAssertTrue(
      relaunched.appState.openFiles.contains { $0.url.standardizedFileURL == keptURL },
      "quitting with a file open must bring it back")
    XCTAssertEqual(
      relaunched.appState.documentSession.url?.standardizedFileURL, keptURL,
      "the launch window is empty, so the restored document belongs IN it rather than in a"
        + " second window that leaves this one to be reaped")
    XCTAssertTrue(
      relaunched.registry.openDocuments.contains { $0.identity == .file(keptURL) },
      "the file came back only in the model: no window, no tab, and no Open Files row — from"
        + " the user's side it did not come back at all")
  }

  /// The second and later files take the other branch — the real
  /// `requestOpenDocumentWindow` route — so they arrive as their own document
  /// windows/tabs rather than being silently dropped after the first.
  func testEveryFileLeftOpenComesBackNotJustTheFirst() throws {
    let harness = try makeHarness()
    let firstURL = try harness.writeLooseNote(named: "first.md")
    let secondURL = try harness.writeLooseNote(named: "second.md")
    try harness.openWorkspace()

    let session = AppState()
    XCTAssertNotNil(harness.manager.registerOpenFile(url: firstURL, into: session))
    XCTAssertNotNil(harness.manager.registerOpenFile(url: secondURL, into: session))

    let relaunched = try harness.relaunch()

    let reopened = Set(relaunched.registry.openDocuments.map(\.identity))
    XCTAssertEqual(
      reopened, [.file(firstURL), .file(secondURL)],
      "a working set of two files must come back as two open documents")
  }

  /// ONE FILE IS ONE TAB, however many times the working set names it.
  ///
  /// The operator's `fileBookmarks` held fifteen entries for twelve files —
  /// three of them recorded twice — and the restore turns each entry into a
  /// request for a window.
  ///
  /// This leg passes on the build that HAS the duplicated key, because
  /// `prepareWorkspaceShell` de-duplicates the live list before the reopen ever
  /// sees it; the defect it belongs to lives further down, in the store that
  /// kept the duplicate across launches (`StartupRestoreWorkingSetHygieneTests`)
  /// and in the reopen's own habit of trusting the list it was handed. It is
  /// kept as the CONTRACT pin for the whole path: exactly one of those three
  /// layers has to be wrong for the user to get two tabs on one document, and
  /// this is the only place that would notice.
  func testAWorkingSetThatNamesOneFileTwiceComesBackAsOneDocument() throws {
    let harness = try makeHarness()
    let keptURL = try harness.writeLooseNote(named: "kept.md")
    let repeatedURL = try harness.writeLooseNote(named: "repeated.md")
    try harness.openWorkspace()
    try harness.persistWorkingSet([keptURL, repeatedURL, repeatedURL])

    let relaunched = try harness.relaunch()

    XCTAssertEqual(
      relaunched.appState.openFiles.map(\.url.standardizedFileURL), [keptURL, repeatedURL],
      "the duplicate reached the working set, and every ref in it is a window the launch asks"
        + " for")
    XCTAssertEqual(
      relaunched.registry.openDocuments.count, 2,
      "one document came back as two tabs")
  }

  /// THE TRASH IS DEAD. A file the user threw away still exists on disk and its
  /// bookmark still resolves, so nothing in the restore's existence checks
  /// stopped it — the launch faithfully reopened a document that is, from the
  /// user's side, deleted.
  func testAFileTheUserThrewAwayDoesNotComeBack() throws {
    let harness = try makeHarness()
    let keptURL = try harness.writeLooseNote(named: "kept.md")
    let trashedURL = try harness.writeTrashedNote(named: "thrown-away.md")
    try harness.openWorkspace()
    try harness.persistWorkingSet([keptURL, trashedURL])

    let relaunched = try harness.relaunch()

    XCTAssertEqual(
      relaunched.appState.openFiles.map(\.url.standardizedFileURL), [keptURL],
      "a file in the Trash came back into the working set")
    XCTAssertEqual(
      relaunched.registry.openDocuments.map(\.identity), [.file(keptURL)],
      "the launch reopened a document the user had thrown away")
  }

  /// CLOSING THE LAST DOCUMENT MUST CLOSE IT.
  ///
  /// A native window close deliberately LEAVES the file in the working set —
  /// only "Close from Open Files" retires it — and the registry re-opens a
  /// launcher after the last document window goes, so the app is never left
  /// windowless. That replacement launcher's root runs the very same
  /// `start(intent: .coldLaunch)` as the launch one did. With the reopen
  /// gated per controller, the launcher immediately reloaded the file the user
  /// had just closed: the last document could not be closed at all without
  /// first removing its Open Files row.
  func testClosingTheLastDocumentDoesNotImmediatelyReopenIt() throws {
    let harness = try makeHarness()
    let keptURL = try harness.writeLooseNote(named: "kept.md")
    try harness.openWorkspace()

    let session = AppState()
    XCTAssertNotNil(harness.manager.registerOpenFile(url: keptURL, into: session))

    let launched = try harness.relaunch()
    XCTAssertEqual(
      launched.appState.documentSession.url?.standardizedFileURL, keptURL,
      "the launch never opened the document, so closing it would prove nothing")

    let replacement = harness.closeWindowAdoptingTheReplacementLauncher(launched.window)

    XCTAssertNil(
      replacement.appState.documentSession.url,
      "closing the last document reopened it in the replacement launcher — from the user's"
        + " side the window simply refuses to close")
    XCTAssertTrue(
      replacement.registry.openDocuments.isEmpty,
      "the document the user just closed came straight back as an open document row")
  }

  /// RESTORE-ON-LAUNCH OFF MEANS THE FILES STAY SHUT — including the ones the
  /// launch reopens through the WINDOW REGISTRY, which is the half the user
  /// actually sees. The setting promises "no workspace, no open files", and the
  /// working set is restored by a different step from the workspace, so the
  /// control leg above (`testAFileLeftOpenAtQuitStillComesBack`) is the only
  /// thing that makes this measurable at all.
  ///
  /// The second window is the trap. `start` claims the application's one
  /// startup restore BEFORE it consults the setting, so a declining cold launch
  /// still consumes it; were the claim taken after the gate, the replacement
  /// launcher would arrive unclaimed and reopen the very files the user turned
  /// off — the setting would hold for exactly one window.
  func testColdLaunchWithRestoreOffReopensNoFilesInAnyWindow() throws {
    let harness = try makeHarness()
    let keptURL = try harness.writeLooseNote(named: "kept.md")
    try harness.openWorkspace()

    let session = AppState()
    XCTAssertNotNil(harness.manager.registerOpenFile(url: keptURL, into: session))
    harness.launchSettings.restoreSessionOnLaunch = false

    let launched = try harness.relaunch()
    XCTAssertNil(
      launched.appState.documentSession.url,
      "a cold launch with restore off must open no document")
    XCTAssertTrue(
      launched.registry.openDocuments.isEmpty,
      "the file came back as an open document despite the setting")

    let replacement = harness.closeWindowAdoptingTheReplacementLauncher(launched.window)
    XCTAssertNil(
      replacement.appState.documentSession.url,
      "the replacement launcher inherited the startup reopen the user had turned off")
    XCTAssertTrue(replacement.registry.openDocuments.isEmpty)
  }

  /// The measurement behind "first is not most recent", kept as a pin because it
  /// is the reason the resurrected file looked arbitrary: folders sort before
  /// files, each group alphabetically, and the walk is depth-first.
  func testWorkspaceDocumentOrderIsDepthFirstFoldersBeforeFiles() throws {
    let harness = try makeHarness()
    _ = try harness.writeNote(named: "zulu.md", in: "Archive")
    _ = try harness.writeNote(named: "alpha.md")

    let appState = AppState()
    harness.manager.open(url: harness.root, into: appState)

    XCTAssertEqual(
      appState.documents.first?.url.lastPathComponent, "zulu.md",
      "a file buried in the alphabetically-first FOLDER precedes a file named `alpha.md` at the"
        + " root — which is exactly why the document a launch used to auto-open looked random")
  }

  // MARK: - Harness

  private func makeHarness() throws -> LaunchHarness {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PensieveLaunchOpensNothing-\(UUID().uuidString)", isDirectory: true)
    // The workspace root, the support directory and the loose files are
    // siblings: anything under the root is a WORKSPACE document, which is a
    // different working set from Open Files.
    let root = container.appendingPathComponent("Workspace", isDirectory: true)
    let support = container.appendingPathComponent("Support", isDirectory: true)
    let loose = container.appendingPathComponent("Loose", isDirectory: true)
    // A Trash of this fixture's own. The real one is never touched, and the
    // product rule is about the LOCATION — `~/.Trash`, a volume's `.Trashes` —
    // not about one particular path.
    let trash = container.appendingPathComponent(".Trash", isDirectory: true)
    for directory in [root, support, loose, trash] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    addTeardownBlock {
      try? FileManager.default.removeItem(at: container)
    }

    let defaults = makeEphemeralDefaults(prefix: "PensieveLaunchOpensNothing")
    let bookmarkStore = BookmarkStore(defaults: defaults)
    let harness = LaunchHarness(
      root: root,
      support: support,
      loose: loose,
      trash: trash,
      defaults: defaults,
      launchSettings: LaunchSettings(
        defaults: makeEphemeralDefaults(prefix: "PensieveLaunchOpensNothingLaunchSettings")),
      manager: makeManager(support: support, bookmarkStore: bookmarkStore),
      makeManager: makeManager,
      makeStore: makeStore
    )
    addTeardownBlock {
      await MainActor.run { harness.closeWindows() }
    }
    return harness
  }

  private func makeStore(support: URL, bookmarkStore: BookmarkStore) -> DocumentStore {
    makeTestDocumentStore(
      indexDatabase: IndexDatabase(
        databaseURL: support.appendingPathComponent("store-\(UUID().uuidString).db")),
      bookmarkStore: bookmarkStore)
  }

  private func makeManager(support: URL, bookmarkStore: BookmarkStore) -> FolderManager {
    FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: support.appendingPathComponent("workspace.json")),
      indexDatabase: IndexDatabase(
        databaseURL: support.appendingPathComponent("index-\(UUID().uuidString).db")),
      bookmarkStore: bookmarkStore,
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true)))
    )
  }
}

/// One window's session, as the user meets it: the session state, the window
/// registry the Open Files sidebar actually renders from, and the window
/// itself so a test can close it the way the user does.
@MainActor
private struct RelaunchedSession {
  let appState: AppState
  let registry: DocumentWindowRegistry
  let window: NSWindow
}

@MainActor
private final class LaunchHarness {
  let root: URL
  let support: URL
  let loose: URL
  let trash: URL
  let defaults: UserDefaults
  /// The restore-on-launch preference this simulated process launches under.
  /// Its own defaults suite, so flipping it never reaches the workspace keys.
  let launchSettings: LaunchSettings
  let manager: FolderManager
  let makeManager: (URL, BookmarkStore) -> FolderManager
  let makeStore: (URL, BookmarkStore) -> DocumentStore
  private var windows: [NSWindow] = []
  /// The launched process's registry and its once-per-process startup-restore
  /// decision, kept so a SECOND window in the same process (the launcher the
  /// registry re-opens after the last document closes) shares both — which is
  /// the whole point of the pin that uses them.
  private var registry: DocumentWindowRegistry?
  private var startupRestore: ApplicationStartupRestore?
  private var bookmarkStore: BookmarkStore?
  /// What `scheduleDeferredMainWork` would run 0.1s later in production.
  private var deferredMainWork: [() -> Void] = []

  init(
    root: URL,
    support: URL,
    loose: URL,
    trash: URL,
    defaults: UserDefaults,
    launchSettings: LaunchSettings,
    manager: FolderManager,
    makeManager: @escaping (URL, BookmarkStore) -> FolderManager,
    makeStore: @escaping (URL, BookmarkStore) -> DocumentStore
  ) {
    self.root = root
    self.support = support
    self.loose = loose
    self.trash = trash
    self.defaults = defaults
    self.launchSettings = launchSettings
    self.manager = manager
    self.makeManager = makeManager
    self.makeStore = makeStore
  }

  func closeWindows() {
    for window in windows { window.close() }
    windows.removeAll()
  }

  @discardableResult
  func writeNote(named name: String, in folder: String? = nil) throws -> URL {
    var directory = root
    if let folder {
      directory = root.appendingPathComponent(folder, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return try write(name: name, in: directory)
  }

  /// A file outside the workspace root — the only kind Open Files carries.
  @discardableResult
  func writeLooseNote(named name: String) throws -> URL {
    try write(name: name, in: loose)
  }

  /// A loose note the user then threw away: still on disk, still resolvable
  /// from its bookmark, and — as far as Pensieve is concerned — gone.
  @discardableResult
  func writeTrashedNote(named name: String) throws -> URL {
    try write(name: name, in: trash)
  }

  /// Seeds the persisted working set the way an older build could leave it:
  /// one file recorded twice. The key is a cross-process contract, so a pin
  /// for the state it can be found in has to name it.
  func persistWorkingSet(_ urls: [URL]) throws {
    let bookmarks = try urls.map {
      try $0.bookmarkData(
        options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    defaults.set(bookmarks, forKey: "Pensieve.workspace.fileBookmarks")
  }

  private func write(name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name).standardizedFileURL
    try name.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  /// The user opening the folder once, which is what persists the root bookmark
  /// every later launch restores from. Any document this leaves selected is the
  /// PREVIOUS session's business; the relaunch below starts from a clean
  /// `AppState`, so only what reached the defaults survives — and with nothing
  /// registered in Open Files, that is exactly "nothing open".
  func openWorkspace() throws {
    let appState = AppState()
    manager.open(url: root, into: appState)
  }

  /// The next launch: brand-new stores reading the same persisted defaults,
  /// driven through the REAL entry point (`AppController.start`) rather than
  /// through `FolderManager` alone. That distinction is the whole point — the
  /// model list and the window registry disagreed for a long time, and only the
  /// registry is what the user sees.
  func relaunch() throws -> RelaunchedSession {
    let bookmarkStore = BookmarkStore(defaults: defaults)
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { true },
      scheduleDeferredMainWork: { [weak self] work in self?.deferredMainWork.append(work) },
      scheduleLauncherWindowSweep: { _ in },
      mergeWindowIntoTabs: { _, _ in },
      orderAndActivateWindow: { _ in },
      currentMergeTarget: { nil },
      closeWindow: { $0.close() }
    )
    self.bookmarkStore = bookmarkStore
    self.registry = registry
    // ONE launch, so ONE startup restore — shared by every window this process
    // goes on to build, exactly as the production singleton is.
    self.startupRestore = ApplicationStartupRestore()

    // The window the app starts in, registered as the launcher exactly the way
    // a cold start does; every LATER window comes from the factory.
    let launcherWindow = makeWindow()
    registry.makeDocumentWindow = { _, _ in launcherWindow }
    registry.openLauncherWindow(intent: .coldLaunch)
    registry.makeDocumentWindow = { [weak self] _, _ in self?.makeWindow() }

    return adoptRootView(for: launcherWindow)
  }

  /// The user closing the last document window. AppKit's close reaches the
  /// registry, which — so the app is never left windowless — re-opens a
  /// launcher through the factory; that launcher's root then runs the same
  /// `start(intent: .coldLaunch)` as the launch one. Returns the
  /// REPLACEMENT launcher's session.
  func closeWindowAdoptingTheReplacementLauncher(_ window: NSWindow) -> RelaunchedSession {
    guard let registry else {
      preconditionFailure("relaunch() first: there is no launched process to close a window in")
    }
    let windowsBefore = windows.count
    window.close()
    registry.handleWindowClosed(window, tombstonePolicy: .reusableWindow)
    runDeferredMainWork()
    guard windows.count > windowsBefore, let replacement = windows.last else {
      preconditionFailure(
        "closing the last document window left the app windowless — the registry never"
          + " re-opened a launcher, so this pin is not exercising the reported path")
    }
    return adoptRootView(for: replacement)
  }

  /// Everything `DocumentWindowRootView` does for one window: build the
  /// session and controller, publish the controller to the registry, run the
  /// launch decision, and report back what the window ended up holding.
  private func adoptRootView(for window: NSWindow) -> RelaunchedSession {
    guard let registry, let bookmarkStore, let startupRestore else {
      preconditionFailure("relaunch() first: there is no launched process to build a window in")
    }
    let appState = AppState()
    let controller = AppController(
      appState: appState,
      folderManager: makeManager(support, bookmarkStore),
      documentStore: makeStore(support, bookmarkStore),
      indexDatabase: IndexDatabase(
        databaseURL: support.appendingPathComponent("launch-\(UUID().uuidString).db")),
      launchSettings: launchSettings,
      documentWindowRegistry: registry,
      startupRestore: startupRestore
    )
    controller.requestOpenDocumentWindow = { registry.open($0) }
    registry.registerController(controller, for: window)

    controller.start(intent: .coldLaunch)

    // What SwiftUI's `DocumentWindowAccessor` publishes for this window,
    // spelled out: a headless test has no render pass, so nothing else would
    // ever tell the registry what this window ended up holding. Every value is
    // read from the session — the simulation reports the state, it does not
    // invent it, so a launch that loaded nothing still registers as a launcher.
    registry.attach(
      window,
      identity: appState.documentSession.identity,
      documentID: appState.selectedDocumentID,
      title: appState.documentSession.displayTitle,
      representedURL: appState.documentSession.url,
      isDirty: appState.documentSession.isDirty,
      hasEditableBuffer: appState.documentSession.hasEditableBuffer)

    return RelaunchedSession(appState: appState, registry: registry, window: window)
  }

  /// Runs what production would run 0.1s after the close, and nothing that the
  /// run itself enqueues — one turn of the main queue, not a spin to fixpoint.
  private func runDeferredMainWork() {
    let pending = deferredMainWork
    deferredMainWork.removeAll()
    for work in pending { work() }
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: .zero)
    windows.append(window)
    return window
  }
}
