import Foundation
import XCTest

@testable import Pensieve

/// What the persisted ROOT set is allowed to hand a launch, and what a launch is
/// allowed to hand the scanner.
///
/// Measured, not argued: production Pensieve 0.4.4 reached 8.6 GB resident over a
/// five-hour workspace scan, and `Pensieve.workspace.rootBookmarks` held one real
/// notes folder plus FOUR entries for `/tmp` — one more per launch across
/// 2026-08-19…08-26. Every entry in that key gets its own full recursive walk, so
/// four copies of one root is four traversals of one tree.
///
/// Two writers produced them. `persistRoot` deduped on bookmark BLOB equality,
/// which is not an identity for the directory behind the bytes, and the restore's
/// stale-bookmark refresh went through `persistRoot`, which APPENDED the
/// refreshed blob and left the stale one in the key. The fixtures below build
/// exactly that shape: renaming a directory makes its bookmark resolvable AND
/// stale, and a blob minted afterwards for the same directory differs byte for
/// byte from the one that came before it.
@MainActor
final class WorkspaceRootBookmarkHygieneTests: XCTestCase {
  /// The persisted key, spelled out. It is a cross-process contract, so a test
  /// that seeds the shape an older build left behind has to name it.
  private let rootBookmarksKey = "Pensieve.workspace.rootBookmarks"

  // MARK: - The writer

  /// THE WRITER'S HALF. Opening a folder the workspace already holds must not
  /// grow the key. Blob equality happened to hide this whenever the two mints
  /// produced identical bytes; a stale entry is precisely the case where they
  /// do not.
  func testPersistingTheSameRootTwiceKeepsOneEntry() throws {
    let harness = try makeHarness()
    let root = try harness.makeFolder(named: "Notes")
    let store = harness.makeBookmarkStore()

    try store.persistRoot(url: root, into: AppState())
    try store.persistRoot(url: root, into: AppState())

    XCTAssertEqual(
      harness.persistedRootBookmarks.count, 1,
      "re-opening a folder already in the workspace recorded it a second time — the sidebar build"
        + " then walks that tree twice")
    XCTAssertEqual(harness.persistedRootPaths, [root.standardizedFileURL.path])
  }

  /// Two spellings of one real directory are one root. The temp fixture lives
  /// under `/var`, so `/private` + that path is the other macOS name of the
  /// same folder — the same alias pair as `/tmp` vs `/private/tmp`, without
  /// walking the operator's real `/private/tmp`.
  func testTwoSpellingsOfOneDirectoryCollapseOnPersist() throws {
    let harness = try makeHarness()
    let root = try harness.makeFolder(named: "Notes")
    let aliasSpelling = URL(
      fileURLWithPath: "/private" + root.standardizedFileURL.path, isDirectory: true)
    XCTAssertTrue(
      root.standardizedFileURL.path.hasPrefix("/var/"),
      "Precondition: this fixture needs a temp directory under the /var alias")
    XCTAssertTrue(FileManager.default.fileExists(atPath: aliasSpelling.path))
    let store = harness.makeBookmarkStore()

    try store.persistRoot(url: root, into: AppState())
    try store.persistRoot(url: aliasSpelling, into: AppState())

    XCTAssertEqual(
      harness.persistedRootBookmarks.count, 1,
      "two spellings of one directory were recorded as two roots")
    XCTAssertEqual(harness.persistedRootPaths, [root.standardizedFileURL.path])
  }

  /// The blobs the operator's key actually held: several DIFFERENT byte strings,
  /// every one of them resolving to the same directory. Identity is what a blob
  /// resolves to, so an ordinary open collapses them — the key heals without
  /// waiting for the next launch.
  func testDistinctBlobsForOneDirectoryCollapseOnTheNextOpen() throws {
    let harness = try makeHarness()
    let first = try harness.makeFolder(named: "First")
    let repeated = try harness.makeFolder(named: "Repeated")
    let store = harness.makeBookmarkStore()
    try store.persistRoot(url: first, into: AppState())
    let sediment = try harness.staleBlobs(count: 3, for: repeated)
    XCTAssertEqual(
      Set(sediment).count, 3,
      "Precondition: the fixture must be DISTINCT blobs, or blob equality"
        + " would already have caught them")
    harness.defaults.set(harness.persistedRootBookmarks + sediment, forKey: rootBookmarksKey)

    try store.persistRoot(url: repeated, into: AppState())

    XCTAssertEqual(harness.persistedRootBookmarks.count, 2)
    XCTAssertEqual(
      harness.persistedRootPaths,
      [first.standardizedFileURL.path, repeated.standardizedFileURL.path],
      "the survivor must be the same directory, in the place its first copy already held")
  }

