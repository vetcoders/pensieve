import CodescribeBridge
import Combine
import Foundation

/// One codescribe Ask conversation, keyed by the document's birth UUID — never
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

  /// Computes char counts and pages. Does not send. The user must confirm.
  @discardableResult
  func prepareSend(document: String, provider: AskProvider) -> AskPreflight? {
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

  /// Grill contract: send is blocked until the user has confirmed the preflight.
  @discardableResult
  func sendWithoutConfirm(document: String, provider: AskProvider) -> Bool {
    lastError = "Confirm the character counts before sending."
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
  func confirmAndSend(document: String, provider: AskProvider) -> Bool {
    guard AskReadiness.isReady(provider) else {
      lastError = AskReadiness.notReadyMessage(for: provider)
      return false
    }
    guard phase == .awaitingConfirmation, let prepared = preflight, !prepared.pages.isEmpty else {
      lastError = "Confirm the character counts before sending."
      return false
    }
    let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      lastError = "Write a question before sending."
      return false
    }
    startStreaming(prompt: prompt, pages: prepared.pages)
    return true
  }

  private func startStreaming(prompt: String, pages: [String]) {
    inFlightTask?.cancel()
    turns.append(AskTurn(role: .user, text: prompt))
    let assistantID = UUID()
    turns.append(AskTurn(id: assistantID, role: .assistant, text: "", isStreaming: true))
    phase = .streaming
    draft = ""
    lastError = nil

    let threadID = id.uuidString.lowercased()
    let agent = self.agent
    inFlightTask = Task { [weak self] in
      let listener = AskStreamListener()
      listener.onDelta = { [weak self] delta in
        Task { @MainActor in
          self?.appendDelta(assistantID: assistantID, delta: delta)
        }
      }
      listener.onComplete = { [weak self] text in
        Task { @MainActor in
          self?.replaceAssistantText(assistantID: assistantID, text: text)
        }
      }
      listener.onFailure = { [weak self] message in
        Task { @MainActor in
          self?.failStreaming(assistantID: assistantID, message: message)
        }
      }

      do {
        var last = ""
        for page in pages {
          try Task.checkCancellation()
          last = try await agent.streamReply(
            text: page, threadId: threadID, listener: listener)
        }
        await MainActor.run { [weak self] in
          self?.finishAssistant(assistantID: assistantID, text: last)
        }
      } catch is CancellationError {
        await MainActor.run { [weak self] in
          self?.failStreaming(assistantID: assistantID, message: "Ask was cancelled.")
        }
      } catch {
        await MainActor.run { [weak self] in
          self?.failStreaming(
            assistantID: assistantID, message: error.localizedDescription)
        }
      }
    }
  }

  private func appendDelta(assistantID: UUID, delta: String) {
    guard let index = turns.firstIndex(where: { $0.id == assistantID }) else { return }
    turns[index].text += delta
    turns[index].isStreaming = true
    phase = .streaming
  }

  private func replaceAssistantText(assistantID: UUID, text: String) {
    guard let index = turns.firstIndex(where: { $0.id == assistantID }) else { return }
    if !text.isEmpty {
      turns[index].text = text
    }
    turns[index].isStreaming = true
    phase = .streaming
  }

  private func finishAssistant(assistantID: UUID, text: String) {
    guard let index = turns.firstIndex(where: { $0.id == assistantID }) else { return }
    if !text.isEmpty {
      turns[index].text = text
    }
    turns[index].isStreaming = false
    phase = .completed
    preflight = nil
  }

  private func failStreaming(assistantID: UUID, message: String) {
    if let index = turns.firstIndex(where: { $0.id == assistantID }) {
      turns[index].isStreaming = false
      if turns[index].text.isEmpty {
        turns[index].text = message
      }
    }
    lastError = message
    phase = .failed(message)
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
/// actually streams through — codescribe's assistive lane (see
/// `GrokAccountSnapshot.askProvider(apiKey:)`) — so Pensieve keeps no provider
/// choice of its own that could disagree with where a question is sent.
enum AskProvider: Equatable, Sendable {
  /// OpenAI / Anthropic: the configured provider's API key (the W5 rule).
  case apiKey(String?)
  /// Grok (xAI), authenticated by device-code OAuth — never by an API key field.
  case grok(accountAuthorized: Bool)
}

/// API-key providers are ready when the key is non-empty; Grok is ready only
/// when the codescribe FFI reports its xAI account authorized.
enum AskReadiness {
  static let apiKeyNotReadyMessage = "Add a provider API key in Settings before asking."
  static let grokNotReadyMessage = "Sign in to Grok in Settings ▸ AI before asking."

  static func isReady(_ provider: AskProvider) -> Bool {
    switch provider {
    case .apiKey(let apiKey):
      let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return !key.isEmpty
    case .grok(let accountAuthorized):
      return accountAuthorized
    }
  }

  static func notReadyMessage(for provider: AskProvider) -> String {
    switch provider {
    case .apiKey: return apiKeyNotReadyMessage
    case .grok: return grokNotReadyMessage
    }
  }

  /// The composer's chip names the credential that will actually be used.
  static func chipLabel(for provider: AskProvider) -> String {
    switch provider {
    case .apiKey: return isReady(provider) ? "Ready" : "Needs API key"
    case .grok: return isReady(provider) ? "Grok ready" : "Grok: sign in"
    }
  }
}

struct AskPreflight: Equatable, Sendable {
  /// Pagination protects the app: oversized context is split, never refused.
  static let pageCharacterLimit = 8_000

  var promptCharacters: Int
  var documentCharacters: Int
  var pageCount: Int
  var totalCharacters: Int
  var pages: [String]
  var summary: String

  static func make(prompt: String, document: String) -> AskPreflight {
    let pages = paginate(prompt: prompt, document: document)
    let total = pages.reduce(0) { $0 + $1.count }
    return AskPreflight(
      promptCharacters: prompt.count,
      documentCharacters: document.count,
      pageCount: pages.count,
      totalCharacters: total,
      pages: pages,
      summary: summary(
        promptCharacters: prompt.count,
        documentCharacters: document.count,
        pageCount: pages.count,
        totalCharacters: total))
  }

  static func paginate(prompt: String, document: String) -> [String] {
    let header = "Prompt:\n\(prompt)\n\nDocument:\n"
    let combined = header + document
    if combined.isEmpty { return [""] }
    if combined.count <= pageCharacterLimit { return [combined] }

    var pages: [String] = []
    var remainder = combined
    var index = 1
    while !remainder.isEmpty {
      let limit =
        index == 1
        ? pageCharacterLimit
        : max(pageCharacterLimit - 32, 1)
      let prefix = String(remainder.prefix(limit))
      remainder = String(remainder.dropFirst(prefix.count))
      if index == 1 {
        pages.append(prefix)
      } else {
        pages.append("[continued \(index)]\n" + prefix)
      }
      index += 1
    }
    return pages
  }

  static func summary(
    promptCharacters: Int,
    documentCharacters: Int,
    pageCount: Int,
    totalCharacters: Int
  ) -> String {
    let pageWord = pageCount == 1 ? "page" : "pages"
    return
      "Prompt \(promptCharacters) characters. Document \(documentCharacters) characters. "
      + "\(totalCharacters) characters will be processed across \(pageCount) \(pageWord). "
      + "A long reply may take up to 20 minutes."
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

  func streamReply(text: String, threadId: String, listener: CsAgentListener) async throws
    -> String
  {
    let agent = resolved()
    return try await agent.streamReply(text: text, threadId: threadId, listener: listener)
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

final class AskStreamListener: CsAgentListener, @unchecked Sendable {
  var onDelta: @Sendable (String) -> Void = { _ in }
  var onComplete: @Sendable (String) -> Void = { _ in }
  var onFailure: @Sendable (String) -> Void = { _ in }

  func onTextDelta(delta: String) { onDelta(delta) }
  func onTextDone(text: String) { onComplete(text) }
  func onReasoningDelta(delta: String) {}
  func onToolExecuting(name: String, id: String) {}
  func onToolApprovalRequested(request: CsToolApprovalRequest) {}
  func onToolResult(name: String, id: String, summary: String, isError: Bool) {}
  func onDone() {}
  func onError(message: String) { onFailure(message) }
}
