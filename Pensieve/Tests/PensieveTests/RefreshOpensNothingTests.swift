import Foundation
import XCTest

@testable import Pensieve

/// The second half of "the app never picks a document for you": the LIVE
/// refresh, not the launch.
///
/// `applyRefresh` ended in the same `else if let first = documents.first` the
/// restore path did. It is reached from exactly two places — the debounced file
/// watcher and the forced refresh explicit actions schedule (create, save,
/// rename, move, trash, exclusion changes) — so it always runs against a
/// workspace that is ALREADY open. Nothing switches workspaces through here;
/// `open`/`openFolder` go down the cold path and end in
/// `selectRestoredDocument` instead.
///
/// That left two ways for the app to open a document nobody asked for:
///
/// - nothing selected (which, since the launch fix, is what an untouched
///   session looks like) and any file event at all — the next refresh picked
///   `documents.first` and loaded it;
/// - the document the user WAS reading leaves the workspace — trashed, or its
///   subtree excluded — and `removeReferences` has already nilled the
///   selection, so the same branch handed them a neighbouring file instead of
///   an empty editor.
///
/// The operator's decision is that both show the empty state. The paths that
/// legitimately move a selection do not go through this branch at all: rename
/// and move re-point `selectedDocumentID` to the new URL through
/// `replaceReferences` BEFORE the refresh runs, and create/duplicate select the
/// new document themselves. Those are the control legs below.
@MainActor
final class RefreshOpensNothingTests: XCTestCase {
  /// THE REGRESSION PIN, case one: an open workspace with nothing selected —
  /// the launcher state — plus one file event. Before the fix, the refresh
  /// that event triggers opened a document on its own.
  func testARefreshWithNothingSelectedOpensNothing() async throws {
    let harness = try makeHarness()
    _ = try harness.writeNote(named: "alpha.md", in: "Archive")
    _ = try harness.writeNote(named: "beta.md")

    let appState = AppState()
    harness.manager.open(url: harness.root, into: appState)
    await harness.manager.waitForPendingWorkspaceBuild()
    XCTAssertNil(appState.selectedDocumentID, "precondition: the open selects nothing")

    _ = try harness.writeNote(named: "gamma.md")
    harness.manager.refresh(into: appState, force: true)
    await harness.manager.waitForPendingForcedRefresh()

    XCTAssertEqual(
      appState.documents.count, 3, "precondition: the refresh really did republish the tree")
    XCTAssertNil(
      appState.selectedDocumentID,
      "a file appearing in the workspace is not a request to open anything — the refresh chose"
        + " `documents.first` for a user who had chosen nothing")
    XCTAssertNil(appState.documentSession.url, "and it did not merely select it, it LOADED it")
    XCTAssertEqual(appState.activeDocumentText, "")
  }

  /// THE REGRESSION PIN, case two: the document being read leaves the
  /// workspace. `removeReferences` has already cleared the selection and the
  /// session by the time the refresh lands, so the fallback was free to hand
  /// the user a different file — in an editor they had not asked to change.
  func testDeletingTheOpenDocumentLeavesTheEditorEmpty() async throws {
    let harness = try makeHarness()
    let alphaURL = try harness.writeNote(named: "alpha.md", in: "Archive")
    _ = try harness.writeNote(named: "beta.md")

    let appState = AppState()
    harness.manager.open(url: harness.root, into: appState)
    await harness.manager.waitForPendingWorkspaceBuild()
    selectDocument(at: alphaURL, in: appState)
    XCTAssertEqual(appState.documentSession.url?.standardizedFileURL, alphaURL)

    try FileManager.default.removeItem(at: alphaURL)
    appState.selectedDocumentID = nil
    appState.documentSession.clear()
    harness.manager.refresh(into: appState, force: true)
    await harness.manager.waitForPendingForcedRefresh()

    XCTAssertNil(
      appState.selectedDocumentID,
      "losing the document you were reading is not an instruction to read a different one")
    XCTAssertNil(appState.documentSession.url)
    XCTAssertEqual(appState.activeDocumentText, "")
  }

  /// THE REGRESSION PIN, case three: excluding the subtree the open document
  /// lives in. Same branch, and the one the operator named directly.
  func testExcludingTheSubtreeYouAreReadingLeavesTheEditorEmpty() async throws {
    let harness = try makeHarness()
    let alphaURL = try harness.writeNote(named: "alpha.md", in: "Archive")
    _ = try harness.writeNote(named: "beta.md")

    let appState = AppState()
    harness.manager.open(url: harness.root, into: appState)
    await harness.manager.waitForPendingWorkspaceBuild()
    selectDocument(at: alphaURL, in: appState)

    harness.manager.addExcludedURLs(
      [harness.root.appendingPathComponent("Archive", isDirectory: true)], into: appState)
    await harness.manager.waitForPendingForcedRefresh()

    XCTAssertFalse(
      appState.documents.contains { $0.url.standardizedFileURL == alphaURL },
      "precondition: the exclusion really did drop the document from the workspace")
    XCTAssertNil(
      appState.selectedDocumentID,
      "hiding a folder must empty the editor, not silently swap in whatever file the scanner"
        + " reaches first")
    XCTAssertEqual(appState.activeDocumentText, "")
  }

