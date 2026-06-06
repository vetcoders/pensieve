//  IndexDatabaseExternalContentFtsTests.swift
//  PensieveTests
//
//  STAGE 1 (external-content FTS): proves the migration from the legacy
//  CONTENTFUL `workspace_search_documents` table to the external-content
//  `document_fts` index over `documents`. Covers: (1) migrating a DB populated in
//  the OLD contentful schema keeps every hit searchable and stores NO body in the
//  FTS, (2) workspace_id scoping is enforced in SQL, (3) ad-hoc out-of-workspace
//  docs stay searchable, (4) the FTS holds no body (no `_content`/`_docsize`
//  shadow tables — the double-body fix), and (5) migration idempotency / safety
//  on an existing populated DB.

import GRDB
import XCTest

@testable import Pensieve

@MainActor
final class IndexDatabaseExternalContentFtsTests: XCTestCase {

  // MARK: - Fixtures

  private func makeBase() throws -> URL {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("ExtContentFtsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
  }

  private func makeIdentity(root: URL) -> WorkspaceIdentity {
    WorkspaceIdentity.make(rootURL: root, bookmarkData: nil)
  }

  @discardableResult
  private func makeDoc(root: URL, name: String, body: String) throws -> DocumentRef {
    let fileURL = root.appendingPathComponent(name)
    try body.write(to: fileURL, atomically: true, encoding: .utf8)
    return DocumentRef(id: fileURL.standardizedFileURL, rootURL: root, relativePath: name)
  }

  private func tableNames(at databaseURL: URL) throws -> Set<String> {
    let queue = try DatabaseQueue(path: databaseURL.path)
    return try queue.read { db in
      Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
    }
  }

  // MARK: - (1)+(5) Migration from the OLD contentful schema

  /// Builds a DB whose schema STOPS at the legacy contentful FTS + its
  /// documents-mirroring triggers (the pre-external-content state), populates it
  /// the OLD way (workspace docs via the contentful trigger, an ad-hoc row
  /// inserted directly), THEN runs `IndexDatabase.open` which applies the
  /// external-content migration. Asserts: the migration succeeds, every prior hit
  /// is still searchable through the unchanged `search` contract, and the body is
  /// no longer duplicated in the FTS.
  func testMigrationFromLegacyContentfulSchemaPreservesSearchAndDropsDoubleBody() throws {
    let base = try makeBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.resolvingSymlinksInPath().standardizedFileURL
    let databaseURL = root.appendingPathComponent("index.db", isDirectory: false)

    // Real on-disk files so `search` (which reads the live DocumentRefs) resolves.
    let wsRef = try makeDoc(root: root, name: "ws.md", body: "alpha workspace plutonium body")
    let adHocURL = root.appendingPathComponent("scratch.md")
    try "adhoc beryllium content".write(to: adHocURL, atomically: true, encoding: .utf8)
    let identity = makeIdentity(root: root)

    // ---- Stand up a DB in the LEGACY (pre-external-content) shape: run only the
    // migrations up to and including the legacy contentful FTS + its triggers.
    try buildLegacyContentfulDatabase(at: databaseURL, identity: identity, root: root)

    // Populate the legacy way: a workspace doc through the documents->contentful
    // trigger, and an ad-hoc row inserted DIRECTLY into the contentful FTS (the
    // pre-migration ad-hoc representation — never in `documents`).
    let legacyPool = try DatabasePool(path: databaseURL.path)
    try legacyPool.write { db in
      try db.execute(
        sql: """
          INSERT INTO documents
              (workspace_id, path, title, body, mtime, size, is_ad_hoc, indexed_at)
          VALUES (?, 'ws.md', 'ws', 'alpha workspace plutonium body', 100, 30, 0, 100)
          """,
        arguments: [identity.workspaceID])
      // Ad-hoc row only in the contentful FTS (full standardized path).
      try db.execute(
        sql: """
          INSERT INTO workspace_search_documents
              (path, title, display_path, body, is_ad_hoc, updated_at)
          VALUES (?, 'scratch', 'scratch.md', 'adhoc beryllium content', 1, 200)
          """,
        arguments: [adHocURL.standardizedFileURL.path])
    }
    try legacyPool.close()

    // Sanity: legacy contentful table exists and holds the body twice (workspace
    // doc body lives in BOTH `documents` and the contentful FTS).
    XCTAssertTrue(try tableNames(at: databaseURL).contains("workspace_search_documents"))

    // ---- Run the external-content migration via the production open path.
    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError, "external-content migration must succeed on a populated DB")

    // The legacy contentful table is retired; the external-content index exists.
    let tables = try tableNames(at: databaseURL)
    XCTAssertFalse(tables.contains("workspace_search_documents"))
    XCTAssertTrue(tables.contains("document_fts"))

    // The workspace doc is still searchable (it was in `documents` already).
    let wsResults = database.search(query: "plutonium", documents: [wsRef])
    XCTAssertEqual(wsResults.map(\.document.id), [wsRef.url.standardizedFileURL])

    // The ad-hoc body, which lived ONLY in the contentful FTS, was migrated into
    // `documents` under the reserved workspace and stays searchable.
    let adHocRef = DocumentRef(id: adHocURL.standardizedFileURL, isAdHoc: true)
    let adHocResults = database.search(query: "beryllium", documents: [adHocRef])
    XCTAssertEqual(adHocResults.map(\.document.id), [adHocURL.standardizedFileURL])

    // No double body: the external-content FTS stores no `_content`/`_docsize`.
    assertNoBodyStoredInFTS(at: databaseURL)
  }