  /// CONTROL: de-duplication must not become "keep one root". Two different
  /// folders stay two roots, in the order they were opened — that order is the
  /// sidebar's, and the first entry is what the workspace cache identity reads.
  func testTwoDifferentRootsStayTwoEntriesInOrder() throws {
    let harness = try makeHarness()
    let first = try harness.makeFolder(named: "First")
    let second = try harness.makeFolder(named: "Second")
    let store = harness.makeBookmarkStore()

    try store.persistRoot(url: first, into: AppState())
    try store.persistRoot(url: second, into: AppState())

    XCTAssertEqual(
      harness.persistedRootPaths,
      [first.standardizedFileURL.path, second.standardizedFileURL.path])
  }

  /// CONTROL: a root nested inside another root is not a duplicate. The user
  /// asked for both, and collapsing them would silently drop a workspace.
  func testANestedFolderIsStillARootOfItsOwn() throws {
    let harness = try makeHarness()
    let outer = try harness.makeFolder(named: "Outer")
    let inner = outer.appendingPathComponent("Inner", isDirectory: true)
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
    let store = harness.makeBookmarkStore()

    try store.persistRoot(url: outer, into: AppState())
    try store.persistRoot(url: inner, into: AppState())

    XCTAssertEqual(
      harness.persistedRootPaths,
      [outer.standardizedFileURL.path, inner.standardizedFileURL.path])
  }

  /// CONTROL: re-persisting a root the key already holds must not move it to the
  /// end. Root order is the sidebar's order and its first entry seeds both the
  /// legacy single-folder key and the workspace cache identity.
  func testRePersistingARootKeepsItsPlace() throws {
    let harness = try makeHarness()
    let first = try harness.makeFolder(named: "First")
    let second = try harness.makeFolder(named: "Second")
    let store = harness.makeBookmarkStore()

    try store.persistRoot(url: first, into: AppState())
    try store.persistRoot(url: second, into: AppState())
    try store.persistRoot(url: first, into: AppState())

    XCTAssertEqual(
      harness.persistedRootPaths,
      [first.standardizedFileURL.path, second.standardizedFileURL.path])
  }

  /// THE OTHER WRITER. `replaceWorkspace` rewrites the whole key in one go, so
  /// it is the one path that could seed a duplicate merely by being handed one.
  func testReplacingTheWorkspaceRecordsEachRootOnce() throws {
    let harness = try makeHarness()
    let first = try harness.makeFolder(named: "First")
    let second = try harness.makeFolder(named: "Second")
    let store = harness.makeBookmarkStore()

    try store.replaceWorkspace(
      rootURLs: [first, second, first], fileURLs: [], into: AppState())

    XCTAssertEqual(harness.persistedRootBookmarks.count, 2)
    XCTAssertEqual(
      harness.persistedRootPaths,
      [first.standardizedFileURL.path, second.standardizedFileURL.path])
  }

  // MARK: - The restore

  /// THE LEGACY CASE: a key that already names one folder four times. Nothing in
  /// session reads that key, so the restore is where the sediment has to die —
  /// in the returned set AND in the key, permanently.
  func testRestoreCollapsesRepeatedRootsAndWritesBackTheCleanedSet() throws {
    let harness = try makeHarness()
    let notes = try harness.makeFolder(named: "Notes")
    let repeated = try harness.makeFolder(named: "Repeated")
    harness.defaults.set(
      try [harness.bookmarkData(for: notes)] + harness.staleBlobs(count: 4, for: repeated),
      forKey: rootBookmarksKey)

    let restored = harness.makeBookmarkStore().restoreWorkspace(into: AppState())

    XCTAssertEqual(
      restored.rootURLs.map(\.standardizedFileURL.path),
      [notes.standardizedFileURL.path, repeated.standardizedFileURL.path],
      "one directory came back as four roots — the workspace build walks each of them in full")
    XCTAssertEqual(
      harness.persistedRootBookmarks.count, 2,
      "the duplicates survived in the key, so the next launch pays for them again")
  }

