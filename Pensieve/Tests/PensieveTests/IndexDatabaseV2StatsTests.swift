import GRDB
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
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: folder))
    )

    manager.openInBackground(url: folder, into: appState)
    await manager.waitForPendingWorkspaceBuild()

    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: appState.bookmarkData)
    let dbQueue = try DatabaseQueue(path: databaseURL.path)

    // Check scan_sessions
    try await dbQueue.read { db in
      let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scan_sessions")!
      XCTAssertEqual(count, 1)

      let row = try Row.fetchOne(
        db, sql: "SELECT * FROM scan_sessions WHERE workspace_id = ?",
        arguments: [identity.workspaceID])!
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
      let stats = try Row.fetchOne(
        db, sql: "SELECT * FROM workspace_stats WHERE workspace_id = ?",
        arguments: [identity.workspaceID])!
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
      bookmarkStore: temporaryBookmarkStore(),
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
      let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM scan_sessions")!
      XCTAssertEqual(count, 2)

      let rows = try Row.fetchAll(
        db, sql: "SELECT * FROM scan_sessions WHERE workspace_id = ? ORDER BY finished_at ASC",
        arguments: [identity.workspaceID])
      XCTAssertEqual(rows[0]["file_count"] as Int, 1)
      XCTAssertEqual(rows[1]["file_count"] as Int, 2)
    }

    // Check workspace_stats
    try await dbQueue.read { db in
      let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workspace_stats")!
      XCTAssertEqual(count, 1)  // Updated in place

      let stats = try Row.fetchOne(
        db, sql: "SELECT * FROM workspace_stats WHERE workspace_id = ?",
        arguments: [identity.workspaceID])!
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
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: folder))
    )

    manager.openInBackground(url: folder, into: appState)
    await manager.waitForPendingWorkspaceBuild()

    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: appState.bookmarkData)
    let dbQueue = try DatabaseQueue(path: databaseURL.path)

    try await dbQueue.read { db in
      let stats = try Row.fetchOne(
        db, sql: "SELECT * FROM workspace_stats WHERE workspace_id = ?",
        arguments: [identity.workspaceID])!
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
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: folder))
    )

    manager.openInBackground(url: folder, into: appState)
    await manager.waitForPendingWorkspaceBuild()

    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: appState.bookmarkData)
    let dbQueue = try DatabaseQueue(path: databaseURL.path)

    try await dbQueue.read { db in
      let start = Date()
      let stats = try Row.fetchOne(
        db, sql: "SELECT * FROM workspace_stats WHERE workspace_id = ?",
        arguments: [identity.workspaceID])!
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

  private func temporaryBookmarkStore() -> BookmarkStore {
    let suiteName = "PensieveIndexV2StatsBookmarkTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return BookmarkStore(defaults: defaults)
  }
}
