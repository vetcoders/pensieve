import Foundation
import GRDB

@MainActor
final class IndexDatabase {
  static let shared = IndexDatabase()

  private var databasePool: DatabasePool?
  private(set) var databaseURL: URL?
  private let configuredDatabaseURL: URL?
  private let searchIndexBatchSize: Int
  private let didInsertSearchIndexBatch: (@Sendable (Int) -> Void)?

  /// Tracks the in-flight background index write (full reindex OR incremental
  /// delta apply). Each new background update chains onto this task before
  /// starting its own `pool.write`, so writes are serialized in submission
  /// order: a newer delta cannot start until the prior one has finished, and a
  /// stale update can never overwrite the rows a later one already wrote.
  /// Tests await it via `waitForPendingReindex()` instead of sleeping.
  private var pendingIndexUpdateTask: Task<Void, Never>?

  init(
    databaseURL: URL? = nil,
    searchIndexBatchSize: Int = 32,
    didInsertSearchIndexBatch: (@Sendable (Int) -> Void)? = nil
  ) {
    self.configuredDatabaseURL = databaseURL
    self.searchIndexBatchSize = max(1, searchIndexBatchSize)
    self.didInsertSearchIndexBatch = didInsertSearchIndexBatch
  }

  func open(into appState: AppState? = nil) {
    do {
      let url: URL
      if let configuredDatabaseURL {
        url = configuredDatabaseURL
      } else {
        let directory = try applicationSupportDirectory()
        url = directory.appendingPathComponent("index.db", isDirectory: false)
      }

      let directory = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

      let pool = try DatabasePool(path: url.path)

      var migrator = DatabaseMigrator()
      migrator.registerMigration("mvp_workspace_search_fts") { db in
        try db.execute(
          sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS workspace_search_documents
            USING fts5(
                path UNINDEXED,
                title,
                display_path,
                body,
                is_ad_hoc UNINDEXED,
                updated_at UNINDEXED,
                tokenize = 'unicode61'
            )
            """)
      }
      registerIndexV2Migrations(&migrator)
      try migrator.migrate(pool)

      databasePool = pool
      databaseURL = url
    } catch {
      let message = "Could not open Pensieve index database: \(error.localizedDescription)"
      appState?.lastError = message
      NSLog(message)
    }
  }

  /// B-2 IndexDatabase v2 schema (I-01, Wave A foundation).
  ///
  /// Registered AFTER `mvp_workspace_search_fts` so the existing FTS table is
  /// created first; the `b2_v2_*` namespace stays separate from the MVP
  /// migration for clarity. `DatabaseMigrator` runs each registered migration
  /// exactly once per database, so adding these alongside the MVP migration is
  /// idempotent by construction.
  ///
  /// Order matters: `documents` is created before the tables that FK to it
  /// (`document_revisions`, `document_chunks`), and `workspaces` before the
  /// tables that FK to it (`documents`, `scan_sessions`, `workspace_stats`).
  ///
  /// Active writers land in later waves — `workspaces`/`documents` in W-B-1
  /// (I-02), FTS5 content-link in W-C-1 (I-03), `scan_sessions`/
  /// `workspace_stats` in W-D-1 (I-04). `document_revisions` and
  /// `document_chunks` are scaffolding DDL only this wave (writers in H-1 and
  /// C-3 respectively). No FTS scaffolding migration is needed here — W-C-1
  /// owns the full FTS5 content-link rebuild as a self-contained migration.
  private func registerIndexV2Migrations(_ migrator: inout DatabaseMigrator) {
    migrator.registerMigration("b2_v2_workspaces") { db in
      try db.execute(
        sql: """
          CREATE TABLE workspaces (
              workspace_id TEXT PRIMARY KEY,
              canonical_path TEXT NOT NULL,
              volume_resource_id TEXT,
              bookmark_hash TEXT,
              first_seen_at INTEGER NOT NULL,
              last_seen_at INTEGER NOT NULL,
              status TEXT NOT NULL
          )
          """)
    }

    migrator.registerMigration("b2_v2_documents") { db in
      try db.execute(
        sql: """
          CREATE TABLE documents (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
              path TEXT NOT NULL,
              title TEXT NOT NULL,
              body TEXT NOT NULL,
              mtime INTEGER NOT NULL,
              size INTEGER NOT NULL,
              is_ad_hoc INTEGER NOT NULL,
              indexed_at INTEGER NOT NULL,
              UNIQUE(workspace_id, path)
          )
          """)
      try db.execute(sql: "CREATE INDEX idx_documents_workspace ON documents(workspace_id)")
      try db.execute(sql: "CREATE INDEX idx_documents_path ON documents(workspace_id, path)")
    }

    // Scaffolding DDL only; writer added in future H-1 version history pack.
    migrator.registerMigration("b2_v2_document_revisions") { db in
      try db.execute(
        sql: """
          CREATE TABLE document_revisions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              document_id INTEGER NOT NULL REFERENCES documents(id),
              revision_at INTEGER NOT NULL,
              body_hash TEXT NOT NULL
          )
          """)
    }

    // Scaffolding DDL only; chunker writer + embedding column added in future
    // C-3 vector layer pack.
    migrator.registerMigration("b2_v2_document_chunks") { db in
      try db.execute(
        sql: """
          CREATE TABLE document_chunks (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              document_id INTEGER NOT NULL REFERENCES documents(id),
              chunk_index INTEGER NOT NULL,
              chunk_text TEXT NOT NULL,
              chunk_hash TEXT NOT NULL
          )
          """)
    }

    migrator.registerMigration("b2_v2_scan_sessions") { db in
      try db.execute(
        sql: """
          CREATE TABLE scan_sessions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              workspace_id TEXT NOT NULL REFERENCES workspaces(workspace_id),
              started_at INTEGER NOT NULL,
              finished_at INTEGER,
              trigger TEXT NOT NULL,
              scanner_version INTEGER NOT NULL,
              fingerprint_hash TEXT,
              file_count INTEGER,
              folder_count INTEGER,
              duration_ms INTEGER
          )
          """)
      try db.execute(
        sql: "CREATE INDEX idx_scan_sessions_workspace ON scan_sessions(workspace_id, started_at)")
    }

    migrator.registerMigration("b2_v2_workspace_stats") { db in
      try db.execute(
        sql: """
          CREATE TABLE workspace_stats (
              workspace_id TEXT PRIMARY KEY REFERENCES workspaces(workspace_id),
              file_count INTEGER NOT NULL,
              folder_count INTEGER NOT NULL,
              last_scan_at INTEGER,
              last_indexed_at INTEGER,
              index_health TEXT NOT NULL
          )
          """)
    }

    // I-03 (W-C-1) v1 (RETIRED by `b2_v2_external_content_fts` below): the
    // original documents->`workspace_search_documents` mirroring triggers. KEPT
    // REGISTERED (not deleted) so the applied-migration history is preserved on
    // the operator's existing DB (DatabaseMigrator keys migrations by identifier;
    // removing this one would orphan its recorded identifier). On a FRESH DB it
    // recreates these triggers and the next migration immediately drops them
    // (wasteful but correct); on the operator's DB it was already applied and is
    // a no-op. The CONTENTFUL `workspace_search_documents` table itself is
    // created by the MVP `mvp_workspace_search_fts` migration and retired in the
    // external-content migration below.
    migrator.registerMigration("b2_v2_fts_documents_triggers") { db in
      try db.execute(
        sql: """
          CREATE TRIGGER documents_after_insert_fts
          AFTER INSERT ON documents
          WHEN NEW.is_ad_hoc = 0
          BEGIN
              DELETE FROM workspace_search_documents
               WHERE path = (
                   SELECT canonical_path FROM workspaces
                    WHERE workspace_id = NEW.workspace_id
               ) || '/' || NEW.path;
              INSERT INTO workspace_search_documents
                  (path, title, display_path, body, is_ad_hoc, updated_at)
              VALUES (
                  (SELECT canonical_path FROM workspaces
                    WHERE workspace_id = NEW.workspace_id) || '/' || NEW.path,
                  NEW.title,
                  NEW.path,
                  NEW.body,
                  NEW.is_ad_hoc,
                  NEW.mtime
              );
          END
          """)
      try db.execute(
        sql: """
          CREATE TRIGGER documents_after_update_fts
          AFTER UPDATE OF body, title, mtime ON documents
          WHEN NEW.is_ad_hoc = 0
          BEGIN
              DELETE FROM workspace_search_documents
               WHERE path = (
                   SELECT canonical_path FROM workspaces
                    WHERE workspace_id = OLD.workspace_id
               ) || '/' || OLD.path;
              INSERT INTO workspace_search_documents
                  (path, title, display_path, body, is_ad_hoc, updated_at)
              VALUES (
                  (SELECT canonical_path FROM workspaces
                    WHERE workspace_id = NEW.workspace_id) || '/' || NEW.path,
                  NEW.title,
                  NEW.path,
                  NEW.body,
                  NEW.is_ad_hoc,
                  NEW.mtime
              );
          END
          """)
      try db.execute(
        sql: """
          CREATE TRIGGER documents_after_delete_fts
          AFTER DELETE ON documents
          WHEN OLD.is_ad_hoc = 0
          BEGIN
              DELETE FROM workspace_search_documents
               WHERE path = (
                   SELECT canonical_path FROM workspaces
                    WHERE workspace_id = OLD.workspace_id
               ) || '/' || OLD.path;
          END
          """)
    }

    // I-03 (W-C-1) v2: EXTERNAL-CONTENT FTS5 over `documents`.
    //
    // STAGE 1 (external-content FTS): `documents` is the SINGLE source of truth
    // for every searchable row — workspace docs AND ad-hoc out-of-workspace docs
    // (the latter live under the reserved `__adhoc__` workspace, see below).
    // `document_fts` is an external-content FTS5 index over `documents`: it
    // stores ONLY the inverted index, never the body text (the old contentful
    // `workspace_search_documents` stored the full body, doubling on-disk size
    // since `documents.body` already holds it). The FTS rowid IS `documents.id`
    // (an INTEGER PRIMARY KEY alias for the SQLite rowid), so a search joins
    // `document_fts.rowid = documents.id` and reads title/display_path/body and
    // the workspace scope directly from `documents`.
    //
    // Column mapping (matches the prior FTS columns the search reads):
    //   title <- documents.title, display_path <- documents.path,
    //   body <- documents.body. `is_ad_hoc`/`updated_at`/full-`path` are NOT FTS
    //   columns anymore — they are read from `documents` (is_ad_hoc, mtime) and
    //   reconstructed (full path = canonical_path || '/' || path for workspace
    //   docs, or `path` verbatim for ad-hoc) in the search SQL.
    //
    // Tokenizer: `unicode61` with the default `remove_diacritics = 1` — byte-for-
    // byte the same tokenize spec the old `workspace_search_documents` used, so
    // tokenization (and therefore MATCH/bm25 hit sets) is identical.
    // `columnsize=0`: we never need per-column sizes (bm25 with default weights
    // does not require them here), which shrinks the index further.
    //
    // The three triggers below follow the canonical FTS5 external-content
    // contract (sqlite.org/fts5.html): AFTER INSERT inserts (rowid, cols); AFTER
    // DELETE / AFTER UPDATE issue the special `'delete'` command with the OLD
    // column values so the inverted-index entries for the removed document are
    // located and removed (the delete command REQUIRES the original text the row
    // held — `old.*` provides exactly that). They fire for ALL documents rows
    // (workspace + ad-hoc): every `documents` row is searchable, scoped in SQL.
    //
    // The migration is registered AFTER `b2_v2_documents` (the content table must
    // exist first) and is idempotent by construction (DatabaseMigrator runs it
    // once per DB). On an EXISTING populated DB it: (1) reserves the `__adhoc__`
    // workspace, (2) backfills `documents` from the legacy contentful FTS for any
    // body that lived ONLY in `workspace_search_documents` (ad-hoc rows, and any
    // legacy inline-indexed row not in `documents`) so nothing searchable is
    // lost, (3) creates `document_fts` + triggers + `'rebuild'` backfill from
    // `documents`, then (4) RETIRES the old contentful table and its triggers.
    migrator.registerMigration("b2_v2_external_content_fts") { db in
      // (1) Reserved sentinel workspace for ad-hoc / out-of-workspace docs so they
      // satisfy `documents.workspace_id NOT NULL REFERENCES workspaces`. Empty
      // canonical_path: ad-hoc `documents.path` is the FULL standardized path, so
      // the search full-path reconstruction uses `path` verbatim for them. Created
      // LAZILY — only when the legacy FTS holds rows that will be migrated as
      // ad-hoc (step 2) — so a DB with no ad-hoc docs keeps a clean `workspaces`
      // table. At runtime `ensureWorkspaceRow` re-creates it on the first ad-hoc
      // write. (DROP TABLE on the legacy FTS happens AFTER the backfill below.)
      let legacyAdHocCount =
        (try? Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM workspace_search_documents f
            WHERE NOT EXISTS (
                SELECT 1 FROM documents d
                JOIN workspaces w ON w.workspace_id = d.workspace_id
                WHERE w.canonical_path || '/' || d.path = f.path
            )
            """)) ?? 0
      if legacyAdHocCount > 0 {
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO workspaces
                (workspace_id, canonical_path, volume_resource_id, bookmark_hash,
                 first_seen_at, last_seen_at, status)
            VALUES (?, '', NULL, NULL, 0, 0, 'adhoc')
            """,
          arguments: [Self.adHocWorkspaceID])
      }

      // (2) Migrate any body that lived ONLY in the legacy contentful FTS into
      // `documents` so it stays searchable under external content. This covers
      // ad-hoc rows (never in `documents`) and any legacy inline-indexed
      // workspace row that predates the documents writer. Workspace rows already
      // in `documents` (matched by reconstructed full path) are skipped — their
      // body is authoritative in `documents` already.
      //
      // The legacy `path` column is the FULL standardized path. A row maps to an
      // existing workspace doc when `canonical_path || '/' || documents.path`
      // equals it; otherwise it is treated as ad-hoc and inserted under the
      // sentinel workspace with `path` = the full path. `mtime`/`size` come from
      // the legacy `updated_at` (best-effort; size is the body byte length).
      // `INSERT OR IGNORE` + `GROUP BY f.path` keep the migration safe on a messy
      // operator DB: any legacy duplicate full path (or a collision with the
      // reserved workspace's `UNIQUE(workspace_id, path)`) is collapsed instead
      // of aborting the migration.
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO documents
              (workspace_id, path, title, body, mtime, size, is_ad_hoc, indexed_at)
          SELECT
              ?,
              f.path,
              f.title,
              f.body,
              CAST(f.updated_at AS INTEGER),
              length(f.body),
              1,
              CAST(f.updated_at AS INTEGER)
          FROM workspace_search_documents f
          WHERE NOT EXISTS (
              SELECT 1 FROM documents d
              JOIN workspaces w ON w.workspace_id = d.workspace_id
              WHERE w.canonical_path || '/' || d.path = f.path
          )
          GROUP BY f.path
          """,
        arguments: [Self.adHocWorkspaceID])