  /// CONTROL LEG: the document you are reading survives the refresh. It must
  /// stay selected AND pick up what changed on disk — this is the branch above
  /// the one being removed, and the reason a refresh exists at all.
  func testARefreshKeepsAndReloadsTheDocumentYouAreReading() async throws {
    let harness = try makeHarness()
    let noteURL = try harness.writeNote(named: "note.md")

    let appState = AppState()
    harness.manager.open(url: harness.root, into: appState)
    await harness.manager.waitForPendingWorkspaceBuild()
    selectDocument(at: noteURL, in: appState)

    try "rewritten outside the app".write(to: noteURL, atomically: true, encoding: .utf8)
    harness.manager.refresh(into: appState, force: true)
    await harness.manager.waitForPendingForcedRefresh()

    XCTAssertEqual(appState.selectedDocumentID?.standardizedFileURL, noteURL)
    XCTAssertEqual(appState.activeDocumentText, "rewritten outside the app")
    XCTAssertFalse(appState.activeDocumentDirty)
  }

  /// CONTROL LEG: renaming the open document. This is the case that LOOKS like
  /// it depends on the removed fallback — the old URL is gone from the
  /// workspace after the scan — and does not: `replaceReferences` re-points the
  /// selection to the new URL before the refresh is scheduled, so the document
  /// is found by the branch above.
  func testRenamingTheOpenDocumentKeepsItOpenUnderItsNewName() async throws {
    let harness = try makeHarness()
    let noteURL = try harness.writeNote(named: "note.md")

    let appState = AppState()
    harness.manager.open(url: harness.root, into: appState)
    await harness.manager.waitForPendingWorkspaceBuild()
    selectDocument(at: noteURL, in: appState)

    XCTAssertTrue(harness.manager.rename(url: noteURL, to: "renamed.md", into: appState))
    await harness.manager.waitForPendingForcedRefresh()

    let renamedURL = harness.root.appendingPathComponent("renamed.md").standardizedFileURL
    XCTAssertEqual(
      appState.selectedDocumentID?.standardizedFileURL, renamedURL,
      "a rename keeps you in the document you were reading")
    XCTAssertEqual(appState.documentSession.url?.standardizedFileURL, renamedURL)
  }

  /// CONTROL LEG: an unsaved buffer is still protected. The dirty guard sits
  /// above the removed branch, and removing the branch must not turn "we leave
  /// your unsaved work alone" into "we clear it".
  func testARefreshStillProtectsAnUnsavedBuffer() async throws {
    let harness = try makeHarness()
    let noteURL = try harness.writeNote(named: "note.md")

    let appState = AppState()
    harness.manager.open(url: harness.root, into: appState)
    await harness.manager.waitForPendingWorkspaceBuild()
    selectDocument(at: noteURL, in: appState)

    appState.activeDocumentText = "unsaved edit"
    appState.activeDocumentDirty = true
    try FileManager.default.removeItem(at: noteURL)
    harness.manager.refresh(into: appState, force: true)
    await harness.manager.waitForPendingForcedRefresh()

    XCTAssertEqual(appState.activeDocumentText, "unsaved edit", "dirty buffer preserved")
    XCTAssertTrue(appState.documentSession.isDirty)
  }

  // MARK: - Harness

  private func makeHarness() throws -> RefreshHarness {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PensieveRefreshOpensNothing-\(UUID().uuidString)", isDirectory: true)
    let root = container.appendingPathComponent("Workspace", isDirectory: true)
    let support = container.appendingPathComponent("Support", isDirectory: true)
    for directory in [root, support] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    addTeardownBlock {
      try? FileManager.default.removeItem(at: container)
    }

    let manager = FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: support.appendingPathComponent("workspace.json")),
      indexDatabase: IndexDatabase(
        databaseURL: support.appendingPathComponent("index-\(UUID().uuidString).db")),
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveRefreshOpensNothing")),
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true))),
      // A real watcher would fire its own refreshes mid-test and the assertions
      // would be racing it; every refresh here is scheduled explicitly.
      watcher: FileWatcher(sourceFactory: { @Sendable in SilentWatcherEventSource() })
    )
    return RefreshHarness(root: root, manager: manager)
  }
}

@MainActor
private struct RefreshHarness {
  let root: URL
  let manager: FolderManager

  @discardableResult
  func writeNote(named name: String, in folder: String? = nil) throws -> URL {
    var directory = root
    if let folder {
      directory = root.appendingPathComponent(folder, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let url = directory.appendingPathComponent(name).standardizedFileURL
    try name.write(to: url, atomically: true, encoding: .utf8)
    return url
  }
}

/// A watcher that never fires: these tests schedule every refresh themselves.
private final class SilentWatcherEventSource: FileWatcherEventSource, @unchecked Sendable {
  func start(
    paths: [String],
    onEvents: @escaping @Sendable ([FileWatcherEvent]) -> Void
  ) throws {}

  func stop() {}
}