  /// PERMANENTLY, not once per launch. Sediment that is merely filtered on read
  /// survives every launch and costs a bookmark resolution every time. A second
  /// launch on the cleaned key must be a no-op.
  func testASecondRestoreOnACleanedSetChangesNothing() throws {
    let harness = try makeHarness()
    let notes = try harness.makeFolder(named: "Notes")
    let repeated = try harness.makeFolder(named: "Repeated")
    harness.defaults.set(
      try [harness.bookmarkData(for: notes)] + harness.staleBlobs(count: 4, for: repeated),
      forKey: rootBookmarksKey)
    _ = harness.makeBookmarkStore().restoreWorkspace(into: AppState())
    let cleaned = harness.persistedRootBookmarks

    let secondLaunch = harness.makeBookmarkStore().restoreWorkspace(into: AppState())

    XCTAssertEqual(
      secondLaunch.rootURLs.map(\.standardizedFileURL.path),
      [notes.standardizedFileURL.path, repeated.standardizedFileURL.path])
    XCTAssertEqual(
      harness.persistedRootBookmarks, cleaned,
      "the second launch rewrote a key it had nothing to fix — a restore that is not idempotent"
        + " is a restore that churns the workspace cache identity on every start")
  }

  /// THE GENERATOR. macOS invalidates a bookmark whenever its directory moves,
  /// and the refresh used to go through `persistRoot`: the refreshed blob was
  /// APPENDED while the stale one stayed. That is one extra root per launch,
  /// guaranteed — the exact `+1` the operator's manifests recorded.
  func testAStaleRootBookmarkIsRefreshedInPlaceInsteadOfAppended() throws {
    let harness = try makeHarness()
    let notes = try harness.makeFolder(named: "Notes")
    let moving = try harness.makeFolder(named: "Moving")
    let staleBlob = try harness.bookmarkData(for: moving)
    let moved = harness.container.appendingPathComponent("Moved", isDirectory: true)
    try FileManager.default.moveItem(at: moving, to: moved)
    XCTAssertTrue(
      harness.isStale(staleBlob),
      "Precondition: the fixture must actually be a stale bookmark, or this pin proves nothing")
    harness.defaults.set(
      [staleBlob, try harness.bookmarkData(for: notes)], forKey: rootBookmarksKey)

    let restored = harness.makeBookmarkStore().restoreWorkspace(into: AppState())

    XCTAssertEqual(
      restored.rootURLs.map(\.standardizedFileURL.path),
      [moved.standardizedFileURL.path, notes.standardizedFileURL.path])
    XCTAssertEqual(
      harness.persistedRootBookmarks.count, 2,
      "the refreshed bookmark was appended and the stale one kept — one extra root per launch")
    XCTAssertEqual(
      harness.persistedRootPaths,
      [moved.standardizedFileURL.path, notes.standardizedFileURL.path],
      "the refreshed entry must take the stale one's place, not the end of the list")
    XCTAssertFalse(
      harness.isStale(harness.persistedRootBookmarks[0]),
      "a refresh that leaves the entry stale re-runs on every launch")
  }