      // (3) External-content FTS5 index over `documents`, then triggers + rebuild.
      // FTS5 external content reads the indexed columns from the content table BY
      // NAME (the 'rebuild' command + implicit reads issue `SELECT id, <fts cols>
      // FROM documents`), so the FTS column names MUST match `documents` columns:
      // title, path (the workspace-relative or full ad-hoc path; the old
      // contentful table's separate `display_path` is reconstructed at search
      // time), body. is_ad_hoc / mtime / workspace scope are read from
      // `documents`, not indexed.
      try db.execute(
        sql: """
          CREATE VIRTUAL TABLE document_fts USING fts5(
              title,
              path,
              body,
              content='documents',
              content_rowid='id',
              columnsize=0,
              tokenize='unicode61'
          )
          """)
      try db.execute(
        sql: """
          CREATE TRIGGER documents_ai AFTER INSERT ON documents BEGIN
              INSERT INTO document_fts(rowid, title, path, body)
              VALUES (new.id, new.title, new.path, new.body);
          END
          """)
      try db.execute(
        sql: """
          CREATE TRIGGER documents_ad AFTER DELETE ON documents BEGIN
              INSERT INTO document_fts(document_fts, rowid, title, path, body)
              VALUES ('delete', old.id, old.title, old.path, old.body);
          END
          """)
      try db.execute(
        sql: """
          CREATE TRIGGER documents_au AFTER UPDATE ON documents BEGIN
              INSERT INTO document_fts(document_fts, rowid, title, path, body)
              VALUES ('delete', old.id, old.title, old.path, old.body);
              INSERT INTO document_fts(rowid, title, path, body)
              VALUES (new.id, new.title, new.path, new.body);
          END
          """)
      // Backfill the inverted index from every existing `documents` row.
      try db.execute(sql: "INSERT INTO document_fts(document_fts) VALUES('rebuild')")

