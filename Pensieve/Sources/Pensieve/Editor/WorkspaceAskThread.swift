import CodescribeBridge
import Foundation
import Observation
import Synchronization

protocol WorkspaceAgentStreaming: AnyObject, Sendable {
  func streamWorkspace(
    text: String, threadId: String, workspace: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String
  func cancelTurn(threadId: String) -> Bool
  func resolveToolApproval(
    sessionId: String, threadId: String, callId: String, approved: Bool, remember: Bool
  ) -> Bool
}

extension CodescribeAgent: WorkspaceAgentStreaming {}

/// A workspace conversation survives document and tab changes. The root-set
/// identity, not the editor's document identity, owns its history and tools.
@Observable
@MainActor
final class WorkspaceAskThread {
  let identity: WorkspaceIdentity
  let id = UUID()
  private(set) var turns: [AskTurn] = []
  private(set) var isStreaming = false
  private(set) var isPreparing = false
  var isBusy: Bool { isStreaming || isPreparing }
  private(set) var lastError: String?
  var draft = ""

  /// Pending image attachments for the next send. Staged clipboard copies are
  /// Pensieve-owned; external files are only referenced.
  let attachmentStore: AskAttachmentStore

  @ObservationIgnored private let makeAgent: @Sendable () -> any WorkspaceAgentStreaming
  @ObservationIgnored private var agent: (any WorkspaceAgentStreaming)?
  @ObservationIgnored private var inFlightTask: Task<Void, Never>?
  @ObservationIgnored private var activeHost: WorkspaceToolHost?
  @ObservationIgnored private var generation: UUID?
  @ObservationIgnored private var inFlightPrompt: String?

  init(
    identity: WorkspaceIdentity,
    makeAgent: @escaping @Sendable () -> any WorkspaceAgentStreaming = { CodescribeAgent() },
    attachmentStore: AskAttachmentStore? = nil
  ) {
    self.identity = identity
    self.makeAgent = makeAgent
    self.attachmentStore = attachmentStore ?? AskAttachmentStore()
  }

  /// Called on submit, never in a view body. Only indexed documents belonging
  /// to these roots are admitted; ad-hoc files are outside workspace access.
  func makeHost(
    documents: [DocumentRef], database: IndexDatabase,
    openDocument: (
      @MainActor @Sendable (DocumentRef, @escaping @Sendable () -> Bool) async throws ->
        DocumentToolHost
    )? = nil
  ) async -> WorkspaceToolHost {
    let identity = self.identity
    return await Task.detached(priority: .userInitiated) {
      let roots = Set(identity.canonicalRootURLs.map(\.standardizedFileURL))
      let physicalRoots = roots.map { $0.resolvingSymlinksInPath() }
      let scoped = documents.filter { ref in
        autoreleasepool {
          guard let root = ref.rootURL, !ref.isAdHoc else { return false }
          return roots.contains(root.standardizedFileURL)
            && WorkspaceScanner.contains(ref.url, in: root)
            && physicalRoots.contains {
              WorkspaceScanner.contains(ref.url.resolvingSymlinksInPath(), in: $0)
            }
        }
      }
      let allowed = Dictionary(
        scoped.map { ref in
          autoreleasepool { (ref.url.standardizedFileURL.path, ref.url.resolvingSymlinksInPath()) }
        },
        uniquingKeysWith: { first, _ in first })
      let references = Dictionary(
        scoped.map { ($0.url.standardizedFileURL.path, $0) },
        uniquingKeysWith: { first, _ in first })
      return WorkspaceToolHost(
        search: { query, limit in
          try Self.searchFromCallback(
            query: query, limit: limit, documents: scoped, database: database)
        },
        containsPath: { path in
          guard let target = allowed[path] else { return false }
          return URL(fileURLWithPath: path).resolvingSymlinksInPath() == target
        },
        readFile: { path in
          guard let target = allowed[path],
            URL(fileURLWithPath: path).resolvingSymlinksInPath() == target
          else { throw CsError.Agent(msg: "Path is outside this workspace.") }
          return try autoreleasepool { try String(contentsOf: target, encoding: .utf8) }
        },
        openDocument: { path, isActive in
          guard let ref = references[path], let target = allowed[path],
            URL(fileURLWithPath: path).resolvingSymlinksInPath() == target,
            let openDocument
          else { throw CsError.Agent(msg: "The document cannot be opened from this workspace.") }
          return try Self.openFromCallback(ref: ref, isActive: isActive, openDocument: openDocument)
        })
    }.value
  }

