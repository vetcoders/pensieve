import GRDB
import Observation
import XCTest

@testable import Pensieve

@MainActor
final class IndexDatabaseV2StatsTests: XCTestCase {
  func testColdScanAppendsSessionAndUpsertsStats() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let alphaURL = folder.appendingPathComponent("alpha.md")
    try "# Alpha Title\n\nalpha body".write(to: alphaURL, atomically: true, encoding: .utf8)

    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let appState = AppState()
    let indexDatabase = IndexDatabase(databaseURL: databaseURL)
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: try temporaryBookmarkStore(),
      workspaceSubstrate: WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: folder))
    )

    manager.openInBackground(url: folder, into: appState)
    await manager.waitForPendingWorkspaceBuild()

    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: appState.bookmarkData)
    let dbQueue = try DatabaseQueue(path: databaseURL.path)

    // Check scan_sessions
    try await dbQueue.read { db in
      let count = try XCTUnwrap(
        Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scan_sessions"),
        "Expected COUNT(*) over scan_sessions to return a row")
      XCTAssertEqual(count, 1)

      let recordedWorkspaceIDs = try String.fetchAll(
        db, sql: "SELECT workspace_id FROM scan_sessions ORDER BY id")
      let row = try XCTUnwrap(
        Row.fetchOne(
          db, sql: "SELECT * FROM scan_sessions WHERE workspace_id = ?",
          arguments: [identity.workspaceID]),
        "Expected cold_scan session for workspace_id \(identity.workspaceID); recorded \(recordedWorkspaceIDs)"
      )
      XCTAssertEqual(row["trigger"] as String, "cold_scan")
      XCTAssertEqual(row["file_count"] as Int, 1)
      XCTAssertGreaterThanOrEqual(row["folder_count"] as Int, 0)
      XCTAssertNotNil(row["fingerprint_hash"] as String?)
      XCTAssertGreaterThanOrEqual(row["duration_ms"] as Int, 0)
      XCTAssertGreaterThanOrEqual(row["started_at"] as Int, 0)
      XCTAssertGreaterThanOrEqual(row["finished_at"] as Int, row["started_at"] as Int)
    }

    // Check workspace_stats
    try await dbQueue.read { db in
      let statsRow = try Row.fetchOne(
        db, sql: "SELECT * FROM workspace_stats WHERE workspace_id = ?",
        arguments: [identity.workspaceID])
      let stats = try XCTUnwrap(
        statsRow, "Expected workspace_stats row for workspace_id \(identity.workspaceID)")
      XCTAssertEqual(stats["file_count"] as Int, 1)
      XCTAssertGreaterThanOrEqual(stats["folder_count"] as Int, 0)
      XCTAssertEqual(stats["index_health"] as String, "green")
      XCTAssertNotNil(stats["last_scan_at"] as Int?)
      XCTAssertNotNil(stats["last_indexed_at"] as Int?)
    }
  }

  func testRescanAppendsSecondSessionAndUpdatesStats() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let alphaURL = folder.appendingPathComponent("alpha.md")
    try "alpha".write(to: alphaURL, atomically: true, encoding: .utf8)

    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let appState = AppState()
    let indexDatabase = IndexDatabase(databaseURL: databaseURL)
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: try temporaryBookmarkStore(),
      workspaceSubstrate: WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: folder))
    )

    manager.openInBackground(url: folder, into: appState)
    await manager.waitForPendingWorkspaceBuild()

    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: appState.bookmarkData)

    // Now simulate re-scan
    let betaURL = folder.appendingPathComponent("beta.md")
    try "beta".write(to: betaURL, atomically: true, encoding: .utf8)
    manager.openInBackground(url: folder, into: appState)
    await manager.waitForPendingWorkspaceBuild()

    let dbQueue = try DatabaseQueue(path: databaseURL.path)

    // Check scan_sessions
    try await dbQueue.read { db in
      let count = try XCTUnwrap(
        Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scan_sessions"),
        "Expected COUNT(*) over scan_sessions to return a row")
      XCTAssertEqual(count, 2)

      let rows = try Row.fetchAll(
        db, sql: "SELECT * FROM scan_sessions WHERE workspace_id = ? ORDER BY finished_at ASC",
        arguments: [identity.workspaceID])
      XCTAssertEqual(
        rows.count, 2, "Expected two scan_sessions for workspace_id \(identity.workspaceID)")
      guard rows.count >= 2 else { return }
      XCTAssertEqual(rows[0]["file_count"] as Int, 1)
      XCTAssertEqual(rows[1]["file_count"] as Int, 2)
    }

    // Check workspace_stats
    try await dbQueue.read { db in
      let count = try XCTUnwrap(
        Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workspace_stats"),
        "Expected COUNT(*) over workspace_stats to return a row")
      XCTAssertEqual(count, 1)  // Updated in place

      let statsRow = try Row.fetchOne(
        db, sql: "SELECT * FROM workspace_stats WHERE workspace_id = ?",
        arguments: [identity.workspaceID])
      let stats = try XCTUnwrap(
        statsRow, "Expected updated workspace_stats row for workspace_id \(identity.workspaceID)")
      XCTAssertEqual(stats["file_count"] as Int, 2)
      XCTAssertEqual(stats["index_health"] as String, "green")
    }
  }

  func testEmptyWorkspaceStats() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let appState = AppState()
    let indexDatabase = IndexDatabase(databaseURL: databaseURL)
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: try temporaryBookmarkStore(),
      workspaceSubstrate: WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: folder))
    )

    manager.openInBackground(url: folder, into: appState)
    await manager.waitForPendingWorkspaceBuild()

    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: appState.bookmarkData)
    let dbQueue = try DatabaseQueue(path: databaseURL.path)

    try await dbQueue.read { db in
      let statsRow = try Row.fetchOne(
        db, sql: "SELECT * FROM workspace_stats WHERE workspace_id = ?",
        arguments: [identity.workspaceID])
      let stats = try XCTUnwrap(
        statsRow, "Expected empty-workspace stats row for workspace_id \(identity.workspaceID)")
      XCTAssertEqual(stats["file_count"] as Int, 0)
      XCTAssertGreaterThanOrEqual(stats["folder_count"] as Int, 0)
      XCTAssertEqual(stats["index_health"] as String, "empty")
    }
  }

  func testStatsReadIsFastPKLookup() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let appState = AppState()
    let indexDatabase = IndexDatabase(databaseURL: databaseURL)
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: try temporaryBookmarkStore(),
      workspaceSubstrate: WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: folder))
    )

    manager.openInBackground(url: folder, into: appState)
    await manager.waitForPendingWorkspaceBuild()

    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: appState.bookmarkData)
    let dbQueue = try DatabaseQueue(path: databaseURL.path)

    try await dbQueue.read { db in
      let start = Date()
      let statsRow = try Row.fetchOne(
        db, sql: "SELECT * FROM workspace_stats WHERE workspace_id = ?",
        arguments: [identity.workspaceID])
      let stats = try XCTUnwrap(
        statsRow, "Expected fast-lookup stats row for workspace_id \(identity.workspaceID)")
      let durationMs = Date().timeIntervalSince(start) * 1000
      XCTAssertLessThan(durationMs, 10.0)  // < 10ms target
      XCTAssertEqual(stats["file_count"] as Int, 0)

      let explainRows = try Row.fetchAll(
        db, sql: "EXPLAIN QUERY PLAN SELECT * FROM workspace_stats WHERE workspace_id = ?",
        arguments: [identity.workspaceID])
      let explainText = explainRows.map { $0["detail"] as String }.joined(separator: " ")
      XCTAssertTrue(
        explainText.contains("SEARCH")
          && (explainText.contains("INDEX") || explainText.contains("PRIMARY KEY")
            || explainText.contains("sqlite_autoindex")),
        "Should use index/PK for fast lookup")
    }
  }

  // MARK: - SUBAGENT_09: cold-start substrate `.valid` skip (kill the per-launch scan/commit storm)

  /// THE LIVE-SKIP TEST. A fresh relaunch (new FolderManager + new AppState, SAME on-disk
  /// substrate cache + SAME index DB) of an UNCHANGED workspace must consult the substrate
  /// `.valid` verdict FIRST and SKIP the whole cold scan/commit: NO new `cold_scan` scan_session,
  /// the workspaceBuilder walks the tree EXACTLY ONCE (no double-walk), the FTS row count is
  /// unchanged (no reindex churn), no "Indexing N" activity — yet the sidebar tree + documents
  /// are restored and search still finds a known file. This is the observable behavior the
  /// operator saw broken (5 identical cold_scan rows across 5 launches); the prior fixes made
  /// tests pass but the scan still ran.
  func testRelaunchOfUnchangedWorkspaceSkipsColdScanEntirely() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    // 30+ files (per the brief) spread across nested folders so the tree/fingerprint is non-trivial.
    let docsDir = folder.appendingPathComponent("docs", isDirectory: true)
    let subDir = docsDir.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
    for index in 0..<32 {
      let dir = index % 3 == 0 ? subDir : (index % 3 == 1 ? docsDir : folder)
      try "live-skip-token body \(index) needle-\(index)".write(
        to: dir.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
    }

    let cacheDir = folder.appendingPathComponent("cache", isDirectory: true)
    let substrate = WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: cacheDir))
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    // ONE IndexDatabase (one pool) across both launches — a real relaunch reopens the same file.
    let indexDatabase = IndexDatabase(databaseURL: databaseURL)

    let firstCalls = BuilderCallCounter()
    let firstBuilder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      firstCalls.increment()
      return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
    }

    // ---- First launch: full cold path → 1 cold_scan, full index, persisted manifest+signature.
    let firstState = AppState()
    let firstManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: try temporaryBookmarkStore(),
      workspaceBuilder: firstBuilder,
      workspaceSubstrate: substrate)
    firstManager.openInBackground(url: folder, into: firstState)
    await firstManager.waitForPendingWorkspaceBuild()
    await firstManager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()

    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: firstState.bookmarkData)
    let rootPath = folder.standardizedFileURL.path
    let ftsRowsAfterFirst =
      indexDatabase.indexedDocumentCount(forRootPaths: [rootPath], appState: firstState)
    XCTAssertEqual(ftsRowsAfterFirst, 32, "first launch full-indexes all 32 docs into FTS")

    let dbQueue = try DatabaseQueue(path: databaseURL.path)
    let sessionsAfterFirst = try await dbQueue.read { db in
      try XCTUnwrap(
        Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM scan_sessions WHERE workspace_id = ?",
          arguments: [identity.workspaceID]),
        "Expected first-launch scan_session count for workspace_id \(identity.workspaceID)")
    }
    XCTAssertEqual(sessionsAfterFirst, 1, "first launch writes exactly one cold_scan session")
    firstManager.closeWorkspace(into: firstState)  // simulate app quit between launches

    // ---- Second launch: fresh manager + fresh AppState (empty in-memory tree, like a relaunch).
    let secondCalls = BuilderCallCounter()
    let secondBuilder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      secondCalls.increment()
      return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
    }
    let secondState = AppState()
    let activity = ActivityRecorder(observing: secondState)
    let secondManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: try temporaryBookmarkStore(),
      workspaceBuilder: secondBuilder,
      workspaceSubstrate: substrate)
    secondManager.openInBackground(url: folder, into: secondState)
    await secondManager.waitForPendingWorkspaceBuild()
    await secondManager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()

    // (1) NO double walk: the relaunch walks the tree EXACTLY ONCE.
    XCTAssertEqual(
      secondCalls.value, 1,
      "valid-skip relaunch walks the tree exactly once (no validate-walk + cold-scan double walk)")

    // (2) NO new cold_scan session written on the unchanged relaunch.
    let sessionsAfterSecond = try await dbQueue.read { db in
      try XCTUnwrap(
        Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM scan_sessions WHERE workspace_id = ?",
          arguments: [identity.workspaceID]),
        "Expected second-launch scan_session count for workspace_id \(identity.workspaceID)")
    }
    XCTAssertEqual(
      sessionsAfterSecond, 1,
      "relaunch of an unchanged workspace writes NO new scan_session (substrate .valid skip)")

    // (3) The FTS index is reused untouched — same row count, no reindex churn on the skip.
    XCTAssertEqual(
      indexDatabase.indexedDocumentCount(forRootPaths: [rootPath], appState: secondState),
      ftsRowsAfterFirst, "valid-skip relaunch reuses the existing FTS index (no reindex churn)")

    // (4) The "Indexing N" activity NEVER appeared on the valid-skip open.
    let sawIndexing = activity.observedDetails.contains { $0.hasPrefix("Indexing ") }
    let observed = activity.observedDetails
    XCTAssertFalse(
      sawIndexing, "no 'Indexing N files' phase on a valid-skip relaunch (observed: \(observed))")
    XCTAssertNil(secondState.workspaceActivity, "activity cleared after the valid-skip open")

    // (5) The tree + documents are correctly restored from the single walk.
    XCTAssertEqual(secondState.documents.count, 32, "all 32 docs restored into the sidebar tree")
    XCTAssertFalse(secondState.workspaceTree.isEmpty, "the workspace tree is restored")

    // (6) Search still finds a known file against the reused index.
    XCTAssertEqual(
      indexDatabase.search(query: "needle-7", documents: secondState.allDocuments).count, 1,
      "the reused index still answers search after the skip")
  }

  /// A relaunch after a `.md` file CHANGED must NOT take the valid-skip (fingerprint differs) —
  /// it falls through to the cold/incremental path, writes a NEW scan_session, and search
  /// reflects the change.
  func testRelaunchAfterChangeDoesNotSkipAndReflectsChange() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    for index in 0..<5 {
      try "orig-token body \(index)".write(
        to: folder.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
    }

    let cacheDir = folder.appendingPathComponent("cache", isDirectory: true)
    let substrate = WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: cacheDir))
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let indexDatabase = IndexDatabase(databaseURL: databaseURL)

    let firstState = AppState()
    let firstManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: try temporaryBookmarkStore(),
      workspaceSubstrate: substrate)
    firstManager.openInBackground(url: folder, into: firstState)
    await firstManager.waitForPendingWorkspaceBuild()
    await firstManager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()
    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: firstState.bookmarkData)
    firstManager.closeWorkspace(into: firstState)

    // Operator changes one file between launches.
    try "changed-token modified content noticeably longer than before".write(
      to: folder.appendingPathComponent("note-1.md"), atomically: true, encoding: .utf8)

    let secondState = AppState()
    let secondManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: try temporaryBookmarkStore(),
      workspaceSubstrate: substrate)
    secondManager.openInBackground(url: folder, into: secondState)
    await secondManager.waitForPendingWorkspaceBuild()
    await secondManager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()

    let dbQueue = try DatabaseQueue(path: databaseURL.path)
    let sessions = try await dbQueue.read { db in
      try XCTUnwrap(
        Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM scan_sessions WHERE workspace_id = ?",
          arguments: [identity.workspaceID]),
        "Expected changed-workspace scan_session count for workspace_id \(identity.workspaceID)")
    }
    XCTAssertEqual(
      sessions, 2, "a changed workspace does NOT skip — a second cold_scan session is written")

    let refs = secondState.allDocuments
    XCTAssertEqual(
      indexDatabase.search(query: "changed-token", documents: refs)
        .map(\.document.url.lastPathComponent),
      ["note-1.md"], "the changed file's new content is searchable after the non-skip relaunch")
    XCTAssertTrue(
      indexDatabase.search(query: "orig-token", documents: refs)
        .allSatisfy { $0.document.url.lastPathComponent != "note-1.md" },
      "the changed file's stale content is gone")
  }

  /// Empty-index guard: a valid fingerprint (manifest matches the files) over an index that has
  /// NO rows for this workspace (operator nuked the index DB) must NOT skip — it must full-reindex
  /// and write a fresh cold_scan session.
  func testRelaunchWithValidFingerprintButEmptyIndexFullReindexes() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    for index in 0..<4 {
      try "guard-token body \(index)".write(
        to: folder.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
    }

    let cacheDir = folder.appendingPathComponent("cache", isDirectory: true)
    let substrate = WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: cacheDir))
    let rootPath = folder.standardizedFileURL.path

    // First launch into index.db.
    let firstURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let firstIndex = IndexDatabase(databaseURL: firstURL)
    let firstState = AppState()
    let firstManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: firstIndex,
      bookmarkStore: try temporaryBookmarkStore(),
      workspaceSubstrate: substrate)
    firstManager.openInBackground(url: folder, into: firstState)
    await firstManager.waitForPendingWorkspaceBuild()
    await firstManager.waitForPendingIndexUpdate()
    await firstIndex.waitForPendingReindex()
    XCTAssertEqual(
      firstIndex.indexedDocumentCount(forRootPaths: [rootPath], appState: firstState), 4,
      "first launch full-indexes")
    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: firstState.bookmarkData)
    XCTAssertNotNil(
      substrate.store.readSearchSignature(for: identity), "signature persisted after first launch")
    firstManager.closeWorkspace(into: firstState)

    // Second launch points at a BRAND-NEW empty index DB; manifest/fingerprint still match files.
    let secondURL = folder.appendingPathComponent("index-2.db", isDirectory: false)
    let secondIndex = IndexDatabase(databaseURL: secondURL)
    let secondState = AppState()
    let secondManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: secondIndex,
      bookmarkStore: try temporaryBookmarkStore(),
      workspaceSubstrate: substrate)
    secondManager.openInBackground(url: folder, into: secondState)
    await secondManager.waitForPendingWorkspaceBuild()
    await secondManager.waitForPendingIndexUpdate()
    await secondIndex.waitForPendingReindex()

    XCTAssertEqual(
      secondIndex.indexedDocumentCount(forRootPaths: [rootPath], appState: secondState), 4,
      "empty index + matching fingerprint must FULL-reindex (never skip an empty index)")
    let dbQueue = try DatabaseQueue(path: secondURL.path)
    let sessions = try await dbQueue.read { db in
      try XCTUnwrap(
        Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM scan_sessions WHERE workspace_id = ?",
          arguments: [identity.workspaceID]),
        "Expected empty-index scan_session count for workspace_id \(identity.workspaceID)")
    }
    XCTAssertEqual(
      sessions, 1, "the empty-index relaunch writes a fresh cold_scan session (no skip)")
    XCTAssertEqual(
      secondIndex.search(query: "guard-token", documents: secondState.allDocuments).count, 4,
      "all docs searchable after the guarded full reindex")
  }

  /// MULTI-ROOT valid-skip (Cut 3-1, F4 proof). A 2-root workspace cold-opens ONCE; an unchanged
  /// relaunch (a fresh manager + AppState that RESTORES the persisted multi-root workspace) takes
  /// the substrate `.valid` skip: no second tree walk, no new cold_scan session (no manifest
  /// re-commit), no FTS reindex churn. This is the cut that flips multi-root user-visible behavior —
  /// before lifting the `count == 1` cache gates a 2-root workspace cold-reindexed on EVERY open.
  func testMultiRootRelaunchTakesValidSkipWithoutReindex() async throws {
    let rootA = try makeTemporaryFolder()
    let rootB = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: rootA) }
    defer { try? FileManager.default.removeItem(at: rootB) }

    for index in 0..<6 {
      try "alpha-token body \(index) needle-a-\(index)".write(
        to: rootA.appendingPathComponent("a-\(index).md"), atomically: true, encoding: .utf8)
    }
    for index in 0..<4 {
      try "beta-token body \(index) needle-b-\(index)".write(
        to: rootB.appendingPathComponent("b-\(index).md"), atomically: true, encoding: .utf8)
    }

    // Cache + index DB live OUTSIDE either root so they are never themselves indexed.
    let support = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: support) }
    let substrate = WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: support))
    let databaseURL = support.appendingPathComponent("index.db", isDirectory: false)
    // ONE IndexDatabase (one pool) across both launches — a real relaunch reopens the same file.
    let indexDatabase = IndexDatabase(databaseURL: databaseURL)

    // ONE shared bookmark store across both launches: the relaunch RESTORES the persisted multi-root
    // workspace in a SINGLE open, exactly like a real app restart. (We deliberately do NOT call
    // `closeWorkspace` — it clears the bookmark store; a relaunch is a fresh process, not a folder
    // close. Fresh manager + fresh AppState already gives the empty in-memory tree / nil baseline.)
    let suiteName = "PensieveMultiRootSkipTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(
      UserDefaults(suiteName: suiteName), "Expected UserDefaults suite \(suiteName)")
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let bookmarkStore = BookmarkStore(defaults: defaults)

    let rootPaths = [rootA, rootB].map { $0.standardizedFileURL.path }

    // Seed BOTH roots into the shared bookmark store, then open the 2-root workspace in ONE call
    // via the restore seam. (Opening A then ADDING B would index A's docs under a spurious [A]-only
    // workspace as well, inflating the cross-workspace count; a single multi-root open is the clean
    // analogue of a workspace the operator already assembled in a prior session.)
    let seedState = AppState()
    try bookmarkStore.persistRoot(url: rootA, into: seedState)
    try bookmarkStore.persistRoot(url: rootB, into: seedState)

    // ---- First launch: restore the 2-root workspace → full cold index of all 10 docs.
    let firstState = AppState()
    let firstManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceSubstrate: substrate)
    firstManager.restoreLastFolderInBackground(into: firstState)
    await firstManager.waitForPendingWorkspaceBuild()
    await firstManager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()

    XCTAssertEqual(
      Set(firstState.workspaceRoots.map { $0.url.standardizedFileURL }),
      Set([rootA.standardizedFileURL, rootB.standardizedFileURL]),
      "first launch holds BOTH roots in memory")

    // Multi-root identity keys on the FULL root set (order-independent); used to query sessions.
    let identity = WorkspaceIdentity.make(
      roots: [rootA, rootB], bookmarkData: firstState.bookmarkData)
    // The in-memory sidebar tree (rebuilt from the single scan, not the index) is exact: 10 docs.
    XCTAssertEqual(
      firstState.documents.count, 10, "first launch loads all 10 docs across BOTH roots")
    // FTS rows after the cold open. NOTE: the document-write layer keys workspace docs PER ROOT
    // (`IndexDatabase.documentWriteRecord` → `make(rootURL:)`), while `commitWorkspaceManifest` now
    // ALSO writes them under the COMBINED multi-root identity — so a 2-root cold open currently
    // double-writes (combined copy + per-root copy). That index-layer regression is OUT OF SCOPE
    // for Cut 3-1 (cache fast-path gates) and reported separately; this test pins the cache-SKIP
    // behavior via INVARIANCE across the relaunch, not an absolute row count.
    let ftsRowsAfterFirst =
      indexDatabase.indexedDocumentCount(forRootPaths: rootPaths, appState: firstState)
    XCTAssertGreaterThan(ftsRowsAfterFirst, 0, "first launch indexes the multi-root workspace")

    let dbQueue = try DatabaseQueue(path: databaseURL.path)
    let sessionsAfterFirst = try await dbQueue.read { db in
      try XCTUnwrap(
        Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM scan_sessions WHERE workspace_id = ?",
          arguments: [identity.workspaceID]),
        "Expected first-launch scan_session count for multi-root \(identity.workspaceID)")
    }
    XCTAssertEqual(
      sessionsAfterFirst, 1,
      "first launch writes exactly one cold_scan session for the 2-root identity")
    XCTAssertNotNil(
      substrate.store.readSearchSignature(for: identity),
      "multi-root search signature persisted after first launch")

    // ---- Second launch: fresh manager + AppState (empty tree, nil baseline → relaunch), SAME
    // bookmark store → restore the 2-root workspace in ONE multi-root open. Unchanged files.
    let secondCalls = BuilderCallCounter()
    let secondBuilder: WorkspaceScanner.Builder = { rootURLs, exclusions in
      secondCalls.increment()
      return WorkspaceScanner.build(rootURLs: rootURLs, exclusions: exclusions)
    }
    let secondState = AppState()
    let activity = ActivityRecorder(observing: secondState)
    let secondManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceBuilder: secondBuilder,
      workspaceSubstrate: substrate)
    secondManager.restoreLastFolderInBackground(into: secondState)
    await secondManager.waitForPendingWorkspaceBuild()
    await secondManager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()

    XCTAssertEqual(
      Set(secondState.workspaceRoots.map { $0.url.standardizedFileURL }),
      Set([rootA.standardizedFileURL, rootB.standardizedFileURL]),
      "relaunch restores BOTH roots")

    // (1) NO double walk: the multi-root relaunch walks the tree EXACTLY ONCE.
    XCTAssertEqual(
      secondCalls.value, 1,
      "multi-root valid-skip relaunch walks the tree exactly once (no validate-walk + cold-scan double walk)"
    )

    // (2) NO new cold_scan session — the skip does NOT re-commit the multi-root manifest.
    let sessionsAfterSecond = try await dbQueue.read { db in
      try XCTUnwrap(
        Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM scan_sessions WHERE workspace_id = ?",
          arguments: [identity.workspaceID]),
        "Expected second-launch scan_session count for multi-root \(identity.workspaceID)")
    }
    XCTAssertEqual(
      sessionsAfterSecond, 1,
      "unchanged 2-root relaunch writes NO new scan_session (substrate .valid skip, no manifest re-commit)"
    )

    // (3) The FTS index is reused untouched — same row count, no reindex churn on the skip.
    XCTAssertEqual(
      indexDatabase.indexedDocumentCount(forRootPaths: rootPaths, appState: secondState),
      ftsRowsAfterFirst,
      "multi-root valid-skip relaunch reuses the existing FTS index (no reindex churn)")

    // (4) The misleading "Indexing N" phase NEVER appeared on the multi-root valid-skip open.
    let sawIndexing = activity.observedDetails.contains { $0.hasPrefix("Indexing ") }
    XCTAssertFalse(
      sawIndexing,
      "no 'Indexing N files' phase on a multi-root valid-skip relaunch (observed: \(activity.observedDetails))"
    )
    XCTAssertNil(
      secondState.workspaceActivity, "activity cleared after the multi-root valid-skip open")

    // (5) Tree + documents restored from the single walk, across BOTH roots.
    XCTAssertEqual(
      secondState.documents.count, 10, "all 10 docs across both roots restored into the tree")
    XCTAssertFalse(secondState.workspaceTree.isEmpty, "the multi-root workspace tree is restored")

    // (6) Search answers against the reused index for a file from EACH root (≥1; the index-layer
    // double-write noted above can return duplicate hits — orthogonal to the cache skip).
    XCTAssertGreaterThanOrEqual(
      indexDatabase.search(query: "needle-a-3", documents: secondState.allDocuments).count, 1,
      "the reused index answers search for a root-A file after the multi-root skip")
    XCTAssertGreaterThanOrEqual(
      indexDatabase.search(query: "needle-b-2", documents: secondState.allDocuments).count, 1,
      "the reused index answers search for a root-B file after the multi-root skip")
  }

  /// MULTI-ROOT freshness (Cut 3-1). A change in the SECOND root must invalidate the multi-root
  /// fingerprint so the next relaunch does NOT skip — it cold-scans (a new session) and the changed
  /// content becomes searchable. Proves the lifted fingerprint covers every root, not just the first.
  func testMultiRootRelaunchAfterChangeInSecondRootReindexes() async throws {
    let rootA = try makeTemporaryFolder()
    let rootB = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: rootA) }
    defer { try? FileManager.default.removeItem(at: rootB) }

    for index in 0..<3 {
      try "alpha-token body \(index)".write(
        to: rootA.appendingPathComponent("a-\(index).md"), atomically: true, encoding: .utf8)
    }
    for index in 0..<3 {
      try "orig-token body \(index)".write(
        to: rootB.appendingPathComponent("b-\(index).md"), atomically: true, encoding: .utf8)
    }

    let support = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: support) }
    let substrate = WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: support))
    let databaseURL = support.appendingPathComponent("index.db", isDirectory: false)
    let indexDatabase = IndexDatabase(databaseURL: databaseURL)

    let suiteName = "PensieveMultiRootChangeTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(
      UserDefaults(suiteName: suiteName), "Expected UserDefaults suite \(suiteName)")
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let bookmarkStore = BookmarkStore(defaults: defaults)

    // Seed both roots, then open the 2-root workspace in ONE call via restore (see the sibling
    // skip test for why a single multi-root open is used instead of open-A-then-add-B).
    let seedState = AppState()
    try bookmarkStore.persistRoot(url: rootA, into: seedState)
    try bookmarkStore.persistRoot(url: rootB, into: seedState)

    // First launch: restore the 2-root workspace, full cold index.
    let firstState = AppState()
    let firstManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceSubstrate: substrate)
    firstManager.restoreLastFolderInBackground(into: firstState)
    await firstManager.waitForPendingWorkspaceBuild()
    await firstManager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()
    let identity = WorkspaceIdentity.make(
      roots: [rootA, rootB], bookmarkData: firstState.bookmarkData)

    // Operator changes a file in the SECOND root between launches.
    try "changed-token modified content noticeably longer than the original line".write(
      to: rootB.appendingPathComponent("b-1.md"), atomically: true, encoding: .utf8)

    // Second launch: restore → fingerprint over [A,B] now differs → NO skip.
    let secondState = AppState()
    let secondManager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      workspaceSubstrate: substrate)
    secondManager.restoreLastFolderInBackground(into: secondState)
    await secondManager.waitForPendingWorkspaceBuild()
    await secondManager.waitForPendingIndexUpdate()
    await indexDatabase.waitForPendingReindex()

    let dbQueue = try DatabaseQueue(path: databaseURL.path)
    let sessions = try await dbQueue.read { db in
      try XCTUnwrap(
        Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM scan_sessions WHERE workspace_id = ?",
          arguments: [identity.workspaceID]),
        "Expected changed multi-root scan_session count for \(identity.workspaceID)")
    }
    XCTAssertEqual(
      sessions, 2,
      "a change in the SECOND root does NOT skip — a second cold_scan session is written")

    // The changed root-B file's new content is searchable (the fingerprint over BOTH roots caught
    // the change → no skip → reindex). The result maps to b-1.md regardless of any index-layer
    // duplicate rows (the per-file `lastPathComponent` is what matters here).
    let refs = secondState.allDocuments
    let changedHits = indexDatabase.search(query: "changed-token", documents: refs)
      .map(\.document.url.lastPathComponent)
    XCTAssertTrue(
      changedHits.contains("b-1.md") && Set(changedHits) == ["b-1.md"],
      "only the changed root-B file matches the new content after the non-skip relaunch (got \(changedHits))"
    )
  }

  private func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveIndexV2StatsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func temporaryMetadataStore() -> WorkspaceMetadataStore {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveIndexV2StatsMetadataTests-\(UUID().uuidString)",
        isDirectory: true
      )
    return WorkspaceMetadataStore(
      metadataURL: folder.appendingPathComponent("workspace.json", isDirectory: false))
  }

  private func temporaryBookmarkStore() throws -> BookmarkStore {
    let suiteName = "PensieveIndexV2StatsBookmarkTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(
      UserDefaults(suiteName: suiteName),
      "Expected UserDefaults suite \(suiteName) to be creatable")
    defaults.removePersistentDomain(forName: suiteName)
    return BookmarkStore(defaults: defaults)
  }
}

/// Thread-safe walk counter so the `@Sendable` workspace builder closure can tally how many
/// times the tree was walked (proves the single-walk invariant on a valid-skip relaunch).
private final class BuilderCallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}

/// Records every non-nil `WorkspaceActivity.detail` an `AppState` passes through so a test can
/// prove the misleading "Indexing N files" phase NEVER appeared on a valid-skip open. `AppState`
/// is now `@Observable` (no Combine `$` publisher), so this re-arms an Observation tracking loop:
/// each change schedules a main-actor read of the new value and re-arms. `workspaceActivity` is
/// mutated only on the main actor and the test awaits between phases, so each phase is captured.
@MainActor
private final class ActivityRecorder {
  private(set) var observedDetails: [String] = []
  private let appState: AppState

  init(observing appState: AppState) {
    self.appState = appState
    record(appState.workspaceActivity)
    arm()
  }

  private func record(_ activity: WorkspaceActivity?) {
    if let detail = activity?.detail {
      observedDetails.append(detail)
    }
  }

  private func arm() {
    withObservationTracking {
      _ = appState.workspaceActivity
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.record(self.appState.workspaceActivity)
        self.arm()
      }
    }
  }
}
