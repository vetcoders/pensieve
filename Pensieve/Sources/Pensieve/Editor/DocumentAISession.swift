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
}

struct ProviderFingerprint: Codable, Equatable, Sendable {
  let shape: CompletionProviderShape
  let endpoint: String
  let model: String
}

struct AcceptedAITurn: Codable, Equatable, Sendable {
  let input: String
  let output: String
}

enum DocumentAIContinuation: Codable, Equatable, Sendable {
  case none
  case openAI(previousResponseID: String)
}

struct DocumentAISession: Codable, Equatable, Sendable {
  static let maximumTurns = 12
  static let maximumLedgerUTF8Bytes = 48 * 1024

  let documentID: String
  var providerFingerprint: ProviderFingerprint?
  var acceptedTurns: [AcceptedAITurn]
  var continuation: DocumentAIContinuation

  init(
    documentID: String,
    providerFingerprint: ProviderFingerprint? = nil,
    acceptedTurns: [AcceptedAITurn] = [],
    continuation: DocumentAIContinuation = .none
  ) {
    self.documentID = documentID
    self.providerFingerprint = providerFingerprint
    self.acceptedTurns = acceptedTurns
    self.continuation = continuation
  }

  mutating func prepare(for fingerprint: ProviderFingerprint) {
    if providerFingerprint != fingerprint {
      providerFingerprint = fingerprint
      continuation = .none
    }
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

final class DocumentAISessionStore: @unchecked Sendable {
  private let lock = NSLock()
  private let fileURL: URL
  private var sessions: [String: DocumentAISession]

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
    if let data = try? Data(contentsOf: self.fileURL),
      let decoded = try? JSONDecoder().decode([String: DocumentAISession].self, from: data)
    {
      self.sessions = decoded
    } else {
      self.sessions = [:]
    }
  }

  func session(for documentID: String) -> DocumentAISession {
    lock.lock()
    defer { lock.unlock() }
    return sessions[documentID] ?? DocumentAISession(documentID: documentID)
  }

  func save(_ session: DocumentAISession) {
    lock.lock()
    defer { lock.unlock() }
    sessions[session.documentID] = session

    guard let data = try? JSONEncoder().encode(sessions) else { return }
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      DebugTrace.log("could not persist document AI session: \(error.localizedDescription)")
    }
  }

  private static func defaultFileURL() -> URL {
    let root =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? FileManager.default.temporaryDirectory
    return root.appendingPathComponent("Pensieve", isDirectory: true)
      .appendingPathComponent("document-ai-sessions.json")
  }
}
