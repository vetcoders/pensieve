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

    // I-03 (W-C-1): FTS5 trigger-driven sync of WORKSPACE documents.
    //
    // The `documents` table (W-B-1) is the source of truth for workspace docs;
    // these triggers mirror each `is_ad_hoc = 0` row into the existing
    // `workspace_search_documents` FTS5 table so a documents write keeps its FTS
    // row in sync without a separate inline-body rebuild.
    //
    // Friction 1 (path representation): the search join keys on the FULL
    // standardized URL path (`performSearch` -> `documentsByPath[record.path]`),
    // but `documents.path` is the workspace-relative path. The triggers
    // reconstruct the full path as `workspaces.canonical_path || '/' ||
    // documents.path` so the FTS `path` matches the join key.
    //
    // Friction 3 (column mapping): FTS `title` <- documents.title (markdown H1
    // or filename fallback, per the W-B-1 writer), `display_path` <-
    // documents.path (== DocumentRef.displayPath for scanned workspace docs),
    // `body` <- documents.body, `is_ad_hoc` <- documents.is_ad_hoc,
    // `updated_at` <- documents.mtime (file modification time; same source the
    // inline path used for `SearchDocumentRecord.updatedAt`).
    //
    // Ad-hoc docs (`is_ad_hoc = 1`) are intentionally NOT mirrored — they reach
    // FTS via `index(document:body:)` / `reindex` with their own absolute path
    // (a relative-path reconstruction would be wrong for them). The WHEN guard
    // keeps the triggers scoped to workspace docs.
    //
    // `DatabaseMigrator` runs this once per DB; plain `CREATE TRIGGER` is
    // idempotent by construction (no IF NOT EXISTS needed).
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
  }

  /// Reconstructs the FULL standardized paths of all workspace documents
  /// (`is_ad_hoc = 0`) currently mirrored into FTS by the
  /// `b2_v2_fts_documents_triggers` triggers. `reindex` uses this set to leave
  /// those trigger-owned rows untouched and avoid double-writing them.
  private nonisolated static let ftsTriggerOwnedPathsSQL = """
    SELECT w.canonical_path || '/' || d.path
    FROM documents d
    JOIN workspaces w ON w.workspace_id = d.workspace_id
    WHERE d.is_ad_hoc = 0
    """

  func reindex(documents: [DocumentRef], appState: AppState? = nil) {
    guard let pool = ensureOpen(into: appState) else { return }
    reindex(documents: documents, pool: pool, appState: appState)
  }

  func reindexInBackground(documents: [DocumentRef], appState: AppState? = nil) async {
    guard let pool = ensureOpen(into: appState) else { return }
    let batchSize = searchIndexBatchSize
    let didInsertBatch = didInsertSearchIndexBatch

    do {
      try await Task.detached(priority: .utility) {
        try Self.replaceSearchIndex(
          with: documents,
          pool: pool,
          batchSize: batchSize,
          didInsertBatch: didInsertBatch
        )
      }.value
      refreshSearchResults(in: appState)
    } catch {
      report(error, appState: appState, action: "rebuild Pensieve search index")
    }
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

  func index(document: DocumentRef, body: String, appState: AppState? = nil) {
    guard let pool = ensureOpen(into: appState) else { return }
    let record = SearchDocumentRecord(document: document, body: body)

    do {
      try pool.write { db in
        try db.execute(
          sql: "DELETE FROM workspace_search_documents WHERE path = ?",
          arguments: [record.path]
        )
        try insert(record, into: db)
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
          try Self.upsertDocuments(
            records: records,
            workspaceID: identity.workspaceID,
            indexedAt: lastSeenAt,
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

  private func insert(_ record: SearchDocumentRecord, into db: Database) throws {
    try Self.insert(record, into: db)
  }

  private nonisolated static func replaceSearchIndex(
    with documents: [DocumentRef],
    pool: DatabasePool,
    batchSize: Int,
    didInsertBatch: (@Sendable (Int) -> Void)?
  ) throws {
    try pool.write { db in
      // Workspace documents (`is_ad_hoc = 0`) are mirrored into FTS by the
      // `b2_v2_fts_documents_triggers` triggers, keyed on the full path
      // reconstructed from `workspaces.canonical_path` + `documents.path`.
      // reindex must NOT rewrite those rows: doing so would redo the trigger's
      // work and, in the cold-scan flow (documents written THEN reindex),
      // double the write. reindex owns only the rows the triggers do not —
      // ad-hoc docs and any path not backed by the `documents` table.
      let ownedPaths = try Set(String.fetchAll(db, sql: ftsTriggerOwnedPathsSQL))
      try db.execute(
        sql: """
          DELETE FROM workspace_search_documents
          WHERE path NOT IN (\(ftsTriggerOwnedPathsSQL))
          """)

      var batch: [SearchDocumentRecord] = []
      batch.reserveCapacity(batchSize)

      for document in documents {
        guard let record = searchDocumentRecord(from: document) else {
          continue
        }
        // Trigger-owned workspace docs: skip the redundant write when the FTS row
        // already matches the on-disk content — in the cold-scan flow the
        // `documents` triggers just synced it, so this is the double-write
        // collapse. But `manager.refresh` and the file watcher re-run reindex
        // WITHOUT writing the `documents` table, so the triggers cannot see
        // out-of-band file edits; when the file body differs from the trigger
        // row, re-sync it here so the change stays searchable.
        if ownedPaths.contains(record.path) {
          let syncedBody = try String.fetchOne(
            db,
            sql: "SELECT body FROM workspace_search_documents WHERE path = ? LIMIT 1",
            arguments: [record.path])
          if syncedBody == record.body {
            continue
          }
          try db.execute(
            sql: "DELETE FROM workspace_search_documents WHERE path = ?",
            arguments: [record.path])
        }
        batch.append(record)
        if batch.count == batchSize {
          try insert(batch, into: db)
          didInsertBatch?(batch.count)
          batch.removeAll(keepingCapacity: true)
        }
      }

      if !batch.isEmpty {
        try insert(batch, into: db)
        didInsertBatch?(batch.count)
      }
    }
  }

  private nonisolated static func searchDocumentRecord(from document: DocumentRef)
    -> SearchDocumentRecord?
  {
    guard let body = try? String(contentsOf: document.url, encoding: .utf8) else {
      return nil
    }
    return SearchDocumentRecord(document: document, body: body)
  }

  private nonisolated static func insert(
    _ records: [SearchDocumentRecord],
    into db: Database
  ) throws {
    for record in records {
      try insert(record, into: db)
    }
  }

  private nonisolated static func insert(_ record: SearchDocumentRecord, into db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO workspace_search_documents
            (path, title, display_path, body, is_ad_hoc, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        """,
      arguments: [
        record.path,
        record.title,
        record.displayPath,
        record.body,
        record.isAdHoc ? 1 : 0,
        record.updatedAt,
      ]
    )
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
    in db: Database
  ) throws {
    let timestamp = Int(indexedAt.timeIntervalSince1970)
    for record in records {
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
    }
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

    let records = try fetchRecords(
      matching: query, limit: max(limit * 3, limit), pool: pool)
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

  private nonisolated static func fetchRecords(
    matching query: String,
    limit: Int,
    pool: DatabasePool
  ) throws -> [SearchDocumentRecord] {
    let ftsQuery = makeFTSQuery(from: query)
    if !ftsQuery.isEmpty,
      let records = try? pool.read({ db in
        try SearchDocumentRecord.fetchAll(
          db,
          sql: """
            SELECT path, title, display_path, body, is_ad_hoc, updated_at
            FROM workspace_search_documents
            WHERE workspace_search_documents MATCH ?
            LIMIT ?
            """,
          arguments: [ftsQuery, limit]
        )
      })
    {
      return records
    }

    let pattern = "%\(query.lowercased())%"
    return try pool.read { db in
      try SearchDocumentRecord.fetchAll(
        db,
        sql: """
          SELECT path, title, display_path, body, is_ad_hoc, updated_at
          FROM workspace_search_documents
          WHERE lower(title) LIKE ?
             OR lower(display_path) LIKE ?
             OR lower(body) LIKE ?
          LIMIT ?
          """,
        arguments: [pattern, pattern, pattern, limit]
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
}

private struct SearchDocumentRecord: FetchableRecord, Sendable {
  var path: String
  var title: String
  var displayPath: String
  var body: String
  var isAdHoc: Bool
  var updatedAt: TimeInterval

  init(document: DocumentRef, body: String) {
    self.path = document.url.standardizedFileURL.path
    self.title = document.title
    self.displayPath = document.displayPath
    self.body = body
    self.isAdHoc = document.isAdHoc
    self.updatedAt =
      (try? document.url.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate)?
      .timeIntervalSince1970 ?? Date().timeIntervalSince1970
  }

  init(row: Row) throws {
    path = row["path"]
    title = row["title"]
    displayPath = row["display_path"]
    body = row["body"]
    isAdHoc = (row["is_ad_hoc"] as Int) != 0
    updatedAt = row["updated_at"]
  }
}

private struct IndexDocumentRecord: Sendable {
  var path: String
  var title: String
  var body: String
  var mtime: Int
  var size: Int
  var isAdHoc: Bool
}
