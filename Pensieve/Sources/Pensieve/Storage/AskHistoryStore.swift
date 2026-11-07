import Foundation
import GRDB

/// Durable conversation data. Loading this value never constructs an agent or tool host.
struct AskHistoryRecord: Identifiable, Sendable {
  let id: UUID
  let context: AskContext
  var turns: [AskTurn]
  var draft: String
  let createdAt: Date
  var updatedAt: Date

  init(
    id: UUID, context: AskContext, turns: [AskTurn] = [], draft: String = "",
    createdAt: Date = Date(), updatedAt: Date? = nil
  ) {
    self.id = id
    self.context = context
    self.turns = turns
    self.draft = draft
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }
}

enum AskHistoryError: Error, LocalizedError {
  case invalidContextURL(URL)
  case invalidThreadID(String)
  case invalidColumn(String)
  case unsupportedPayloadVersion(Int)
  case contextChanged(UUID)

  var errorDescription: String? {
    switch self {
    case .invalidContextURL(let url):
      return "Ask history requires an absolute file path: \(url.absoluteString)."
    case .invalidThreadID(let raw):
      return "Ask history contains an invalid thread ID: \(raw)."
    case .invalidColumn(let name):
      return "Ask history contains an invalid value in \(name)."
    case .unsupportedPayloadVersion(let version):
      return "Ask history uses an unsupported format version (\(version))."
    case .contextChanged:
      return "This Ask conversation's context changed. Start a new thread for another context."
    }
  }
}

/// One UUID-keyed table, independent of the disposable search index. Every read/write failure
/// reaches the caller; an unreadable history is never presented as an empty conversation list.
/// The earlier document/workspace Ask stores had no disk schema to import: their turns were
/// in-memory arrays. This migration creates the first durable history without inventing legacy data.
final class AskHistoryStore: Sendable {
  let databaseURL: URL
  private let database: DatabaseQueue
  private static let payloadVersion = 1

  init(databaseURL: URL? = nil) throws {
    let url = databaseURL ?? Self.defaultDatabaseURL()
    self.databaseURL = url
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    database = try DatabaseQueue(path: url.path)

    var migrator = DatabaseMigrator()
    migrator.registerMigration("ask_history_v1") { db in
      try db.execute(
        sql: """
          CREATE TABLE ask_threads (
            id TEXT PRIMARY KEY NOT NULL,
            payload_version INTEGER NOT NULL,
            context BLOB NOT NULL,
            turns BLOB NOT NULL,
            draft TEXT NOT NULL,
            created_at DOUBLE NOT NULL,
            updated_at DOUBLE NOT NULL
          )
          """)
      try db.execute(sql: "CREATE INDEX ask_threads_updated_at ON ask_threads(updated_at)")
    }
    try migrator.migrate(database)
  }

