import Foundation
import XCTest

@testable import Pensieve

/// Closing a file out of Open Files has to OUTLIVE the process.
///
/// The operator's standing manual test — close the row with "×", ⌘Q, relaunch,
/// the file must not be back — failed on build 446, and it failed for a reason
/// no window-level test could ever see: the close was real. The window went
/// away, the row went away, the file was gone for the rest of the session. What
/// nothing did was tell the WORKING SET, and the working set is what a relaunch
/// reads. So every launch resolved the same never-pruned bookmark and put the
/// file back, forever.
///
/// These pins therefore live at the store level and span a simulated relaunch:
/// fresh stores over the SAME defaults, which is exactly what the next launch
/// of the app is. Asserting on the live window registry would have passed
/// throughout the bug.
@MainActor
final class ClosedFileStaysClosedTests: XCTestCase {
  /// THE REGRESSION PIN — the operator's cycle, minus the windows.
  func testAFileClosedOutOfOpenFilesIsNotRestoredByTheNextLaunch() throws {
    let harness = try makeHarness()
    let noteURL = try harness.writeNote(named: "closed.md")

    let session = AppState()
    XCTAssertNotNil(harness.manager.registerOpenFile(url: noteURL, into: session))
    XCTAssertEqual(session.openFiles.map(\.url), [noteURL])

    harness.documentStore.forgetOpenFile(noteURL, into: session)
    XCTAssertTrue(session.openFiles.isEmpty, "the close must empty the list it was invoked from")

    let relaunched = try harness.relaunch()
    XCTAssertFalse(
      relaunched.openFiles.contains { $0.url == noteURL },
      "a file the user closed came back on the next launch — the close never reached the"
        + " working set the launch restores from")
    XCTAssertNotEqual(
      relaunched.selectedDocumentID, noteURL,
      "worse than coming back: it came back SELECTED, re-arming the reopen record and making"
        + " the resurrection self-sustaining")
  }

  /// The control leg. Without the close, the very same harness DOES bring the
  /// file back — so the pin above is measuring the close, not a restore path
  /// that happens to be inert under test.
  func testAFileLeftOpenIsStillRestoredByTheNextLaunch() throws {
    let harness = try makeHarness()
    let noteURL = try harness.writeNote(named: "kept.md")

    let session = AppState()
    XCTAssertNotNil(harness.manager.registerOpenFile(url: noteURL, into: session))

    let relaunched = try harness.relaunch()
    XCTAssertTrue(
      relaunched.openFiles.contains { $0.url == noteURL },
      "quitting with a file open must bring it back — this is the behaviour the close is"
        + " carved out of, and a pin that forgets everything would break it silently")
  }

  /// The store-level half of the same truth, stated where the bookmark lives:
  /// a closed file must leave no entry for the restore to resolve. Kept separate
  /// because `removeFile` is the piece with no prior existence — before this fix
  /// `BookmarkStore` had no single-file removal API at all, which is why the
  /// close had nowhere to land.
  func testClosingAFileLeavesNoBookmarkForTheRestoreToResolve() throws {
    let harness = try makeHarness()
    let closedURL = try harness.writeNote(named: "closed.md")
    let keptURL = try harness.writeNote(named: "kept.md")

    let session = AppState()
    XCTAssertNotNil(harness.manager.registerOpenFile(url: closedURL, into: session))
    XCTAssertNotNil(harness.manager.registerOpenFile(url: keptURL, into: session))

    harness.documentStore.forgetOpenFile(closedURL, into: session)

    // Resolved bookmarks come back as the PHYSICAL path (`/private/var/…`),
    // so compare on the standardized form the rest of the app keys documents by.
    let restored = BookmarkStore(defaults: harness.defaults).restoreWorkspace(into: AppState())
    let restoredPaths = Set(restored.fileURLs.map(\.standardizedFileURL.path))
    XCTAssertFalse(
      restoredPaths.contains(closedURL.path),
      "the closed file still has a bookmark, so every future launch will resolve it again")
    XCTAssertTrue(
      restoredPaths.contains(keptURL.path),
      "closing one file must not prune the others — identity is the resolved path, not"
        + " \"everything in the key\"")
  }

  /// Closing a file also has to drop the "reopen this on launch" record, which
  /// is a SECOND store and a second resurrection route: it is re-armed on every
  /// successful load and never consumed at claim, so a file that keeps it comes
  /// back even once its bookmark is gone.
  func testClosingTheActiveFileAlsoDropsTheReopenOnLaunchRecord() throws {
    let harness = try makeHarness()
    let noteURL = try harness.writeNote(named: "active.md")

    let session = AppState()
    XCTAssertNotNil(harness.manager.registerOpenFile(url: noteURL, into: session))
    harness.documentStore.noteActiveDocumentForRestore(noteURL)

    harness.documentStore.forgetOpenFile(noteURL, into: session)

    XCTAssertNil(
      BookmarkStore(defaults: harness.defaults).claimActiveDocumentForRestore(),
      "the closed file is still the document the next launch reopens")
  }

  // MARK: - Harness

  private func makeHarness() throws -> RelaunchHarness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PensieveClosedFileStaysClosed-\(UUID().uuidString)", isDirectory: true)
    let support = root.appendingPathComponent("Support", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: root)
    }

    let defaults = makeEphemeralDefaults(prefix: "PensieveClosedFileStaysClosed")
    let bookmarkStore = BookmarkStore(defaults: defaults)
    return RelaunchHarness(
      root: root,
      support: support,
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
private struct RelaunchHarness {
  let root: URL
  let support: URL
  let defaults: UserDefaults
  let manager: FolderManager
  let documentStore: DocumentStore
  let makeManager: (URL, BookmarkStore) -> FolderManager

  func writeNote(named name: String) throws -> URL {
    let url = root.appendingPathComponent(name).standardizedFileURL
    try name.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  /// The next launch: brand-new stores reading the same persisted defaults,
  /// with nothing carried over in memory. This is the step the bug hid behind —
  /// in-session everything looked closed.
  func relaunch() throws -> AppState {
    let appState = AppState()
    makeManager(support, BookmarkStore(defaults: defaults)).restoreLastFolder(into: appState)
    return appState
  }
}