  nonisolated private static func openFromCallback(
    ref: DocumentRef, isActive: @escaping @Sendable () -> Bool,
    openDocument:
      @escaping @MainActor @Sendable (DocumentRef, @escaping @Sendable () -> Bool) async throws ->
      DocumentToolHost
  ) throws -> DocumentToolHost {
    guard !Thread.isMainThread else {
      throw CsError.Agent(msg: "Document opening must run off the main thread.")
    }
    let ready = DispatchSemaphore(value: 0)
    let result = Mutex<Result<DocumentToolHost, any Error>?>(nil)
    Task { @MainActor in
      defer { ready.signal() }
      do {
        guard isActive() else { throw CsError.Agent(msg: "The workspace request was stopped.") }
        let host = try await openDocument(ref, isActive)
        result.withLock { $0 = .success(host) }
      } catch { result.withLock { $0 = .failure(error) } }
    }
    ready.wait()
    guard let outcome = result.withLock({ $0 }) else {
      throw CsError.Agent(msg: "Document opening did not return a result.")
    }
    return try outcome.get()
  }

  /// UniFFI's synchronous callback runs on Rust's spawn_blocking pool. Wait
  /// only there: GRDB and snippet reads use the existing background search.
  nonisolated private static func searchFromCallback(
    query: String, limit: Int, documents: [DocumentRef], database: IndexDatabase
  ) throws -> String {
    guard !Thread.isMainThread else {
      throw CsError.Agent(msg: "Workspace search must run off the main thread.")
    }
    let ready = DispatchSemaphore(value: 0)
    let result = Mutex<Result<String, any Error>?>(nil)
    Task { @MainActor in
      defer { ready.signal() }
      do {
        let json = try await WorkspaceSearchTool.workspaceSearchInBackground(
          query: query, limit: limit, documents: documents, database: database)
        result.withLock { $0 = .success(json) }
      } catch {
        result.withLock { $0 = .failure(error) }
      }
    }
    ready.wait()
    guard let outcome = result.withLock({ $0 }) else {
      throw CsError.Agent(msg: "Workspace search did not return a result.")
    }
    return try outcome.get()
  }

  @discardableResult
  func prepareAndSend(
    text: String, documents: [DocumentRef], database: IndexDatabase,
    provider: AskProvider, configuration: CsDocumentProvider? = nil,
    openDocument: (
      @MainActor @Sendable (DocumentRef, @escaping @Sendable () -> Bool) async throws ->
        DocumentToolHost
    )? = nil
  ) async -> Bool {
    guard !isBusy else { return false }
    guard AskReadiness.isReady(provider) else {
      lastError = AskReadiness.notReadyMessage(for: provider)
      return false
    }
    let token = UUID()
    generation = token
    isPreparing = true
    let host = await makeHost(documents: documents, database: database, openDocument: openDocument)
    guard generation == token, !Task.isCancelled else {
      host.invalidate()
      if generation == token {
        generation = nil
        isPreparing = false
      }
      return false
    }
    isPreparing = false
    generation = nil
    return send(text: text, host: host, provider: provider, configuration: configuration)
  }

