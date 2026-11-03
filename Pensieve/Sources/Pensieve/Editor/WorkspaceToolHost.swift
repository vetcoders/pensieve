import CodescribeBridge
import Foundation
import Synchronization

/// Workspace membership gates every path. Opening a file selects a live
/// DocumentToolHost, which remains the authority for revisions and undo.
final class WorkspaceToolHost: CsDocumentToolHost, Sendable {
  private static let defaultSearchLimit = 5
  private static let searchLimitRange = 1...20
  private static let maximumReadCharacters = 8000

  private let search: @Sendable (String, Int) throws -> String
  private let containsPath: @Sendable (String) -> Bool
  private let readFile: @Sendable (String) throws -> String
  private let active = Mutex(true)
  private let selectedDocument = Mutex<(path: String, host: DocumentToolHost)?>(nil)
  private let openDocument:
    (@Sendable (String, @escaping @Sendable () -> Bool) throws -> DocumentToolHost)?

  init(
    search: @escaping @Sendable (String, Int) throws -> String,
    containsPath: @escaping @Sendable (String) -> Bool,
    readFile: @escaping @Sendable (String) throws -> String,
    openDocument: (@Sendable (String, @escaping @Sendable () -> Bool) throws -> DocumentToolHost)? =
      nil
  ) {
    self.search = search
    self.containsPath = containsPath
    self.readFile = readFile
    self.openDocument = openDocument
  }

  func isActive() -> Bool { active.withLock { $0 } }

  func invalidate() {
    active.withLock { $0 = false }
    let selected = selectedDocument.withLock { current in
      let previous = current
      current = nil
      return previous
    }
    selected?.host.invalidate()
  }

  func execute(name: String, argumentsJson arguments: String) throws -> String {
    guard isActive() else { throw failure("This workspace session is no longer active.") }
    let data = Data(arguments.utf8)
    let decoder = JSONDecoder()
    switch name {
    case "document_open":
      let request = try decoder.decode(Open.self, from: data)
      guard containsPath(request.path), let openDocument else {
        throw failure("The document cannot be opened from this workspace.")
      }
      let host = try openDocument(request.path, { [weak self] in self?.isActive() == true })
      guard isActive() else {
        host.invalidate()
        throw failure("This workspace session is no longer active.")
      }
      let previous = selectedDocument.withLock { current in
        let previous = current
        current = (request.path, host)
        return previous
      }
      previous?.host.invalidate()
      // Cancellation may race the assignment; never leave a usable orphan.
      guard isActive() else {
        host.invalidate()
        throw failure("This workspace session is no longer active.")
      }
      return try json(["opened": true, "path": request.path, "document_tools_available": true])
    case "document_read", "document_search", "document_replace":
      guard let host = selectedDocument.withLock({ $0?.host }) else {
        throw failure("Open a workspace document with document_open first.")
      }
      return try host.execute(name: name, argumentsJson: arguments)
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
      if let selected = selectedDocument.withLock({ $0 }), selected.path == request.path {
        let live = try selected.host.execute(
          name: "document_read",
          argumentsJson: try json(["offset": offset, "limit": limit]))
        var payload =
          try JSONSerialization.jsonObject(with: Data(live.utf8)) as? [String: Any] ?? [:]
        payload["path"] = request.path
        return try json(payload)
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

  private struct Open: Decodable { let path: String }
  private struct Read: Decodable {
    let path: String
    let offset: Int?
    let limit: Int?
  }
}