  /// THE CODEX CASE: the first blob for a directory is stale and reminting it
  /// fails, while a later blob for the same directory is already usable.
  /// Marking the identity as seen before the survivor is known used to keep
  /// the stale entry and throw the working copy away.
  func testRestorePrefersALaterUsableDuplicateWhenStaleRefreshFails() throws {
    let harness = try makeHarness()
    let notes = try harness.makeFolder(named: "Notes")
    let original = try harness.makeFolder(named: "Repeated")
    let notesBlob = try harness.bookmarkData(for: notes)
    let staleBlob = try harness.bookmarkData(for: original)
    let moved = harness.container.appendingPathComponent("Repeated-moved", isDirectory: true)
    try FileManager.default.moveItem(at: original, to: moved)
    XCTAssertTrue(
      harness.isStale(staleBlob),
      "Precondition: the first blob for the repeated root must be stale")
    let freshBlob = try harness.bookmarkData(for: moved)
    XCTAssertFalse(
      harness.isStale(freshBlob),
      "Precondition: the later blob must be usable without reminting")
    XCTAssertNotEqual(staleBlob, freshBlob)
    harness.defaults.set(
      [notesBlob, staleBlob, freshBlob], forKey: rootBookmarksKey)

    let restored = harness.makeBookmarkStore(
      mintFileBookmark: { _ in throw CocoaError(.fileWriteNoPermission) }
    ).restoreWorkspace(into: AppState())

    XCTAssertEqual(
      restored.rootURLs.map(\.standardizedFileURL.path),
      [notes.standardizedFileURL.path, moved.standardizedFileURL.path])
    XCTAssertEqual(
      harness.persistedRootBookmarks, [notesBlob, freshBlob],
      "the stale first copy was kept and the later usable bookmark for the same directory was discarded"
    )
    XCTAssertFalse(harness.isStale(harness.persistedRootBookmarks[1]))
  }

  /// CONTROL: remint failure is not a reason to drop a root that still
  /// resolves. With no later usable copy, the stale bookmark stays.
  func testRestoreKeepsAStaleRootWhenRefreshFailsAndNoUsableDuplicateExists() throws {
    let harness = try makeHarness()
    let notes = try harness.makeFolder(named: "Notes")
    let moving = try harness.makeFolder(named: "Moving")
    let staleBlob = try harness.bookmarkData(for: moving)
    let notesBlob = try harness.bookmarkData(for: notes)
    let moved = harness.container.appendingPathComponent("Moved", isDirectory: true)
    try FileManager.default.moveItem(at: moving, to: moved)
    XCTAssertTrue(
      harness.isStale(staleBlob),
      "Precondition: the fixture must actually be a stale bookmark, or this pin proves nothing")
    harness.defaults.set([staleBlob, notesBlob], forKey: rootBookmarksKey)

    let restored = harness.makeBookmarkStore(
      mintFileBookmark: { _ in throw CocoaError(.fileWriteNoPermission) }
    ).restoreWorkspace(into: AppState())

    XCTAssertEqual(
      restored.rootURLs.map(\.standardizedFileURL.path),
      [moved.standardizedFileURL.path, notes.standardizedFileURL.path],
      "a stale bookmark that still resolves must still restore the folder")
    XCTAssertEqual(
      harness.persistedRootBookmarks, [staleBlob, notesBlob],
      "remint failure without a later usable copy dropped or replaced the stale bookmark")
  }

  /// CONTROL, and the line the cleanup must not cross: a root that is merely
  /// GONE keeps its bookmark. It drops out of this launch's list and out of
  /// nothing else — bare launch shows the empty launcher, and the folder can
  /// still come back.
  func testAMissingRootDropsFromTheLaunchButKeepsItsBookmark() throws {
    let harness = try makeHarness()
    let vanishing = try harness.makeFolder(named: "Vanishes")
    let store = harness.makeBookmarkStore()
    try store.persistRoot(url: vanishing, into: AppState())
    try FileManager.default.removeItem(at: vanishing)

    let restored = harness.makeBookmarkStore().restoreWorkspace(into: AppState())

    XCTAssertTrue(restored.rootURLs.isEmpty)
    XCTAssertEqual(
      harness.persistedRootBookmarks.count, 1,
      "a folder that is missing today is not a folder the user removed from the workspace")
  }

