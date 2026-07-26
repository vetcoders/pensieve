import CryptoKit
import Foundation

enum AIEditingTask: Equatable, Sendable {
  case inlineContinuation(AutocompleteContext)
  case rewrite(RewriteContext, RewriteIntent)
  case transformDictation(text: String, mode: String)
}

struct RewriteContext: Codable, Equatable, Sendable {
  let text: String
  let rangeLocation: Int
  let rangeLength: Int
  let documentRevision: UInt64
}

enum RewriteIntent: String, Codable, CaseIterable, Equatable, Sendable {
  case improve
  case shorten
  case expand
  case fixGrammar

  var label: String {
    switch self {
    case .improve: return "Improve Writing"
    case .shorten: return "Make Shorter"
    case .expand: return "Expand"
    case .fixGrammar: return "Fix Grammar"
    }
  }
}

struct AIRewriteCommand: Equatable, Identifiable, Sendable {
  enum Action: Equatable, Sendable {
    case request(RewriteIntent)
    case accept
    case cancel
  }

  let id = UUID()
  let action: Action
}

struct AIRewritePreview: Equatable, Identifiable, Sendable {
  let id: UUID
  let original: String
  let proposed: String
  let intent: RewriteIntent
  let replacementRange: NSRange
  let documentRevision: UInt64
}

struct ProviderFingerprint: Codable, Equatable, Sendable {
  let shape: CompletionProviderShape
  let endpoint: String
  let model: String

  fileprivate var persistenceDigest: String {
    Self.digest("\(shape.rawValue)\u{0}\(endpoint)\u{0}\(model)")
  }

  fileprivate static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

struct AcceptedAITurn: Codable, Equatable, Sendable {
  let input: String
  let output: String
}

enum DocumentAIContinuation: Codable, Equatable, Sendable {
  case none
  case openAI(previousResponseID: String)
}

struct DocumentAISession: Equatable, Sendable {
  static let maximumTurns = 12
  static let maximumLedgerUTF8Bytes = 48 * 1024

  let documentID: String
  var providerFingerprint: ProviderFingerprint?
  private var restoredProviderFingerprintDigest: String?
  var acceptedTurns: [AcceptedAITurn]
  var continuation: DocumentAIContinuation

  init(
    documentID: String,
    providerFingerprint: ProviderFingerprint? = nil,
    restoredProviderFingerprintDigest: String? = nil,
    acceptedTurns: [AcceptedAITurn] = [],
    continuation: DocumentAIContinuation = .none
  ) {
    self.documentID = documentID
    self.providerFingerprint = providerFingerprint
    self.restoredProviderFingerprintDigest = restoredProviderFingerprintDigest
    self.acceptedTurns = acceptedTurns
    self.continuation = continuation
  }

  mutating func prepare(for fingerprint: ProviderFingerprint) {
    let restoredFingerprintMatches =
      providerFingerprint == nil
      && restoredProviderFingerprintDigest == fingerprint.persistenceDigest
    if providerFingerprint != fingerprint && !restoredFingerprintMatches {
      providerFingerprint = fingerprint
      continuation = .none
    } else if restoredFingerprintMatches {
      providerFingerprint = fingerprint
    }
    restoredProviderFingerprintDigest = nil
  }

  mutating func accept(_ candidate: AICandidate) {
    guard candidate.documentID == documentID else { return }
    prepare(for: candidate.providerFingerprint)
    acceptedTurns.append(AcceptedAITurn(input: candidate.providerInput, output: candidate.text))
    continuation = candidate.pendingContinuation
    boundLedger()
  }

  mutating func invalidateOpaqueContinuation() {
    continuation = .none
  }

  private mutating func boundLedger() {
    if acceptedTurns.count > Self.maximumTurns {
      acceptedTurns.removeFirst(acceptedTurns.count - Self.maximumTurns)
    }
    while acceptedTurns.count > 1 && ledgerUTF8Bytes > Self.maximumLedgerUTF8Bytes {
      acceptedTurns.removeFirst()
    }
  }