  @discardableResult
  func send(
    text: String, host: WorkspaceToolHost, provider: AskProvider,
    configuration: CsDocumentProvider? = nil
  ) -> Bool {
    guard !isBusy else { return false }
    guard AskReadiness.isReady(provider) else {
      lastError = AskReadiness.notReadyMessage(for: provider)
      host.invalidate()
      return false
    }
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      host.invalidate()
      return false
    }
    let agent = self.agent ?? makeAgent()
    self.agent = agent
    let attachments = attachmentStore.attachments
    let token = UUID()
    generation = token
    activeHost = host
    inFlightPrompt = prompt
    turns.append(
      AskTurn(role: .user, text: prompt, attachmentIDs: attachments.map(\.id)))
    let assistantID = UUID()
    turns.append(AskTurn(id: assistantID, role: .assistant, text: "", isStreaming: true))
    isStreaming = true
    lastError = nil
    draft = ""
    let threadID = id.uuidString.lowercased()
    let attachmentStore = self.attachmentStore
    inFlightTask = Task { [weak self] in
      let listener = AskStreamListener()
      let reader = Task { @MainActor [weak self] in
        for await event in listener.events {
          guard let self, self.generation == token else { continue }
          self.consume(event, assistantID: assistantID, agent: agent)
        }
      }
      do {
        try Task.checkCancellation()
        let final: String
        if attachments.isEmpty {
          final = try await agent.streamWorkspace(
            text: prompt, threadId: threadID, workspace: host,
            provider: configuration, listener: listener)
        } else {
          // Validation runs here, off the UI actor and before anything reaches
          // the provider; the Rust side re-validates authoritatively.
          try await Task.detached(priority: .userInitiated) {
            try AskAttachmentStore.validateForSend(attachments)
          }.value
          guard let streaming = agent as? any WorkspaceAgentAttachmentStreaming else {
            throw CsError.Agent(
              msg: "This Ask engine cannot send attachments. Remove them or update the app.")
          }
          final = try await streaming.streamWorkspaceWithAttachments(
            text: prompt, threadId: threadID,
            attachments: attachments.map { CsAttachment(path: $0.url.path) }, workspace: host,
            provider: configuration, listener: listener)
        }
        listener.finish()
        await reader.value
        guard let self, self.generation == token else { return }
        // A completed send consumes its attachments so the same images cannot
        // be submitted twice; staged copies are released.
        attachmentStore.releaseSent(ids: attachments.map(\.id))
        self.inFlightPrompt = nil
        self.complete(assistantID: assistantID, text: final, error: self.lastError)
      } catch {
        listener.finish()
        await reader.value
        guard let self, self.generation == token else { return }
        // A failed send keeps the draft (unless a newer one exists) and keeps
        // every attachment pending.
        if self.draft.isEmpty { self.draft = prompt }
        self.inFlightPrompt = nil
        self.complete(assistantID: assistantID, text: "", error: error.localizedDescription)
      }
    }
    return true
  }

  func cancel() {
    guard isBusy else { return }
    isPreparing = false
    generation = nil
    activeHost?.invalidate()
    activeHost = nil
    _ = agent?.cancelTurn(threadId: id.uuidString.lowercased())
    inFlightTask?.cancel()
    inFlightTask = nil
    for index in turns.indices { turns[index].isStreaming = false }
    // A stopped turn keeps the user's input unless a newer draft replaced it.
    if let prompt = inFlightPrompt, draft.isEmpty { draft = prompt }
    inFlightPrompt = nil
    isStreaming = false
  }

  private func consume(
    _ event: AskStreamListener.Event, assistantID: UUID, agent: any WorkspaceAgentStreaming
  ) {
    guard let index = turns.firstIndex(where: { $0.id == assistantID }) else { return }
    switch event {
    case .delta(let text): turns[index].text += text
    case .text(let text): if !text.isEmpty { turns[index].text = text }
    case .failure(let message): lastError = message
    case .approval(let request):
      _ = agent.resolveToolApproval(
        sessionId: request.sessionId, threadId: request.threadId, callId: request.callId,
        approved: false, remember: false)
      lastError =
        "The agent requested an action outside this workspace and its open documents. It was refused."
    case .activity: break
    }
  }

  private func complete(assistantID: UUID, text: String, error: String?) {
    guard let index = turns.firstIndex(where: { $0.id == assistantID }) else { return }
    if !text.isEmpty { turns[index].text = text }
    turns[index].isStreaming = false
    activeHost?.invalidate()
    activeHost = nil
    generation = nil
    inFlightTask = nil
    lastError = error
    isStreaming = false
  }
}

@MainActor
final class WorkspaceAskThreadStore {
  static let shared = WorkspaceAskThreadStore()
  private var threads: [String: WorkspaceAskThread] = [:]
  private let makeAgent: @Sendable () -> any WorkspaceAgentStreaming

  init(makeAgent: @escaping @Sendable () -> any WorkspaceAgentStreaming = { CodescribeAgent() }) {
    self.makeAgent = makeAgent
  }

  func thread(for identity: WorkspaceIdentity) -> WorkspaceAskThread {
    if let existing = threads[identity.workspaceID] { return existing }
    let thread = WorkspaceAskThread(identity: identity, makeAgent: makeAgent)
    threads[identity.workspaceID] = thread
    return thread
  }
}