  // MARK: - (4) No double body

  /// The external-content `document_fts` (columnsize=0) must NOT create the
  /// `_content` shadow table (where a CONTENTFUL FTS5 stores the full body) nor
  /// `_docsize` — proof the body is no longer duplicated. Contrast: a contentful
  /// FTS5 creates BOTH (verified out-of-band against sqlite3).
  func testExternalContentFtsStoresNoBody() throws {
    let base = try makeBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let databaseURL = base.appendingPathComponent("index.db", isDirectory: false)

    let appState = AppState()
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open(into: appState)
    XCTAssertNil(appState.lastError)

    assertNoBodyStoredInFTS(at: databaseURL)
  }

  private func assertNoBodyStoredInFTS(at databaseURL: URL) {
    guard let tables = try? tableNames(at: databaseURL) else {
      return XCTFail("could not read schema")
    }
    XCTAssertFalse(
      tables.contains("document_fts_content"),
      "external-content FTS must NOT have a `_content` shadow table (that holds the body)")
    XCTAssertFalse(
      tables.contains("document_fts_docsize"),
      "columnsize=0 must suppress the `_docsize` shadow table")
    XCTAssertTrue(
      tables.contains("document_fts_data") && tables.contains("document_fts_idx"),
      "the inverted-index shadow tables must exist")
  }

  // MARK: - (2) workspace_id scoping enforced in SQL

  /// Two workspaces, each with a doc containing the SAME query token. A search
  /// scoped to workspace A's docs must return ONLY A's doc — the scope is applied
  /// in SQL (the join filters by the workspaces' canonical_path), not merely by
  /// the in-memory post-filter.
  func testSearchIsScopedToWorkspaceInSQL() async throws {
    let base = try makeBase()
    defer { try? FileManager.default.removeItem(at: base) }

    let rootA = base.appendingPathComponent("A", isDirectory: true).standardizedFileURL
    let rootB = base.appendingPathComponent("B", isDirectory: true).standardizedFileURL
    try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)

    let databaseURL = base.appendingPathComponent("index.db", isDirectory: false)
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open()

