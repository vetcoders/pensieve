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
  private var defaults: UserDefaults!
  private var folder: URL!

  override func setUp() async throws {
    // Suite cleanup (domain + backing plist) is registered as a teardown
    // block by the helper. The suite name is an absolute path (a domain
    // identifier, not a display name), so the scratch folder gets its own
    // unique name rather than reusing it.
    defaults = makeEphemeralDefaults(prefix: "BookmarkStoreSecurityScopeTests")
    folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "BookmarkStoreSecurityScopeTests-\(UUID().uuidString)", isDirectory: true)
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
