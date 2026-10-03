import Foundation

/// Agent-facing search over the current workspace's `document_fts` index.
///
/// The sidebar keeps `IndexDatabase.search` (default limit 50, its own ~160
/// character window). This tool does not add a method to that hub: it calls
/// `search` and then reads each hit's file for a snippet of at most 320
/// characters. Result order is whatever `search` already returned — bm25, then
/// date — and is not re-sorted by `updated_at`.
@MainActor
enum WorkspaceSearchTool {
  /// Name the host cut binds. This cut only owns the contract behind it.
  nonisolated static let toolName = "workspace_search"
  nonisolated static let defaultLimit = 5
  nonisolated static let minimumLimit = 1
  nonisolated static let maximumLimit = 20
  nonisolated static let snippetCharacterLimit = 320

  enum Failure: Error, LocalizedError {
    case missingQuery
    case limitOutOfRange(Int)

    var errorDescription: String? {
      switch self {
      case .missingQuery:
        "Missing required non-empty string field 'query'"
      case .limitOutOfRange(let limit):
        "Limit \(limit) is outside 1...20"
      }
    }
  }

  /// JSON object `{ query, count, matches: [{ path, title, updated_at, snippet, match }] }`.
  /// `limit == nil` means 5. A limit outside 1...20 throws; it is never clamped.
  static func workspaceSearch(
    query: String,
    limit: Int? = nil,
    documents: [DocumentRef],
    database: IndexDatabase
  ) throws -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw Failure.missingQuery }
    let resolvedLimit = try resolveLimit(limit)
    let results = database.search(
      query: trimmed,
      documents: documents,
      limit: resolvedLimit
    )
    return try encode(query: trimmed, results: results)
  }

  /// Production callbacks keep GRDB and full-file snippet work off the UI actor.
  static func workspaceSearchInBackground(
    query: String, limit: Int? = nil, documents: [DocumentRef], database: IndexDatabase
  ) async throws -> String {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw Failure.missingQuery }
    let resolvedLimit = try resolveLimit(limit)
    let results = await database.searchInBackground(
      query: trimmed, documents: documents, limit: resolvedLimit)
    return try await Task.detached(priority: .userInitiated) {
      try autoreleasepool { try encode(query: trimmed, results: results) }
    }.value
  }

  nonisolated private static func resolveLimit(_ limit: Int?) throws -> Int {
    guard let limit else { return defaultLimit }
    guard (minimumLimit...maximumLimit).contains(limit) else {
      throw Failure.limitOutOfRange(limit)
    }
    return limit
  }

  private struct Payload: Encodable {
    var query: String
    var count: Int
    var matches: [Match]
  }

  private struct Match: Encodable {
    var path: String
    var title: String
    var updatedAt: String
    var snippet: String
    var match: String

    enum CodingKeys: String, CodingKey {
      case path
      case title
      case snippet
      case match
      case updatedAt = "updated_at"
    }
  }

  nonisolated private static func encode(query: String, results: [WorkspaceSearchResult]) throws
    -> String
  {
    let payload = Payload(
      query: query,
      count: results.count,
      matches: results.map { result in
        Match(
          path: result.document.url.standardizedFileURL.path,
          title: result.title,
          updatedAt: timestamp(result.updatedAt),
          snippet: fileSnippet(for: result, query: query),
          match: matchLabel(result.matchKind)
        )
      }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(payload)
    return String(decoding: data, as: UTF8.self)
  }

  nonisolated private static func matchLabel(_ kind: WorkspaceSearchResult.MatchKind) -> String {
    switch kind {
    case .title: "title"
    case .path: "path"
    case .body: "body"
    }
  }

  nonisolated private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: date)
  }

  /// Snippet is cut from the file on disk, not from `WorkspaceSearchResult.snippet`.
  /// The index window is about 160 characters and is the sidebar's, not the tool's.
  nonisolated private static func fileSnippet(for result: WorkspaceSearchResult, query: String)
    -> String
  {
    let url = result.document.url.standardizedFileURL
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
    let collapsed =
      text
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !collapsed.isEmpty else { return "" }
    guard collapsed.count > snippetCharacterLimit else { return collapsed }

    let anchor = matchStart(in: collapsed, query: query) ?? collapsed.startIndex
    let anchorOffset = collapsed.distance(from: collapsed.startIndex, to: anchor)
    let startOffset = max(0, anchorOffset - snippetCharacterLimit / 2)
    let start = collapsed.index(collapsed.startIndex, offsetBy: startOffset)
    let end =
      collapsed.index(
        start,
        offsetBy: snippetCharacterLimit,
        limitedBy: collapsed.endIndex
      ) ?? collapsed.endIndex
    if collapsed.distance(from: start, to: end) < snippetCharacterLimit {
      let deficit = snippetCharacterLimit - collapsed.distance(from: start, to: end)
      let back =
        collapsed.index(start, offsetBy: -deficit, limitedBy: collapsed.startIndex)
        ?? collapsed.startIndex
      return String(collapsed[back..<end].prefix(snippetCharacterLimit))
    }
    return String(collapsed[start..<end].prefix(snippetCharacterLimit))
  }

  nonisolated private static func matchStart(in text: String, query: String) -> String.Index? {
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    if let range = text.range(of: query, options: options) {
      return range.lowerBound
    }
    return
      searchTerms(in: query)
      .compactMap { text.range(of: $0, options: options)?.lowerBound }
      .min()
  }

  /// Same letter/number split `IndexDatabase.makeFTSQuery` uses. That helper is
  /// private on the hub, so the window finder keeps its own copy.
  nonisolated private static func searchTerms(in text: String) -> [String] {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
      .split { !$0.isLetter && !$0.isNumber }
      .map(String.init)
      .filter { !$0.isEmpty }
  }
}
