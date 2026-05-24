import Foundation
import GRDB

@MainActor
final class IndexDatabase {
    static let shared = IndexDatabase()

    private var databaseQueue: DatabaseQueue?
    private(set) var databaseURL: URL?
    private let configuredDatabaseURL: URL?

    init(databaseURL: URL? = nil) {
        self.configuredDatabaseURL = databaseURL
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

            let queue = try DatabaseQueue(path: url.path)

            var migrator = DatabaseMigrator()
            migrator.registerMigration("mvp_workspace_search_fts") { db in
                try db.execute(sql: """
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
            try migrator.migrate(queue)

            databaseQueue = queue
            databaseURL = url
        } catch {
            let message = "Could not open Pensieve index database: \(error.localizedDescription)"
            appState?.lastError = message
            NSLog(message)
        }
    }

    func reindex(documents: [DocumentRef], appState: AppState? = nil) {
        guard let queue = ensureOpen(into: appState) else { return }

        let records = documents.compactMap { document -> SearchDocumentRecord? in
            guard let body = try? String(contentsOf: document.url, encoding: .utf8) else {
                return nil
            }
            return SearchDocumentRecord(document: document, body: body)
        }

        do {
            try queue.write { db in
                try db.execute(sql: "DELETE FROM workspace_search_documents")
                for record in records {
                    try insert(record, into: db)
                }
            }
            refreshSearchResults(in: appState)
        } catch {
            report(error, appState: appState, action: "rebuild Pensieve search index")
        }
    }

    func index(document: DocumentRef, body: String, appState: AppState? = nil) {
        guard let queue = ensureOpen(into: appState) else { return }
        let record = SearchDocumentRecord(document: document, body: body)

        do {
            try queue.write { db in
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
        guard let queue = ensureOpen(into: appState) else { return [] }

        let documentsByPath = Dictionary(
            uniqueKeysWithValues: documents.map { ($0.url.standardizedFileURL.path, $0) }
        )
        guard !documentsByPath.isEmpty else { return [] }

        do {
            let records = try fetchRecords(matching: trimmedQuery, limit: max(limit * 3, limit), queue: queue)
            let results = records.compactMap { record -> WorkspaceSearchResult? in
                guard let document = documentsByPath[record.path] else { return nil }
                return makeResult(record: record, document: document, query: trimmedQuery)
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

    private func ensureOpen(into appState: AppState?) -> DatabaseQueue? {
        if databaseQueue == nil {
            open(into: appState)
        }
        return databaseQueue
    }

    private func insert(_ record: SearchDocumentRecord, into db: Database) throws {
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
                record.updatedAt
            ]
        )
    }

    private func fetchRecords(
        matching query: String,
        limit: Int,
        queue: DatabaseQueue
    ) throws -> [SearchDocumentRecord] {
        let ftsQuery = makeFTSQuery(from: query)
        if !ftsQuery.isEmpty,
           let records = try? queue.read({ db in
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
           }) {
            return records
        }

        let pattern = "%\(query.lowercased())%"
        return try queue.read { db in
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

    private func makeResult(
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
            snippet: (bodyContainsPhrase || bodyContainsTerms) ? snippet(in: record.body, query: query, terms: terms) : nil,
            matchKind: matchKind,
            score: score,
            updatedAt: Date(timeIntervalSince1970: record.updatedAt)
        )
    }

    private func makeFTSQuery(from query: String) -> String {
        searchTerms(in: query)
            .map { "\($0)*" }
            .joined(separator: " AND ")
    }

    private func searchTerms(in text: String) -> [String] {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private func containsAll(_ terms: [String], in text: String) -> Bool {
        !terms.isEmpty && terms.allSatisfy { text.contains($0) }
    }

    private func snippet(in body: String, query: String, terms: [String]) -> String? {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let matchRange = body.range(of: query, options: options)
            ?? terms.compactMap { body.range(of: $0, options: options) }.first

        guard let matchRange else { return nil }

        let start = body.index(matchRange.lowerBound, offsetBy: -70, limitedBy: body.startIndex) ?? body.startIndex
        let end = body.index(matchRange.upperBound, offsetBy: 90, limitedBy: body.endIndex) ?? body.endIndex
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

private struct SearchDocumentRecord: FetchableRecord {
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
        self.updatedAt = (try? document.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
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
