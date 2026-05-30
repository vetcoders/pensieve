import GRDB
import XCTest

@testable import Pensieve

/// B-2 IndexDatabase v2 schema verification (I-01, Wave A foundation).
///
/// These tests pin the v2 migration shape produced by `IndexDatabase.open()`:
/// table presence, named indices, migration idempotency across reopens, and
/// foreign-key enforcement. They inspect the on-disk schema through an
/// independent GRDB connection opened with the same default configuration the
/// app uses (GRDB enables `PRAGMA foreign_keys = ON` by default), so the FK
/// declarations are exercised under production-equivalent settings.
@MainActor
final class IndexDatabaseV2Tests: XCTestCase {
  private let expectedV2Tables: Set<String> = [
    "workspaces",
    "documents",
    "document_revisions",
    "document_chunks",
    "scan_sessions",
    "workspace_stats",
  ]

  func testIndexDatabaseV2SchemaIncludesAllTablesAfterMigration() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    let tables = try readTableNames(at: databaseURL)
    // All six v2 tables plus the existing MVP FTS table must be present.
    XCTAssertTrue(
      expectedV2Tables.isSubset(of: tables),
      "missing v2 tables: \(expectedV2Tables.subtracting(tables).sorted())")
    XCTAssertTrue(
      tables.contains("workspace_search_documents"),
      "existing FTS table workspace_search_documents must survive v2 migrations")

    let indices = try readIndexNames(at: databaseURL)
    let expectedIndices: Set<String> = [
      "idx_documents_workspace",
      "idx_documents_path",
      "idx_scan_sessions_workspace",
    ]
    XCTAssertTrue(
      expectedIndices.isSubset(of: indices),
      "missing v2 indices: \(expectedIndices.subtracting(indices).sorted())")
  }

  func testIndexDatabaseV2MigrationsAreIdempotentAcrossTwoOpens() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let firstAppState = AppState()
    let firstDatabase = IndexDatabase(databaseURL: databaseURL)
    firstDatabase.open(into: firstAppState)
    XCTAssertNil(firstAppState.lastError)
    let tablesAfterFirstOpen = try readTableNames(at: databaseURL)

    // Sentinel row written between opens; it must survive a second open and
    // the second open must not re-run migrations (which would throw on the
    // already-existing tables).
    try writeSentinelWorkspace(at: databaseURL)

    let secondAppState = AppState()
    let secondDatabase = IndexDatabase(databaseURL: databaseURL)
    secondDatabase.open(into: secondAppState)
    XCTAssertNil(secondAppState.lastError)

    let tablesAfterSecondOpen = try readTableNames(at: databaseURL)
    XCTAssertEqual(
      tablesAfterFirstOpen, tablesAfterSecondOpen,
      "table list changed across reopen — migrations are not idempotent")

    let sentinelCount = try readSentinelWorkspaceCount(at: databaseURL)
    XCTAssertEqual(sentinelCount, 1, "sentinel workspace row did not persist across reopen")
  }

  func testIndexDatabaseV2DocumentsForeignKeyEnforced() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    // Insert a documents row referencing a workspace_id that does not exist.
    // With foreign keys enabled (GRDB default) SQLite must reject it.
    let writer = try DatabaseQueue(path: databaseURL.path)
    XCTAssertThrowsError(
      try writer.write { db in
        try db.execute(
          sql: """
            INSERT INTO documents
                (workspace_id, path, title, body, mtime, size, is_ad_hoc, indexed_at)
            VALUES ('nonexistent-workspace', 'ghost.md', 'Ghost', 'body', 0, 0, 0, 0)
            """)
      }
    ) { error in
      guard let databaseError = error as? DatabaseError else {
        return XCTFail("expected GRDB DatabaseError, got \(error)")
      }
      XCTAssertEqual(databaseError.resultCode.primaryResultCode, .SQLITE_CONSTRAINT)
      XCTAssertEqual(databaseError.extendedResultCode, .SQLITE_CONSTRAINT_FOREIGNKEY)
    }
  }

  // MARK: - Helpers

  private func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveIndexV2Tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// Read schema object names through an independent read-write GRDB connection.
  /// A read-write connection (rather than read-only) sidesteps the SQLite WAL
  /// shared-memory limitation that can block read-only opens of a live database.
  private func readNames(ofType type: String, at databaseURL: URL) throws -> Set<String> {
    let queue = try DatabaseQueue(path: databaseURL.path)
    return try queue.read { db in
      Set(
        try String.fetchAll(
          db, sql: "SELECT name FROM sqlite_master WHERE type = ?", arguments: [type]))
    }
  }

  private func readTableNames(at databaseURL: URL) throws -> Set<String> {
    try readNames(ofType: "table", at: databaseURL)
  }

  private func readIndexNames(at databaseURL: URL) throws -> Set<String> {
    try readNames(ofType: "index", at: databaseURL)
  }

  private func writeSentinelWorkspace(at databaseURL: URL) throws {
    let queue = try DatabaseQueue(path: databaseURL.path)
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO workspaces
              (workspace_id, canonical_path, first_seen_at, last_seen_at, status)
          VALUES ('sentinel-workspace', '/tmp/sentinel', 0, 0, 'active')
          """)
    }
  }

  private func readSentinelWorkspaceCount(at databaseURL: URL) throws -> Int {
    let queue = try DatabaseQueue(path: databaseURL.path)
    return try queue.read { db in
      try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM workspaces WHERE workspace_id = ?",
        arguments: ["sentinel-workspace"]) ?? 0
    }
  }
}