  private var ledgerUTF8Bytes: Int {
    acceptedTurns.reduce(0) { $0 + $1.input.utf8.count + $1.output.utf8.count }
  }

  fileprivate var persistenceFingerprintDigest: String? {
    providerFingerprint?.persistenceDigest ?? restoredProviderFingerprintDigest
  }
}

struct AICandidate: Equatable, Sendable {
  let documentID: String
  let text: String
  let providerInput: String
  let providerFingerprint: ProviderFingerprint
  let pendingContinuation: DocumentAIContinuation
  let invalidatedOpaqueContinuation: Bool
  let documentRevision: UInt64
  let replacementRange: NSRange
}

protocol SessionAutocompleteCompleting: Sendable {
  func complete(
    context: AutocompleteContext,
    maxTokens: UInt32,
    session: DocumentAISession,
    documentRevision: UInt64,
    replacementRange: NSRange
  ) async throws -> AICandidate
}

protocol AIRewriting: Sendable {
  func rewrite(
    context: RewriteContext,
    intent: RewriteIntent,
    session: DocumentAISession
  ) async throws -> AICandidate
}

final class DocumentAISessionStore: @unchecked Sendable {
  static let shared = DocumentAISessionStore()

  private let lock = NSLock()
  private let fileURL: URL
  private var sessions: [String: DocumentAISession]
  private var persistedRecords: [String: PersistedRecord]

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    if let data = try? Data(contentsOf: self.fileURL),
      let envelope = try? JSONDecoder().decode(PersistedEnvelope.self, from: data),
      envelope.version == PersistedEnvelope.currentVersion
    {
      self.persistedRecords = envelope.records
    } else {
      self.persistedRecords = [:]
      // Pre-release builds briefly stored document paths and accepted text in
      // this file. Never carry that plaintext format forward.
      if FileManager.default.fileExists(atPath: self.fileURL.path) {
        try? FileManager.default.removeItem(at: self.fileURL)
      }
    }
    self.sessions = [:]
  }

  func session(for documentID: String) -> DocumentAISession {
    lock.lock()
    defer { lock.unlock() }
    if let session = sessions[documentID] { return session }
    let persisted = persistedRecords[Self.documentDigest(documentID)]
    let session = DocumentAISession(
      documentID: documentID,
      restoredProviderFingerprintDigest: persisted?.providerFingerprintDigest,
      continuation: persisted?.continuation ?? .none)
    sessions[documentID] = session
    return session
  }

  func save(_ session: DocumentAISession) {
    lock.lock()
    defer { lock.unlock() }
    sessions[session.documentID] = session

    do {
      let key = Self.documentDigest(session.documentID)
      if case .none = session.continuation {
        persistedRecords.removeValue(forKey: key)
      } else if let fingerprintDigest = session.persistenceFingerprintDigest {
        persistedRecords[key] = PersistedRecord(
          providerFingerprintDigest: fingerprintDigest,
          continuation: session.continuation)
      }
      let data = try JSONEncoder().encode(
        PersistedEnvelope(version: PersistedEnvelope.currentVersion, records: persistedRecords))
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: fileURL.deletingLastPathComponent().path)
      try data.write(to: fileURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch {
      DebugTrace.log("could not persist document AI session: \(error.localizedDescription)")
    }
  }

  private static func documentDigest(_ documentID: String) -> String {
    ProviderFingerprint.digest(documentID)
  }

  private static func defaultFileURL() -> URL {
    if let overrideRoot = AppSupportLocation.overrideRoot() {
      return overrideRoot.appendingPathComponent("document-ai-sessions.json")
    }
    let root =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? FileManager.default.temporaryDirectory
    return root.appendingPathComponent("Pensieve", isDirectory: true)
      .appendingPathComponent("document-ai-sessions.json")
  }

  private struct PersistedEnvelope: Codable {
    static let currentVersion = 1

    let version: Int
    let records: [String: PersistedRecord]
  }

  private struct PersistedRecord: Codable {
    let providerFingerprintDigest: String
    let continuation: DocumentAIContinuation
  }
}