  /// CONTROL: unresolvable is not garbage. A blob this machine cannot resolve —
  /// an unplugged volume — must never be collapsed away as somebody else's
  /// duplicate, and must never cost the user a root.
  func testAnUnresolvableRootKeepsItsBookmarkAndCollapsesNothing() throws {
    let harness = try makeHarness()
    let notes = try harness.makeFolder(named: "Notes")
    let unresolvable = Data("not a bookmark".utf8)
    let notesBlob = try harness.bookmarkData(for: notes)
    harness.defaults.set(
      [unresolvable, notesBlob], forKey: rootBookmarksKey)

    let restored = harness.makeBookmarkStore().restoreWorkspace(into: AppState())

    XCTAssertEqual(
      restored.rootURLs.map(\.standardizedFileURL.path), [notes.standardizedFileURL.path])
    XCTAssertEqual(
      harness.persistedRootBookmarks, [unresolvable, notesBlob],
      "an entry that cannot be resolved today lost its bookmark")
  }

  // MARK: - The scan

  /// THE SAFETY NET. Roots are made unique upstream, but the cost of being wrong
  /// about that lands here: one repeated root is one extra full recursive walk.
  /// Both spellings of one directory count as one root — a bookmark minted for
  /// `/tmp` resolves to `/private/tmp`, and the temp directory this fixture
  /// lives in is under the same `/var` alias.
  func testTheScannerWalksEachRealRootOnceEvenWhenHandedItTwice() throws {
    let harness = try makeHarness()
    let root = try harness.makeFolder(named: "Notes")
    try "# note".write(
      to: root.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
    let aliasSpelling = URL(
      fileURLWithPath: "/private" + root.standardizedFileURL.path, isDirectory: true)
    XCTAssertTrue(
      root.standardizedFileURL.path.hasPrefix("/var/"),
      "Precondition: this fixture needs a temp directory under the /var alias")
    XCTAssertTrue(FileManager.default.fileExists(atPath: aliasSpelling.path))

    let repeated = WorkspaceScanner.build(rootURLs: [root, root], exclusions: [])
    let aliased = WorkspaceScanner.build(rootURLs: [root, aliasSpelling], exclusions: [])

    XCTAssertEqual(repeated.count, 1, "the same root was walked twice")
    XCTAssertEqual(aliased.count, 1, "two spellings of one directory were walked as two roots")
    XCTAssertEqual(repeated.first?.documents.count, 1)
  }

  /// CONTROL for the scanner guard: two genuinely different roots are still two
  /// walks, and a nested root is still its own walk.
  func testTheScannerStillWalksEveryDistinctRoot() throws {
    let harness = try makeHarness()
    let outer = try harness.makeFolder(named: "Outer")
    let other = try harness.makeFolder(named: "Other")
    let inner = outer.appendingPathComponent("Inner", isDirectory: true)
    try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)

    let scans = WorkspaceScanner.build(rootURLs: [outer, other, inner], exclusions: [])

    XCTAssertEqual(scans.count, 3)
  }

  // MARK: - The operator's shape, end to end

  /// THE INCIDENT, reproduced: one real notes folder plus four entries for a
  /// second directory, exactly what the 8.6 GB scan was handed. One launch must
  /// end with one root each, one walk per directory, and a key that stays clean.
  func testTheOperatorsRootSedimentHealsInOneLaunchAndIsScannedOnce() async throws {
    let harness = try makeHarness()
    let notes = try harness.makeFolder(named: "Notes")
    let repeated = try harness.makeFolder(named: "Repeated")
    try "# note".write(
      to: notes.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
    harness.defaults.set(
      try [harness.bookmarkData(for: notes)] + harness.staleBlobs(count: 4, for: repeated),
      forKey: rootBookmarksKey)

    let scannedRoots = ScannedRootRecorder()
    let bookmarkStore = harness.makeBookmarkStore()
    let support = try harness.makeFolder(named: "Support")
    let manager = FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: support.appendingPathComponent("workspace.json", isDirectory: false)),
      indexDatabase: IndexDatabase(
        databaseURL: support.appendingPathComponent("index.db", isDirectory: false)),
      bookmarkStore: bookmarkStore,
      workspaceBuilder: { roots, exclusions in
        scannedRoots.record(roots)
        return WorkspaceScanner.defaultBuilder(roots, exclusions)
      },
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true)))
    )
    let appState = AppState()

    manager.restoreLastFolder(into: appState)
    await manager.waitForPendingIndexUpdate()

    XCTAssertEqual(
      appState.workspaceRoots.map { $0.url.standardizedFileURL.path },
      [notes.standardizedFileURL.path, repeated.standardizedFileURL.path],
      "the sidebar took one directory as four roots")
    for walk in scannedRoots.walks {
      XCTAssertEqual(
        walk.count, Set(walk.map(\.standardizedFileURL.path)).count,
        "the scanner was handed the same directory more than once in a single walk: \(walk)")
    }
    XCTAssertEqual(
      harness.persistedRootBookmarks.count, 2,
      "the launch left the sediment in the key, so every later launch pays for it again")

    let nextLaunch = harness.makeBookmarkStore().restoreWorkspace(into: AppState())
    XCTAssertEqual(
      nextLaunch.rootURLs.map(\.standardizedFileURL.path),
      [notes.standardizedFileURL.path, repeated.standardizedFileURL.path])
    XCTAssertEqual(harness.persistedRootBookmarks.count, 2)
  }

  // MARK: - Harness

  private func makeHarness() throws -> RootBookmarkHarness {
    let container = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PensieveRootBookmarkHygiene-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: container)
    }
    return RootBookmarkHarness(
      container: container,
      defaults: makeEphemeralDefaults(prefix: "PensieveRootBookmarkHygiene"),
      rootBookmarksKey: rootBookmarksKey)
  }
}

