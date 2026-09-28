import CodescribeBridge
import Combine
import Foundation

/// One Pensieve Ask conversation, keyed by the document's birth UUID — never
/// by path. Save As / rename keep talking to the same thread; a new untitled
/// buffer or a different file mints a new one.
@MainActor
final class DocumentAskThread: ObservableObject, Identifiable {
  let id: UUID

  @Published private(set) var turns: [AskTurn] = []
  @Published private(set) var phase: AskThreadPhase = .idle
  @Published private(set) var preflight: AskPreflight?
  @Published private(set) var lastError: String?
  @Published var draft: String = ""

  private let agent: any CodescribeAgentStreaming
  private var inFlightTask: Task<Void, Never>?
  private var activeHost: DocumentToolHost?
  private var generation: UUID?
  @Published private(set) var activity: String?

  init(id: UUID, agent: any CodescribeAgentStreaming) {
    self.id = id
    self.agent = agent
  }

  var isStreaming: Bool {
    if case .streaming = phase { return true }
    return false
  }

  var streamingText: String {
    turns.last(where: { $0.role == .assistant && $0.isStreaming })?.text ?? ""
  }

  func appendDictation(_ text: String) {
    let utterance = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !utterance.isEmpty else { return }
    turns.append(AskTurn(role: .dictation, text: utterance))
  }

  /// Explains document access before starting the agent.
  @discardableResult
  func prepareSend(document: String, provider: AskProvider) -> AskPreflight? {
    guard !isStreaming else { return nil }
    lastError = nil
    guard AskReadiness.isReady(provider) else {
      lastError = AskReadiness.notReadyMessage(for: provider)
      preflight = nil
      phase = .idle
      return nil
    }
    let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      lastError = "Write a question before sending."
      preflight = nil
      phase = .idle
      return nil
    }
    let prepared = AskPreflight.make(prompt: prompt, document: document)
    preflight = prepared
    phase = .awaitingConfirmation
    return prepared
  }

  /// Document access starts only after the user confirms.
  @discardableResult
  func sendWithoutConfirm(document: String, provider: AskProvider) -> Bool {
    lastError = "Confirm document access before sending."
    return false
  }

  func cancelPreflight() {
    preflight = nil
    lastError = nil
    if phase == .awaitingConfirmation {
      phase = .idle
    }
  }

  @discardableResult
  func confirmAndSend(
    document: String, provider: AskProvider, host: DocumentToolHost,
    configuration: CsDocumentProvider? = nil
  ) -> Bool {
    guard AskReadiness.isReady(provider) else {
      lastError = AskReadiness.notReadyMessage(for: provider)
      return false
    }
    guard phase == .awaitingConfirmation, preflight != nil else {
      lastError = "Confirm document access before sending."
      return false
    }
    let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      lastError = "Write a question before sending."
      return false
    }
    preflight = AskPreflight.make(prompt: prompt, document: document)
    startStreaming(prompt: prompt, host: host, configuration: configuration)
    return true
  }

  func cancel() {
    guard isStreaming else { return }
    activeHost?.invalidate()
    activeHost = nil
    generation = nil
    _ = agent.cancelTurn(threadId: id.uuidString.lowercased())
    inFlightTask?.cancel()
    for index in turns.indices { turns[index].isStreaming = false }
    activity = "Stopped"
    phase = .idle
    preflight = nil
  }

  private func startStreaming(
    prompt: String, host: DocumentToolHost, configuration: CsDocumentProvider?
  ) {
    let token = UUID()
    generation = token
    activeHost = host
    turns.append(AskTurn(role: .user, text: prompt))
    let assistantID = UUID()
    turns.append(AskTurn(id: assistantID, role: .assistant, text: "", isStreaming: true))
    phase = .streaming
    activity = "Working…"
    draft = ""
    lastError = nil
    let threadID = id.uuidString.lowercased()
    let agent = self.agent
    inFlightTask = Task { [weak self] in
      let listener = AskStreamListener()
      let reader = Task { @MainActor [weak self] in
        for await event in listener.events {
          guard let self, self.generation == token else { continue }
          self.consume(event, assistantID: assistantID)
        }
      }
      do {
        try Task.checkCancellation()
        let final = try await agent.streamDocument(
          text: prompt, threadId: threadID, document: host,
          provider: configuration, listener: listener)
        listener.finish()
        await reader.value
        guard let self, self.generation == token else { return }
        self.complete(assistantID: assistantID, text: final, error: self.lastError)
      } catch {
        listener.finish()
        await reader.value
        guard let self, self.generation == token else { return }
        self.complete(assistantID: assistantID, text: "", error: error.localizedDescription)
      }
    }
  }

  private func consume(_ event: AskStreamListener.Event, assistantID: UUID) {
    guard let index = turns.firstIndex(where: { $0.id == assistantID }) else { return }
    switch event {
    case .delta(let text): turns[index].text += text
    case .text(let text):
      if !text.isEmpty { turns[index].text = text }
    case .activity(let text): activity = text
    case .failure(let message): lastError = message
    case .approval(let request):
      // The document registry grants only this buffer's reversible actions.
      // Unexpected permissions are refused explicitly, never left waiting.
      _ = agent.resolveToolApproval(
        sessionId: request.sessionId, threadId: request.threadId, callId: request.callId,
        approved: false, remember: false)
      lastError = "The agent requested an action outside this document. It was refused."
    }
  }

  private func complete(assistantID: UUID, text: String, error: String?) {
    guard let index = turns.firstIndex(where: { $0.id == assistantID }) else { return }
    if !text.isEmpty { turns[index].text = text }
    turns[index].isStreaming = false
    activeHost?.invalidate()
    activeHost = nil
    generation = nil
    lastError = error
    phase = error.map(AskThreadPhase.failed) ?? .completed
    activity = error == nil ? nil : "Failed"
    preflight = nil
    inFlightTask = nil
  }

}

