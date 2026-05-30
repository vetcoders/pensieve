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
  }

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
      try db.execute(sql: "DELETE FROM workspace_search_documents")
      var batch: [SearchDocumentRecord] = []
      batch.reserveCapacity(batchSize)

      for document in documents {
        guard let record = searchDocumentRecord(from: document) else {
          continue
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
