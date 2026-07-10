//  IndexDatabaseV2FtsTriggerTests.swift
//  PensieveTests
//
//  W-C-1 (I-03): FTS5 trigger-driven sync of workspace documents from the
//  `documents` table. Proves the three triggers (INSERT/UPDATE/DELETE), the
//  full-path reconstruction, the double-write collapse (no duplicate FTS rows),
//  ad-hoc preservation via `index(document:body:)`, and semantic preservation
//  of the search contract against the pre-trigger inline reindex path.

import GRDB
import XCTest

@testable import Pensieve

@MainActor
final class IndexDatabaseV2FtsTriggerTests: XCTestCase {

  // I-03 trigger coverage; identity via memberwise WorkspaceIdentity init (computedAt required).

  // MARK: - Fixtures

  /// Creates an on-disk index DB under a *canonical* root (symlinks resolved,
  /// standardized) so `workspaces.canonical_path` matches the standardized URL
  /// path used by `performSearch`'s join — the friction-1 invariant.
  private func makeWorkspace() throws -> (database: IndexDatabase, databaseURL: URL, root: URL) {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("FtsTriggerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let root = base.resolvingSymlinksInPath().standardizedFileURL
    let databaseURL = root.appendingPathComponent("index.db", isDirectory: false)
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open()
    return (database, databaseURL, root)
  }

  /// Production identity scheme (`WorkspaceIdentity.make`): the cold-scan
  /// `documents` writer (`commitWorkspaceManifest`) and the reindex path BOTH
  /// derive the workspace_id this way, so they converge on the SAME
  /// `(workspace_id, path)` keys and a documents-write-then-reindex produces no
  /// duplicate rows. A synthetic workspace_id would diverge from the id reindex
  /// derives from the ref's root and spuriously double-insert — that mismatch is
  /// a test artifact, not a production state. canonical_path is the already-
  /// canonical `root`, so it equals the standardized doc path.
  private func makeIdentity(root: URL) -> WorkspaceIdentity {
    WorkspaceIdentity.make(rootURL: root, bookmarkData: nil)
  }

  @discardableResult
  private func makeDoc(root: URL, name: String, body: String) throws -> DocumentRef {
    let fileURL = root.appendingPathComponent(name)
    try body.write(to: fileURL, atomically: true, encoding: .utf8)
    return DocumentRef(
      id: fileURL.standardizedFileURL,
      rootURL: root,
      relativePath: name)
  }

  private struct SearchIndexRow {
    let path: String
    let title: String
    let displayPath: String
    let body: String
    let isAdHoc: Bool
  }

  /// Reads the SEARCHABLE rows directly from the single source of truth
  /// (`documents` joined to `workspaces`), reconstructing the full-path view the
  /// retired contentful `workspace_search_documents` table used to expose
  /// (`canonical_path || '/' || path` for workspace docs, `path` verbatim for
  /// the reserved `__adhoc__` workspace). STAGE 1 moved body storage out of the
  /// FTS into `documents` (external content), so this is where a duplicate /
  /// stale row would now manifest.
  private func fetchSearchIndexRows(at databaseURL: URL) throws -> [SearchIndexRow] {
    let pool = try DatabasePool(path: databaseURL.path)
    defer { try? pool.close() }
    return try pool.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT
              CASE WHEN w.canonical_path = '' THEN d.path
                   ELSE w.canonical_path || '/' || d.path END AS path,
              d.title AS title,
              d.path AS display_path,
              d.body AS body,
              d.is_ad_hoc AS is_ad_hoc
          FROM documents d
          JOIN workspaces w ON w.workspace_id = d.workspace_id
          ORDER BY path
          """
      ).map { row in
        SearchIndexRow(
          path: row["path"],
          title: row["title"],
          displayPath: row["display_path"],
          body: row["body"],
          isAdHoc: (row["is_ad_hoc"] as Int) != 0)
      }
    }
  }

  /// Reconstructed full paths that appear more than once — the acceptance
  /// no-duplicate probe, now over `documents` (the FTS source of truth).
  private func fetchDuplicatePaths(at databaseURL: URL) throws -> [String] {
    let pool = try DatabasePool(path: databaseURL.path)
    defer { try? pool.close() }
    return try pool.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT
              CASE WHEN w.canonical_path = '' THEN d.path
                   ELSE w.canonical_path || '/' || d.path END AS path
          FROM documents d
          JOIN workspaces w ON w.workspace_id = d.workspace_id
          GROUP BY path HAVING COUNT(*) > 1
          """)
    }
  }

  // MARK: - Trigger sync

  func testInsertTriggerMirrorsWorkspaceDocumentIntoFTSWithFullPath() async throws {
    let (database, databaseURL, root) = try makeWorkspace()
    let ref = try makeDoc(root: root, name: "note.md", body: "alpha crystal harmonics body")

    await database.upsertWorkspace(
      identity: makeIdentity(root: root), roots: [root], documents: [ref])

    let rows = try fetchSearchIndexRows(at: databaseURL)
    XCTAssertEqual(rows.count, 1)
    let row = try XCTUnwrap(rows.first)
    // Friction 1: FTS path is the FULL standardized path, == the search join key.
    XCTAssertEqual(row.path, ref.url.standardizedFileURL.path)
    XCTAssertEqual(row.path, "\(root.path)/note.md")
    // Friction 3: column mapping.
    XCTAssertEqual(row.displayPath, ref.displayPath)
    XCTAssertEqual(row.body, "alpha crystal harmonics body")
    XCTAssertFalse(row.isAdHoc)

    // End-to-end: the row is reachable through the unchanged search contract.
    let results = database.search(query: "crystal harmonics", documents: [ref])
    XCTAssertEqual(results.map(\.document.id), [ref.url.standardizedFileURL])
    XCTAssertEqual(results.first?.matchKind, .body)
  }

  func testUpdateTriggerResyncsFTSOnBodyChange() async throws {
    let (database, databaseURL, root) = try makeWorkspace()
    let ref = try makeDoc(root: root, name: "n.md", body: "alpha original phrase")
    await database.upsertWorkspace(
      identity: makeIdentity(root: root), roots: [root], documents: [ref])

    XCTAssertEqual(
      database.search(query: "original", documents: [ref]).map(\.document.id),
      [ref.url.standardizedFileURL])

    // Rewrite body on disk, re-commit -> ON CONFLICT UPDATE -> AFTER UPDATE trigger.
    try "alpha revised plutonium phrase".write(to: ref.url, atomically: true, encoding: .utf8)
    await database.upsertWorkspace(
      identity: makeIdentity(root: root), roots: [root], documents: [ref])

    XCTAssertEqual(
      database.search(query: "plutonium", documents: [ref]).map(\.document.id),
      [ref.url.standardizedFileURL])
    XCTAssertTrue(database.search(query: "original", documents: [ref]).isEmpty)
    XCTAssertEqual(try fetchSearchIndexRows(at: databaseURL).count, 1)
    XCTAssertEqual(try fetchDuplicatePaths(at: databaseURL), [])
  }

  func testDeleteTriggerRemovesFTSRowOnTombstone() async throws {
    let (database, databaseURL, root) = try makeWorkspace()
    let keep = try makeDoc(root: root, name: "keep.md", body: "keep alpha")
    let drop = try makeDoc(root: root, name: "drop.md", body: "drop bravo nebula")
    await database.upsertWorkspace(
      identity: makeIdentity(root: root), roots: [root], documents: [keep, drop])
    XCTAssertEqual(try fetchSearchIndexRows(at: databaseURL).count, 2)

    // Re-scan without `drop` -> tombstone DELETE -> AFTER DELETE trigger.
    await database.upsertWorkspace(
      identity: makeIdentity(root: root), roots: [root], documents: [keep])

    let rows = try fetchSearchIndexRows(at: databaseURL)
    XCTAssertEqual(rows.map(\.path), [keep.url.standardizedFileURL.path])
    // The FTS row is gone, not merely hidden by the search join.
    XCTAssertTrue(database.search(query: "nebula", documents: [keep, drop]).isEmpty)
  }

  // MARK: - Double-write collapse

  func testNoDuplicateFTSRowsAfterDocumentsWriteAndReindex() async throws {
    let (database, databaseURL, root) = try makeWorkspace()
    let a = try makeDoc(root: root, name: "a.md", body: "alpha body text")
    let b = try makeDoc(root: root, name: "b.md", body: "bravo body text")

    // Cold-scan order: documents write (triggers fire) THEN reindex.
    await database.upsertWorkspace(
      identity: makeIdentity(root: root), roots: [root], documents: [a, b])
    await database.reindexInBackground(documents: [a, b])

    XCTAssertEqual(try fetchDuplicatePaths(at: databaseURL), [])
    let rows = try fetchSearchIndexRows(at: databaseURL)
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(Set(rows.map(\.isAdHoc)), [false])

    XCTAssertEqual(
      database.search(query: "alpha", documents: [a, b]).map(\.document.id),
      [a.url.standardizedFileURL])
  }

  // MARK: - Ad-hoc preservation

  func testAdHocIndexedDocRemainsSearchableWithWorkspaceDocs() async throws {
    let (database, databaseURL, root) = try makeWorkspace()
    let workspaceDoc = try makeDoc(root: root, name: "ws.md", body: "workspace zonk content")
    await database.upsertWorkspace(
      identity: makeIdentity(root: root), roots: [root], documents: [workspaceDoc])

    // Ad-hoc doc opened outside the workspace — NOT in the `documents` table.
    let adHocURL = root.appendingPathComponent("scratch.md")
    try "adhoc plutonium content".write(to: adHocURL, atomically: true, encoding: .utf8)
    let adHocRef = DocumentRef(id: adHocURL.standardizedFileURL, isAdHoc: true)
    // Awaiting the off-main twin is the write-completion sync point (it returns after the detached
    // `pool.write` commits), so the synchronous asserts below see the ad-hoc row.
    await database.indexInBackground(document: adHocRef, body: "adhoc plutonium content")

    let documents = [workspaceDoc, adHocRef]
    XCTAssertEqual(
      database.search(query: "plutonium", documents: documents).map(\.document.id),
      [adHocURL.standardizedFileURL])
    XCTAssertEqual(
      database.search(query: "zonk", documents: documents).map(\.document.id),
      [workspaceDoc.url.standardizedFileURL])
    XCTAssertEqual(try fetchDuplicatePaths(at: databaseURL), [])

    // The workspace row is trigger-owned (is_ad_hoc=0); the ad-hoc row isn't.
    let rows = try fetchSearchIndexRows(at: databaseURL)
    XCTAssertEqual(
      Dictionary(uniqueKeysWithValues: rows.map { ($0.path, $0.isAdHoc) }),
      [
        workspaceDoc.url.standardizedFileURL.path: false,
        adHocURL.standardizedFileURL.path: true,
      ])
  }

  // MARK: - Semantic preservation

  func testTriggerPathPreservesSearchSemanticsVersusInlinePath() async throws {
    // Fixed corpus WITHOUT H1 headings so documents.title falls back to the
    // DocumentRef title (filename) — identical to the inline path's FTS title —
    // and queries resolve to distinct scores so updated_at is not a tiebreaker.
    let corpus = [
      ("apex.md", "the quick brown fox apex marker"),
      ("delta.md", "lazy dog delta apex tail"),
      ("gamma.md", "gamma metric tensor field"),
    ]
    let queries = ["apex", "gamma", "tensor", "fox", "missing"]

    // Path A — NEW trigger-driven path (documents populated, reindex collapses).
    let triggered = try makeWorkspace()
    let triggeredRefs = try corpus.map {
      try makeDoc(root: triggered.root, name: $0.0, body: $0.1)
    }
    await triggered.database.upsertWorkspace(
      identity: makeIdentity(root: triggered.root), roots: [triggered.root],
      documents: triggeredRefs)
    await triggered.database.reindexInBackground(documents: triggeredRefs)

    // Path B — OLD inline path (documents table EMPTY -> reindex writes every row).
    let inline = try makeWorkspace()
    let inlineRefs = try corpus.map {
      try makeDoc(root: inline.root, name: $0.0, body: $0.1)
    }
    inline.database.reindex(documents: inlineRefs)

    for query in queries {
      let triggeredResults = triggered.database.search(query: query, documents: triggeredRefs)
      let inlineResults = inline.database.search(query: query, documents: inlineRefs)
      // Compare by relative identity (roots differ) + matchKind + snippet presence.
      let triggeredShape = triggeredResults.map {
        "\($0.displayPath)|\($0.matchKind)|\($0.score)|\($0.snippet != nil)"
      }
      let inlineShape = inlineResults.map {
        "\($0.displayPath)|\($0.matchKind)|\($0.score)|\($0.snippet != nil)"
      }
      XCTAssertEqual(
        triggeredShape, inlineShape,
        "result set / order diverged for query \"\(query)\"")
    }
  }
}
