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
/// the user left empty there is no previous selection, so that branch runs, loads
/// a document nobody asked for, and `loadClean` writes it to
/// `Pensieve.workspace.activeDocument` — which the NEXT launch then claims,
/// making it self-sustaining. `claimActiveDocumentForRestore` never removes the
/// key, so once written it stays written.
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
      relaunched.selectedDocumentID,
      "the launch selected a document the user never opened — `documents.first` is not a"
        + " session, it is whatever the scanner happened to reach first")
    XCTAssertNil(
      relaunched.documentSession.url,
      "worse than selected: it was LOADED, so the window came back showing a file the user"
        + " had not opened")
    XCTAssertTrue(
      relaunched.openFiles.isEmpty,
      "an empty working set must stay empty across a launch")
    XCTAssertNil(
      BookmarkStore(defaults: harness.defaults).claimActiveDocumentForRestore(),
      "the auto-load wrote its own reopen record, which is what makes the resurrection"
        + " self-sustaining: every later launch claims it before the workspace is even scanned")
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
  func testAFileLeftOpenAtQuitStillComesBack() throws {
    let harness = try makeHarness()
    let keptURL = try harness.writeLooseNote(named: "kept.md")
    try harness.openWorkspace()

    let session = AppState()
    XCTAssertNotNil(harness.manager.registerOpenFile(url: keptURL, into: session))

    let relaunched = try harness.relaunch()
    XCTAssertTrue(
      relaunched.openFiles.contains { $0.url.standardizedFileURL == keptURL },
      "quitting with a file open must bring it back")
  }

  /// The reopen record is a ONE-SHOT. It survived the claim, so a document that
  /// once became active came back on every launch after that — including launches
  /// where the user had closed it, as long as nothing happened to rewrite the key.
  func testTheReopenRecordIsConsumedByTheLaunchThatClaimsIt() throws {
    let harness = try makeHarness()
    let noteURL = try harness.writeNote(named: "active.md")

    harness.documentStore.noteActiveDocumentForRestore(noteURL)

    let firstLaunch = BookmarkStore(defaults: harness.defaults)
    XCTAssertEqual(
      firstLaunch.claimActiveDocumentForRestore()?.standardizedFileURL, noteURL,
      "the launch that follows a quit must still reopen the document the user was on")

    let secondLaunch = BookmarkStore(defaults: harness.defaults)
    XCTAssertNil(
      secondLaunch.claimActiveDocumentForRestore(),
      "the record outlived the launch that used it, so it reopens the same document forever —"
        + " restore is a hand-off, not a standing instruction")
  }

  /// Consuming the record must not cost the user the document while the app is
  /// still running: the window that claimed it re-publishes it on load and on
  /// every key activation, so a quit with that document frontmost restores it
  /// again.
  func testTheRecordIsRewrittenBySimplyWorkingInTheRestoredDocument() throws {
    let harness = try makeHarness()
    let noteURL = try harness.writeNote(named: "active.md")

    harness.documentStore.noteActiveDocumentForRestore(noteURL)
    let launch = BookmarkStore(defaults: harness.defaults)
    XCTAssertNotNil(launch.claimActiveDocumentForRestore())

    // What the app does the moment the restored window shows the document.
    harness.documentStore.noteActiveDocumentForRestore(noteURL)

    XCTAssertEqual(
      BookmarkStore(defaults: harness.defaults)
        .claimActiveDocumentForRestore()?.standardizedFileURL,
      noteURL,
      "consuming the record must not make the CURRENT session unrestorable — the live window"
        + " owns it again as soon as it is showing the document")
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
    for directory in [root, support, loose] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    addTeardownBlock {
      try? FileManager.default.removeItem(at: container)
    }

    let defaults = makeEphemeralDefaults(prefix: "PensieveLaunchOpensNothing")
    let bookmarkStore = BookmarkStore(defaults: defaults)
    return LaunchHarness(
      root: root,
      support: support,
      loose: loose,
      defaults: defaults,
      manager: makeManager(support: support, bookmarkStore: bookmarkStore),
      documentStore: makeTestDocumentStore(bookmarkStore: bookmarkStore),
      makeManager: makeManager
    )
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

@MainActor
private struct LaunchHarness {
  let root: URL
  let support: URL
  let loose: URL
  let defaults: UserDefaults
  let manager: FolderManager
  let documentStore: DocumentStore
  let makeManager: (URL, BookmarkStore) -> FolderManager

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

  private func write(name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name).standardizedFileURL
    try name.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  /// The user opening the folder once, which is what persists the root bookmark
  /// every later launch restores from. Any document this leaves selected is the
  /// PREVIOUS session's business; the relaunch below starts from a clean
  /// `AppState`, so only what reached the defaults survives.
  func openWorkspace() throws {
    let appState = AppState()
    manager.open(url: root, into: appState)
    // Whatever that open selected, the user then closed — the working set the
    // next launch reads must be exactly "nothing open".
    BookmarkStore(defaults: defaults).persistActiveDocument(url: nil)
  }

  /// The next launch: brand-new stores reading the same persisted defaults.
  func relaunch() throws -> AppState {
    let appState = AppState()
    makeManager(support, BookmarkStore(defaults: defaults)).restoreLastFolder(into: appState)
    return appState
  }
}