  static func defaultDatabaseURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default, isTestProcess: Bool? = nil
  ) -> URL {
    WorkspaceMetadataStore.applicationSupportDirectory(
      environment: environment, fileManager: fileManager, isTestProcess: isTestProcess
    ).appendingPathComponent("AskHistory.sqlite", isDirectory: false)
  }

  func load(id: UUID) throws -> AskHistoryRecord? {
    try database.read { db in
      try Row.fetchOne(
        db, sql: "SELECT * FROM ask_threads WHERE id = ?", arguments: [Self.key(id)]
      ).map(Self.decode)
    }
  }

  /// Most recently changed first; UUID breaks timestamp ties deterministically.
  func list() throws -> [AskHistoryRecord] {
    try database.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM ask_threads ORDER BY updated_at DESC, id ASC")
        .map(Self.decode)
    }
  }

  /// Updates retain the thread's original context and creation time. Context cannot silently
  /// widen under the same UUID, including after an app restart.
  func save(_ record: AskHistoryRecord) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let context = try encoder.encode(StoredContext(record.context))
    let turns = try encoder.encode(record.turns.map(StoredTurn.init))
    try database.write { db in
      if let existing: Row = try Row.fetchOne(
        db, sql: "SELECT * FROM ask_threads WHERE id = ?",
        arguments: [Self.key(record.id)])
      {
        let version: Int = try Self.column("payload_version", from: existing)
        guard version == Self.payloadVersion else {
          throw AskHistoryError.unsupportedPayloadVersion(version)
        }
        // A caller that failed to restore must not replace a corrupt conversation with an
        // empty snapshot under the same UUID. Validate the original before any update.
        _ = try Self.decode(existing)
        let original: Data = try Self.column("context", from: existing)
        guard original == context else { throw AskHistoryError.contextChanged(record.id) }
        try db.execute(
          sql: "UPDATE ask_threads SET turns = ?, draft = ?, updated_at = ? WHERE id = ?",
          arguments: [
            turns, record.draft, record.updatedAt.timeIntervalSince1970, Self.key(record.id),
          ])
      } else {
        try db.execute(
          sql: """
            INSERT INTO ask_threads
              (id, payload_version, context, turns, draft, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            Self.key(record.id), Self.payloadVersion, context, turns, record.draft,
            record.createdAt.timeIntervalSince1970, record.updatedAt.timeIntervalSince1970,
          ])
      }
    }
  }

  func delete(id: UUID) throws {
    try database.write { db in
      try db.execute(sql: "DELETE FROM ask_threads WHERE id = ?", arguments: [Self.key(id)])
    }
  }

  private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

  /// GRDB's nonoptional typed Row subscript traps on incompatible SQLite storage types.
  /// Decode through DatabaseValue so malformed rows become caller-visible errors instead.
  private static func column<Value: DatabaseValueConvertible>(
    _ name: String, from row: Row
  ) throws -> Value {
    let raw: DatabaseValue? = row[name]
    guard let raw, let value = Value.fromDatabaseValue(raw) else {
      throw AskHistoryError.invalidColumn(name)
    }
    return value
  }

  private static func decode(_ row: Row) throws -> AskHistoryRecord {
    let version: Int = try column("payload_version", from: row)
    guard version == payloadVersion else {
      throw AskHistoryError.unsupportedPayloadVersion(version)
    }
    let rawID: String = try column("id", from: row)
    guard let id = UUID(uuidString: rawID) else { throw AskHistoryError.invalidThreadID(rawID) }
    let contextData: Data = try column("context", from: row)
    let turnsData: Data = try column("turns", from: row)
    let decoder = JSONDecoder()
    let context = try decoder.decode(StoredContext.self, from: contextData).context()
    let turns = try decoder.decode([StoredTurn].self, from: turnsData).map(\.turn)
    let createdAt: Double = try column("created_at", from: row)
    let updatedAt: Double = try column("updated_at", from: row)
    return AskHistoryRecord(
      id: id, context: context, turns: turns, draft: try column("draft", from: row),
      createdAt: Date(timeIntervalSince1970: createdAt),
      updatedAt: Date(timeIntervalSince1970: updatedAt))
  }

  private struct StoredContext: Codable {
    let roots: [String]
    let files: [StoredDocument]
    let draftID: UUID?

    init(_ context: AskContext) throws {
      roots = try Set(context.roots.map(Self.pinnedPath)).sorted()
      files = try context.files.map(StoredDocument.init)
      draftID = context.draftID
    }

    func context() throws -> AskContext {
      AskContext(
        restoringRoots: Set(try roots.map { try Self.fileURL($0) }),
        restoringFiles: try files.map { try $0.document() },
        draftID: draftID)
    }

    /// The context resolved physical paths at birth. Saving or restoring later must not
    /// follow a symlink installed at one of those paths and silently change its authority.
    static func pinnedPath(_ url: URL) throws -> String {
      guard url.isFileURL, url.path.hasPrefix("/") else {
        throw AskHistoryError.invalidContextURL(url)
      }
      return url.standardizedFileURL.path
    }

    static func fileURL(_ path: String) throws -> URL {
      guard path.hasPrefix("/") else {
        throw AskHistoryError.invalidContextURL(URL(fileURLWithPath: path))
      }
      // Birth-canonical URLs use no directory marker. Retain that representation for exact
      // context equality without probing a path that may now be a different filesystem object.
      return URL(fileURLWithPath: path, isDirectory: false)
    }
  }

  private struct StoredDocument: Codable {
    let path: String
    let rootPath: String?
    let relativePath: String?
    let isAdHoc: Bool

    init(_ document: DocumentRef) throws {
      path = try StoredContext.pinnedPath(document.url)
      rootPath = try document.rootURL.map(StoredContext.pinnedPath)
      relativePath = document.relativePath
      isAdHoc = document.isAdHoc
    }

    func document() throws -> DocumentRef {
      DocumentRef(
        id: try StoredContext.fileURL(path),
        rootURL: try rootPath.map { try StoredContext.fileURL($0) },
        relativePath: relativePath, isAdHoc: isAdHoc)
    }
  }

  private struct StoredTurn: Codable {
    enum Role: String, Codable { case user, assistant, dictation }

    let id: UUID
    let role: Role
    let text: String
    let attachmentIDs: [UUID]

    init(_ turn: AskTurn) {
      id = turn.id
      switch turn.role {
      case .user: role = .user
      case .assistant: role = .assistant
      case .dictation: role = .dictation
      }
      text = turn.text
      attachmentIDs = turn.attachmentIDs
    }

    /// A saved delta is useful history after a crash, but a past process's stream is finished.
    var turn: AskTurn {
      let restoredRole: AskTurn.Role
      switch role {
      case .user: restoredRole = .user
      case .assistant: restoredRole = .assistant
      case .dictation: restoredRole = .dictation
      }
      return AskTurn(id: id, role: restoredRole, text: text, attachmentIDs: attachmentIDs)
    }
  }
}
