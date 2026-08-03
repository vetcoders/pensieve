import Foundation
import XCTest

@testable import Pensieve

/// What the persisted working set is allowed to hand a launch.
///
/// Both failures here were measured in the operator's `defaults`, not argued.
/// `Pensieve.workspace.fileBookmarks` held FIFTEEN entries for twelve files —
/// three of them were the same file twice — and one of the survivors resolved
/// into `~/.Trash`. The launch restore opens that set for real, one tab per
/// ref, so each duplicate was a second tab on the same document and the trashed
/// entry was a document the user had thrown away coming back as a tab.
///
/// Both are properties of the STORE, so they are pinned at the store: the fix
/// has to hold for the install that already has such a key, which means the
/// restore itself must clean it up rather than merely refuse to act on it.
@MainActor
final class StartupRestoreWorkingSetHygieneTests: XCTestCase {
  /// The persisted key, spelled out. It is a cross-process contract, so a test
  /// that seeds the shape an older build left behind has to name it.
  private let fileBookmarksKey = "Pensieve.workspace.fileBookmarks"

  // MARK: - Duplicates

  /// THE LEGACY CASE: a key that already names one file twice. Nothing in
  /// session can repair it — only the restore reads that key — so the restore
  /// is where the duplicate has to die, in the returned set AND in the key.
  func testARepeatedBookmarkRestoresOnceAndLosesItsDuplicate() throws {
    let harness = try makeHarness()
    let note = try harness.writeNote(named: "kept.md")
    let bookmark = try harness.bookmarkData(for: note)
    harness.defaults.set([bookmark, bookmark], forKey: fileBookmarksKey)

    let restored = BookmarkStore(defaults: harness.defaults)
      .restoreWorkspace(into: AppState())

    XCTAssertEqual(
      restored.fileURLs.map(\.standardizedFileURL), [note],
      "the same file came back twice — the startup restore turns each of those refs into its"
        + " own request for a window, so this is two tabs on one document")
    XCTAssertEqual(
      harness.persistedFileBookmarks.count, 1,
      "the duplicate survived in the key, so the next launch would restore it again")

    // PERMANENTLY, not once per launch. Sediment that is merely filtered on
    // read is sediment forever: it survives every launch, and every launch
    // pays to resolve it. A launch that finds it must also remove it.
    let nextLaunch = BookmarkStore(defaults: harness.defaults)
      .restoreWorkspace(into: AppState())
    XCTAssertEqual(nextLaunch.fileURLs.map(\.standardizedFileURL), [note])
    XCTAssertEqual(harness.persistedFileBookmarks.count, 1)
  }

  /// THE WRITER'S HALF. `persistFile` decides what the key already holds, and
  /// it used to decide it by comparing bookmark BLOBS — which is not an
  /// identity for the file behind them. Faced with a key that already names one
  /// file twice it kept both and the duplicate outlived every later open.
  /// Identity is the resolved path, so the entry the user is opening collapses
  /// onto one, in the place the first copy held.
  func testPersistingAFileTheKeyAlreadyHoldsTwiceCollapsesTheDuplicate() throws {
    let harness = try makeHarness()
    let first = try harness.writeNote(named: "first.md")
    let repeated = try harness.writeNote(named: "repeated.md")
    let bookmark = try harness.bookmarkData(for: repeated)
    let store = BookmarkStore(defaults: harness.defaults)
    try store.persistFile(url: first, into: AppState())
    harness.defaults.set(
      harness.persistedFileBookmarks + [bookmark, bookmark], forKey: fileBookmarksKey)

    try store.persistFile(url: repeated, into: AppState())

    XCTAssertEqual(
      harness.persistedFileBookmarks.count, 2,
      "opening the file again left its duplicate in the key — the working set keeps two entries"
        + " for one document, and the next launch opens both")
    XCTAssertEqual(
      store.restoreWorkspace(into: AppState()).fileURLs.map(\.standardizedFileURL),
      [first, repeated],
      "the surviving entry must still be the same file, in the place it already held")
  }

  /// CONTROL: de-duplication must not become "keep one file". Two DIFFERENT
  /// files stay two entries, in the order they were recorded — the working set
  /// is ordered, and the cap prunes from the front of it.
  func testTwoDifferentFilesStayTwoEntriesInOrder() throws {
    let harness = try makeHarness()
    let first = try harness.writeNote(named: "first.md")
    let second = try harness.writeNote(named: "second.md")
    let store = BookmarkStore(defaults: harness.defaults)
    let appState = AppState()

    try store.persistFile(url: first, into: appState)
    try store.persistFile(url: second, into: appState)

    XCTAssertEqual(
      store.restoreWorkspace(into: AppState()).fileURLs.map(\.standardizedFileURL),
      [first, second])
  }

  /// CONTROL: re-persisting a file the key already holds must not move it to
  /// the end. The order of this key IS the working set's order, and the cap
  /// keeps its tail — a silent reorder would change which files a launch over
  /// the cap decides to forget.
  func testRePersistingAFileKeepsItsPlaceInTheWorkingSet() throws {
    let harness = try makeHarness()
    let first = try harness.writeNote(named: "first.md")
    let second = try harness.writeNote(named: "second.md")
    let store = BookmarkStore(defaults: harness.defaults)
    let appState = AppState()

    try store.persistFile(url: first, into: appState)
    try store.persistFile(url: second, into: appState)
    try store.persistFile(url: first, into: appState)

    XCTAssertEqual(
      store.restoreWorkspace(into: AppState()).fileURLs.map(\.standardizedFileURL),
      [first, second])
  }