enum AskThreadPhase: Equatable, Sendable {
  case idle
  case awaitingConfirmation
  case streaming
  case completed
  case failed(String)
}

struct AskTurn: Equatable, Identifiable, Sendable {
  enum Role: Equatable, Sendable {
    case user
    case assistant
    case dictation
  }

  let id: UUID
  var role: Role
  var text: String
  var isStreaming: Bool

  init(id: UUID = UUID(), role: Role, text: String, isStreaming: Bool = false) {
    self.id = id
    self.role = role
    self.text = text
    self.isStreaming = isStreaming
  }
}

/// The credential Ask is gated on. Which case applies is read from the lane Ask
/// actually streams through — Pensieve's embedded assistive lane (see
/// `GrokAccountSnapshot.askProvider(apiKey:)`) — so Pensieve keeps no provider
/// choice of its own that could disagree with where a question is sent.
enum AskProvider: Equatable, Sendable {
  /// OpenAI / Anthropic: the configured provider's API key (the W5 rule).
  case apiKey(String?)
  /// Grok (xAI), authenticated by device-code OAuth — never by an API key field.
  case grok(accountAuthorized: Bool)
  /// Codex (OpenAI account), authenticated by the provider's OAuth sign-in —
  /// never by the API-key field.
  case codex(accountAuthorized: Bool)
}

/// API-key providers are ready when the key is non-empty. Grok and Codex are
/// ready only when the embedded engine reports that Pensieve account authorized.
enum AskReadiness {
  static let apiKeyNotReadyMessage = "Add a provider API key in Settings before asking."
  static let grokNotReadyMessage = "Sign in to Grok in Settings ▸ AI before asking."
  static let codexNotReadyMessage = "Sign in to Codex in Settings ▸ AI before asking."

  static func isReady(_ provider: AskProvider) -> Bool {
    switch provider {
    case .apiKey(let apiKey):
      let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return !key.isEmpty
    case .grok(let accountAuthorized), .codex(let accountAuthorized):
      return accountAuthorized
    }
  }

  static func notReadyMessage(for provider: AskProvider) -> String {
    switch provider {
    case .apiKey: return apiKeyNotReadyMessage
    case .grok: return grokNotReadyMessage
    case .codex: return codexNotReadyMessage
    }
  }

  /// The composer's chip names the credential that will actually be used.
  static func chipLabel(for provider: AskProvider) -> String {
    switch provider {
    case .apiKey: return isReady(provider) ? "Ready" : "Needs API key"
    case .grok: return isReady(provider) ? "Grok ready" : "Grok: sign in"
    case .codex: return isReady(provider) ? "Codex ready" : "Codex: sign in"
    }
  }
}

