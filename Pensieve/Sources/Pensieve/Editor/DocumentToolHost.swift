import CodescribeBridge
import CryptoKit
import Foundation
import Synchronization

struct AskDocumentSnapshot: Sendable {
  let id: UUID
  let title: String
  let text: String

  var revision: String {
    SHA256.hash(data: Data((id.uuidString + text).utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}

/// The editor buffer is the sole authority. Tools never infer a target from
/// desktop focus or a file path, and edits never write directly to disk.
final class DocumentToolHost: CsDocumentToolHost, Sendable {
  private let documentID: UUID
  private let snapshot: @MainActor @Sendable () -> AskDocumentSnapshot?
  private let replace: @MainActor @Sendable (String, String) -> Bool
  private let active = Mutex(true)

  init(
    documentID: UUID,
    snapshot: @escaping @MainActor @Sendable () -> AskDocumentSnapshot?,
    replace: @escaping @MainActor @Sendable (String, String) -> Bool
  ) {
    self.documentID = documentID
    self.snapshot = snapshot
    self.replace = replace
  }

  func isActive() -> Bool { active.withLock { $0 } }

  func invalidate() { active.withLock { $0 = false } }

  private func onMain<Value: Sendable>(
    _ body: @MainActor @Sendable () throws -> Value
  ) rethrows -> Value {
    if Thread.isMainThread {
      return try MainActor.assumeIsolated { try body() }
    }
    return try DispatchQueue.main.sync {
      try MainActor.assumeIsolated { try body() }
    }
  }

  func execute(name: String, argumentsJson arguments: String) throws -> String {
    // Rust calls this on its blocking pool. Only capturing/applying editor
    // state hops to MainActor; searching, hashing and encoding stay off it.
    let document = try onMain {
      guard active.withLock({ $0 }), let document = snapshot(), document.id == documentID else {
        throw failure("This document session is no longer active.")
      }
      return document
    }
    let data = Data(arguments.utf8)
    let decoder = JSONDecoder()
    switch name {
    case "document_read":
      let request = try decoder.decode(Read.self, from: data)
      let count = document.text.count
      guard request.offset >= 0, request.fromEnd == true || request.offset <= count,
        (1...8000).contains(request.limit)
      else {
        throw failure("Read offset or limit is out of bounds.")
      }
      let start = request.fromEnd == true ? max(0, count - request.offset) : request.offset
      let text = String(document.text.dropFirst(start).prefix(request.limit))
      let end = start + text.count
      return try json([
        "title": document.title, "revision": document.revision, "text": text,
        "offset": start, "total_characters": count,
        "next_offset": end < count ? end as Any : NSNull(),
      ])
    case "document_search":
      let request = try decoder.decode(Search.self, from: data)
      guard !request.query.isEmpty else { throw failure("Search text must not be empty.") }
      let offset = request.offset ?? 0
      let limit = request.limit ?? 30
      guard offset >= 0, offset <= document.text.count, (1...30).contains(limit) else {
        throw failure("Search offset or limit is out of bounds.")
      }
      var cursor = document.text.index(document.text.startIndex, offsetBy: offset)
      var matches: [[String: Any]] = []
      while cursor < document.text.endIndex, matches.count < limit,
        let range = document.text.range(of: request.query, range: cursor..<document.text.endIndex)
      {
        matches.append([
          "offset": document.text.distance(from: document.text.startIndex, to: range.lowerBound),
          "text": String(document.text[range.lowerBound...].prefix(160)),
        ])
        cursor = range.upperBound
      }
      return try json([
        "revision": document.revision, "matches": matches,
        "limit_reached": matches.count == limit,
        "next_offset": matches.count == limit && cursor < document.text.endIndex
          ? document.text.distance(from: document.text.startIndex, to: cursor) as Any : NSNull(),
      ])
    case "document_replace":
      let request = try decoder.decode(Replacement.self, from: data)
      guard request.revision == document.revision else {
        throw failure("The document changed. Read its current revision before editing.")
      }
      let range: Range<String.Index>
      if request.oldText.isEmpty {
        guard document.text.isEmpty else {
          throw failure("Empty old_text is allowed only for an empty document.")
        }
        range = document.text.startIndex..<document.text.endIndex
      } else {
        guard let match = document.text.range(of: request.oldText) else {
          throw failure("The exact text to replace was not found. Read again.")
        }
        let next = document.text.index(after: match.lowerBound)
        guard document.text.range(of: request.oldText, range: next..<document.text.endIndex) == nil
        else {
          throw failure("The text is not unique. Include more surrounding text.")
        }
        range = match
      }
      var updated = document.text
      updated.replaceSubrange(range, with: request.newText)
      let replacement = updated
      let current = try onMain {
        guard active.withLock({ $0 }), let live = snapshot(), live.id == documentID,
          live.text == document.text, replace(document.text, replacement), let current = snapshot(),
          current.id == documentID, current.text == replacement
        else { throw failure("The editor did not accept this edit. Read again.") }
        return current
      }
      return try json(["edited": true, "revision": current.revision, "direct_file_write": false])
    default:
      throw failure("Unknown document tool.")
    }
  }

  private func failure(_ message: String) -> CsError { .Agent(msg: message) }

  private func json(_ value: [String: Any]) throws -> String {
    String(
      decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
      as: UTF8.self)
  }

  private struct Read: Decodable {
    let offset: Int
    let limit: Int
    let fromEnd: Bool?
    enum CodingKeys: String, CodingKey {
      case offset, limit
      case fromEnd = "from_end"
    }
  }
  private struct Search: Decodable {
    let query: String
    let offset: Int?
    let limit: Int?
  }
  private struct Replacement: Decodable {
    let revision: String
    let oldText: String
    let newText: String
    enum CodingKeys: String, CodingKey {
      case revision
      case oldText = "old_text"
      case newText = "new_text"
    }
  }
}