  /// THE OTHER WRITER. `replaceWorkspace` rewrites the whole key in one go —
  /// it is the only path that could seed a duplicate merely by being handed
  /// one. Its caller passes a list that is de-duplicated upstream, which is
  /// exactly the kind of fact that stops being true the day someone adds a
  /// second caller.
  func testReplacingTheWorkspaceRecordsEachFileOnce() throws {
    let harness = try makeHarness()
    let first = try harness.writeNote(named: "first.md")
    let second = try harness.writeNote(named: "second.md")
    let store = BookmarkStore(defaults: harness.defaults)

    try store.replaceWorkspace(
      rootURLs: [], fileURLs: [first, second, first], into: AppState())

    XCTAssertEqual(harness.persistedFileBookmarks.count, 2)
    XCTAssertEqual(
      store.restoreWorkspace(into: AppState()).fileURLs.map(\.standardizedFileURL),
      [first, second],
      "the working set kept a second entry for a file it already held, in the order it was"
        + " first recorded")
  }

  // MARK: - Trash

  /// The Trash is dead: a file whose bookmark leads into it does not exist for
  /// Pensieve. It passes the existence check — a trashed file is still a file —
  /// so nothing else in the restore would have stopped it from coming back as
  /// an open document.
  func testAFileInTheTrashIsNeitherRestoredNorKept() throws {
    let harness = try makeHarness()
    let trashed = try harness.writeTrashedNote(named: "thrown-away.md")
    let kept = try harness.writeNote(named: "kept.md")
    let store = BookmarkStore(defaults: harness.defaults)
    let appState = AppState()
    try store.persistFile(url: trashed, into: appState)
    try store.persistFile(url: kept, into: appState)
    XCTAssertEqual(harness.persistedFileBookmarks.count, 2, "both were recorded before the launch")

    let restored = BookmarkStore(defaults: harness.defaults)
      .restoreWorkspace(into: AppState())

    XCTAssertEqual(
      restored.fileURLs.map(\.standardizedFileURL), [kept],
      "a document the user threw away came back as an open file")
    XCTAssertEqual(
      harness.persistedFileBookmarks.count, 1,
      "the trashed ref kept its bookmark, so it would be back on the next launch — and its"
        + " security-scoped grant with it")
  }

  /// CONTROL, and the line the Trash rule must not cross: an entry that is
  /// merely GONE keeps its bookmark. Unresolvable is not garbage — an unplugged
  /// volume must never be a reason to forget a file the user did not close — so
  /// it drops out of this launch's set and out of nothing else.
  func testAMissingFileDropsFromTheLaunchButKeepsItsBookmark() throws {
    let harness = try makeHarness()
    let note = try harness.writeNote(named: "vanishes.md")
    let store = BookmarkStore(defaults: harness.defaults)
    try store.persistFile(url: note, into: AppState())
    try FileManager.default.removeItem(at: note)

    let restored = BookmarkStore(defaults: harness.defaults)
      .restoreWorkspace(into: AppState())

    XCTAssertTrue(restored.fileURLs.isEmpty)
    XCTAssertEqual(
      harness.persistedFileBookmarks.count, 1,
      "a file that is missing today is not a file the user closed")
  }

  // MARK: - Harness

  private func makeHarness() throws -> WorkingSetHarness {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PensieveWorkingSetHygiene-\(UUID().uuidString)", isDirectory: true)
    let root = container.appendingPathComponent("Notes", isDirectory: true)
    // A Trash directory of our own: the pin must never touch the real one, and
    // the product rule is about the LOCATION — `~/.Trash` and a volume's
    // `/.Trashes` alike — not about one particular path.
    let trash = container.appendingPathComponent(".Trash", isDirectory: true)
    for directory in [root, trash] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    addTeardownBlock {
      try? FileManager.default.removeItem(at: container)
    }
    return WorkingSetHarness(
      root: root,
      trash: trash,
      defaults: makeEphemeralDefaults(prefix: "PensieveWorkingSetHygiene"),
      fileBookmarksKey: fileBookmarksKey)
  }
}

@MainActor
private struct WorkingSetHarness {
  let root: URL
  let trash: URL
  let defaults: UserDefaults
  let fileBookmarksKey: String

  var persistedFileBookmarks: [Data] {
    defaults.array(forKey: fileBookmarksKey) as? [Data] ?? []
  }

  func writeNote(named name: String) throws -> URL {
    try write(name: name, in: root)
  }

  func writeTrashedNote(named name: String) throws -> URL {
    try write(name: name, in: trash)
  }

  func bookmarkData(for url: URL) throws -> Data {
    try url.bookmarkData(
      options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
  }

  private func write(name: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent(name).standardizedFileURL
    try name.write(to: url, atomically: true, encoding: .utf8)
    return url
  }
}
