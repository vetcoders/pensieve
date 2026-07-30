//  IndexDatabaseStorageHygieneTests.swift
//  PensieveTests
//
//  W1-B (index hygiene): pins the disk-space contract of the index database.
//  `DatabasePool` implies WAL, and SQLite's own auto-checkpoint is PASSIVE — it
//  recycles WAL frames but never shrinks the `-wal` file, which is how this
//  project measured a 3.7 GB index.db next to a 2.2 GB index.db-wal during a
//  reindex storm. These tests assert on FILE SIZES and SQLite pragmas, not on
//  "the maintenance function ran": a green checkpoint call that leaves the WAL
//  at its high-water mark would be exactly the bug this cut exists to prevent.

import AppKit
import GRDB
import XCTest

@testable import Pensieve

@MainActor
final class IndexDatabaseStorageHygieneTests: XCTestCase {

  // MARK: - Fixtures

  private func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveStorageHygieneTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func fileSize(at url: URL) -> Int64 {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let size = attributes[.size] as? Int64
    else { return 0 }
    return size
  }

  private func walSize(for databaseURL: URL) -> Int64 {
    fileSize(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
  }

  /// Reads a pragma through an INDEPENDENT connection, so the assertion reflects
  /// the on-disk database rather than the state of the pool under test.
  private func pragmaValue(_ pragma: String, at databaseURL: URL) throws -> Int {
    let queue = try DatabaseQueue(path: databaseURL.path)
    return try queue.read { db in try Int.fetchOne(db, sql: "PRAGMA \(pragma)") ?? 0 }
  }

  /// Counts rows through an INDEPENDENT connection, so "this write committed" is read from the
  /// on-disk database rather than from the pool that is under test.
  private func rowCount(_ table: String, at databaseURL: URL) throws -> Int {
    let queue = try DatabaseQueue(path: databaseURL.path)
    return try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
  }

  /// Counts FTS matches through an INDEPENDENT connection. Required after a quit: the termination
  /// latch closes the index funnel, so the database under test refuses to open anything and would
  /// answer every query with "empty" regardless of what actually landed on disk.
  private func indexHits(matching needle: String, at databaseURL: URL) throws -> Int {
    let queue = try DatabaseQueue(path: databaseURL.path)
    return try queue.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM document_fts WHERE document_fts MATCH ?",
        arguments: [needle]) ?? 0
    }
  }

  private func documentRef(root: URL, name: String) -> DocumentRef {
    DocumentRef(
      id: root.appendingPathComponent(name).standardizedFileURL,
      rootURL: root,
      relativePath: name
    )
  }

  /// Writes `count` documents of ~24 KiB each through the synchronous index path
  /// (one transaction per document, no maintenance hook), then deletes
  /// `deleting` of them — the upsert+delete churn a reindex storm produces.
  /// Returns the paths that are still indexed.
  @discardableResult
  private func churn(
    database: IndexDatabase,
    root: URL,
    count: Int,
    deleting: Int
  ) -> [String] {
    let body = String(repeating: "pensieve storage hygiene churn payload ", count: 600)
    var paths: [String] = []
    for index in 0..<count {
      let ref = documentRef(root: root, name: "churn-\(index).md")
      database.index(document: ref, body: "\(body) \(index)")
      paths.append(ref.url.path)
    }
    let deletedPaths = Array(paths.prefix(deleting))
    if !deletedPaths.isEmpty {
      database.updateSearchIndex(upserting: [], deletingPaths: deletedPaths)
    }
    return Array(paths.dropFirst(deleting))
  }

  // MARK: - auto_vacuum provisioning

  /// A fresh index.db must be born `auto_vacuum = INCREMENTAL` (mode 2). SQLite
  /// only accepts the mode change while the file header does not exist yet —
  /// after `journal_mode = WAL` it silently ignores the pragma — so this pins the
  /// ordering that `IndexDatabase.makeConfiguration` relies on. Without it, every
  /// page freed by a delete stays inside the file forever.
  func testFreshIndexDatabaseIsCreatedWithIncrementalAutoVacuum() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    XCTAssertEqual(
      try pragmaValue("auto_vacuum", at: databaseURL), 2,
      "fresh index.db must use auto_vacuum = INCREMENTAL so freed pages can be reclaimed")
  }

  /// Migration path for databases created before this cut: they carry
  /// `auto_vacuum = 0`, and SQLite only switches modes through a full VACUUM.
  /// Workspace close performs that one-shot conversion.
  func testLegacyDatabaseIsConvertedToIncrementalAutoVacuumOnWorkspaceClose() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    // Stand up the file the pre-hygiene way: WAL first, so the header exists and
    // auto_vacuum can no longer be set by a pragma alone.
    let legacyPool = try DatabasePool(path: databaseURL.path)
    try await legacyPool.write { db in
      try db.execute(sql: "CREATE TABLE legacy_marker(id INTEGER PRIMARY KEY)")
    }
    // Release the fixture connection so the conversion VACUUM runs against the
    // same single-writer situation the app has at workspace close.
    try legacyPool.close()
    XCTAssertEqual(
      try pragmaValue("auto_vacuum", at: databaseURL), 0,
      "fixture precondition: the legacy database must start in auto_vacuum = NONE")

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)
    XCTAssertEqual(
      try pragmaValue("auto_vacuum", at: databaseURL), 0,
      "opening an existing database must not silently rewrite it — only maintenance may VACUUM")

    await database.performMaintenanceInBackground(reason: .workspaceClose)

    XCTAssertEqual(
      try pragmaValue("auto_vacuum", at: databaseURL), 2,
      "workspace-close maintenance must convert a legacy database to INCREMENTAL auto_vacuum")
  }

  /// Stands up a database the pre-hygiene way — WAL first, so the header exists and `auto_vacuum` can
  /// no longer be set by a pragma alone — and releases the fixture connection, so a later conversion
  /// VACUUM meets the same single-writer situation the app has at workspace close.
  private func makeLegacyDatabase(at databaseURL: URL) async throws {
    let legacyPool = try DatabasePool(path: databaseURL.path)
    try await legacyPool.write { db in
      try db.execute(sql: "CREATE TABLE legacy_marker(id INTEGER PRIMARY KEY)")
    }
    try legacyPool.close()
    XCTAssertEqual(
      try pragmaValue("auto_vacuum", at: databaseURL), 0,
      "fixture precondition: the legacy database must start in auto_vacuum = NONE")
  }

  /// The conversion's cost ceiling used to be read off `index.db` alone. `VACUUM` rewrites the whole
  /// LOGICAL database, and in WAL mode a large part of that can still be sitting in `index.db-wal`
  /// (a reader holding a snapshot is enough to stop checkpoints moving it back) — so a small main
  /// file next to a multi-gigabyte WAL sailed past the very limit that exists to bound the rewrite
  /// cost and the roughly 2× peak disk usage.
  ///
  /// The limit is placed BETWEEN the two measurements rather than at a guessed byte count: the main
  /// file alone fits comfortably under it, main + WAL does not. That is the reviewer's scenario
  /// exactly, and it cannot drift with the fixture's size.
  func testLegacyConversionDeclinesWhenTheWalPushesTheLogicalSizeOverTheLimit() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try await makeLegacyDatabase(at: databaseURL)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)
    churn(database: database, root: root, count: 300, deleting: 0)

    let mainSize = fileSize(at: databaseURL)
    let walBytes = walSize(for: databaseURL)
    XCTAssertGreaterThan(
      walBytes, 1,
      "fixture precondition: the churn must leave pages in the WAL for the guard to have to count")
    let limit = mainSize + walBytes / 2
    XCTAssertLessThanOrEqual(
      mainSize, limit, "fixture precondition: the main file alone must fit under the limit")
    XCTAssertGreaterThan(
      mainSize + walBytes, limit,
      "fixture precondition: main + WAL must exceed it, or the guard is not being exercised")
    database.autoVacuumConversionByteLimitOverride = limit

    await database.performMaintenanceInBackground(reason: .workspaceClose)

    XCTAssertEqual(
      try pragmaValue("auto_vacuum", at: databaseURL), 0,
      "the one-shot conversion must be bounded by the LOGICAL database: a \(mainSize)-byte index.db "
        + "next to a \(walBytes)-byte WAL still costs a full rewrite of both")
  }

  /// The control for the guard above: the same legacy-plus-WAL shape converts as soon as the logical
  /// size genuinely fits, so the decline is the WAL being counted rather than a guard that now
  /// refuses everything with a non-empty log.
  func testLegacyConversionStillRunsWhenMainAndWalTogetherFitTheLimit() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try await makeLegacyDatabase(at: databaseURL)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)
    churn(database: database, root: root, count: 300, deleting: 0)

    let walBytes = walSize(for: databaseURL)
    XCTAssertGreaterThan(
      walBytes, 1, "fixture precondition: this control must carry a WAL too, or it proves nothing")
    database.autoVacuumConversionByteLimitOverride =
      fileSize(at: databaseURL) + walBytes + 1024 * 1024

    await database.performMaintenanceInBackground(reason: .workspaceClose)

    XCTAssertEqual(
      try pragmaValue("auto_vacuum", at: databaseURL), 2,
      "a legacy database whose main file AND WAL fit the ceiling must still be converted")
  }

  // MARK: - WAL bound

  /// The headline assertion: after churn the `-wal` file has a real high-water
  /// mark, and a workspace-close checkpoint gives that space back.
  ///
  /// Thresholds: the churn writes ~7 MiB across ~300 transactions, so the WAL
  /// high-water mark sits around SQLite's 4 MiB auto-checkpoint threshold —
  /// asserting `>= 512 KiB` before keeps the test honest (a vacuous run would
  /// fail here) with a wide margin. A TRUNCATE checkpoint sets the WAL to 0
  /// bytes; the `<= 64 KiB` ceiling afterwards absorbs any incidental frame a
  /// later connection could append without accepting a still-growing log.
  func testWorkspaceCloseMaintenanceTruncatesWalAfterChurn() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    churn(database: database, root: root, count: 300, deleting: 150)

    let walBefore = walSize(for: databaseURL)
    XCTAssertGreaterThanOrEqual(
      walBefore, 512 * 1024,
      "fixture precondition: the churn must actually grow the WAL, otherwise the truncate proves nothing"
    )

    await database.performMaintenanceInBackground(reason: .workspaceClose)

    let walAfter = walSize(for: databaseURL)
    XCTAssertLessThanOrEqual(
      walAfter, 64 * 1024,
      "TRUNCATE checkpoint must hand the WAL back to the filesystem (was \(walBefore) bytes, now \(walAfter))"
    )
  }

  /// The batch hook must NOT take the barrier lock on every small write — that
  /// would put a full checkpoint on the save/watcher path. Below the 16 MiB
  /// threshold the WAL is left alone, which a non-zero `-wal` file proves.
  func testIndexBatchMaintenanceIsThrottledBelowWalThreshold() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let noteURL = root.appendingPathComponent("small.md")
    try "tiny delta".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    await database.openInBackground(into: appState)
    XCTAssertNil(appState.lastError)

    let didWrite = await database.updateSearchIndexInBackground(
      upserting: [documentRef(root: root, name: "small.md")],
      deletingPaths: [],
      appState: appState
    )
    XCTAssertTrue(didWrite)
    await database.waitForPendingReindex()
    // …and the maintenance hand-off too: since round 11 it lives outside the supersede chain, so
    // `waitForPendingReindex()` alone would let this pin pass before the throttle was even consulted.
    await database.drainPendingIndexWrites()

    XCTAssertGreaterThan(
      walSize(for: databaseURL), 0,
      "a single small delta must not trigger a barrier checkpoint — the WAL throttle is the point")
  }

  // MARK: - Compaction

  /// Deleting indexed documents leaves free pages behind. In INCREMENTAL mode
  /// maintenance must return them to the filesystem instead of letting the file
  /// keep its worst-ever size.
  func testMaintenanceReclaimsFreePagesAfterDeletes() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    churn(database: database, root: root, count: 300, deleting: 300)

    let freelistBefore = try pragmaValue("freelist_count", at: databaseURL)
    XCTAssertGreaterThan(
      freelistBefore, IndexDatabaseStorageHygieneTests.compactionThresholdPages,
      "fixture precondition: deleting every indexed document must leave free pages to reclaim")
    let sizeBefore = fileSize(at: databaseURL)

    await database.performMaintenanceInBackground(reason: .workspaceClose)

    let freelistAfter = try pragmaValue("freelist_count", at: databaseURL)
    let sizeAfter = fileSize(at: databaseURL)
    XCTAssertLessThan(
      freelistAfter, freelistBefore,
      "incremental_vacuum must consume the freelist (was \(freelistBefore), now \(freelistAfter))")
    XCTAssertLessThan(
      sizeAfter, sizeBefore,
      "reclaimed pages must shrink index.db itself (was \(sizeBefore) bytes, now \(sizeAfter))")
  }

  // MARK: - Production wiring: every quit path checkpoints

  /// The checkpoint used to hang off the custom "Quit Pensieve" menu item alone
  /// (`AppController.applicationShouldTerminate()`), so Dock quit, logout and
  /// shutdown — everything that goes straight to `terminate:` — skipped it.
  ///
  /// This drives the REAL delegate entry point AppKit calls, not a helper: the
  /// bug was never in the terminal checkpoint itself (which had its own passing
  /// tests), it was in nothing calling it. Note the delegate hook deliberately
  /// is NOT `applicationShouldTerminate(_:)`: under
  /// `@NSApplicationDelegateAdaptor` that method is never invoked at all
  /// (falsified at runtime on 2026-07-29), so a test pinning it would have gone
  /// green against dead code.
  func testApplicationWillTerminateCheckpointsTheIndexOnQuitPathsWithoutTheMenuItem() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    churn(database: database, root: root, count: 300, deleting: 0)
    let walBefore = walSize(for: databaseURL)
    XCTAssertGreaterThanOrEqual(
      walBefore, 512 * 1024,
      "fixture precondition: the churn must actually grow the WAL, otherwise the truncate proves nothing"
    )

    let delegate = PensieveAppDelegate()
    // Kept off the process-wide singletons so this test cannot leave a
    // `beginTermination()` latch behind for whatever runs next in the suite.
    delegate.terminationWindowRegistryOverride = DocumentWindowRegistry()
    delegate.terminationIndexDatabaseOverride = database
    delegate.applicationWillTerminate(
      Notification(name: NSApplication.willTerminateNotification))

    XCTAssertLessThanOrEqual(
      walSize(for: databaseURL), 64 * 1024,
      "quitting without the menu item must still truncate the WAL (was \(walBefore) bytes, now \(walSize(for: databaseURL)))"
    )
  }

  // MARK: - Production wiring: last-root removal orders its delete before maintenance

  /// `removeRoot` on the LAST root closes the workspace and then deletes that
  /// root's paths from the index. Close arms the compaction/checkpoint, so the
  /// two used to be independent tasks with no ordering between them: maintenance
  /// could truncate the WAL and reclaim pages BEFORE the delete, and the delete's
  /// own frames and free pages then stayed on disk — with the workspace gone,
  /// no further batch checkpoint was coming to notice them.
  ///
  /// The assertion is the ordering, not "maintenance ran": awaiting ONLY the
  /// maintenance handle must already imply the delete landed (it is chained
  /// behind it), and the WAL must be back at zero — which can only be true if
  /// the truncate was strictly last.
  ///
  /// Sibling pin:
  /// `testCloseWorkspaceDefersMaintenanceOnlyWhenTheCallerOwnsAFinalIndexWrite`
  /// covers the other half of the fix (close must not fire its own maintenance
  /// alongside the delete). Removing the fix makes THAT one fail deterministically;
  /// this one is a race, and GRDB's write barrier happens to queue behind an
  /// in-flight write often enough that the unordered version still passes it
  /// most of the time — measured, not assumed.
  func testLastRootRemovalDeletesFromTheIndexBeforeMaintenanceCompacts() async throws {
    let sandbox = try makeWorkspaceSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Sized so the DELETE alone writes well past the post-truncate ceiling asserted
    // below: that is what makes the ordering observable rather than merely likely.
    let body = String(repeating: "pensieve last root removal payload ", count: 600)
    for index in 0..<120 {
      try "\(body) \(index)".write(
        to: root.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
    }

    let harness = try makeWorkspaceHarness(in: sandbox.support)
    let appState = AppState()
    harness.manager.open(url: root, into: appState)
    await settle(harness)

    let indexedDocument = try XCTUnwrap(appState.documents.first)
    XCTAssertFalse(
      harness.indexDatabase.search(
        query: "payload", documents: [indexedDocument], appState: appState
      ).isEmpty,
      "fixture precondition: the workspace must actually be indexed before it is removed")
    XCTAssertEqual(appState.workspaceRoots.count, 1)

    harness.manager.removeRoot(root, into: appState)
    // ONLY the maintenance handle — deliberately not the index-update handle.
    // Under the unordered version this returns while the delete is still in
    // flight, which is precisely the defect.
    await harness.manager.waitForPendingIndexMaintenance()
    // Sampled before any assertion touches the pool, so the reading is the state
    // the maintenance left behind and nothing else.
    let databaseURL = sandbox.support.appendingPathComponent("index.db", isDirectory: false)
    let walAfterMaintenance = walSize(for: databaseURL)

    XCTAssertTrue(
      harness.indexDatabase.search(
        query: "payload", documents: [indexedDocument], appState: appState
      ).isEmpty,
      "close-time maintenance must not complete before the last root's rows are deleted")
    XCTAssertLessThanOrEqual(
      walAfterMaintenance, 64 * 1024,
      "the truncating checkpoint must run AFTER the delete, otherwise the delete's WAL frames "
        + "survive the workspace that would have checkpointed them (WAL is \(walAfterMaintenance) bytes)"
    )
  }

  /// The half of the last-root fix that does not depend on scheduling: a close
  /// whose CALLER still owes the index a write must not arm its own maintenance,
  /// because that is the task that could otherwise compact ahead of the write.
  /// Both directions are asserted, so neither "never runs maintenance" nor
  /// "always runs it" can pass.
  func testCloseWorkspaceDefersMaintenanceOnlyWhenTheCallerOwnsAFinalIndexWrite() async throws {
    for deferring in [true, false] {
      let sandbox = try makeWorkspaceSandbox()
      let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let body = String(repeating: "pensieve close maintenance payload ", count: 600)
      for index in 0..<120 {
        try "\(body) \(index)".write(
          to: root.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
      }

      let harness = try makeWorkspaceHarness(in: sandbox.support)
      let appState = AppState()
      harness.manager.open(url: root, into: appState)
      await settle(harness)

      let databaseURL = sandbox.support.appendingPathComponent("index.db", isDirectory: false)
      XCTAssertGreaterThan(
        walSize(for: databaseURL), 64 * 1024,
        "fixture precondition: indexing the workspace must leave a WAL worth truncating")

      harness.manager.closeWorkspace(into: appState, deferringIndexMaintenance: deferring)
      await harness.manager.waitForPendingIndexMaintenance()
      let wal = walSize(for: databaseURL)

      if deferring {
        XCTAssertGreaterThan(
          wal, 64 * 1024,
          "a deferring close must leave the housekeeping to its caller — firing it here is the "
            + "task that races the caller's final delete (WAL is \(wal) bytes)")
      } else {
        XCTAssertLessThanOrEqual(
          wal, 64 * 1024,
          "an ordinary close is still the point where the WAL gets truncated (WAL is \(wal) bytes)")
      }
    }
  }

  // MARK: - Production wiring: an ordinary save is subject to the WAL threshold

  /// Production saves route a single document through `indexInBackground`. That
  /// path wrote, refreshed and returned — it never consulted the 16 MiB WAL
  /// bound the rest of this cut declares, so a large document (or a long
  /// editing session) could push the log past the ceiling and leave it there
  /// until an unrelated lifecycle event. Threshold lowered through the internal
  /// seam so the test does not have to write 16 MiB to reach the checkpoint.
  func testSingleDocumentSaveCheckpointsOnceTheWalPassesTheThreshold() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    churn(database: database, root: root, count: 300, deleting: 0)
    let walBefore = walSize(for: databaseURL)
    XCTAssertGreaterThan(
      walBefore, 0, "fixture precondition: the WAL must be non-empty before the save under test")
    database.walCheckpointThresholdBytesOverride = Int64(walBefore)

    let didWrite = await database.indexInBackground(
      document: documentRef(root: root, name: "saved.md"),
      body: "the document the operator just saved",
      appState: appState
    )
    XCTAssertTrue(didWrite)
    // Since round 11 the batch maintenance is ARMED by the write rather than awaited inside it, so
    // the save returns before the truncate — that is the liveness fix, and this is the seam that
    // observes it. `drainPendingIndexWrites()` is the right wait because it is the same one the quit
    // sequence uses: it tracks the maintenance hand-off, `waitForPendingReindex()` no longer does.
    await database.drainPendingIndexWrites()

    XCTAssertLessThanOrEqual(
      walSize(for: databaseURL), 64 * 1024,
      "an ordinary save past the WAL threshold must take the checkpoint like any other index batch "
        + "(was \(walBefore) bytes, now \(walSize(for: databaseURL)))"
    )
  }

  /// The other half of the same contract: below the threshold a save must stay
  /// free. A non-empty `-wal` afterwards proves no barrier checkpoint was taken
  /// on the typing/saving hot path.
  func testSingleDocumentSaveIsThrottledBelowTheWalThreshold() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    await database.openInBackground(into: appState)
    XCTAssertNil(appState.lastError)

    let didWrite = await database.indexInBackground(
      document: documentRef(root: root, name: "small.md"),
      body: "tiny save",
      appState: appState
    )
    XCTAssertTrue(didWrite)
    // Drained rather than merely returned-from: since round 11 the maintenance is armed as its own
    // tracked write, so "nothing was truncated" is only a claim once that hand-off has finished.
    await database.drainPendingIndexWrites()

    XCTAssertGreaterThan(
      walSize(for: databaseURL), 0,
      "a small save must not take the barrier checkpoint — the 16 MiB throttle is the point")
  }

  // MARK: - R11: storage hygiene must not stall functional writes

  /// Round 11, finding 3 (P2) — the campaign's only finding about a RUNNING session's liveness rather
  /// than about durability.
  ///
  /// `performMaintenanceInBackground` takes `barrierWriteWithoutTransaction`, which excludes the
  /// pool's READERS — deliberately, because a plain write leaves readers holding WAL snapshots and
  /// SQLite silently downgrades the truncate to a no-op. The `.indexBatch` call was `await`ed INSIDE
  /// the write task `pendingIndexUpdateTask` points at, so that barrier sat in the supersede tail:
  /// one slow or wedged search/backlink query blocked not just the truncate but every reindex,
  /// watcher delta and save submitted afterwards, for the rest of the session.
  ///
  /// The fix keeps the barrier exactly as it is — a passive checkpoint would recycle WAL frames
  /// without ever shrinking the `-wal` file, quietly retiring the 16 MiB bound in the very case it
  /// exists for — and changes only who waits for it: nobody. `.workspaceClose` maintenance keeps its
  /// chained shape; only the hot path moved.
  ///
  /// The pass is parked at `maintenanceGateOverride`, which sits after every early return and
  /// immediately before the detached vacuum + truncate. That pins the CONTRACT — "a write submitted
  /// behind reader-blocked hygiene still completes" — rather than a race against a real reader, which
  /// would be an assertion about the scheduler.
  func testHotPathMaintenanceCannotStallTheIndexWritesSubmittedBehindIt() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    churn(database: database, root: root, count: 300, deleting: 0)
    let walBefore = walSize(for: databaseURL)
    XCTAssertGreaterThan(
      walBefore, 0, "fixture precondition: the WAL must be non-empty, or maintenance never triggers")
    database.walCheckpointThresholdBytesOverride = Int64(walBefore)

    // Parked exactly where the reader-excluding barrier would be: this is the wedged reader, without
    // the race a real one would bring.
    let gate = ParkingGate()
    database.maintenanceGateOverride = { await gate.arrive() }

    let armingRef = documentRef(root: root, name: "arms-maintenance.md")
    let firstWriteFinished = CompletionFlag()
    database.scheduleIndexWrite {
      await database.indexInBackground(
        document: armingRef, body: "hotpathfirstneedle", appState: nil)
      firstWriteFinished.isSet = true
    }
    try await waitUntil("the batch maintenance pass to reach its barrier") {
      await gate.arrivals >= 1
    }
    XCTAssertTrue(
      firstWriteFinished.isSet,
      "fixture precondition: the write that ARMED the maintenance must already have completed — "
        + "awaiting the barrier inside that write task is the defect under test")

    // Submitted while the hygiene barrier is demonstrably held.
    let behindRef = documentRef(root: root, name: "behind-maintenance.md")
    let secondWriteFinished = CompletionFlag()
    database.scheduleIndexWrite {
      await database.indexInBackground(
        document: behindRef, body: "hotpathsecondneedle", appState: nil)
      secondWriteFinished.isSet = true
    }
    try await waitUntil("the index write submitted behind the parked maintenance to complete") {
      secondWriteFinished.isSet
    }
    let arrivalsWhileParked = await gate.arrivals
    XCTAssertEqual(
      arrivalsWhileParked, 1,
      "fixture precondition: the maintenance pass must still be held — and the second write must not "
        + "have piled another blocked barrier behind it, which is what the coalescing is for")
    XCTAssertEqual(
      try indexHits(matching: "hotpathsecondneedle", at: databaseURL), 1,
      "a write submitted behind reader-blocked storage hygiene must still land: one slow search "
        + "must never be able to stop every index update for the rest of the session")

    // …and the hygiene pass is still the termination drain's business. Started while the pass is
    // held, the drain must NOT return until it is released — that is what keeps the quit guarantees
    // untouched by moving the work out of the supersede tail.
    let drainFinished = CompletionFlag()
    Task { @MainActor in
      await database.drainPendingIndexWrites()
      drainFinished.isSet = true
    }
    try await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertFalse(
      drainFinished.isSet,
      "the drain must still COVER the hot-path maintenance: `scheduleIndexWrite` registers it, so a "
        + "quit cannot latch and checkpoint while a vacuum + truncate is still in flight")

    await gate.open()
    try await waitUntil("the drain to complete once the maintenance barrier is released") {
      drainFinished.isSet
    }
    XCTAssertLessThanOrEqual(
      walSize(for: databaseURL), 64 * 1024,
      "…and the truncate the drain waited for must actually have landed (was \(walBefore) bytes, "
        + "now \(walSize(for: databaseURL)))")
  }

  // MARK: - R12: hot-path hygiene takes no reader-excluding lock at all

  /// Round 12 — the POOL-LEVEL half of round 11's finding 3. Round 11 moved WHO WAITS for the
  /// `.indexBatch` pass out of the supersede tail; the pass itself still took
  /// `barrierWriteWithoutTransaction` and still waited a reader out. Its pin parks at
  /// `maintenanceGateOverride`, which sits BEFORE that barrier is entered, so nothing in this suite
  /// exercised the pool lock. This does, with a genuine wedged reader and no seam standing in for it.
  ///
  /// The mechanism is NOT the one the review claimed, and the difference decides what this pin
  /// asserts. Measured against GRDB 6.29.3 (round-12 probe, verbatim in `R12_report.md`):
  /// `barrierWriteWithoutTransaction` is `readerPool.barrier { writer.sync }`, so the serialized
  /// writer is taken only AFTER the readers have drained. A `pool.write` submitted while the barrier
  /// is pending therefore COMPLETES — saves, watcher deltas and reindexes are not frozen by it. A
  /// `pool.read` submitted while the barrier is pending BLOCKS: reader checkout goes through the very
  /// queue the barrier holds. So the damage a hot-path barrier does is to every LATER READ — search,
  /// backlinks, counts — for as long as one slow reader keeps the barrier waiting.
  ///
  /// Hence the discriminator here is the SEARCH submitted while the hygiene pass runs (step 4). The
  /// write in step 5 is corroboration only: it passes with the barrier restored too, and saying
  /// otherwise would be repeating the claim instead of pinning it.
  ///
  /// The other half is that the truncate cannot simply be abandoned: the 16 MiB bound is a size
  /// bound, and a plain-write TRUNCATE checkpoint does not silently no-op (the pre-round-12 comment
  /// in `performMaintenanceInBackground` said it would) — with a reader on an older snapshot SQLite
  /// answers `SQLITE_BUSY` in ~0.2 ms and leaves the `-wal` alone. So the pass defers and re-arms,
  /// and step 6 pins that the deferred truncate lands once the reader lets go WITHOUT any further
  /// index write arriving to carry it.
  func testHotPathMaintenanceNeitherWaitsForAReaderNorBlocksTheReadsBehindIt() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    // The wedge holds one of GRDB's reader connections on a real `pool.read`. The valve is far above
    // every wait below, so a build that reintroduces the barrier FAILS the assertions instead of
    // being rescued by the release.
    let wedge = WedgeSignal()
    let released = DispatchSemaphore(value: 0)
    defer { released.signal() }
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.poolWedgeReleaseSeconds) {
      released.signal()
    }

    let appState = AppState()
    let database = IndexDatabase(
      databaseURL: databaseURL,
      didOpenBacklinkRead: {
        wedge.markReached()
        released.wait()
      })
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    churn(database: database, root: root, count: 300, deleting: 0)
    let walBefore = walSize(for: databaseURL)
    XCTAssertGreaterThan(
      walBefore, 0, "fixture precondition: the WAL must be non-empty, or maintenance never triggers")
    database.walCheckpointThresholdBytesOverride = Int64(walBefore)
    // Milliseconds instead of the production second: this pin waits for the re-arm, and a real-second
    // ladder in a test is a wall-clock flake waiting to happen.
    database.indexBatchTruncationRetryDelayNanosecondsOverride = 25_000_000

    // 1 — wedge a genuine pool reader, inside `fetchBacklinkRecords`' own `pool.read`.
    let documents = (0..<3).map { documentRef(root: root, name: "churn-\($0).md") }
    let backlinksFinished = CompletionFlag()
    Task { @MainActor in
      _ = await database.backlinksInBackground(to: documents[0], documents: documents)
      backlinksFinished.isSet = true
    }
    try await waitUntil("the backlink query to be holding one of the pool's readers") {
      wedge.isReached
    }

    // 2 — arm the hot path. This write also moves the WAL forward BEHIND the wedged reader, which is
    // what makes its snapshot an older one: that is the case where SQLite refuses the truncate rather
    // than quietly succeeding, so the deferral below is a real refusal and not a fixture artefact.
    let armingRef = documentRef(root: root, name: "arms-maintenance.md")
    let armingWriteFinished = CompletionFlag()
    database.scheduleIndexWrite {
      await database.indexInBackground(
        document: armingRef, body: "poolwedgearmneedle", appState: nil)
      armingWriteFinished.isSet = true
    }
    try await waitUntil("the write that arms the hygiene pass to complete", timeout: 5) {
      armingWriteFinished.isSet
    }

    // 3 — the pass must GIVE UP on the truncate and re-arm it, rather than wait the reader out. With
    // the barrier restored this wait is what times out: the pass never comes back at all.
    try await waitUntil(
      "the hot-path hygiene pass to refuse the truncate and re-arm it", timeout: 5
    ) {
      database.indexBatchTruncationDeferrals >= 1
    }
    XCTAssertGreaterThanOrEqual(
      walSize(for: databaseURL), walBefore,
      "a WAL truncated while the reader still holds its snapshot would mean the pass either waited "
        + "for the reader or reported success it did not achieve")

    // 4 — THE DISCRIMINATOR: a search submitted while the reader is still wedged. Reader checkout is
    // what a pending barrier blocks, so this is the read the old shape froze for the whole session.
    let searchFinished = CompletionFlag()
    let searchHits = SearchHitCount()
    Task { @MainActor in
      let results = await database.searchInBackground(
        query: "poolwedgearmneedle", documents: [armingRef])
      searchHits.value = results.count
      searchFinished.isSet = true
    }
    try await waitUntil(
      "the search submitted behind the hot-path hygiene pass to complete", timeout: 5
    ) {
      searchFinished.isSet
    }
    XCTAssertTrue(
      wedge.isReached,
      "fixture precondition: the wedged reader must still be holding its connection — the search "
        + "must have gone through the pool WHILE the hygiene pass was subject to it")
    XCTAssertGreaterThan(
      searchHits.value, 0,
      "the search must actually have reached the index (and seen the arming write), not returned an "
        + "empty list from a refused open")

    // 5 — corroboration, not the discriminator: an index write submitted behind the pass lands too.
    let behindRef = documentRef(root: root, name: "behind-maintenance.md")
    let behindWriteFinished = CompletionFlag()
    database.scheduleIndexWrite {
      await database.indexInBackground(
        document: behindRef, body: "poolwedgebehindneedle", appState: nil)
      behindWriteFinished.isSet = true
    }
    try await waitUntil("the index write submitted behind the hygiene pass to complete", timeout: 5) {
      behindWriteFinished.isSet
    }
    XCTAssertEqual(
      try indexHits(matching: "poolwedgebehindneedle", at: databaseURL), 1,
      "the write submitted behind reader-blocked storage hygiene must land on disk")

    // 6 — release the reader and submit NOTHING further: the deferred truncate has to come back on
    // its own and enforce the bound. Without the re-arm the WAL would keep its high-water mark until
    // an unrelated lifecycle event, which is how the 16 MiB bound gets retired by accident.
    released.signal()
    try await waitUntil(
      "the deferred truncate to re-arm itself and hand the WAL back once the reader let go",
      timeout: 10
    ) {
      walSize(for: databaseURL) <= 64 * 1024
    }
    try await waitUntil("the wedged backlink query to finish") { backlinksFinished.isSet }
  }

  // MARK: - R13: a coalesced maintenance request must re-arm, never be dropped

  /// Round 13 — the last hole in round 11's coalescing guard. `scheduleIndexBatchMaintenance()`
  /// returned as soon as it saw a pass already armed, which is sound only while that pass still
  /// covers the requester's frames. It stops covering them the moment it has checkpointed: an index
  /// write that commits after the truncate but before the pass's task clears
  /// `pendingIndexBatchMaintenance` adds WAL frames no pass has ever seen, and its request was
  /// dropped on the floor. The log then stayed over the 16 MiB bound with NOTHING owed — until the
  /// next index write or a close/quit happened to come along, which under an idle editor is minutes
  /// or never. Disk space rather than durability, same family as the bound itself.
  ///
  /// The pass is parked at `maintenanceCompletionGateOverride`, which sits after
  /// `performMaintenanceInBackground` returned — so after the truncate, with the pool writer already
  /// released — and immediately before the handle is cleared. That is the window verbatim, reached
  /// synchronously instead of raced: parking BEFORE the truncate (`maintenanceGateOverride`, rounds
  /// 11–12) reaches a state where coalescing is still correct, and would pin nothing.
  ///
  /// The discriminator is step 3: after the release NOTHING further is submitted — no index write, no
  /// workspace close, no quit — so the WAL can only come back under the bound if the coalesced
  /// request armed its own successor.
  func testAMaintenanceRequestCoalescedIntoACheckpointedPassRearmsItsOwnSuccessor() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    churn(database: database, root: root, count: 300, deleting: 0)
    XCTAssertGreaterThan(
      walSize(for: databaseURL), Self.coalescedRearmWalBoundBytes,
      "fixture precondition: the WAL must start over the (lowered) bound, or the arming write never "
        + "puts a pass in flight at all")
    database.walCheckpointThresholdBytesOverride = Self.coalescedRearmWalBoundBytes

    // Parked with the pass's work DONE and its coalescing handle still installed.
    let completionGate = ParkingGate()
    database.maintenanceCompletionGateOverride = { await completionGate.arrive() }

    // 1 — arm the hot path through the ordinary save tail, then let the pass do its work and park.
    let armingDidWrite = await database.indexInBackground(
      document: documentRef(root: root, name: "arms-maintenance.md"),
      body: "coalescedrearmarmneedle",
      appState: appState
    )
    XCTAssertTrue(armingDidWrite)
    try await waitUntil("the hygiene pass to reach the handle-clearing gate", timeout: 5) {
      await completionGate.arrivals >= 1
    }
    XCTAssertLessThanOrEqual(
      walSize(for: databaseURL), Self.coalescedRearmWalBoundBytes,
      "fixture precondition: the parked pass must ALREADY have checkpointed — while it has not, "
        + "coalescing a later write into it is correct, and that is not the window under test")

    // 2 — a save commits NOW: after that checkpoint, before the handle clears. Its own maintenance
    //     request is the one the guard swallows.
    let racingDidWrite = await database.indexInBackground(
      document: documentRef(root: root, name: "races-the-handle.md"),
      body: Self.walGrowingBody(needle: "coalescedrearmracingneedle"),
      appState: appState
    )
    XCTAssertTrue(racingDidWrite)
    XCTAssertGreaterThan(
      walSize(for: databaseURL), Self.coalescedRearmWalBoundBytes,
      "fixture precondition: the racing save must have pushed the WAL back OVER the bound, or a "
        + "successor pass would have nothing to enforce")
    let arrivalsAfterTheRacingSave = await completionGate.arrivals
    XCTAssertEqual(
      arrivalsAfterTheRacingSave, 1,
      "fixture precondition: that save's request must have been COALESCED into the parked pass "
        + "rather than arming a second one — the coalescing is what this pin is about")

    // 3 — release the pass and submit NOTHING else. No write, no close, no quit.
    await completionGate.open()
    try await waitUntil(
      "the coalesced maintenance request to re-arm a successor pass and hand the WAL back under the "
        + "bound", timeout: 10
    ) {
      walSize(for: databaseURL) <= Self.coalescedRearmWalBoundBytes
    }
    XCTAssertEqual(
      database.indexBatchTruncationDeferrals, 0,
      "no reader was ever wedged here, so the successor must have TRUNCATED rather than deferred — "
        + "otherwise this pin would be passing on the round-12 ladder instead of the re-arm")
    XCTAssertEqual(
      try indexHits(matching: "coalescedrearmracingneedle", at: databaseURL), 1,
      "…and the bound must have been enforced by checkpointing the racing save's frames into the "
        + "database, not by losing them")
  }

  /// The other half of round 13, and the trap in it: the prompt re-arm must not fight round 12's
  /// backoff ladder. A pass the wedged reader REFUSED has already armed a successor through
  /// `deferIndexBatchTruncation()` (1 s → ×2 → cap 30 s), and that successor comes back through
  /// `scheduleIndexBatchMaintenance()`, so it re-stats the WAL and covers the coalesced request's
  /// frames as well — absorbed, not lost. Re-arming promptly ON TOP of that would put a pass in
  /// flight immediately after a refusal, which the same reader refuses again in ~0.2 ms: once per
  /// index write, for as long as the wedge lasts. The ladder exists precisely so a reader that never
  /// lets go cannot be polled.
  ///
  /// So this pins the composition from both sides: no extra pass while the ladder owes one (step 4),
  /// and the coalesced request still enforced once the reader lets go, with nothing further
  /// submitted (step 5).
  func testACoalescedRequestDuringARefusedTruncateStaysOnTheBackoffLadder() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    // Same wedge shape as the round-12 pool pin: a genuine `pool.read` held open, with the release
    // valve far above every wait below so a wrong build fails an assertion instead of being rescued.
    let wedge = WedgeSignal()
    let released = DispatchSemaphore(value: 0)
    defer { released.signal() }
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.poolWedgeReleaseSeconds) {
      released.signal()
    }

    let appState = AppState()
    let database = IndexDatabase(
      databaseURL: databaseURL,
      didOpenBacklinkRead: {
        wedge.markReached()
        released.wait()
      })
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    churn(database: database, root: root, count: 300, deleting: 0)
    XCTAssertGreaterThan(
      walSize(for: databaseURL), Self.coalescedRearmWalBoundBytes,
      "fixture precondition: the WAL must start over the (lowered) bound")
    database.walCheckpointThresholdBytesOverride = Self.coalescedRearmWalBoundBytes
    // Long next to the quiet window in step 4 and short next to its own wait in step 5, so the
    // ladder's successor cannot fire early enough to be mistaken for a prompt re-arm.
    database.indexBatchTruncationRetryDelayNanosecondsOverride = Self.ladderRetryDelayNanoseconds

    let completionGate = ParkingGate()
    database.maintenanceCompletionGateOverride = { await completionGate.arrive() }

    // 1 — wedge a genuine pool reader inside `fetchBacklinkRecords`' own `pool.read`.
    let documents = (0..<3).map { documentRef(root: root, name: "churn-\($0).md") }
    let backlinksFinished = CompletionFlag()
    Task { @MainActor in
      _ = await database.backlinksInBackground(to: documents[0], documents: documents)
      backlinksFinished.isSet = true
    }
    try await waitUntil("the backlink query to be holding one of the pool's readers") {
      wedge.isReached
    }

    // 2 — arm the hot path. The reader holds an older snapshot, so the truncate is REFUSED, the pass
    //     defers onto the ladder, and only then parks with its handle still installed.
    let armingDidWrite = await database.indexInBackground(
      document: documentRef(root: root, name: "arms-maintenance.md"),
      body: "ladderarmneedle",
      appState: appState
    )
    XCTAssertTrue(armingDidWrite)
    try await waitUntil("the refused pass to reach the handle-clearing gate", timeout: 5) {
      await completionGate.arrivals >= 1
    }
    XCTAssertEqual(
      database.indexBatchTruncationDeferrals, 1,
      "fixture precondition: the parked pass must have been REFUSED by the wedged reader — a pass "
        + "that truncated would put the ladder out of the picture entirely")

    // 3 — a save commits while the refused pass still holds the handle, so its request coalesces.
    let racingDidWrite = await database.indexInBackground(
      document: documentRef(root: root, name: "races-the-handle.md"),
      body: Self.walGrowingBody(needle: "ladderracingneedle"),
      appState: appState
    )
    XCTAssertTrue(racingDidWrite)
    let arrivalsAfterTheRacingSave = await completionGate.arrivals
    XCTAssertEqual(
      arrivalsAfterTheRacingSave, 1,
      "fixture precondition: that save's request must have been coalesced, not armed as a second "
        + "pass")

    // 4 — release the pass. The coalesced request must NOT put a successor in flight now: the reader
    //     is still wedged, so it would be refused within a millisecond and the ladder would be
    //     bypassed once per write for the whole wedge.
    await completionGate.open()
    try await Task.sleep(nanoseconds: Self.ladderQuietWindowNanoseconds)
    XCTAssertTrue(
      wedge.isReached,
      "fixture precondition: the wedged reader must still be holding its connection through the "
        + "quiet window")
    XCTAssertEqual(
      database.indexBatchTruncationDeferrals, 1,
      "a coalesced request must be absorbed by the ladder that already owes a successor, not "
        + "re-armed on top of it: a second refusal here is the ~0.2 ms busy-poll round 12's backoff "
        + "exists to prevent")

    // 5 — and it is ABSORBED rather than lost: once the reader lets go, the ladder's own successor
    //     re-stats the WAL and covers the racing save's frames too, with nothing further submitted.
    released.signal()
    try await waitUntil(
      "the ladder's successor to enforce the bound over the coalesced request's frames", timeout: 20
    ) {
      walSize(for: databaseURL) <= Self.coalescedRearmWalBoundBytes
    }
    XCTAssertEqual(
      try indexHits(matching: "ladderracingneedle", at: databaseURL), 1,
      "…and it must have enforced the bound by checkpointing those frames, not by losing them")
    try await waitUntil("the wedged backlink query to finish") { backlinksFinished.isSet }
  }

  // MARK: - R14: an armed backoff ladder must absorb incoming maintenance requests

  /// Round 14 — the ARMING-side twin of the trap round 13 closed on the re-arm side. Round 12's
  /// ladder owns a successor after a reader refuses a truncate, but `scheduleIndexBatchMaintenance()`
  /// only consulted the latch and the coalescing handle. Once the refused pass had cleared that
  /// handle, the ladder was armed and nothing was in flight — so the next save or watcher delta walked
  /// straight past both guards and armed a fresh pass: a 4096-page `incremental_vacuum` plus a
  /// checkpoint the same wedged reader refuses ~0.2 ms later. Once per index write, for as long as the
  /// wedge lasts, which is the 1 s → 30 s backoff defeated from the outside — the ladder existed
  /// precisely so a reader that never lets go cannot be polled.
  ///
  /// The contract is ABSORPTION, not refusal: the ladder's successor re-enters through the same single
  /// entry point, re-stats the WAL and therefore covers the newer write's frames as well. So the pin
  /// asserts both halves — no second attempt while the wedge holds (step 4), and the newer write's
  /// frames still checkpointed once the reader lets go, with nothing further submitted (step 5).
  ///
  /// `indexBatchTruncationDeferrals` is the discriminator, and it is exact here: while the reader is
  /// wedged, any pass that gets armed MUST end in a refusal, so an extra attempt cannot hide. The
  /// proof that the fixture reaches the arming-side window rather than round 13's coalescing window is
  /// the mutation: removing the new guard turns step 4 into `2`, which is only reachable past the
  /// coalescing guard.
  func testAnArmedTruncationRetryAbsorbsAHotPathMaintenanceRequest() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    // Same wedge shape as the round-12/13 pool pins: a genuine `pool.read` held open, with the release
    // valve far above every wait below so a wrong build fails an assertion instead of being rescued.
    let wedge = WedgeSignal()
    let released = DispatchSemaphore(value: 0)
    defer { released.signal() }
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.poolWedgeReleaseSeconds) {
      released.signal()
    }

    let appState = AppState()
    let database = IndexDatabase(
      databaseURL: databaseURL,
      didOpenBacklinkRead: {
        wedge.markReached()
        released.wait()
      })
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    churn(database: database, root: root, count: 300, deleting: 0)
    XCTAssertGreaterThan(
      walSize(for: databaseURL), Self.coalescedRearmWalBoundBytes,
      "fixture precondition: the WAL must start over the (lowered) bound")
    database.walCheckpointThresholdBytesOverride = Self.coalescedRearmWalBoundBytes
    // Long next to the quiet windows below, so a pass appearing there can only have been armed by the
    // hot path, never by the ladder firing early.
    database.indexBatchTruncationRetryDelayNanosecondsOverride = Self.ladderRetryDelayNanoseconds

    // 1 — wedge a genuine pool reader inside `fetchBacklinkRecords`' own `pool.read`.
    let documents = (0..<3).map { documentRef(root: root, name: "churn-\($0).md") }
    let backlinksFinished = CompletionFlag()
    Task { @MainActor in
      _ = await database.backlinksInBackground(to: documents[0], documents: documents)
      backlinksFinished.isSet = true
    }
    try await waitUntil("the backlink query to be holding one of the pool's readers") {
      wedge.isReached
    }

    // 2 — arm the hot path. The reader holds an older snapshot, so the truncate is REFUSED and the
    //     ladder takes ownership of the successor.
    let armingDidWrite = await database.indexInBackground(
      document: documentRef(root: root, name: "arms-maintenance.md"),
      body: "armingsidearmneedle",
      appState: appState
    )
    XCTAssertTrue(armingDidWrite)
    try await waitUntil("the refused pass to defer onto the backoff ladder", timeout: 5) {
      database.indexBatchTruncationDeferrals == 1
    }
    // Let that pass's task finish clearing its coalescing handle. Without this the write below would
    // meet round 13's coalescing guard, which is a different window and already pinned.
    try await Task.sleep(nanoseconds: Self.ladderQuietWindowNanoseconds)

    // 3 — a real save lands while the ladder owes a successor. This is the hot-path request that used
    //     to arm a pass of its own.
    let laterDidWrite = await database.indexInBackground(
      document: documentRef(root: root, name: "lands-while-armed.md"),
      body: Self.walGrowingBody(needle: "armingsidelaterneedle"),
      appState: appState
    )
    XCTAssertTrue(laterDidWrite)
    XCTAssertGreaterThan(
      walSize(for: databaseURL), Self.coalescedRearmWalBoundBytes,
      "fixture precondition: that save must leave the WAL OVER the bound, or a pass armed by it would "
        + "return early at the threshold check and the absorption would be untestable")

    // 4 — nothing new may be armed: the reader is still wedged, so a pass here is the busy-poll the
    //     backoff exists to prevent.
    try await Task.sleep(nanoseconds: Self.ladderQuietWindowNanoseconds)
    XCTAssertTrue(
      wedge.isReached,
      "fixture precondition: the wedged reader must still be holding its connection through the "
        + "quiet window")
    XCTAssertEqual(
      database.indexBatchTruncationDeferrals, 1,
      "an incoming request must be ABSORBED by the armed ladder rather than arming a pass of its "
        + "own: a second refusal here is round 12's backoff bypassed from the arming side, once per "
        + "index write for the whole wedge")

    // 5 — absorbed, not dropped: once the reader lets go, the ladder's successor alone re-stats the
    //     WAL and covers the newer save's frames, with nothing further submitted.
    released.signal()
    try await waitUntil(
      "the ladder's successor to enforce the bound over the absorbed request's frames", timeout: 20
    ) {
      walSize(for: databaseURL) <= Self.coalescedRearmWalBoundBytes
    }
    XCTAssertEqual(
      try indexHits(matching: "armingsidelaterneedle", at: databaseURL), 1,
      "…and it must have enforced the bound by checkpointing those frames, not by losing them")
    try await waitUntil("the wedged backlink query to finish") { backlinksFinished.isSet }
  }

  /// The trap the guard above creates, pinned so it cannot be reintroduced: the ladder must not
  /// absorb its OWN retry. That retry re-enters through `scheduleIndexBatchMaintenance()` — which is
  /// deliberate, it is how the latch, the coalescing and the 16 MiB threshold get re-checked — so if
  /// it re-entered while `pendingIndexBatchTruncationRetry` still pointed at itself, the new guard
  /// would swallow it and hot-path hygiene would never run again for the life of the process. A
  /// self-deadlock, and one that no other pin would notice: every other path would look healthy.
  ///
  /// `deferIndexBatchTruncation()` clears the handle BEFORE re-entering, which is what makes this
  /// safe. The pin drives exactly that path — a retry firing after the reader let go — and asserts
  /// the pass actually ran and truncated. Nothing else is submitted after the arming save, so the
  /// ladder's own retry is the only thing that can enforce the bound.
  func testTheArmedTruncationRetryIsNotAbsorbedByItsOwnHandle() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    let wedge = WedgeSignal()
    let released = DispatchSemaphore(value: 0)
    defer { released.signal() }
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.poolWedgeReleaseSeconds) {
      released.signal()
    }

    let appState = AppState()
    let database = IndexDatabase(
      databaseURL: databaseURL,
      didOpenBacklinkRead: {
        wedge.markReached()
        released.wait()
      })
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    churn(database: database, root: root, count: 300, deleting: 0)
    XCTAssertGreaterThan(
      walSize(for: databaseURL), Self.coalescedRearmWalBoundBytes,
      "fixture precondition: the WAL must start over the (lowered) bound")
    database.walCheckpointThresholdBytesOverride = Self.coalescedRearmWalBoundBytes
    database.indexBatchTruncationRetryDelayNanosecondsOverride =
      Self.selfAbsorptionLadderDelayNanoseconds

    // 1 — wedge a genuine pool reader, so the first pass is refused and the ladder arms.
    let documents = (0..<3).map { documentRef(root: root, name: "churn-\($0).md") }
    let backlinksFinished = CompletionFlag()
    Task { @MainActor in
      _ = await database.backlinksInBackground(to: documents[0], documents: documents)
      backlinksFinished.isSet = true
    }
    try await waitUntil("the backlink query to be holding one of the pool's readers") {
      wedge.isReached
    }

    // 2 — the one and only hot-path write in this pin.
    let armingDidWrite = await database.indexInBackground(
      document: documentRef(root: root, name: "arms-maintenance.md"),
      body: Self.walGrowingBody(needle: "selfabsorptionarmneedle"),
      appState: appState
    )
    XCTAssertTrue(armingDidWrite)
    try await waitUntil("the refused pass to defer onto the backoff ladder", timeout: 5) {
      database.indexBatchTruncationDeferrals == 1
    }

    // 3 — let the reader go while the retry is still sleeping, then submit NOTHING else. Only the
    //     ladder's own re-entry can bring the WAL back under the bound now.
    released.signal()
    try await waitUntil(
      "the ladder's own retry to re-enter, run a pass and truncate the WAL", timeout: 20
    ) {
      walSize(for: databaseURL) <= Self.coalescedRearmWalBoundBytes
    }
    XCTAssertEqual(
      database.indexBatchTruncationDeferrals, 1,
      "the retry must have fired AFTER the release and truncated on its first attempt — a second "
        + "deferral would mean this pin proved a later rung of the ladder rather than the re-entry "
        + "under test")
    XCTAssertEqual(
      try indexHits(matching: "selfabsorptionarmneedle", at: databaseURL), 1,
      "…and the bound must have been enforced by checkpointing the arming save's frames into the "
        + "database, not by losing them")
    try await waitUntil("the wedged backlink query to finish") { backlinksFinished.isSet }
  }

  /// Ordinary `Close Folder` used to compact against whatever the index happened to have finished.
  /// `closeWorkspace` cancels `FolderManager`'s `indexUpdateTask` — which by its own contract
  /// abandons only the WAIT, never the write underneath, that one belongs to `IndexDatabase`'s
  /// supersede chain — and then armed the housekeeping with nothing to await. A write still queued
  /// behind a predecessor therefore landed AFTER the TRUNCATE, and its frames stayed on disk: the
  /// workspace is gone, so no later close is coming to notice them.
  ///
  /// Sibling `testCloseWorkspaceDefersMaintenanceOnlyWhenTheCallerOwnsAFinalIndexWrite` covers the
  /// last-root special case. This is the general one, and it is deterministic where the older
  /// last-root pin is not: the first write is BLOCKED at an injection seam so a second write is
  /// genuinely still queued when the close runs. That matters because GRDB's
  /// `barrierWriteWithoutTransaction` usually queues behind an already submitted `pool.write`, which
  /// is exactly how the unordered version passes a settle-first test by accident.
  ///
  /// The ordering is asserted directly — the housekeeping must NOT be able to complete while the
  /// queue is still parked — and then corroborated by the after-effects: both queued documents are
  /// in the index and the WAL is back at zero, which can only be true if the truncate went last.
  func testCloseWorkspaceMaintenanceWaitsForTheWholePendingIndexChain() async throws {
    let sandbox = try makeWorkspaceSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let body = String(repeating: "pensieve pending chain payload ", count: 600)
    for index in 0..<60 {
      try "\(body) \(index)".write(
        to: root.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
    }

    let harness = try makeWorkspaceHarness(in: sandbox.support)
    let appState = AppState()
    harness.manager.open(url: root, into: appState)
    await settle(harness)

    let databaseURL = sandbox.support.appendingPathComponent("index.db", isDirectory: false)
    XCTAssertGreaterThan(
      walSize(for: databaseURL), 64 * 1024,
      "fixture precondition: indexing the workspace must leave a WAL worth truncating")

    // Deliberately OUTSIDE the workspace root: nothing but the two queued writes below can put
    // these documents in the index, so finding them afterwards proves those writes committed.
    let outside = sandbox.root.appendingPathComponent("Outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let firstRef = documentRef(root: outside, name: "queued-first.md")
    let secondRef = documentRef(root: outside, name: "queued-second.md")
    try "\(body) firstqueuedmarker".write(to: firstRef.url, atomically: true, encoding: .utf8)
    try "\(body) secondqueuedmarker".write(to: secondRef.url, atomically: true, encoding: .utf8)

    let gate = FirstWriteGate()
    let indexDatabase = harness.indexDatabase
    indexDatabase.backgroundWriteGateOverride = { await gate.arrive() }

    // Write #1 parks at the gate holding the chain open; write #2 passes the gate and queues behind
    // #1. Each is only submitted once the previous one has ARRIVED, because arrival happens after
    // the write took its place in the supersede chain — that is what makes the queue real.
    Task {
      await indexDatabase.updateSearchIndexInBackground(
        upserting: [firstRef], deletingPaths: [], appState: nil)
    }
    try await waitUntil("the first index write to park at the gate") { await gate.arrivals >= 1 }
    Task {
      await indexDatabase.updateSearchIndexInBackground(
        upserting: [secondRef], deletingPaths: [], appState: nil)
    }
    try await waitUntil("the second index write to queue behind it") { await gate.arrivals >= 2 }

    harness.manager.closeWorkspace(into: appState)

    let maintenanceFinished = CompletionFlag()
    let maintenance = Task { @MainActor in
      await harness.manager.waitForPendingIndexMaintenance()
      maintenanceFinished.isSet = true
    }
    // The ordering assertion. A close that waits for the chain CANNOT finish its housekeeping while
    // both writes are still parked; the unordered version truncates within milliseconds.
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertFalse(
      maintenanceFinished.isSet,
      "close-time maintenance completed while two index writes were still queued — the truncate "
        + "would land before their frames")

    await gate.open()
    await maintenance.value
    // Sampled before any assertion touches the pool, so the reading is the state maintenance left.
    let walAfterMaintenance = walSize(for: databaseURL)

    XCTAssertFalse(
      indexDatabase.search(query: "firstqueuedmarker", documents: [firstRef], appState: nil)
        .isEmpty,
      "the first queued write must have committed before maintenance finished")
    XCTAssertFalse(
      indexDatabase.search(query: "secondqueuedmarker", documents: [secondRef], appState: nil)
        .isEmpty,
      "the second queued write must have committed before maintenance finished")
    XCTAssertLessThanOrEqual(
      walAfterMaintenance, 64 * 1024,
      "the truncating checkpoint must run AFTER the whole queue drains, otherwise the queued writes' "
        + "WAL frames survive the workspace that would have checkpointed them (WAL is "
        + "\(walAfterMaintenance) bytes)")
  }

  /// The drain has to see EVERY writer, and the workspace-metadata writer was invisible to it.
  /// `commitWorkspaceManifest` handed its `upsertWorkspace` / scan-session / stats writes to a bare
  /// detached task held as `workspaceIndexWriteTask` — represented by neither `scheduledIndexWrites`
  /// nor `pendingIndexUpdateTask`. Close Folder cancels that handle, but cancelling abandons the WAIT,
  /// not the record build underneath: the drain returned, maintenance truncated the WAL, and the
  /// manifest writes then landed and recreated the frames the checkpoint had just reclaimed.
  ///
  /// A FORCED refresh is the trigger on purpose. It re-commits the manifest while provably writing no
  /// search index at all — `applyRefresh` authorizes presentation and FTS from two independent
  /// signatures, and the search signature is derived from the `.md` documents, none of which change
  /// here. So the only thing that can be parked at the gate below is a manifest write, which is what
  /// makes the "maintenance has not finished" assertion mean what it says.
  func testCloseWorkspaceMaintenanceWaitsForTheWorkspaceManifestWrite() async throws {
    let sandbox = try makeWorkspaceSandbox()
    let root = sandbox.root.appendingPathComponent("Root", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let body = String(repeating: "pensieve manifest drain payload ", count: 600)
    for index in 0..<40 {
      try "\(body) \(index)".write(
        to: root.appendingPathComponent("note-\(index).md"), atomically: true, encoding: .utf8)
    }

    let harness = try makeWorkspaceHarness(in: sandbox.support)
    let appState = AppState()
    harness.manager.open(url: root, into: appState)
    await settle(harness)

    let databaseURL = sandbox.support.appendingPathComponent("index.db", isDirectory: false)
    let scanSessionsAfterOpen = try rowCount("scan_sessions", at: databaseURL)
    XCTAssertGreaterThan(
      scanSessionsAfterOpen, 0,
      "fixture precondition: the cold open must have committed a manifest of its own")

    // Parks EVERY arrival, unlike `FirstWriteGate`: the point here is to hold the manifest write
    // itself, and a watcher-driven refresh may legitimately queue a second one behind it.
    let gate = ParkingGate()
    let indexDatabase = harness.indexDatabase
    indexDatabase.backgroundWriteGateOverride = { await gate.arrive() }

    harness.manager.refresh(into: appState, force: true)
    try await waitUntil("the workspace manifest write to park at the gate") {
      await gate.arrivals >= 1
    }
    XCTAssertEqual(
      try rowCount("scan_sessions", at: databaseURL), scanSessionsAfterOpen,
      "fixture precondition: the refresh's manifest write must still be parked, not committed")

    harness.manager.closeWorkspace(into: appState)

    let maintenanceFinished = CompletionFlag()
    let maintenance = Task { @MainActor in
      await harness.manager.waitForPendingIndexMaintenance()
      maintenanceFinished.isSet = true
    }
    // The ordering assertion. With the manifest write invisible to the drain, the close finds
    // nothing owed and checkpoints within milliseconds — while the writes are still coming.
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertFalse(
      maintenanceFinished.isSet,
      "close-time maintenance completed while the workspace manifest write was still queued — the "
        + "truncate would land before its frames")

    await gate.open()
    await maintenance.value
    // Sampled before any assertion touches the pool, so the reading is the state maintenance left.
    let walAfterMaintenance = walSize(for: databaseURL)

    XCTAssertGreaterThan(
      try rowCount("scan_sessions", at: databaseURL), scanSessionsAfterOpen,
      "the manifest write must have committed before maintenance finished")
    XCTAssertLessThanOrEqual(
      walAfterMaintenance, 64 * 1024,
      "the truncating checkpoint must run AFTER the manifest write drains, otherwise its frames "
        + "survive the workspace that would have checkpointed them (WAL is \(walAfterMaintenance) "
        + "bytes)")
  }

  // MARK: - Production wiring: quit flushes windows and drains the index before it checkpoints

  /// Quit used to checkpoint the index and only THEN let the windows tear down. That is backwards:
  /// `applicationWillTerminate` fires BEFORE `NSWindow.willCloseNotification`, so a dirty window's
  /// final save ran after the truncate — and the save's index write is a background hand-off, so it
  /// landed after that again, if the process lived long enough to run it at all. On a Dock quit or a
  /// logout the last edit's FTS row was simply lost.
  ///
  /// This drives the REAL delegate entry point, not a helper, and asserts the whole contract in one
  /// go: the file on disk carries the edit (the sequence flushed the window itself), the index
  /// carries it (the write was drained), and the WAL is empty (the checkpoint went last). The final
  /// write is deliberately tiny, so it is BELOW the 16 MiB batch threshold and cannot have
  /// checkpointed itself — see `testSingleDocumentSaveIsThrottledBelowTheWalThreshold`, which pins
  /// exactly that. The pre-existing WAL-only test above cannot see any of this: it quits with no
  /// dirty window, so nothing writes after the checkpoint.
  func testTerminationFlushesTheFinalWindowSaveIntoTheIndexBeforeCheckpointing() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let noteURL = root.appendingPathComponent("quit-note.md")
    try "before the quit".write(to: noteURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    // Give the terminal truncate something to reclaim, so "WAL is empty afterwards" cannot be an
    // artefact of nothing ever having been written.
    churn(database: database, root: root, count: 300, deleting: 0)
    XCTAssertGreaterThanOrEqual(
      walSize(for: databaseURL), 512 * 1024,
      "fixture precondition: the churn must actually grow the WAL")

    // A minute-long debounce: the only thing that can reach disk before the process exits is the
    // termination flush itself, never a scheduled autosave.
    let autosaver = Autosaver(saveDelayMilliseconds: 60_000, indexDelayMilliseconds: 60_000)
    let store = DocumentStore(
      autosaver: autosaver,
      indexDatabase: database,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveTerminationFlushBookmarks")),
      recoveryStore: RecoveryStore(
        directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true))
    )
    let registry = DocumentWindowRegistry()
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: WorkspaceMetadataStore(
          metadataURL: folder.appendingPathComponent("workspace.json")),
        indexDatabase: database,
        bookmarkStore: BookmarkStore(
          defaults: makeEphemeralDefaults(prefix: "PensieveTerminationFlushWorkspace"))),
      documentStore: store,
      indexDatabase: database,
      documentWindowRegistry: registry
    )

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    registry.registerController(controller, for: window)

    let ref = DocumentRef(id: noteURL.standardizedFileURL)
    appState.documents = [ref]
    appState.documentSession.load(document: ref, text: "before the quit")
    appState.activeDocumentText = "edited moments before the quit"
    store.documentDidChange(appState: appState)
    XCTAssertTrue(appState.activeDocumentDirty)
    XCTAssertEqual(
      try String(contentsOf: noteURL, encoding: .utf8), "before the quit",
      "fixture precondition: the debounced write must not have fired yet")

    let delegate = PensieveAppDelegate()
    delegate.terminationWindowRegistryOverride = registry
    delegate.terminationIndexDatabaseOverride = database
    delegate.applicationWillTerminate(
      Notification(name: NSApplication.willTerminateNotification))

    let walAfterQuit = walSize(for: databaseURL)

    XCTAssertEqual(
      try String(contentsOf: noteURL, encoding: .utf8), "edited moments before the quit",
      "the quit must flush the window's pending edit itself — willCloseNotification fires after "
        + "applicationWillTerminate, far too late to be the app's final save")
    // Read through an INDEPENDENT connection, not through `database.search`. Since the termination
    // latch (R5) the quit closes the index funnel one way, and that includes the lazy open every
    // read goes through — a read is allowed to CREATE and migrate the database, which is the last
    // thing a process on its way out should do. So a query through the database under test now
    // returns empty whether or not the write landed, and only the file on disk can answer this.
    XCTAssertGreaterThan(
      try indexHits(matching: "moments", at: databaseURL), 0,
      "the final save's index write must be drained before the process is allowed to go")
    XCTAssertLessThanOrEqual(
      walAfterQuit, 64 * 1024,
      "the truncating checkpoint must be the LAST step of the quit (WAL is \(walAfterQuit) bytes)")
  }

  /// "Exactly one owner" is a testable claim, so it is tested. The custom ⌘Q item used to take its
  /// own checkpoint before calling `terminate:` — a SECOND checkpoint, and the earlier one, so it ran
  /// before the final window saves it was supposed to protect. It must now be a pure dirty-session
  /// guard that leaves storage alone; the shared `applicationWillTerminate` path that ⌘Q also goes
  /// through is what truncates.
  func testQuitMenuGuardLeavesTheCheckpointToTheTerminationSequence() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    churn(database: database, root: root, count: 300, deleting: 0)
    let walBefore = walSize(for: databaseURL)
    XCTAssertGreaterThanOrEqual(
      walBefore, 512 * 1024,
      "fixture precondition: the churn must actually grow the WAL")

    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: WorkspaceMetadataStore(
          metadataURL: folder.appendingPathComponent("workspace.json")),
        indexDatabase: database,
        bookmarkStore: BookmarkStore(
          defaults: makeEphemeralDefaults(prefix: "PensieveQuitGuardWorkspace"))),
      documentStore: DocumentStore(
        indexDatabase: database,
        bookmarkStore: BookmarkStore(
          defaults: makeEphemeralDefaults(prefix: "PensieveQuitGuardBookmarks")),
        recoveryStore: RecoveryStore(
          directoryURL: folder.appendingPathComponent("Recovery", isDirectory: true))),
      indexDatabase: database,
      documentWindowRegistry: DocumentWindowRegistry()
    )

    XCTAssertTrue(controller.applicationShouldTerminate(), "a clean session must let the quit pass")
    XCTAssertEqual(
      walSize(for: databaseURL), walBefore,
      "the quit menu guard must not checkpoint: the termination sequence owns the ordering, and a "
        + "checkpoint fired here runs BEFORE the final window saves")

    let delegate = PensieveAppDelegate()
    delegate.terminationWindowRegistryOverride = DocumentWindowRegistry()
    delegate.terminationIndexDatabaseOverride = database
    delegate.applicationWillTerminate(
      Notification(name: NSApplication.willTerminateNotification))

    XCTAssertLessThanOrEqual(
      walSize(for: databaseURL), 64 * 1024,
      "…and the one owner still truncates on the very same ⌘Q path (was \(walBefore) bytes)")
  }

  /// The post-timeout fallback used to deadlock on the very stall it exists to escape. When the drain
  /// budget expired the old code took the terminal checkpoint inline, and its
  /// `barrierWriteWithoutTransaction`
  /// queues behind the wedged writer SYNCHRONOUSLY on the calling thread — so quitting during a stuck
  /// reindex could hang indefinitely despite the timeout. The timeout has to be an escape, not a
  /// detour into the same lock.
  ///
  /// The wedge is real, not simulated: `didInsertSearchIndexBatch` fires INSIDE the index write's
  /// `pool.write` transaction, so blocking it holds a genuine writer inside the pool — exactly what a
  /// checkpoint has to queue behind. Nothing else in this test calls that hook (`churn` uses the sync
  /// `index(document:body:)`, which never batches), so the only thing parked is the write under test.
  ///
  /// A safety valve releases the wedge after `wedgeReleaseSeconds` so a regressed build FAILS the
  /// bound instead of hanging the suite. The bound itself is deliberately loose — a whole order of
  /// magnitude above the shrunk budget and far below the release valve — because this suite already
  /// carries wall-clock flakes and this assertion must never become the next one.
  func testQuitReturnsWithinItsBudgetWhenAnIndexWriteIsWedgedInsideThePool() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let wedge = WedgeSignal()
    let released = DispatchSemaphore(value: 0)
    // Belt and braces: released here on every exit path, and by the timer below even if the test
    // aborts on an assertion before reaching this line.
    defer { released.signal() }
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.wedgeReleaseSeconds) {
      released.signal()
    }

    let appState = AppState()
    let database = IndexDatabase(
      databaseURL: databaseURL,
      didInsertSearchIndexBatch: { _ in
        wedge.markReached()
        released.wait()
      })
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    // Give the terminal checkpoint something it would visibly reclaim, so "the WAL survived" below
    // cannot be an artefact of an empty log.
    churn(database: database, root: root, count: 300, deleting: 0)
    let walBeforeQuit = walSize(for: databaseURL)
    XCTAssertGreaterThanOrEqual(
      walBeforeQuit, 512 * 1024,
      "fixture precondition: the churn must actually grow the WAL")

    let wedgedRef = documentRef(root: root, name: "wedged-write.md")
    try "the write that never finishes".write(to: wedgedRef.url, atomically: true, encoding: .utf8)
    let writeFinished = CompletionFlag()
    database.scheduleIndexWrite {
      await database.updateSearchIndexInBackground(
        upserting: [wedgedRef], deletingPaths: [], appState: nil)
      writeFinished.isSet = true
    }
    pumpMainRunLoop(until: { wedge.isReached }, timeout: 10)
    XCTAssertTrue(
      wedge.isReached,
      "fixture precondition: the scheduled index write must actually be holding the pool's writer")

    let sequence = TerminationSequence(
      registry: DocumentWindowRegistry(),
      indexDatabase: database,
      drainTimeout: Self.shrunkDrainBudget)

    let startedAt = Date()
    sequence.runBlockingMainRunLoop()
    let elapsed = Date().timeIntervalSince(startedAt)
    // Sampled before the wedge is released, so it reports what the QUIT left behind rather than what
    // the abandoned best-effort checkpoint does once the pool frees up.
    let walAfterQuit = walSize(for: databaseURL)

    XCTAssertLessThan(
      elapsed, Self.boundedQuitSeconds,
      "the quit must return once its drain budget expires; it waited \(elapsed) s, which means it "
        + "queued behind the wedged writer instead of escaping it")
    XCTAssertGreaterThanOrEqual(
      walAfterQuit, walBeforeQuit,
      "past the deadline the checkpoint must NOT run on the calling thread — a truncated WAL here "
        + "means the quit took the barrier the stuck writer is holding")

    released.signal()
    pumpMainRunLoop(until: { writeFinished.isSet }, timeout: 10)
  }

  /// The sibling above bounds the quit when a WRITER is stuck; this one bounds it when a READER is,
  /// and that used to be a hole the budget never covered. `TerminationSequence.run()` took the
  /// terminal checkpoint SYNCHRONOUSLY on the main actor, and `barrierWriteWithoutTransaction`
  /// excludes the pool's reader connections as well as its writer — which is precisely why the
  /// truncate needs that barrier. The pump in `runBlockingMainRunLoop()` only regains control when
  /// the main-actor task SUSPENDS, so a synchronous barrier parked the pump: the deadline stopped
  /// being re-checked, and a slow backlink query could hang the quit for as long as it held its
  /// reader. `drainPendingIndexWrites()` does not help — it tracks writes, and never claimed
  /// otherwise. The budget only ever covered the drain.
  ///
  /// The wedge is a genuine pool READER, not a writer and not a simulation: `didOpenBacklinkRead`
  /// fires from INSIDE `fetchBacklinkRecords`' `pool.read`, with the reader connection already
  /// checked out. Nothing here schedules an index write, and the churn goes through the synchronous
  /// `index(document:body:)`, so the drain has nothing to wait for and the ONLY thing the quit can be
  /// blocked on is the reader. That is what separates this pin from the writer one.
  ///
  /// The bound is deliberately loose for the same reason as its sibling — this suite already carries
  /// wall-clock flakes — and the same safety valve frees the wedge so a regressed build FAILS the
  /// assertion instead of hanging the suite.
  func testQuitReturnsWithinItsBudgetWhenAPoolReaderIsWedged() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let root = folder.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let wedge = WedgeSignal()
    let released = DispatchSemaphore(value: 0)
    defer { released.signal() }
    DispatchQueue.global().asyncAfter(deadline: .now() + Self.wedgeReleaseSeconds) {
      released.signal()
    }

    let appState = AppState()
    let database = IndexDatabase(
      databaseURL: databaseURL,
      didOpenBacklinkRead: {
        wedge.markReached()
        released.wait()
      })
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    // Give the terminal checkpoint something it would visibly reclaim, so "the WAL survived" below
    // cannot be an artefact of an empty log.
    churn(database: database, root: root, count: 300, deleting: 0)
    let walBeforeQuit = walSize(for: databaseURL)
    XCTAssertGreaterThanOrEqual(
      walBeforeQuit, 512 * 1024,
      "fixture precondition: the churn must actually grow the WAL")

    let documents = (0..<3).map { documentRef(root: root, name: "churn-\($0).md") }
    let backlinksFinished = CompletionFlag()
    Task { @MainActor in
      _ = await database.backlinksInBackground(to: documents[0], documents: documents)
      backlinksFinished.isSet = true
    }
    pumpMainRunLoop(until: { wedge.isReached }, timeout: 10)
    XCTAssertTrue(
      wedge.isReached,
      "fixture precondition: the backlink query must actually be holding one of the pool's readers")

    let sequence = TerminationSequence(
      registry: DocumentWindowRegistry(),
      indexDatabase: database,
      drainTimeout: Self.shrunkDrainBudget)

    let startedAt = Date()
    sequence.runBlockingMainRunLoop()
    let elapsed = Date().timeIntervalSince(startedAt)
    // Sampled before the wedge is released, so it reports what the QUIT left behind rather than what
    // the abandoned best-effort checkpoint does once the reader lets go.
    let walAfterQuit = walSize(for: databaseURL)

    XCTAssertLessThan(
      elapsed, Self.boundedQuitSeconds,
      "the quit must stay inside its budget while a pool reader is wedged; it waited \(elapsed) s, "
        + "which means the terminal checkpoint's barrier ran without suspending and the pump could "
        + "never re-check the deadline")
    XCTAssertGreaterThanOrEqual(
      walAfterQuit, walBeforeQuit,
      "a truncated WAL here means the quit sat on the barrier until the reader released it, rather "
        + "than returning when its budget expired")

    released.signal()
    pumpMainRunLoop(until: { backlinksFinished.isSet }, timeout: 10)
  }

  // MARK: - Ordering fixtures

  /// How long the wedged writer is held before a safety valve frees it. Generously above the bound
  /// the test asserts, so a build that reintroduces the deadlock fails on the assertion (having
  /// waited this long) instead of hanging the whole suite.
  private static let wedgeReleaseSeconds: TimeInterval = 20

  /// The drain budget under test, shrunk from the production 5 s through `TerminationSequence`'s own
  /// init seam. Nothing in this test needs the real budget — the contract is "returns once it
  /// expires", not "expires after exactly 5 s".
  private static let shrunkDrainBudget: TimeInterval = 0.4

  /// The bound the quit must respect. ~12× the shrunk budget and ~4× below the release valve, so
  /// neither a slow machine nor a busy CI runner can push a correct build over it.
  private static let boundedQuitSeconds: TimeInterval = 5

  /// Thread-safe "the writer got inside the transaction" latch. The hook that sets it runs on GRDB's
  /// writer thread while the test reads it from the main thread, so the flag cannot be a plain `var`.
  private final class WedgeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var reached = false

    var isReached: Bool {
      lock.lock()
      defer { lock.unlock() }
      return reached
    }

    func markReached() {
      lock.lock()
      reached = true
      lock.unlock()
    }
  }

  /// Synchronous sibling of `waitUntil` for the tests that must stay non-async because they drive
  /// `runBlockingMainRunLoop()`. Pumps the run loop exactly the way production does, so main-actor
  /// work (the scheduled index write, the drain) keeps making progress while the test waits.
  private func pumpMainRunLoop(until condition: () -> Bool, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.005))
    }
  }

  /// One-shot release valve behind `IndexDatabase.backgroundWriteGateOverride`. The FIRST background
  /// index write parks here until the test opens the gate; every later write passes straight through
  /// so it queues on the supersede chain — behind write #1 — rather than on this gate. `arrivals` is
  /// how the test knows a write has genuinely taken its place in that chain: the gate sits at the
  /// head of the write task, which cannot start before the write registered itself.
  private actor FirstWriteGate {
    private(set) var arrivals = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arrive() async {
      arrivals += 1
      guard arrivals == 1, !isOpen else { return }
      await withCheckedContinuation { continuation in
        waiters.append(continuation)
      }
    }

    func open() {
      isOpen = true
      for waiter in waiters { waiter.resume() }
      waiters.removeAll()
    }
  }

  /// Holds EVERY background index write until the test opens it, where `FirstWriteGate` holds only
  /// the first. Used when the write under test is not the first one to arrive, or when a second
  /// arrival (a watcher-driven refresh, say) must not be allowed to slip past while the test is
  /// asserting that nothing has been allowed through yet.
  private actor ParkingGate {
    private(set) var arrivals = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arrive() async {
      arrivals += 1
      guard !isOpen else { return }
      await withCheckedContinuation { continuation in
        waiters.append(continuation)
      }
    }

    func open() {
      isOpen = true
      for waiter in waiters { waiter.resume() }
      waiters.removeAll()
    }
  }

  /// Main-actor flag a probe task can set, so a test can observe "did this finish yet?" without
  /// awaiting the thing it is trying to prove has NOT finished.
  @MainActor private final class CompletionFlag {
    var isSet = false
  }

  /// Sibling of `CompletionFlag` for the one probe that has to report WHAT it read, not just that it
  /// returned: a search that completed with zero hits would not prove it reached the pool.
  @MainActor private final class SearchHitCount {
    var value = 0
  }

  /// The wedged-reader valve for the round-12 pool pin. Far above every wait in that test (the
  /// longest is 10 s) so a build that reintroduces the reader-excluding barrier fails an assertion
  /// instead of being rescued by the release.
  private static let poolWedgeReleaseSeconds: TimeInterval = 45

  /// The WAL bound the two round-13 pins work against, lowered through
  /// `walCheckpointThresholdBytesOverride` for the same reason every other pin here lowers it: a test
  /// that had to write the production 16 MiB would be a minute-long disk-bound test. Small enough
  /// that a single save crosses it, large enough that a truncated (zero-length) `-wal` is
  /// unambiguously under it.
  private static let coalescedRearmWalBoundBytes: Int64 = 64 * 1024

  /// Ladder delay for the composition pin. Long next to its 200 ms quiet window — so a successor
  /// appearing during that window can only be a prompt re-arm, never the ladder firing early — and
  /// short next to the 20 s wait that follows the reader's release.
  private static let ladderRetryDelayNanoseconds: UInt64 = 5_000_000_000

  /// How long the composition pin watches for a successor that must not appear. 25× below the ladder
  /// delay above, so a loaded runner cannot turn a correct build into a failure.
  private static let ladderQuietWindowNanoseconds: UInt64 = 200_000_000

  /// Ladder delay for the round-14 self-absorption pin, where the retry must fire AFTER the reader let
  /// go. The release is a semaphore signal taken within milliseconds of the deferral being observed,
  /// so this is a wide margin on the gap it has to lose — and short enough that the pin does not turn
  /// into a wall-clock test.
  private static let selfAbsorptionLadderDelayNanoseconds: UInt64 = 2_000_000_000

  /// A document body big enough that committing it alone pushes the `-wal` file over
  /// `coalescedRearmWalBoundBytes` (~288 KiB against a 64 KiB bound), carrying a searchable needle so
  /// the pin can prove the frames were CHECKPOINTED rather than dropped.
  private static func walGrowingBody(needle: String) -> String {
    needle + " " + String(repeating: "coalesced rearm payload ", count: 12_000)
  }

  /// Polls a monotone condition instead of sleeping a fixed amount: a correct build waits only as
  /// long as it actually needs, and a wrong one fails the assertion rather than a guessed duration.
  private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 10,
    _ condition: () async -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await condition() { return }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("timed out waiting for \(description)")
  }

  // MARK: - Workspace fixtures (last-root removal)

  private struct WorkspaceSandbox {
    let root: URL
    let support: URL
  }

  private struct WorkspaceHarness {
    let manager: FolderManager
    let indexDatabase: IndexDatabase
  }

  private func makeWorkspaceSandbox() throws -> WorkspaceSandbox {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveStorageHygieneWorkspace-\(UUID().uuidString)", isDirectory: true)
    let support = root.appendingPathComponent("Support", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return WorkspaceSandbox(root: root, support: support)
  }

  private func makeWorkspaceHarness(in support: URL) throws -> WorkspaceHarness {
    let indexDatabase = IndexDatabase(
      databaseURL: support.appendingPathComponent("index.db", isDirectory: false))
    let manager = FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: support.appendingPathComponent("workspace.json")),
      indexDatabase: indexDatabase,
      bookmarkStore: BookmarkStore(
        defaults: makeEphemeralDefaults(prefix: "PensieveStorageHygieneBookmarks")),
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true)))
    )
    return WorkspaceHarness(manager: manager, indexDatabase: indexDatabase)
  }

  private func settle(_ harness: WorkspaceHarness) async {
    await harness.manager.waitForPendingWorkspaceBuild()
    await harness.manager.waitForPendingForcedRefresh()
    await harness.manager.waitForPendingIndexUpdate()
    await harness.manager.waitForPendingWorkspaceIndexWrite()
    await harness.indexDatabase.waitForPendingReindex()
  }

  /// Mirrors `IndexDatabase.freelistCompactionThresholdPages`; kept local because
  /// the production constant is private and the test asserts the OBSERVABLE
  /// contract (enough slack exists to be worth reclaiming), not the constant.
  private static let compactionThresholdPages = 256
}