      // (4) Retire the legacy contentful FTS + its documents-mirroring triggers.
      // After this the body text lives ONLY in `documents.body`; `document_fts`
      // holds no body. Triggers may not exist on a fresh DB — DROP IF EXISTS.
      try db.execute(sql: "DROP TRIGGER IF EXISTS documents_after_insert_fts")
      try db.execute(sql: "DROP TRIGGER IF EXISTS documents_after_update_fts")
      try db.execute(sql: "DROP TRIGGER IF EXISTS documents_after_delete_fts")
      try db.execute(sql: "DROP TABLE IF EXISTS workspace_search_documents")
    }
  }

  /// Reserved workspace_id under which ad-hoc / out-of-workspace open files live
  /// in `documents`, so they satisfy the `workspace_id NOT NULL REFERENCES
  /// workspaces` FK while staying searchable. Their `documents.path` is the FULL
  /// standardized URL path (they have no workspace-relative path); the search
  /// full-path reconstruction uses that verbatim (canonical_path is empty).
  nonisolated static let adHocWorkspaceID = "__adhoc__"

  func reindex(documents: [DocumentRef], appState: AppState? = nil) {
    guard let pool = ensureOpen(into: appState) else { return }
    reindex(documents: documents, pool: pool, appState: appState)
  }

  /// Returns `true` when the off-main FTS write committed, `false` when it threw (the error is
  /// still reported to the user via `report(...)`). Callers gate the on-disk `.md` search
  /// signature persist on this result so a FAILED write never leaves a signature claiming the
  /// index is current — which would make the next cold-start skip-gate silently skip over a
  /// stale/partial index. The result is discardable for callers that do not persist a signature.
  ///
  /// The `pendingIndexUpdateTask` chain returns `Void` (its supersede contract is unchanged); the
  /// success flag is observed by awaiting the dedicated `write` task this call owns.
  @discardableResult
  func reindexInBackground(documents: [DocumentRef], appState: AppState? = nil) async -> Bool {
    guard let pool = ensureOpen(into: appState) else { return false }
    let batchSize = searchIndexBatchSize
    let didInsertBatch = didInsertSearchIndexBatch
    let previous = pendingIndexUpdateTask

    let write = Task { [weak self] () -> Bool in
      await previous?.value
      do {
        try await Task.detached(priority: .utility) {
          try Self.replaceSearchIndex(
            with: documents,
            pool: pool,
            batchSize: batchSize,
            didInsertBatch: didInsertBatch
          )
        }.value
        self?.refreshSearchResults(in: appState)
        return true
      } catch {
        self?.report(error, appState: appState, action: "rebuild Pensieve search index")
        return false
      }
    }
    // Keep the supersede chain `Void`-typed: a later update awaits "the prior write finished",
    // not its boolean result.
    pendingIndexUpdateTask = Task { _ = await write.value }
    return await write.value
  }

  private func reindex(documents: [DocumentRef], pool: DatabasePool, appState: AppState?) {
    do {
      try Self.replaceSearchIndex(
        with: documents,
        pool: pool,
        batchSize: searchIndexBatchSize,
        didInsertBatch: didInsertSearchIndexBatch
      )
      refreshSearchResults(in: appState)
    } catch {
      report(error, appState: appState, action: "rebuild Pensieve search index")
    }
  }

  /// Awaits the in-flight background index write (full reindex OR incremental
  /// delta apply) so tests can drive `updateSearchIndexInBackground` /
  /// `reindexInBackground` deterministically without sleeping. Returns
  /// immediately when nothing is pending.
  func waitForPendingReindex() async {
    await pendingIndexUpdateTask?.value
  }

  /// Synchronous incremental index update: re-upsert each `upserting` doc
  /// (reading its body from disk) and delete the FTS rows for each `deletingPaths`
  /// entry, all inside a single serialized `pool.write` transaction. The update
  /// is proportional to the CHANGE, not to the workspace size — only the
  /// supplied docs/paths are touched; every other FTS row is left intact.
  ///
  /// Per-doc upsert mirrors `index(document:body:)` (DELETE-by-path + INSERT) so
  /// a modified doc's stale row is replaced and a brand-new doc is added.
  /// `deletingPaths` are the FULL standardized paths (== the search join key /
  /// the FTS `path` column) of removed files.
  ///
  /// Used by the explicit one-shot callers (file create/exclusion edits, tests).
  /// The watcher path uses `updateSearchIndexInBackground` so the body reads +
  /// write run off the main actor.
  func updateSearchIndex(
    upserting documents: [DocumentRef],
    deletingPaths: [String],
    appState: AppState? = nil
  ) {
    guard let pool = ensureOpen(into: appState) else { return }
    do {
      try Self.applySearchIndexDelta(
        upserting: documents,
        deletingPaths: deletingPaths,
        pool: pool,
        batchSize: searchIndexBatchSize,
        didInsertBatch: didInsertSearchIndexBatch
      )
      refreshSearchResults(in: appState)
    } catch {
      report(error, appState: appState, action: "update Pensieve search index")
    }
  }

  /// Off-main incremental index update mirroring `reindexInBackground`'s
  /// detached/`.utility`/batched pattern. The body reads + the single
  /// `pool.write` transaction run on a detached background task; only the
  /// `appState`-touching search refresh hops back to the main actor.
  ///
  /// Supersede-safe: each call chains onto `pendingIndexUpdateTask` before it
  /// starts its own write, so concurrent updates are serialized in submission
  /// order. GRDB already serializes `pool.write`; the chaining additionally
  /// guarantees a stale delta cannot land AFTER a newer one. Because the apply
  /// runs in one transaction, a cancelled/failed update either commits wholly or
  /// not at all — it can never leave the FTS index half-written.
  ///
  /// Returns `true` when the off-main delta write committed, `false` when it threw (still
  /// reported). Mirrors `reindexInBackground`: callers persist the on-disk `.md` signature ONLY on
  /// `true`, so a failed delta never advances the persisted cross-launch baseline. Discardable for
  /// non-persisting callers.
  @discardableResult
  func updateSearchIndexInBackground(
    upserting documents: [DocumentRef],
    deletingPaths: [String],
    appState: AppState? = nil
  ) async -> Bool {
    guard let pool = ensureOpen(into: appState) else { return false }
    let batchSize = searchIndexBatchSize
    let didInsertBatch = didInsertSearchIndexBatch
    let previous = pendingIndexUpdateTask

    let write = Task { [weak self] () -> Bool in
      await previous?.value
      do {
        try await Task.detached(priority: .utility) {
          try Self.applySearchIndexDelta(
            upserting: documents,
            deletingPaths: deletingPaths,
            pool: pool,
            batchSize: batchSize,
            didInsertBatch: didInsertBatch
          )
        }.value
        self?.refreshSearchResults(in: appState)
        return true
      } catch {
        self?.report(error, appState: appState, action: "update Pensieve search index")
        return false
      }
    }
    // Supersede chain stays `Void`-typed (see `reindexInBackground`).
    pendingIndexUpdateTask = Task { _ = await write.value }
    return await write.value
  }

  /// Cheap content guard for the cold-open skip decision: how many indexed
  /// documents already live under any of `rootPaths`. The cold-open path must
  /// NEVER skip the reindex when the index is empty/missing for this workspace
  /// (e.g. after the operator nuked Application Support) — a non-zero count here
  /// is the proof that skipping is safe. Counts `documents` rows (the single
  /// source of truth post-external-content migration) whose RECONSTRUCTED full
  /// path (`canonical_path || '/' || path`) is a descendant of a root
  /// (`<root>/…`). Returns 0 when the index cannot be opened (treated as empty →
  /// caller full-reindexes).
  func indexedDocumentCount(forRootPaths rootPaths: [String], appState: AppState? = nil) -> Int {
    guard !rootPaths.isEmpty, let pool = ensureOpen(into: appState) else { return 0 }
    do {
      return try pool.read { db in
        var total = 0
        for rootPath in rootPaths {
          let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
          let count =
            try Int.fetchOne(
              db,
              sql: """
                SELECT COUNT(*) FROM documents d
                JOIN workspaces w ON w.workspace_id = d.workspace_id
                WHERE (w.canonical_path || '/' || d.path) LIKE ? ESCAPE '\\'
                """,
              arguments: [Self.likePrefixPattern(prefix) + "%"]
            ) ?? 0
          total += count
        }
        return total
      }
    } catch {
      report(error, appState: appState, action: "count Pensieve search index rows")
      return 0
    }
  }

  /// Escapes LIKE wildcards (`%`, `_`) and the escape char itself in a literal path prefix so a
  /// path containing them cannot widen the match. Pairs with `ESCAPE '\\'` in the query.
  private nonisolated static func likePrefixPattern(_ prefix: String) -> String {
    var escaped = ""
    escaped.reserveCapacity(prefix.count)
    for character in prefix {
      if character == "\\" || character == "%" || character == "_" {
        escaped.append("\\")
      }
      escaped.append(character)
    }
    return escaped
  }

  /// Single-doc index entry (autosave tail, ad-hoc open files). Writes the doc as
  /// a `documents` row — the single FTS source — so the AI/AU triggers sync
  /// `document_fts`. An ad-hoc / rootless doc lands under the reserved
  /// `__adhoc__` workspace (full standardized path as its `documents.path`); a
  /// workspace doc lands under its own workspace row (relative path). The body is
  /// provided by the caller (the live editor text) rather than re-read from disk.
  func index(document: DocumentRef, body: String, appState: AppState? = nil) {
    guard let pool = ensureOpen(into: appState) else { return }
    let record = Self.documentWriteRecord(from: document, body: body)

    do {
      try pool.write { db in
        try Self.ensureWorkspaceRow(for: record, in: db)
        try Self.upsertDocument(record, in: db)
      }
      refreshSearchResults(in: appState)
    } catch {
      report(error, appState: appState, action: "update Pensieve search index")
    }
  }

  func searchInBackground(
    query: String,
    documents: [DocumentRef],
    limit: Int = 50,
    appState: AppState? = nil
  ) async -> [WorkspaceSearchResult] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return [] }
    guard let pool = ensureOpen(into: appState) else { return [] }

    do {
      return try await Task.detached(priority: .userInitiated) {
        try Self.performSearch(
          query: trimmedQuery,
          documents: documents,
          limit: limit,
          pool: pool
        )
      }.value
    } catch {
      report(error, appState: appState, action: "search Pensieve index")
      return []
    }
  }

  func refreshSearchResults(in appState: AppState?) {
    guard let appState else { return }
    appState.workspaceSearchResults = search(
      query: appState.workspaceSearchQuery,
      documents: appState.allDocuments,
      appState: appState
    )
  }

  func search(
    query: String,
    documents: [DocumentRef],
    limit: Int = 50,
    appState: AppState? = nil
  ) -> [WorkspaceSearchResult] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return [] }
    guard let pool = ensureOpen(into: appState) else { return [] }

    do {
      return try Self.performSearch(
        query: trimmedQuery,
        documents: documents,
        limit: limit,
        pool: pool
      )
    } catch {
      report(error, appState: appState, action: "search Pensieve index")
      return []
    }
  }

  func upsertWorkspace(
    identity: WorkspaceIdentity,
    roots: [URL],
    lastSeenAt: Date = Date(),
    documents: [DocumentRef],
    appState: AppState? = nil
  ) async {
    guard let pool = ensureOpen(into: appState) else { return }
    let didInsertBatch = didInsertSearchIndexBatch
    let batchSize = searchIndexBatchSize

    do {
      let records = await Task.detached(priority: .utility) {
        documents.compactMap(Self.documentRecord)
      }.value
      guard
        databaseURL.map({ FileManager.default.fileExists(atPath: $0.path) }) ?? true
      else {
        return
      }
      try await Task.detached(priority: .utility) {
        try pool.write { db in
          try Self.upsertWorkspace(identity: identity, roots: roots, lastSeenAt: lastSeenAt, in: db)
          // `commitWorkspaceManifest` is the cold-scan `documents` writer, and
          // `documents` is now the single FTS source. Count each row this write
          // actually (re)indexes — inserted or content-changed — so the
          // didInsertBatch observability reflects the indexing work on this path
          // too (the cold-open reindex that follows skips these already-written
          // rows). Unchanged rows are not counted, so a no-change re-commit
          // reports 0 (matching the prior contract where reindex skipped them).
          try Self.upsertDocuments(
            records: records,
            workspaceID: identity.workspaceID,
            indexedAt: lastSeenAt,
            batchSize: batchSize,
            didInsertBatch: didInsertBatch,
            in: db
          )
          try Self.tombstoneDocumentsNotIn(
            paths: records.map(\.path),
            workspaceID: identity.workspaceID,
            in: db
          )
        }
      }.value
    } catch {
      report(error, appState: appState, action: "update Pensieve workspace index")
    }
  }

  private func applicationSupportDirectory() throws -> URL {
    try FileManager.default
      .url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      .appendingPathComponent("Pensieve", isDirectory: true)
  }

  private func ensureOpen(into appState: AppState?) -> DatabasePool? {
    if databasePool == nil {
      open(into: appState)
    }
    return databasePool
  }

  /// Full reindex, documents-as-source. Resolves every `DocumentRef` to a
  /// `documents` row (workspace docs under their own workspace_id + relative
  /// path; ad-hoc / rootless docs under the reserved `__adhoc__` workspace + full
  /// path), upserts each, then tombstones the documents in the TOUCHED workspaces
  /// that are no longer present. The AI/AU/AD triggers keep `document_fts` in
  /// sync — no body is ever written into the FTS. Runs in a single `pool.write`
  /// transaction (commits wholly or not at all).
  ///
  /// `didInsertBatch` fires per batch of ACTUALLY-WRITTEN upserts. A doc whose
  /// existing `documents` row already byte-matches (same title/body/mtime/size)
  /// is skipped and NOT counted — this preserves the cold-open skip semantics
  /// (a re-reindex of an unchanged, already-populated index writes ZERO records)
  /// and collapses the double-write when `commitWorkspaceManifest` already wrote
  /// the same rows. A doc whose body cannot be read from disk is skipped
  /// entirely (never write a partial record).
  ///
  /// Tombstoning is scoped to the workspaces this reindex touched, so an
  /// unrelated workspace's rows (and the `__adhoc__` rows when reindexing a
  /// workspace) are never collected. The cold/refresh callers only ever pass a
  /// single workspace's docs (plus ad-hoc open files), so this matches the prior
  /// "clear-and-rebuild the non-trigger-owned set" scope.
  private nonisolated static func replaceSearchIndex(
    with documents: [DocumentRef],
    pool: DatabasePool,
    batchSize: Int,
    didInsertBatch: (@Sendable (Int) -> Void)?
  ) throws {
    let records = documents.compactMap { documentWriteRecord(from: $0) }

    try pool.write { db in
      // Workspaces represented in this reindex (so tombstoning is scoped to them),
      // each mapped to its REAL canonical_path so the search full-path
      // reconstruction (canonical_path || '/' || path) is correct.
      var canonicalByWorkspace: [String: String] = [:]
      for record in records where canonicalByWorkspace[record.workspaceID] == nil {
        canonicalByWorkspace[record.workspaceID] = record.canonicalPath
      }
      let touchedWorkspaces = Set(canonicalByWorkspace.keys)
      for (workspaceID, canonicalPath) in canonicalByWorkspace {
        try ensureWorkspaceRow(workspaceID: workspaceID, canonicalPath: canonicalPath, in: db)
      }

      var batch: [DocumentWriteRecord] = []
      batch.reserveCapacity(batchSize)
      var keptPathsByWorkspace: [String: Set<String>] = [:]

      for record in records {
        keptPathsByWorkspace[record.workspaceID, default: []].insert(record.path)
        // Skip the write (and the count) when the stored row already matches —
        // the unchanged-relaunch / double-write-collapse case.
        if try existingDocumentMatches(record, in: db) {
          continue
        }
        batch.append(record)
        if batch.count == batchSize {
          try upsertDocuments(batch, in: db)
          didInsertBatch?(batch.count)
          batch.removeAll(keepingCapacity: true)
        }
      }
      if !batch.isEmpty {
        try upsertDocuments(batch, in: db)
        didInsertBatch?(batch.count)
      }

      // Tombstone removed docs ONLY within the workspaces this reindex covered.
      for workspaceID in touchedWorkspaces {
        try tombstoneDocumentsNotIn(
          paths: Array(keptPathsByWorkspace[workspaceID] ?? []),
          workspaceID: workspaceID,
          in: db)
      }
    }
  }

  /// Incremental apply, documents-as-source: upserts ONLY the supplied docs and
  /// deletes ONLY the `deletingPaths`, leaving every other `documents` row (and
  /// thus FTS row) intact. Single `pool.write` transaction — commits wholly or
  /// not at all. The triggers sync `document_fts`.
  ///
  /// `deletingPaths` are FULL standardized URL paths (the prior search join key).
  /// They are resolved back to `documents` rows by matching the reconstructed
  /// full path (`canonical_path || '/' || path`) for workspace docs OR the
  /// verbatim `path` for ad-hoc rows. Deleting the `documents` row fires the AD
  /// trigger, removing the FTS entry.
  ///
  /// `didInsertBatch` fires per upsert batch (same batching contract as
  /// `replaceSearchIndex`). A pure removal upserts nothing → 0 counted, matching
  /// the prior behaviour.
  private nonisolated static func applySearchIndexDelta(
    upserting documents: [DocumentRef],
    deletingPaths: [String],
    pool: DatabasePool,
    batchSize: Int,
    didInsertBatch: (@Sendable (Int) -> Void)?
  ) throws {
    // Read bodies off the write transaction so a slow/failed disk read can't
    // hold the write lock open. A doc whose body cannot be read is skipped.
    let records = documents.compactMap { documentWriteRecord(from: $0) }

    try pool.write { db in
      for fullPath in deletingPaths {
        try deleteDocumentByFullPath(fullPath, in: db)
      }

      var batch: [DocumentWriteRecord] = []
      batch.reserveCapacity(batchSize)
      for record in records {
        try ensureWorkspaceRow(for: record, in: db)
        // Skip (and don't count) a doc whose stored row already byte-matches —
        // e.g. the cold-open flow where `commitWorkspaceManifest` already wrote
        // the changed docs before this delta runs (the double-write collapse).
        // A genuine delta (watcher/refresh) almost always sees a real change, so
        // this only suppresses redundant re-writes.
        if try existingDocumentMatches(record, in: db) {
          continue
        }
        batch.append(record)
        if batch.count == batchSize {
          try upsertDocuments(batch, in: db)
          didInsertBatch?(batch.count)
          batch.removeAll(keepingCapacity: true)
        }
      }
      if !batch.isEmpty {
        try upsertDocuments(batch, in: db)
        didInsertBatch?(batch.count)
      }
    }
  }

  /// Deletes the `documents` row whose RECONSTRUCTED full path matches `fullPath`
  /// — a workspace doc (`canonical_path || '/' || path`) or an ad-hoc row (the
  /// `__adhoc__` workspace, where `path` IS the full standardized path). The AD
  /// trigger removes the matching `document_fts` entry.
  private nonisolated static func deleteDocumentByFullPath(_ fullPath: String, in db: Database)
    throws
  {
    try db.execute(
      sql: """
        DELETE FROM documents
        WHERE id IN (
            SELECT d.id FROM documents d
            JOIN workspaces w ON w.workspace_id = d.workspace_id
            WHERE (w.canonical_path || '/' || d.path) = ?
               OR (d.workspace_id = ? AND d.path = ?)
        )
        """,
      arguments: [fullPath, Self.adHocWorkspaceID, fullPath])
  }

  /// True when the stored `documents` row for `(workspace_id, path)` already
  /// byte-matches the candidate (title/body/mtime/size) — i.e. an upsert would be
  /// a no-op. Used by `replaceSearchIndex` to skip (and not count) unchanged docs.
  private nonisolated static func existingDocumentMatches(
    _ record: DocumentWriteRecord, in db: Database
  ) throws -> Bool {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT title, body, mtime, size FROM documents
        WHERE workspace_id = ? AND path = ? LIMIT 1
        """,
      arguments: [record.workspaceID, record.path])
    guard let row else { return false }
    return (row["title"] as String) == record.title
      && (row["body"] as String) == record.body
      && (row["mtime"] as Int) == record.mtime
      && (row["size"] as Int) == record.size
  }

  /// Resolves a `DocumentRef` (+ on-disk body) to a `DocumentWriteRecord`. Returns
  /// nil when the body cannot be read (never write a partial record). Use the
  /// `body:` overload when the caller already holds the live text (autosave).
  private nonisolated static func documentWriteRecord(from document: DocumentRef)
    -> DocumentWriteRecord?
  {
    let url = document.url.standardizedFileURL
    guard let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return documentWriteRecord(from: document, body: body)
  }

  private nonisolated static func documentWriteRecord(from document: DocumentRef, body: String)
    -> DocumentWriteRecord
  {
    let url = document.url.standardizedFileURL
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let modifiedAt =
      values?.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
    let size = values?.fileSize ?? Data(body.utf8).count
    let title = title(fromMarkdown: body, fallback: document.title)

    // Workspace doc (scanned): under its own workspace_id + relative path.
    // Ad-hoc / rootless / explicitly ad-hoc: under the reserved __adhoc__
    // workspace with the FULL standardized path as `documents.path`.
    if !document.isAdHoc, let rootURL = document.rootURL {
      let identity = WorkspaceIdentity.make(rootURL: rootURL, bookmarkData: nil)
      let storedPath = document.relativePath ?? url.lastPathComponent
      return DocumentWriteRecord(
        workspaceID: identity.workspaceID,
        canonicalPath: identity.canonicalRootURL.path,
        path: storedPath,
        title: title,
        body: body,
        mtime: Int(modifiedAt),
        size: size,
        isAdHoc: false)
    }
    return DocumentWriteRecord(
      workspaceID: Self.adHocWorkspaceID,
      canonicalPath: "",
      path: url.path,
      title: title,
      body: body,
      mtime: Int(modifiedAt),
      size: size,
      isAdHoc: true)
  }

  /// Ensures the `workspaces` row exists for a write record (FK target). Ad-hoc
  /// records reference the reserved `__adhoc__` row (canonical_path ''); workspace
  /// records reference their own row, refreshing `canonical_path`/`last_seen_at`.
  private nonisolated static func ensureWorkspaceRow(
    for record: DocumentWriteRecord, in db: Database
  ) throws {
    if record.isAdHoc {
      try ensureWorkspaceRow(workspaceID: Self.adHocWorkspaceID, canonicalPath: "", in: db)
    } else {
      try ensureWorkspaceRow(
        workspaceID: record.workspaceID, canonicalPath: record.canonicalPath, in: db)
    }
  }

  /// Idempotently inserts a minimal `workspaces` row so `documents` writes satisfy
  /// the FK. `canonicalPath == nil` looks the path up from the record set (it is
  /// only nil in the reindex pre-pass where the per-record canonical path is
  /// applied by the subsequent upsert path-join); when a real path is supplied it
  /// is (re)written. The reserved `__adhoc__` row uses status 'adhoc'; real
  /// workspaces use 'active'. Never downgrades an existing row's canonical_path to
  /// a placeholder.
  private nonisolated static func ensureWorkspaceRow(
    workspaceID: String, canonicalPath: String?, in db: Database
  ) throws {
    let isAdHoc = workspaceID == Self.adHocWorkspaceID
    let status = isAdHoc ? "adhoc" : "active"
    let now = Int(Date().timeIntervalSince1970)
    if let canonicalPath {
      try db.execute(
        sql: """
          INSERT INTO workspaces
              (workspace_id, canonical_path, volume_resource_id, bookmark_hash,
               first_seen_at, last_seen_at, status)
          VALUES (?, ?, NULL, NULL, ?, ?, ?)
          ON CONFLICT(workspace_id) DO UPDATE SET
              canonical_path = excluded.canonical_path,
              last_seen_at = excluded.last_seen_at
          """,
        arguments: [workspaceID, canonicalPath, now, now, status])
    } else {
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO workspaces
              (workspace_id, canonical_path, volume_resource_id, bookmark_hash,
               first_seen_at, last_seen_at, status)
          VALUES (?, '', NULL, NULL, ?, ?, ?)
          """,
        arguments: [workspaceID, now, now, status])
    }
  }

  private nonisolated static func upsertDocuments(
    _ records: [DocumentWriteRecord], in db: Database
  ) throws {
    for record in records {
      try upsertDocument(record, in: db)
    }
  }

  private nonisolated static func upsertDocument(_ record: DocumentWriteRecord, in db: Database)
    throws
  {
    let now = Int(Date().timeIntervalSince1970)
    try db.execute(
      sql: """
        INSERT INTO documents
            (workspace_id, path, title, body, mtime, size, is_ad_hoc, indexed_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(workspace_id, path) DO UPDATE SET
            title = excluded.title,
            body = excluded.body,
            mtime = excluded.mtime,
            size = excluded.size,
            is_ad_hoc = excluded.is_ad_hoc,
            indexed_at = excluded.indexed_at
        """,
      arguments: [
        record.workspaceID,
        record.path,
        record.title,
        record.body,
        record.mtime,
        record.size,
        record.isAdHoc ? 1 : 0,
        now,
      ])
  }

  private nonisolated static func upsertWorkspace(
    identity: WorkspaceIdentity,
    roots: [URL],
    lastSeenAt: Date,
    in db: Database
  ) throws {
    let timestamp = Int(lastSeenAt.timeIntervalSince1970)
    try db.execute(
      sql: """
        INSERT INTO workspaces
            (workspace_id, canonical_path, volume_resource_id, bookmark_hash,
             first_seen_at, last_seen_at, status)
        VALUES (?, ?, ?, ?, ?, ?, 'active')
        ON CONFLICT(workspace_id) DO UPDATE SET
            canonical_path = excluded.canonical_path,
            volume_resource_id = excluded.volume_resource_id,
            bookmark_hash = excluded.bookmark_hash,
            last_seen_at = excluded.last_seen_at,
            status = 'active'
        """,
      arguments: [
        identity.workspaceID,
        identity.canonicalRootURL.path,
        identity.volumeResourceID,
        identity.rootBookmarkHash,
        timestamp,
        timestamp,
      ]
    )
  }

  private nonisolated static func upsertDocuments(
    records: [IndexDocumentRecord],
    workspaceID: String,
    indexedAt: Date,
    batchSize: Int = 1,
    didInsertBatch: (@Sendable (Int) -> Void)? = nil,
    in db: Database
  ) throws {
    let timestamp = Int(indexedAt.timeIntervalSince1970)
    var changedInBatch = 0
    for record in records {
      // INCREMENTAL: only (re)write a row whose indexed content (title/body/mtime/
      // size) is new or changed. An unchanged re-upsert is not just a no-op for the
      // content — its `ON CONFLICT DO UPDATE` still fires the `documents` AU trigger,
      // which deletes + reinserts the row's entry in the external-content
      // `document_fts`. Re-committing all N documents on a cold open therefore
      // re-tokenizes the WHOLE workspace even when a single file changed — the
      // "Indexing N" reindex storm. Skipping the matching rows means only the
      // genuinely added/modified file fires a trigger, so a file add/remove is cheap.
      // Removed paths are tombstoned by the caller's `tombstoneDocumentsNotIn`.
      let changed = try !workspaceDocumentMatches(record, workspaceID: workspaceID, in: db)
      guard changed else { continue }
      try db.execute(
        sql: """
          INSERT INTO documents
              (workspace_id, path, title, body, mtime, size, is_ad_hoc, indexed_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(workspace_id, path) DO UPDATE SET
              title = excluded.title,
              body = excluded.body,
              mtime = excluded.mtime,
              size = excluded.size,
              is_ad_hoc = excluded.is_ad_hoc,
              indexed_at = excluded.indexed_at
          """,
        arguments: [
          workspaceID,
          record.path,
          record.title,
          record.body,
          record.mtime,
          record.size,
          record.isAdHoc ? 1 : 0,
          timestamp,
        ]
      )
      changedInBatch += 1
      if changedInBatch == batchSize {
        didInsertBatch?(changedInBatch)
        changedInBatch = 0
      }
    }
    if changedInBatch > 0 {
      didInsertBatch?(changedInBatch)
    }
  }

  /// True when the stored `documents` row for `(workspaceID, record.path)` already
  /// byte-matches the candidate's indexed content (title/body/mtime/size).
  private nonisolated static func workspaceDocumentMatches(
    _ record: IndexDocumentRecord, workspaceID: String, in db: Database
  ) throws -> Bool {
    let row = try Row.fetchOne(
      db,
      sql: """
        SELECT title, body, mtime, size FROM documents
        WHERE workspace_id = ? AND path = ? LIMIT 1
        """,
      arguments: [workspaceID, record.path])
    guard let row else { return false }
    return (row["title"] as String) == record.title
      && (row["body"] as String) == record.body
      && (row["mtime"] as Int) == record.mtime
      && (row["size"] as Int) == record.size
  }

  private nonisolated static func tombstoneDocumentsNotIn(
    paths: [String],
    workspaceID: String,
    in db: Database
  ) throws {
    guard !paths.isEmpty else {
      try db.execute(sql: "DELETE FROM documents WHERE workspace_id = ?", arguments: [workspaceID])
      return
    }

    let placeholders = Array(repeating: "?", count: paths.count).joined(separator: ", ")
    var arguments: StatementArguments = [workspaceID]
    arguments += StatementArguments(paths)
    try db.execute(
      sql: """
        DELETE FROM documents
        WHERE workspace_id = ?
          AND path NOT IN (\(placeholders))
        """,
      arguments: arguments
    )
  }

  private nonisolated static func documentRecord(from document: DocumentRef)
    -> IndexDocumentRecord?
  {
    let url = document.url.standardizedFileURL
    guard let body = try? String(contentsOf: url, encoding: .utf8) else {
      return nil
    }
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let modifiedAt =
      values?.contentModificationDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
    let size = values?.fileSize ?? Data(body.utf8).count
    return IndexDocumentRecord(
      path: document.relativePath ?? document.displayPath,
      title: title(fromMarkdown: body, fallback: document.title),
      body: body,
      mtime: Int(modifiedAt),
      size: size,
      isAdHoc: document.isAdHoc
    )
  }

  private nonisolated static func title(fromMarkdown body: String, fallback: String) -> String {
    for line in body.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("# ") else { continue }
      let title = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
      if !title.isEmpty {
        return title
      }
    }
    return fallback
  }

  private nonisolated static func performSearch(
    query: String,
    documents: [DocumentRef],
    limit: Int,
    pool: DatabasePool
  ) throws -> [WorkspaceSearchResult] {
    let documentsByPath = Dictionary(
      uniqueKeysWithValues: documents.map { ($0.url.standardizedFileURL.path, $0) }
    )
    guard !documentsByPath.isEmpty else { return [] }

    // SQL-level workspace scoping by ROOT canonical path (not by recomputed
    // workspace_id): the caller's docs belong to workspaces whose
    // `canonical_path` is one of their roots, plus the reserved `__adhoc__`
    // scope when any ad-hoc / rootless open file is present. Scoping on the
    // stored `canonical_path` (rather than re-deriving the workspace_id hash)
    // keeps the join correct regardless of how the workspace_id was minted. A
    // search in workspace A therefore never reads workspace B's rows out of
    // `documents`. The in-memory `documentsByPath` join remains as a safety net
    // (it also maps each hit back to its live `DocumentRef`).
    var rootScopes = Set<String>()
    var includeAdHoc = false
    for document in documents {
      if !document.isAdHoc, let rootURL = document.rootURL {
        rootScopes.insert(rootURL.standardizedFileURL.path)
      } else {
        includeAdHoc = true
      }
    }
    guard !rootScopes.isEmpty || includeAdHoc else { return [] }

    let records = try fetchRecords(
      matching: query, rootScopes: Array(rootScopes), includeAdHoc: includeAdHoc,
      limit: max(limit * 3, limit), pool: pool)
    let results = records.compactMap { record -> WorkspaceSearchResult? in
      guard let document = documentsByPath[record.path] else { return nil }
      return makeResult(record: record, document: document, query: query)
    }
    return Array(
      results
        .sorted { lhs, rhs in
          if lhs.score != rhs.score { return lhs.score < rhs.score }
          if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
          return lhs.displayPath.localizedStandardCompare(rhs.displayPath) == .orderedAscending
        }
        .prefix(limit)
    )
  }

  /// Fetches matching rows from the EXTERNAL-CONTENT `document_fts` joined back to
  /// `documents` (+ `workspaces` for the full-path reconstruction), scoped in SQL
  /// to workspaces whose `canonical_path` is one of `rootScopes`, plus the
  /// reserved `__adhoc__` workspace when `includeAdHoc`. The reconstructed full
  /// path (`canonical_path || '/' || path` for workspace docs, or `path` verbatim
  /// for ad-hoc) is returned as `path` — the same search join key the prior
  /// contentful table exposed. Body/title come from `documents`; `display_path`
  /// is the relative path (workspace) or last path component (ad-hoc);
  /// `updated_at <- documents.mtime`, `is_ad_hoc <- documents.is_ad_hoc`. Ordered
  /// by bm25 relevance so the `LIMIT` keeps the most relevant hits (the caller
  /// re-scores/re-sorts).
  ///
  /// Falls back to a LIKE scan over `documents` (same scope) when the FTS MATCH
  /// query is empty or errors — mirrors the prior fallback path.
  private nonisolated static func fetchRecords(
    matching query: String,
    rootScopes: [String],
    includeAdHoc: Bool,
    limit: Int,
    pool: DatabasePool
  ) throws -> [SearchDocumentRecord] {
    // For workspace docs `display_path` is the workspace-relative `d.path` (==
    // DocumentRef.displayPath); for ad-hoc rows (canonical_path '') the relative
    // notion is the last path component (DocumentRef.displayPath for ad-hoc), so
    // strip the directory prefix from the full path stored in `d.path`.
    let selectClause = """
      SELECT
          CASE WHEN w.canonical_path = '' THEN d.path
               ELSE w.canonical_path || '/' || d.path END AS path,
          d.title AS title,
          CASE WHEN w.canonical_path = ''
               THEN replace(d.path, rtrim(d.path, replace(d.path, '/', '')), '')
               ELSE d.path END AS display_path,
          d.body AS body,
          d.is_ad_hoc AS is_ad_hoc,
          d.mtime AS updated_at
      """

    // Scope predicate over `workspaces`: canonical_path in the caller's roots,
    // and/or the reserved ad-hoc workspace. Bound args are appended in order.
    var scopeClauses: [String] = []
    var scopeArgs: [DatabaseValueConvertible] = []
    if !rootScopes.isEmpty {
      let placeholders = Array(repeating: "?", count: rootScopes.count).joined(separator: ", ")
      scopeClauses.append("w.canonical_path IN (\(placeholders))")
      scopeArgs.append(contentsOf: rootScopes)
    }
    if includeAdHoc {
      scopeClauses.append("d.workspace_id = ?")
      scopeArgs.append(Self.adHocWorkspaceID)
    }
    let scopePredicate = "(" + scopeClauses.joined(separator: " OR ") + ")"

    let ftsQuery = makeFTSQuery(from: query)
    if !ftsQuery.isEmpty {
      var matchArgs: StatementArguments = [ftsQuery]
      matchArgs += StatementArguments(scopeArgs)
      matchArgs += [limit]
      if let records = try? pool.read({ db in
        try SearchDocumentRecord.fetchAll(
          db,
          sql: """
            \(selectClause)
            FROM document_fts
            JOIN documents d ON d.id = document_fts.rowid
            JOIN workspaces w ON w.workspace_id = d.workspace_id
            WHERE document_fts MATCH ?
              AND \(scopePredicate)
            ORDER BY bm25(document_fts)
            LIMIT ?
            """,
          arguments: matchArgs
        )
      }), !records.isEmpty {
        // FTS hit set wins (ranked by bm25). When MATCH yields ZERO rows — e.g. an
        // infix query like "liczek" against the token "pliczek", which FTS5's
        // token-prefix matching can't satisfy — fall through to the substring LIKE
        // scan below so partial-name search still finds the file.
        return records
      }
    }

    let pattern = "%\(query.lowercased())%"
    var likeArgs: StatementArguments = StatementArguments(scopeArgs)
    likeArgs += [pattern, pattern, pattern, limit]
    return try pool.read { db in
      try SearchDocumentRecord.fetchAll(
        db,
        sql: """
          \(selectClause)
          FROM documents d
          JOIN workspaces w ON w.workspace_id = d.workspace_id
          WHERE \(scopePredicate)
            AND (lower(d.title) LIKE ?
              OR lower(d.path) LIKE ?
              OR lower(d.body) LIKE ?)
          LIMIT ?
          """,
        arguments: likeArgs
      )
    }
  }

  private nonisolated static func makeResult(
    record: SearchDocumentRecord,
    document: DocumentRef,
    query: String
  ) -> WorkspaceSearchResult {
    let normalizedQuery = normalize(query)
    let title = normalize(record.title)
    let path = normalize(record.displayPath)
    let body = normalize(record.body)
    let terms = searchTerms(in: query)

    let titleContainsPhrase = !normalizedQuery.isEmpty && title.contains(normalizedQuery)
    let pathContainsPhrase = !normalizedQuery.isEmpty && path.contains(normalizedQuery)
    let bodyContainsPhrase = !normalizedQuery.isEmpty && body.contains(normalizedQuery)
    let titleContainsTerms = containsAll(terms, in: title)
    let pathContainsTerms = containsAll(terms, in: path)
    let bodyContainsTerms = containsAll(terms, in: body)

    let matchKind: WorkspaceSearchResult.MatchKind
    let score: Int
    if titleContainsPhrase {
      matchKind = .title
      score = 0
    } else if pathContainsPhrase {
      matchKind = .path
      score = 1
    } else if titleContainsTerms {
      matchKind = .title
      score = 2
    } else if pathContainsTerms {
      matchKind = .path
      score = 3
    } else if bodyContainsPhrase {
      matchKind = .body
      score = 4
    } else if bodyContainsTerms {
      matchKind = .body
      score = 5
    } else {
      matchKind = .body
      score = 6
    }

    return WorkspaceSearchResult(
      document: document,
      displayPath: record.displayPath,
      snippet: (bodyContainsPhrase || bodyContainsTerms)
        ? snippet(in: record.body, query: query, terms: terms) : nil,
      matchKind: matchKind,
      score: score,
      updatedAt: Date(timeIntervalSince1970: record.updatedAt)
    )
  }

  private nonisolated static func makeFTSQuery(from query: String) -> String {
    searchTerms(in: query)
      .map { "\($0)*" }
      .joined(separator: " AND ")
  }

  private nonisolated static func searchTerms(in text: String) -> [String] {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .filter { !$0.isEmpty }
  }

  private nonisolated static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
  }

  private nonisolated static func containsAll(_ terms: [String], in text: String) -> Bool {
    !terms.isEmpty && terms.allSatisfy { text.contains($0) }
  }

  private nonisolated static func snippet(
    in body: String,
    query: String,
    terms: [String]
  ) -> String? {
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    let matchRange =
      body.range(of: query, options: options)
      ?? terms.compactMap { body.range(of: $0, options: options) }.first

    guard let matchRange else { return nil }

    let start =
      body.index(matchRange.lowerBound, offsetBy: -70, limitedBy: body.startIndex)
      ?? body.startIndex
    let end =
      body.index(matchRange.upperBound, offsetBy: 90, limitedBy: body.endIndex) ?? body.endIndex
    let collapsed = body[start..<end]
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)

    let prefix = start > body.startIndex ? "..." : ""
    let suffix = end < body.endIndex ? "..." : ""
    return "\(prefix)\(collapsed)\(suffix)"
  }

  private func report(_ error: Error, appState: AppState?, action: String) {
    let message = "Could not \(action): \(error.localizedDescription)"
    appState?.lastError = message
    NSLog(message)
  }

  func appendScanSession(
    workspaceID: String,
    trigger: String,
    startedAt: Date,
    finishedAt: Date,
    scannerVersion: Int,
    fingerprintHash: String,
    fileCount: Int,
    folderCount: Int,
    durationMs: Int,
    appState: AppState? = nil
  ) async {
    guard let pool = ensureOpen(into: appState) else { return }
    do {
      try await Task.detached(priority: .utility) {
        try pool.write { db in
          try db.execute(
            sql: """
              INSERT INTO scan_sessions (
                workspace_id, started_at, finished_at, trigger,
                scanner_version, fingerprint_hash, file_count, folder_count, duration_ms
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
              """,
            arguments: [
              workspaceID,
              Int(startedAt.timeIntervalSince1970),
              Int(finishedAt.timeIntervalSince1970),
              trigger,
              scannerVersion,
              fingerprintHash,
              fileCount,
              folderCount,
              durationMs,
            ]
          )
        }
      }.value
    } catch {
      report(error, appState: appState, action: "append Pensieve scan session")
    }
  }

  func refreshWorkspaceStats(
    workspaceID: String,
    fileCount: Int,
    folderCount: Int,
    fingerprintMatches: Bool,
    appState: AppState? = nil
  ) async {
    guard let pool = ensureOpen(into: appState) else { return }
    do {
      try await Task.detached(priority: .utility) {
        try pool.write { db in
          let indexHealth = fileCount == 0 ? "empty" : (fingerprintMatches ? "green" : "stale")
          try db.execute(
            sql: """
              INSERT INTO workspace_stats (
                workspace_id, file_count, folder_count,
                last_scan_at, last_indexed_at, index_health
              ) VALUES (
                ?, ?, ?,
                (SELECT finished_at FROM scan_sessions WHERE workspace_id = ? ORDER BY finished_at DESC LIMIT 1),
                (SELECT max(indexed_at) FROM documents WHERE workspace_id = ?),
                ?
              )
              ON CONFLICT(workspace_id) DO UPDATE SET
                file_count = excluded.file_count,
                folder_count = excluded.folder_count,
                last_scan_at = excluded.last_scan_at,
                last_indexed_at = excluded.last_indexed_at,
                index_health = excluded.index_health
              """,
            arguments: [
              workspaceID,
              fileCount,
              folderCount,
              workspaceID,
              workspaceID,
              indexHealth,
            ]
          )
        }
      }.value
    } catch {
      report(error, appState: appState, action: "refresh Pensieve workspace stats")
    }
  }
}