struct AskPreflight: Equatable, Sendable {
  var promptCharacters: Int
  var documentCharacters: Int
  var summary: String

  static func make(prompt: String, document: String) -> AskPreflight {
    AskPreflight(
      promptCharacters: prompt.count, documentCharacters: document.count,
      summary:
        "Instruction: \(prompt.count) characters. Current document: \(document.count) characters. "
        + "The agent can read this document and make undoable edits when requested. Changes follow your document save settings."
    )
  }
}

/// Per-window registry so Save As keeps the live thread object, not just the UUID.
@MainActor
final class DocumentAskThreadStore: ObservableObject {
  private var threads: [UUID: DocumentAskThread] = [:]
  private let makeAgent: () -> any CodescribeAgentStreaming

  init(makeAgent: @escaping () -> any CodescribeAgentStreaming = { DeferredCodescribeAgent() }) {
    self.makeAgent = makeAgent
  }

  func thread(for id: UUID) -> DocumentAskThread {
    if let existing = threads[id] { return existing }
    let created = DocumentAskThread(id: id, agent: makeAgent())
    threads[id] = created
    objectWillChange.send()
    return created
  }

  func cancelAll() { for thread in threads.values { thread.cancel() } }

  /// Non-minting lookup for chrome that only OBSERVES a thread (the status
  /// bar's Ask chip). Minting on read would birth an empty thread for every
  /// document the window merely displays.
  func existingThread(for id: UUID) -> DocumentAskThread? {
    threads[id]
  }
}

/// Constructs the real FFI agent only on first send so XCTest hosts of
/// `ContentView` never touch a live `CodescribeAgent()` handle.
final class DeferredCodescribeAgent: CodescribeAgentStreaming, @unchecked Sendable {
  private let lock = NSLock()
  private var boxed: (any CodescribeAgentStreaming)?
  private let factory: @Sendable () -> any CodescribeAgentStreaming

  init(factory: @escaping @Sendable () -> any CodescribeAgentStreaming = { CodescribeAgent() }) {
    self.factory = factory
  }

  func streamDocument(
    text: String, threadId: String, document: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String {
    try await resolved().streamDocument(
      text: text, threadId: threadId, document: document, provider: provider, listener: listener)
  }

  func cancelTurn(threadId: String) -> Bool {
    lock.lock()
    let agent = boxed
    lock.unlock()
    return agent?.cancelTurn(threadId: threadId) ?? false
  }

  func resolveToolApproval(
    sessionId: String, threadId: String, callId: String, approved: Bool, remember: Bool
  ) -> Bool {
    resolved().resolveToolApproval(
      sessionId: sessionId, threadId: threadId, callId: callId, approved: approved,
      remember: remember)
  }

  private func resolved() -> any CodescribeAgentStreaming {
    lock.lock()
    defer { lock.unlock() }
    if let boxed { return boxed }
    let created = factory()
    boxed = created
    return created
  }
}

final class AskStreamListener: CsAgentListener, Sendable {
  enum Event: Sendable {
    case delta(String)
    case text(String)
    case activity(String)
    case failure(String)
    case approval(CsToolApprovalRequest)
  }
  let events: AsyncStream<Event>
  private let continuation: AsyncStream<Event>.Continuation

  init() {
    let stream = AsyncStream<Event>.makeStream()
    events = stream.stream
    continuation = stream.continuation
  }

  func finish() { continuation.finish() }
  func onTextDelta(delta: String) { continuation.yield(.delta(delta)) }
  func onTextDone(text: String) { continuation.yield(.text(text)) }
  func onReasoningDelta(delta: String) {}
  func onToolExecuting(name: String, id: String) {
    let label: String
    switch name {
    case "document_read": label = "Reading document…"
    case "document_search": label = "Searching document…"
    case "document_replace": label = "Editing document…"
    default: label = "Working…"
    }
    continuation.yield(.activity(label))
  }
  func onToolApprovalRequested(request: CsToolApprovalRequest) {
    continuation.yield(.approval(request))
  }
  func onToolResult(name: String, id: String, summary: String, isError: Bool) {
    continuation.yield(.activity(isError ? "Action failed: \(summary)" : "Action completed"))
  }
  func onDone() {}
  func onError(message: String) { continuation.yield(.failure(message)) }
}
