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

  /// Mirrors `IndexDatabase.freelistCompactionThresholdPages`; kept local because
  /// the production constant is private and the test asserts the OBSERVABLE
  /// contract (enough slack exists to be worth reclaiming), not the constant.
  private static let compactionThresholdPages = 256
}