/// A search hit read from the `document_fts` JOIN `documents` JOIN `workspaces`
/// projection: `path` is the RECONSTRUCTED full standardized path (the search
/// join key), `display_path`/`title`/`body` come from `documents`, `is_ad_hoc`
/// from `documents.is_ad_hoc`, `updated_at` from `documents.mtime`.
private struct SearchDocumentRecord: FetchableRecord, Sendable {
  var path: String
  var title: String
  var displayPath: String
  var body: String
  var isAdHoc: Bool
  var updatedAt: TimeInterval

  init(row: Row) throws {
    path = row["path"]
    title = row["title"]
    displayPath = row["display_path"]
    body = row["body"]
    isAdHoc = (row["is_ad_hoc"] as Int) != 0
    updatedAt = row["updated_at"]
  }
}

/// A fully-resolved `documents`-row write derived from a `DocumentRef` + body:
/// the workspace_id it belongs to (its own, or the reserved `__adhoc__`), the
/// stored `documents.path` (relative for workspace docs, full standardized path
/// for ad-hoc), the workspace `canonical_path` (for the search full-path
/// reconstruction; '' for ad-hoc), and the indexed metadata.
private struct DocumentWriteRecord: Sendable {
  var workspaceID: String
  var canonicalPath: String
  var path: String
  var title: String
  var body: String
  var mtime: Int
  var size: Int
  var isAdHoc: Bool
}

private struct IndexDocumentRecord: Sendable {
  var path: String
  var title: String
  var body: String
  var mtime: Int
  var size: Int
  var isAdHoc: Bool
}
