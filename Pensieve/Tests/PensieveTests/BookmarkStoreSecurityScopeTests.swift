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

  /// `replaceWorkspace` is the destructive rewrite used by root removal. It
  /// must drop the old grants only after it has minted AND resolved every new
  /// bookmark, then start access on the resolved URLs carrying those grants —
  /// never on plain URLs reconstructed from their paths.
  func testWorkspaceReplacementActivatesURLsResolvedFromFreshBookmarks() throws {
    let noteURL = folder.appendingPathComponent("replacement.md")
    try "replacement".write(to: noteURL, atomically: true, encoding: .utf8)
    var started: [URL] = []
    var stopped: [URL] = []
    let store = BookmarkStore(
      defaults: defaults,
      startSecurityScopedAccess: { url in
        started.append(url)
        return true
      },
      stopSecurityScopedAccess: { stopped.append($0) }
    )

    try store.replaceWorkspace(rootURLs: [folder], fileURLs: [noteURL], into: AppState())

    let rootData = try XCTUnwrap(
      (defaults.array(forKey: "Pensieve.workspace.rootBookmarks") as? [Data])?.first)
    let fileData = try XCTUnwrap(
      (defaults.array(forKey: "Pensieve.workspace.fileBookmarks") as? [Data])?.first)
    let expected = try [rootData, fileData].map { data -> URL in
      var stale = false
      return try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &stale)
    }

    XCTAssertEqual(started, expected)
    XCTAssertEqual(store.activeSecurityScopeCount, 2)
    XCTAssertEqual(store.grantedSecurityScopeCount, 2)

    store.clear(into: AppState())
    XCTAssertEqual(
      stopped.count, expected.count,
      "every granted security scope must receive exactly one matching stop")
    XCTAssertEqual(
      Set(stopped), Set(expected),
      "stop must balance the exact resolved URLs that were started; dictionary traversal order is not a contract"
    )
    XCTAssertEqual(store.activeSecurityScopeCount, 0)
    XCTAssertEqual(store.grantedSecurityScopeCount, 0)
  }

  func testFailedSecurityScopeStartIsTrackedButNotCountedAsAGrant() throws {
    let noteURL = folder.appendingPathComponent("ungranted.md")
    try "ungranted".write(to: noteURL, atomically: true, encoding: .utf8)
    var attempted: [URL] = []
    var stopped: [URL] = []
    let store = BookmarkStore(
      defaults: defaults,
      startSecurityScopedAccess: { url in
        attempted.append(url)
        return false
      },
      stopSecurityScopedAccess: { stopped.append($0) }
    )

    try store.persistFile(url: noteURL, into: AppState())

    XCTAssertEqual(attempted, [noteURL])
    XCTAssertEqual(store.activeSecurityScopeCount, 1, "the failed attempt remains deduplicated")
    XCTAssertEqual(store.grantedSecurityScopeCount, 0, "a failed start is not a live grant")

    store.removeFile(url: noteURL)
    XCTAssertEqual(store.activeSecurityScopeCount, 0)
    XCTAssertEqual(store.grantedSecurityScopeCount, 0)
    XCTAssertTrue(stopped.isEmpty, "a failed start must never receive an unmatched stop")
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

  /// THE PIN, on the exact production sequence. `activate` filed the grant
  /// under the URL as GIVEN while `removeFile` released it under
  /// `url.standardizedFileURL` — and those are two different keys on the
  /// commonest path there is. A relaunch restore activates the
  /// bookmark-RESOLVED URL, which arrives `/private`-prefixed
  /// (`/private/var/folders/…`), and `standardizedFileURL` STRIPS that prefix.
  /// So the stop looked up a key that was never written, found nothing, and the
  /// security-scoped grant leaked until the process exited.
  func testClosingARestoredFileReleasesItsSecurityScopedGrant() throws {
    let noteURL = folder.appendingPathComponent("scoped.md")
    try "scoped".write(to: noteURL, atomically: true, encoding: .utf8)

    let writer = BookmarkStore(defaults: defaults)
    try writer.persistFile(url: noteURL, into: AppState())

    // A fresh store over the same defaults = the relaunch path: restore
    // resolves each bookmark and activates the RESOLVED URL.
    let reader = BookmarkStore(defaults: defaults)
    let restored = reader.restoreWorkspace(into: AppState())
    let resolvedURL = try XCTUnwrap(restored.fileURLs.first)
    XCTAssertEqual(reader.activeSecurityScopeCount, 1, "the restore must take the grant")
    // The premise, asserted rather than assumed: with one spelling this pin
    // would pass on the broken code and prove nothing.
    XCTAssertNotEqual(
      resolvedURL, resolvedURL.standardizedFileURL,
      "the resolved bookmark is already canonical here, so this pin cannot see the bug")

    reader.removeFile(url: resolvedURL.standardizedFileURL)

    XCTAssertEqual(
      reader.activeSecurityScopeCount, 0,
      "the security-scoped grant survived the close — taken under the resolved spelling,"
        + " released under the standardized one, so it leaks for the rest of the process")
  }

  /// THE CONTROL LEG. The already-canonical spelling must keep balancing, and a
  /// URL this store never granted must still be a no-op rather than an
  /// unbalanced stop.
  func testACanonicalCloseStillBalancesAndAnUnknownOneStaysANoOp() throws {
    let noteURL = folder.standardizedFileURL.appendingPathComponent("canonical.md")
    try "canonical".write(to: noteURL, atomically: true, encoding: .utf8)

    let store = BookmarkStore(defaults: defaults)
    try store.persistFile(url: noteURL, into: AppState())
    XCTAssertEqual(store.activeSecurityScopeCount, 1)

    store.removeFile(url: folder.appendingPathComponent("never-opened.md"))
    XCTAssertEqual(
      store.activeSecurityScopeCount, 1,
      "closing a file this store never granted must not release someone else's access")

    store.removeFile(url: noteURL)
    XCTAssertEqual(store.activeSecurityScopeCount, 0)
  }

  /// Moves `name` into a Trash this suite owns, the way the system does: a plain
  /// move, which leaves the bookmark perfectly resolvable — at its new home.
  private func seedTrashedFile(named name: String) throws -> (originURL: URL, trash: URL) {
    let trash = folder.appendingPathComponent("Trash", isDirectory: true)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let noteURL = folder.appendingPathComponent(name)
    try name.write(to: noteURL, atomically: true, encoding: .utf8)
    return (noteURL, trash)
  }

  /// P3-6. The prune releases under the ACTIVATION key — the path the file had
  /// BEFORE it was thrown away, which it reads back out of the bookmark blob.
  /// A blob that cannot name the path it was minted for leaves the prune with no
  /// key to look up at all: the entry left the persisted working set while its
  /// grant stayed live for the rest of the process, and nothing could ever name
  /// that grant again.
  ///
  /// The nil origin is INJECTED because no fixture can mint a real bookmark
  /// whose cached path fails to read — which is exactly why the leak survived
  /// the suite that covers the ordinary prune.
  func testPruningABlobThatCannotNameItsOriginStillReleasesTheGrant() throws {
    let seeded = try seedTrashedFile(named: "origin-less.md")
    var stopped: [URL] = []
    let store = BookmarkStore(
      defaults: defaults,
      trashMembership: SimulatedTrash.membership(at: seeded.trash),
      startSecurityScopedAccess: { _ in true },
      stopSecurityScopedAccess: { stopped.append($0) },
      bookmarkedOrigin: { _ in nil })

    try store.persistFile(url: seeded.originURL, into: AppState())
    XCTAssertEqual(
      store.grantedSecurityScopeCount, 1, "premise: persisting a file takes one live grant")
    try FileManager.default.moveItem(
      at: seeded.originURL, to: seeded.trash.appendingPathComponent("origin-less.md"))

    let pruned = store.pruneTrashedFiles()

    XCTAssertEqual(pruned.count, 1, "premise: the trashed entry is the one being retired")
    XCTAssertNil(
      pruned.first?.originURL, "premise: this leg is about a blob that names no minted path")
    XCTAssertEqual(
      store.grantedSecurityScopeCount, 0,
      "the retired entry's security-scoped grant survived the prune: it was taken under the "
        + "pre-trash path, and with no origin to name that key the store can only find it through "
        + "the blob it was activated alongside")
    XCTAssertEqual(store.activeSecurityScopeCount, 0)
    XCTAssertEqual(
      stopped, [seeded.originURL],
      "the stop must still go through the EXACT URL access was started on")
  }

  /// The control leg: with a readable origin the prune balances the same way, so
  /// the pin above is about the missing-origin path and not about the prune
  /// having been broken for everyone.
  func testPruningABlobThatNamesItsOriginKeepsBalancingTheGrant() throws {
    let seeded = try seedTrashedFile(named: "origin-bearing.md")
    var stopped: [URL] = []
    let store = BookmarkStore(
      defaults: defaults,
      trashMembership: SimulatedTrash.membership(at: seeded.trash),
      startSecurityScopedAccess: { _ in true },
      stopSecurityScopedAccess: { stopped.append($0) })

    try store.persistFile(url: seeded.originURL, into: AppState())
    try FileManager.default.moveItem(
      at: seeded.originURL, to: seeded.trash.appendingPathComponent("origin-bearing.md"))

    let pruned = store.pruneTrashedFiles()

    XCTAssertEqual(
      pruned.compactMap(\.originURL).map(BookmarkStore.identityPath),
      [BookmarkStore.identityPath(seeded.originURL)],
      "premise: a real blob does name the path it was minted for")
    XCTAssertEqual(store.grantedSecurityScopeCount, 0)
    XCTAssertEqual(stopped, [seeded.originURL])
  }

  func testRepeatedPersistKeepsOneGrantAndNilOriginPruneBalancesItOnce() throws {
    let seeded = try seedTrashedFile(named: "repeated.md")
    var started: [URL] = []
    var stopped: [URL] = []
    let store = BookmarkStore(
      defaults: defaults,
      trashMembership: SimulatedTrash.membership(at: seeded.trash),
      startSecurityScopedAccess: { url in
        started.append(url)
        return true
      },
      stopSecurityScopedAccess: { stopped.append($0) },
      bookmarkedOrigin: { _ in nil })

    try store.persistFile(url: seeded.originURL, into: AppState())
    try store.persistFile(url: seeded.originURL, into: AppState())

    XCTAssertEqual(started, [seeded.originURL], "re-persist must not take a second grant")
    XCTAssertEqual(store.grantedSecurityScopeCount, 1)
    XCTAssertEqual(
      (defaults.array(forKey: "Pensieve.workspace.fileBookmarks") as? [Data])?.count, 1,
      "re-persist must keep exactly one working-set row")

    try FileManager.default.moveItem(
      at: seeded.originURL, to: seeded.trash.appendingPathComponent("repeated.md"))
    XCTAssertEqual(store.pruneTrashedFiles().count, 1)
    XCTAssertEqual(stopped, [seeded.originURL])
    XCTAssertEqual(store.grantedSecurityScopeCount, 0)
  }

  func testStaleBookmarkRefreshRetagsTheGrantBeforeNilOriginPrune() throws {
    let trash = folder.appendingPathComponent("Trash", isDirectory: true)
    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
    let originalURL = folder.appendingPathComponent("before-rename.md")
    let renamedURL = folder.appendingPathComponent("after-rename.md")
    try "renamed".write(to: originalURL, atomically: true, encoding: .utf8)

    let writer = BookmarkStore(defaults: defaults)
    try writer.persistFile(url: originalURL, into: AppState())
    let originalBlob = try XCTUnwrap(
      (defaults.array(forKey: "Pensieve.workspace.fileBookmarks") as? [Data])?.first)
    try FileManager.default.moveItem(at: originalURL, to: renamedURL)

    var stopped: [URL] = []
    let reader = BookmarkStore(
      defaults: defaults,
      trashMembership: SimulatedTrash.membership(at: trash),
      startSecurityScopedAccess: { _ in true },
      stopSecurityScopedAccess: { stopped.append($0) },
      bookmarkedOrigin: { _ in nil })

    let restored = reader.restoreWorkspace(into: AppState())
    XCTAssertEqual(restored.fileURLs.map(\.standardizedFileURL), [renamedURL.standardizedFileURL])
    let refreshedBlob = try XCTUnwrap(
      (defaults.array(forKey: "Pensieve.workspace.fileBookmarks") as? [Data])?.first)
    XCTAssertNotEqual(
      refreshedBlob, originalBlob,
      "moving the file must make this fixture stale so the retag path is actually exercised")

    let trashedURL = trash.appendingPathComponent(renamedURL.lastPathComponent)
    try FileManager.default.moveItem(at: renamedURL, to: trashedURL)
    XCTAssertEqual(reader.pruneTrashedFiles().count, 1)
    XCTAssertEqual(
      stopped.count, 1,
      "the grant stayed tagged with the stale blob, so the nil-origin prune could not find it")
    XCTAssertEqual(reader.grantedSecurityScopeCount, 0)
    XCTAssertEqual(reader.activeSecurityScopeCount, 0)
  }

  func testLegacyDuplicateBookmarkRestoresOneGrantAndPrunesItOnce() throws {
    let seeded = try seedTrashedFile(named: "duplicate.md")
    let bookmark = try seeded.originURL.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil)
    defaults.set([bookmark, bookmark], forKey: "Pensieve.workspace.fileBookmarks")

    var stopped: [URL] = []
    let store = BookmarkStore(
      defaults: defaults,
      trashMembership: SimulatedTrash.membership(at: seeded.trash),
      startSecurityScopedAccess: { _ in true },
      stopSecurityScopedAccess: { stopped.append($0) },
      bookmarkedOrigin: { _ in nil })

    XCTAssertEqual(
      store.restoreWorkspace(into: AppState()).fileURLs.map(\.standardizedFileURL),
      [seeded.originURL.standardizedFileURL])
    XCTAssertEqual(store.grantedSecurityScopeCount, 1)
    XCTAssertEqual(
      (defaults.array(forKey: "Pensieve.workspace.fileBookmarks") as? [Data])?.count, 1,
      "restore must retire the duplicate row without duplicating the live grant")

    try FileManager.default.moveItem(
      at: seeded.originURL, to: seeded.trash.appendingPathComponent("duplicate.md"))
    XCTAssertEqual(store.pruneTrashedFiles().count, 1)
    XCTAssertEqual(stopped.count, 1)
    XCTAssertEqual(store.grantedSecurityScopeCount, 0)
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
