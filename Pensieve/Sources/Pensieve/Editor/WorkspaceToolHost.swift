import CodescribeBridge
import Foundation
import Synchronization

/// Read-only tools for one workspace. Search, membership, and file bytes are
/// injected: this type does not import the search cut, and a path the
/// membership closure rejects never reaches `readFile`. The host itself does
/// not open files.
final class WorkspaceToolHost: CsDocumentToolHost, Sendable {
  private static let defaultSearchLimit = 5
  private static let searchLimitRange = 1...20
  private static let maximumReadCharacters = 8000

  private let search: @Sendable (String, Int) throws -> String
  private let containsPath: @Sendable (String) -> Bool
  private let readFile: @Sendable (String) throws -> String
  private let active = Mutex(true)

  init(
    search: @escaping @Sendable (String, Int) throws -> String,
    containsPath: @escaping @Sendable (String) -> Bool,
    readFile: @escaping @Sendable (String) throws -> String
  ) {
    self.search = search
    self.containsPath = containsPath
    self.readFile = readFile
  }

  func isActive() -> Bool { active.withLock { $0 } }

  func invalidate() { active.withLock { $0 = false } }

  func execute(name: String, argumentsJson arguments: String) throws -> String {
    guard isActive() else { throw failure("This workspace session is no longer active.") }
    let data = Data(arguments.utf8)
    let decoder = JSONDecoder()
    switch name {
    case "workspace_search":
      let request = try decoder.decode(Search.self, from: data)
      let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !query.isEmpty else {
        throw failure("Missing required non-empty string field 'query'")
      }
      let limit = request.limit ?? Self.defaultSearchLimit
      guard Self.searchLimitRange.contains(limit) else {
        throw failure("Limit must be from 1 to 20.")
      }
      return try search(query, limit)
    case "workspace_read":
      let request = try decoder.decode(Read.self, from: data)
      guard !request.path.isEmpty else {
        throw failure("Missing required non-empty string field 'path'")
      }
      let offset = request.offset ?? 0
      let limit = request.limit ?? Self.maximumReadCharacters
      guard offset >= 0, (1...Self.maximumReadCharacters).contains(limit) else {
        throw failure("Read offset or limit is out of bounds.")
      }
      guard containsPath(request.path) else {
        throw failure("Path is outside this workspace.")
      }
      let file = try readFile(request.path)
      let total = file.count
      guard offset <= total else { throw failure("Read offset or limit is out of bounds.") }
      let text = String(file.dropFirst(offset).prefix(limit))
      let end = offset + text.count
      return try json([
        "path": request.path,
        "text": text,
        "offset": offset,
        "total_characters": total,
        "next_offset": end < total ? end as Any : NSNull(),
      ])
    default:
      throw failure("Unknown workspace tool.")
    }
  }

  private func failure(_ message: String) -> CsError { .Agent(msg: message) }

  private func json(_ value: [String: Any]) throws -> String {
    String(
      decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
      as: UTF8.self)
  }

  private struct Search: Decodable {
    let query: String
    let limit: Int?
  }

  private struct Read: Decodable {
    let path: String
    let offset: Int?
    let limit: Int?
  }
}
