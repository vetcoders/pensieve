import Foundation
import XCTest

@testable import Pensieve

/// Security-scope audit for BookmarkStore (App Store lane, Cut 3-1).
///
/// The sandbox itself cannot be entered from a test runner, so these tests
/// pin the OPTION bits instead of the sandbox behavior: bookmarks must be
/// CREATED with `.withSecurityScope` (persist paths) and RESOLVED with
/// `.withSecurityScope` (restore paths), or workspace roots and pinned files
/// would not survive a sandboxed relaunch.
@MainActor
final class BookmarkStoreSecurityScopeTests: XCTestCase {
  private var suiteName = ""
  private var defaults: UserDefaults!
  private var folder: URL!

  override func setUp() async throws {
    // Suite cleanup (domain + backing plist) is registered as a teardown
    // block by the helper.
    let suite = makeEphemeralDefaultsSuite(prefix: "BookmarkStoreSecurityScopeTests")
    suiteName = suite.suiteName
    defaults = suite.defaults
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(suiteName, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: folder)
  }

  /// Resolving WITH `.withSecurityScope` throws unless the bookmark data was
  /// created with the security-scope option — that error is the observable
  /// proxy for the option bit, valid also outside a sandbox.
  private func resolvesWithSecurityScope(_ data: Data) -> Bool {
    var stale = false
    return
      (try? URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &stale)) != nil
  }

  func testPersistedRootBookmarkCarriesSecurityScopeOptionBits() throws {
    let store = BookmarkStore(defaults: defaults)
    let appState = AppState()

    try store.persistRoot(url: folder, into: appState)

    let persisted = try XCTUnwrap(appState.bookmarkData)
    XCTAssertTrue(
      resolvesWithSecurityScope(persisted),
      "root bookmark must be created with .withSecurityScope")

    // Negative control: a bookmark WITHOUT the option must fail the same
    // resolution, or the positive assertion above would prove nothing.
    let unscoped = try folder.bookmarkData(
      options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    XCTAssertFalse(
      resolvesWithSecurityScope(unscoped),
      "resolution with .withSecurityScope must reject unscoped bookmark data")
  }

  func testWorkspaceRoundTripRestoresRootsAndFilesFromAFreshStore() throws {
    let noteURL = folder.appendingPathComponent("pinned.md")
    try "pinned".write(to: noteURL, atomically: true, encoding: .utf8)

    let writer = BookmarkStore(defaults: defaults)
    let seedState = AppState()
    try writer.persistRoot(url: folder, into: seedState)
    try writer.persistFile(url: noteURL, into: seedState)

    // Fresh store over the same defaults = the relaunch path (restore reads
    // only persisted data, resolves with .withSecurityScope, and activates
    // startAccessingSecurityScopedResource internally).
    let reader = BookmarkStore(defaults: defaults)
    let restoredState = AppState()
    let restored = reader.restoreWorkspace(into: restoredState)

    XCTAssertEqual(restored.rootURLs.map(\.standardizedFileURL), [folder.standardizedFileURL])
    XCTAssertEqual(restored.fileURLs.map(\.standardizedFileURL), [noteURL.standardizedFileURL])
    XCTAssertNotNil(restoredState.bookmarkData)

    reader.clear(into: restoredState)
    XCTAssertNil(restoredState.bookmarkData)
    let cleared = reader.restoreWorkspace(into: AppState())
    XCTAssertTrue(cleared.rootURLs.isEmpty)
    XCTAssertTrue(cleared.fileURLs.isEmpty)
  }

  func testRestoreDropsBookmarksWhoseTargetsVanished() throws {
    let ghostFolder = folder.appendingPathComponent("ghost", isDirectory: true)
    try FileManager.default.createDirectory(at: ghostFolder, withIntermediateDirectories: true)

    let store = BookmarkStore(defaults: defaults)
    try store.persistRoot(url: ghostFolder, into: AppState())
    try FileManager.default.removeItem(at: ghostFolder)

    let restored = BookmarkStore(defaults: defaults).restoreWorkspace(into: AppState())
    XCTAssertTrue(
      restored.rootURLs.isEmpty,
      "a vanished root must be dropped silently (startup state, not a user error)")
  }

  /// The persisted contract key, spelled out here on purpose: these tests are
  /// about what the SAVED list looks like, not about the store's internals.
  private static let fileBookmarksKey = "Pensieve.workspace.fileBookmarks"

  private func persistedFileBookmarks() -> [Data] {
    defaults.array(forKey: Self.fileBookmarksKey) as? [Data] ?? []
  }

  /// Bookmark BYTES are not a stable identity for a file. Pensieve saves
  /// ATOMICALLY (write to a temp file, then rename), so every save replaces the
  /// inode and the next bookmark minted for the very same path differs — the
  /// old `contains(data)` guard could not recognise it and appended yet another
  /// entry. Reopen a file you edited a few times and the saved list grows a
  /// copy each round. The resolved path is the identity.
  func testReopeningAFileAfterAtomicSavesKeepsASingleBookmark() throws {
    let noteURL = folder.appendingPathComponent("pinned.md")
    try "pinned".write(to: noteURL, atomically: true, encoding: .utf8)

    let store = BookmarkStore(defaults: defaults)
    let state = AppState()
    try store.persistFile(url: noteURL, into: state)
    // The premise, asserted rather than assumed: the same path yields
    // byte-different bookmark data once the file has been rewritten atomically.
    let beforeSave = try XCTUnwrap(persistedFileBookmarks().first)
    try "edited".write(to: noteURL, atomically: true, encoding: .utf8)
    try store.persistFile(url: noteURL, into: state)
    XCTAssertNotEqual(
      persistedFileBookmarks().first, beforeSave,
      "premise gone: an atomic rewrite no longer changes the bookmark bytes")

    try "edited again".write(to: noteURL, atomically: true, encoding: .utf8)
    try store.persistFile(url: noteURL, into: state)

    XCTAssertEqual(
      persistedFileBookmarks().count, 1,
      "the same file was persisted as several bookmarks — the saved list grows on every open")
    XCTAssertEqual(
      BookmarkStore(defaults: defaults).restoreWorkspace(into: AppState()).fileURLs
        .map(\.standardizedFileURL),
      [noteURL.standardizedFileURL])
  }

  /// Installs already polluted by the old guard (the operator's had six copies
  /// of one file among fifteen entries) must heal, not merely stop growing.
  /// Blobs that cannot be resolved at all are NOT touched: unreachable today is
  /// not the same as bogus.
  func testRestoreCollapsesDuplicateBookmarksAndKeepsUnresolvableOnes() throws {
    let noteURL = folder.appendingPathComponent("pinned.md")
    try "pinned".write(to: noteURL, atomically: true, encoding: .utf8)
    let detour = folder.appendingPathComponent("detour", isDirectory: true)
    try FileManager.default.createDirectory(at: detour, withIntermediateDirectories: true)

    let scopedOptions = URL.BookmarkCreationOptions.withSecurityScope
    let canonical = try noteURL.bookmarkData(
      options: scopedOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    let aliased = try detour.appendingPathComponent("../pinned.md").bookmarkData(
      options: scopedOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    let unresolvable = Data("not a bookmark".utf8)
    defaults.set([canonical, aliased, canonical, unresolvable], forKey: Self.fileBookmarksKey)

    let restored = BookmarkStore(defaults: defaults).restoreWorkspace(into: AppState())

    XCTAssertEqual(
      restored.fileURLs.map(\.standardizedFileURL), [noteURL.standardizedFileURL],
      "restore handed the workspace one file several times over")
    XCTAssertEqual(
      persistedFileBookmarks(), [canonical, unresolvable],
      "the polluted saved list was not healed (or the unresolvable blob was pruned with it)")
  }

  func testFailedWorkspaceReplacementPreservesPreviouslyPersistedRoots() throws {
    let store = BookmarkStore(defaults: defaults)
    let state = AppState()
    try store.persistRoot(url: folder, into: state)
    let missing = folder.appendingPathComponent("missing", isDirectory: true)

    XCTAssertThrowsError(
      try store.replaceWorkspace(rootURLs: [missing], fileURLs: [], into: state)
    )

    let restored = BookmarkStore(defaults: defaults).restoreWorkspace(into: AppState())
    XCTAssertEqual(restored.rootURLs.map(\.standardizedFileURL), [folder.standardizedFileURL])
  }
}