@MainActor
private struct RootBookmarkHarness {
  let container: URL
  let defaults: UserDefaults
  let rootBookmarksKey: String

  var persistedRootBookmarks: [Data] {
    defaults.array(forKey: rootBookmarksKey) as? [Data] ?? []
  }

  /// Where each persisted blob actually LEADS. The bytes are not an identity, so
  /// every assertion about this key has to be made on the resolved directory.
  var persistedRootPaths: [String] {
    persistedRootBookmarks.compactMap { resolve($0)?.standardizedFileURL.path }
  }

  func makeBookmarkStore(
    mintFileBookmark: @escaping (URL) throws -> Data = BookmarkStore.securityScopedBookmark
  ) -> BookmarkStore {
    BookmarkStore(defaults: defaults, mintFileBookmark: mintFileBookmark)
  }

  func makeFolder(named name: String) throws -> URL {
    let url = container.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func bookmarkData(for url: URL) throws -> Data {
    try url.bookmarkData(
      options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
  }

  /// `count` DISTINCT blobs that all resolve to `url`, which is the shape the
  /// operator's key actually held.
  ///
  /// Built by renaming the directory between mints: a move is what makes macOS
  /// declare a bookmark stale, the stale blob still resolves — to the new path —
  /// and a blob minted afterwards differs byte for byte from the one before it.
  /// Repeated mints of an unmoved directory return IDENTICAL bytes, so they
  /// could not reproduce a key that blob equality failed to dedupe. The
  /// directory is returned to `url` at the end, so the caller's URL stays the
  /// one every blob names.
  func staleBlobs(count: Int, for url: URL) throws -> [Data] {
    var blobs: [Data] = []
    var current = url
    for index in 0..<count {
      blobs.append(try bookmarkData(for: current))
      let next = container.appendingPathComponent(
        "\(url.lastPathComponent)-move-\(index)", isDirectory: true)
      try FileManager.default.moveItem(at: current, to: next)
      current = next
    }
    try FileManager.default.moveItem(at: current, to: url)
    return blobs
  }

  func isStale(_ bookmark: Data) -> Bool {
    var bookmarkIsStale = false
    _ = try? URL(
      resolvingBookmarkData: bookmark,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &bookmarkIsStale)
    return bookmarkIsStale
  }

  private func resolve(_ bookmark: Data) -> URL? {
    var bookmarkIsStale = false
    return try? URL(
      resolvingBookmarkData: bookmark,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &bookmarkIsStale)
  }
}

/// Every root list the injected scanner was handed, recorded off the main actor
/// because the workspace walk runs there.
private final class ScannedRootRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [[URL]] = []

  func record(_ roots: [URL]) {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(roots)
  }

  var walks: [[URL]] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }
}