    let refA = try makeDoc(root: rootA, name: "a.md", body: "shared overlap token in A")
    let refB = try makeDoc(root: rootB, name: "b.md", body: "shared overlap token in B")
    await database.upsertWorkspace(
      identity: makeIdentity(root: rootA), roots: [rootA], documents: [refA])
    await database.upsertWorkspace(
      identity: makeIdentity(root: rootB), roots: [rootB], documents: [refB])

    // Search scoped to A's docs only.
    let aResults = database.search(query: "overlap token", documents: [refA])
    XCTAssertEqual(
      aResults.map(\.document.id), [refA.url.standardizedFileURL],
      "a workspace-A search returns only A's doc, never B's")

    // Search scoped to B's docs only.
    let bResults = database.search(query: "overlap token", documents: [refB])
    XCTAssertEqual(
      bResults.map(\.document.id), [refB.url.standardizedFileURL],
      "a workspace-B search returns only B's doc, never A's")

    // Both in scope -> both returned (proves the rows coexist, scoping is the gate).
    let bothResults = database.search(query: "overlap token", documents: [refA, refB])
    XCTAssertEqual(
      Set(bothResults.map(\.document.id)),
      [refA.url.standardizedFileURL, refB.url.standardizedFileURL])
  }

  // MARK: - (6) Partial-name (infix) search falls back to substring LIKE

  /// FTS5 `unicode61` does token-PREFIX matching, so an infix query ("liczek"
  /// inside the token "pliczek") yields ZERO FTS hits. The search must then fall
  /// through to the substring LIKE scan and still find the file by partial name.
  /// Discriminating: the prior code returned the (empty) FTS result set without
  /// falling back, so the infix queries below would return nothing.
  func testPartialNameSearchFindsFileViaSubstringFallback() async throws {
    let base = try makeBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("ws", isDirectory: true).standardizedFileURL
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let databaseURL = base.appendingPathComponent("index.db", isDirectory: false)
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open()

    let ref = try makeDoc(root: root, name: "pliczek.md", body: "some unrelated body text")
    await database.upsertWorkspace(
      identity: makeIdentity(root: root), roots: [root], documents: [ref])
    let id = ref.url.standardizedFileURL

    // Prefix query already worked via FTS token-prefix.
    XCTAssertEqual(
      database.search(query: "pliczek", documents: [ref]).map(\.document.id), [id])
    // Infix queries (FTS yields nothing) must find the file via the substring fallback.
    XCTAssertEqual(
      database.search(query: "liczek", documents: [ref]).map(\.document.id), [id],
      "an infix query must find the file by partial name (substring fallback)")
    XCTAssertEqual(
      database.search(query: "czek", documents: [ref]).map(\.document.id), [id],
      "a short infix query must find the file by partial name (substring fallback)")
  }

  // MARK: - (3) Ad-hoc stays searchable alongside a scoped workspace

  /// An ad-hoc doc indexed via `indexInBackground(document:body:)` (no workspace) coexists
  /// with a scoped workspace doc and stays searchable; searching with only the
  /// workspace doc in scope does NOT surface the ad-hoc doc (scope respected),
  /// while including the ad-hoc ref surfaces it.
  func testAdHocSearchableUnderReservedScope() async throws {
    let base = try makeBase()
    defer { try? FileManager.default.removeItem(at: base) }
    let root = base.appendingPathComponent("ws", isDirectory: true).standardizedFileURL
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let databaseURL = base.appendingPathComponent("index.db", isDirectory: false)
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open()

    let wsRef = try makeDoc(root: root, name: "ws.md", body: "workspace tungsten body")
    await database.upsertWorkspace(
      identity: makeIdentity(root: root), roots: [root], documents: [wsRef])

    let adHocURL = base.appendingPathComponent("loose.md")
    try "adhoc rhodium content".write(to: adHocURL, atomically: true, encoding: .utf8)
    let adHocRef = DocumentRef(id: adHocURL.standardizedFileURL, isAdHoc: true)
    // Awaiting the off-main twin is the write-completion sync point (it returns after the detached
    // `pool.write` commits + the search refresh), so the synchronous asserts below see the row.
    await database.indexInBackground(document: adHocRef, body: "adhoc rhodium content")

    // Ad-hoc doc is searchable when its ref is in scope.
    XCTAssertEqual(
      database.search(query: "rhodium", documents: [wsRef, adHocRef]).map(\.document.id),
      [adHocURL.standardizedFileURL])
    // Workspace doc searchable; scoping to only the workspace ref hides the ad-hoc.
    XCTAssertEqual(
      database.search(query: "tungsten", documents: [wsRef]).map(\.document.id),
      [wsRef.url.standardizedFileURL])
    XCTAssertTrue(
      database.search(query: "rhodium", documents: [wsRef]).isEmpty,
      "an ad-hoc hit is not surfaced when only a workspace doc is in scope")
  }

  // MARK: - Legacy DB builder

  /// Stands up a database at the LEGACY (pre-external-content) schema state:
  /// every v2 migration up to and including `b2_v2_fts_documents_triggers`, but
  /// NOT `b2_v2_external_content_fts`. Mirrors the operator's on-disk DB shape
  /// before this stage shipped, so the production `open` then applies exactly the
  /// one new migration under test.
  private func buildLegacyContentfulDatabase(
    at databaseURL: URL, identity: WorkspaceIdentity, root: URL
  ) throws {
    let pool = try DatabasePool(path: databaseURL.path)
    var migrator = DatabaseMigrator()
    migrator.registerMigration("mvp_workspace_search_fts") { db in
      try db.execute(
        sql: """
          CREATE VIRTUAL TABLE IF NOT EXISTS workspace_search_documents
          USING fts5(
              path UNINDEXED, title, display_path, body,
              is_ad_hoc UNINDEXED, updated_at UNINDEXED, tokenize = 'unicode61'
          )
          """)
    }
    migrator.registerMigration("b2_v2_workspaces") { db in
      try db.execute(
        sql: """
          CREATE TABLE workspaces (
              workspace_id TEXT PRIMARY KEY, canonical_path TEXT NOT NULL,
              volume_resource_id TEXT, bookmark_hash TEXT,
              first_seen_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL,
              status TEXT NOT NULL)
          """)
    }
    migrator.registerMigration("b2_v2_documents") { db in
      try db.execute(
        sql: """
          CREATE TABLE documents (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
              path TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL,
              mtime INTEGER NOT NULL, size INTEGER NOT NULL, is_ad_hoc INTEGER NOT NULL,
              indexed_at INTEGER NOT NULL, UNIQUE(workspace_id, path))
          """)
    }
    migrator.registerMigration("b2_v2_fts_documents_triggers") { db in
      try db.execute(
        sql: """
          CREATE TRIGGER documents_after_insert_fts AFTER INSERT ON documents
          WHEN NEW.is_ad_hoc = 0 BEGIN
              DELETE FROM workspace_search_documents WHERE path =
                (SELECT canonical_path FROM workspaces WHERE workspace_id = NEW.workspace_id)
                 || '/' || NEW.path;
              INSERT INTO workspace_search_documents
                  (path, title, display_path, body, is_ad_hoc, updated_at)
              VALUES (
                  (SELECT canonical_path FROM workspaces WHERE workspace_id = NEW.workspace_id)
                   || '/' || NEW.path,
                  NEW.title, NEW.path, NEW.body, NEW.is_ad_hoc, NEW.mtime);
          END
          """)
    }
    try migrator.migrate(pool)
    // Seed the workspace row so the documents->FTS trigger's path reconstruction
    // resolves to the canonical root.
    try pool.write { db in
      try db.execute(
        sql: """
          INSERT INTO workspaces
              (workspace_id, canonical_path, volume_resource_id, bookmark_hash,
               first_seen_at, last_seen_at, status)
          VALUES (?, ?, NULL, NULL, 0, 0, 'active')
          """,
        arguments: [identity.workspaceID, root.path])
    }
    try pool.close()
  }
}
