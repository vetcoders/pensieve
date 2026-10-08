import CodescribeBridge
import Foundation
import Observation
import Synchronization

protocol AskAgentStreaming: AnyObject, Sendable {
  func streamWorkspace(
    text: String, threadId: String, workspace: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String
  func cancelTurn(threadId: String) -> Bool
  func resolveToolApproval(
    sessionId: String, threadId: String, callId: String, approved: Bool, remember: Bool
  ) -> Bool
}

extension CodescribeAgent: AskAgentStreaming {}

/// One conversation and one streaming lane, independent of the current document.
/// Its UUID owns the history; its immutable context owns the capabilities.
@Observable
@MainActor
final class AskThread: Identifiable {
  let id: UUID
  let context: AskContext
  private(set) var turns: [AskTurn] = [] { didSet { onChange?(self) } }
  private(set) var phase: AskThreadPhase = .idle { didSet { onChange?(self) } }
  var isStreaming: Bool { phase == .streaming }
  private(set) var isPreparing = false
  var isBusy: Bool { isStreaming || isPreparing }
  private(set) var lastError: String?
  var draft = "" { didSet { onChange?(self) } }
  private(set) var activity: String?
  @ObservationIgnored var preparationProbe: (@Sendable () async -> Void)?
  @ObservationIgnored var onChange: (@MainActor (AskThread) -> Void)?

  /// Pending image attachments for the next send. Staged clipboard copies are
  /// Pensieve-owned; external files are only referenced.
  let attachmentStore: AskAttachmentStore

  @ObservationIgnored private let makeAgent: @Sendable () -> any AskAgentStreaming
  @ObservationIgnored private var agent: (any AskAgentStreaming)?
  @ObservationIgnored private var inFlightTask: Task<Void, Never>?
  /// The most recently started send task, retained past cancellation so a
  /// test can deterministically observe its completion instead of yielding
  /// and hoping a suspended validator already resumed.
  private(set) var lastSendTask: Task<Void, Never>?
  @ObservationIgnored private var activeHost: WorkspaceToolHost?
  @ObservationIgnored private var generation: UUID?
  @ObservationIgnored private var inFlightPrompt: String?

  init(
    id: UUID = UUID(), context: AskContext = .empty,
    makeAgent: @escaping @Sendable () -> any AskAgentStreaming = { DeferredCodescribeAgent() },
    attachmentStore: AskAttachmentStore? = nil
  ) {
    self.id = id
    self.context = context
    self.makeAgent = makeAgent
    self.attachmentStore = attachmentStore ?? AskAttachmentStore()
  }

  var streamingText: String {
    turns.last(where: { $0.role == .assistant && $0.isStreaming })?.text ?? ""
  }

  func appendDictation(_ text: String) {
    let utterance = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !utterance.isEmpty else { return }
    turns.append(AskTurn(role: .dictation, text: utterance))
  }

  func restore(turns: [AskTurn], draft: String) {
    cancel()
    self.turns = turns.map { turn in
      var restored = turn
      restored.isStreaming = false
      return restored
    }
    self.draft = draft
    lastError = nil
    activity = nil
    phase = .idle
  }

  /// Caller-side capability preparation can fail before a host exists. Keep
  /// that failure visible while preserving the user's draft and attachments.
  @discardableResult
  func rejectSubmission(_ message: String) -> Bool {
    guard !isBusy else { return false }
    lastError = message
    activity = "Failed"
    phase = .failed(message)
    return false
  }

  /// Build capabilities only on submit. Roots admit their scanned files;
  /// explicitly selected files (including ad-hoc files) are admitted individually.
  func makeHost(
    documents: [DocumentRef], database: IndexDatabase,
    initialDocument: (path: String, host: DocumentToolHost)? = nil,
    openDocument: (
      @MainActor @Sendable (DocumentRef, @escaping @Sendable () -> Bool) async throws ->
        DocumentToolHost
    )? = nil
  ) async -> WorkspaceToolHost {
    let context = self.context
    let preparationProbe = self.preparationProbe
    return await Task.detached(priority: .userInitiated) {
      if let preparationProbe { await preparationProbe() }
      // Context paths were resolved at birth. Replacing that physical path
      // with a symlink must revoke access, not silently select a new target.
      let roots = context.roots.filter { $0.isFileURL && $0.resolvingSymlinksInPath() == $0 }
      let physicalRoots = roots.map { $0.resolvingSymlinksInPath() }
      let rooted = documents.filter { ref in
        autoreleasepool {
          guard !ref.isAdHoc else { return false }
          return roots.contains {
            WorkspaceScanner.contains(ref.url.resolvingSymlinksInPath(), in: $0)
          }
            && physicalRoots.contains {
              WorkspaceScanner.contains(ref.url.resolvingSymlinksInPath(), in: $0)
            }
        }
      }
      // Explicit selections are capabilities in their own right. They do not
      // grant access to sibling files or their parent directory.
      var paths: Set<String> = []
      let pinnedFiles = context.files.filter { $0.url.resolvingSymlinksInPath() == $0.url }
      let scoped = (pinnedFiles + rooted).filter {
        $0.url.isFileURL && paths.insert($0.url.standardizedFileURL.path).inserted
      }
      let allowed = Dictionary(
        scoped.map { ref in
          autoreleasepool { (ref.url.standardizedFileURL.path, ref.url.resolvingSymlinksInPath()) }
        },
        uniquingKeysWith: { first, _ in first })
      let references = Dictionary(
        scoped.map { ($0.url.standardizedFileURL.path, $0) },
        uniquingKeysWith: { first, _ in first })
      let seededDocument = initialDocument.flatMap { initial in
        if initial.path == context.draftPath { return initial }
        guard let target = allowed[initial.path],
          URL(fileURLWithPath: initial.path).resolvingSymlinksInPath() == target
        else { return nil }
        return initial
      }
      if seededDocument == nil { initialDocument?.host.invalidate() }
      return WorkspaceToolHost(
        search: { query, limit in
          try Self.searchFromCallback(
            query: query, limit: limit,
            documents: scoped.filter { ref in
              let path = ref.url.standardizedFileURL.path
              return ref.url.resolvingSymlinksInPath() == allowed[path]
            }, database: database)
        },
        containsPath: { path in
          if path == context.draftPath, seededDocument != nil { return true }
          guard let target = allowed[path] else { return false }
          return URL(fileURLWithPath: path).resolvingSymlinksInPath() == target
        },
        readFile: { path in
          guard let target = allowed[path],
            URL(fileURLWithPath: path).resolvingSymlinksInPath() == target
          else { throw CsError.Agent(msg: "Path is outside this workspace.") }
          return try autoreleasepool { try String(contentsOf: target, encoding: .utf8) }
        },
        initialDocument: seededDocument,
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
    initialDocument: (path: String, host: DocumentToolHost)? = nil,
    openDocument: (
      @MainActor @Sendable (DocumentRef, @escaping @Sendable () -> Bool) async throws ->
        DocumentToolHost
    )? = nil
  ) async -> Bool {
    guard !isBusy else {
      initialDocument?.host.invalidate()
      return false
    }
    guard AskReadiness.isReady(provider, context: AskEndpointContext(configuration: configuration))
    else {
      lastError = AskReadiness.notReadyMessage(for: provider)
      initialDocument?.host.invalidate()
      return false
    }
    if context.draftID != nil, initialDocument?.path != context.draftPath {
      lastError =
        "The unsaved document for this conversation is no longer open. Start a new thread."
      initialDocument?.host.invalidate()
      return false
    }
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      lastError = "Write a question before sending."
      initialDocument?.host.invalidate()
      return false
    }
    let token = UUID()
    generation = token
    isPreparing = true
    activity = "Preparing…"
    let host = await makeHost(
      documents: documents, database: database, initialDocument: initialDocument,
      openDocument: openDocument)
    guard generation == token, !Task.isCancelled else {
      host.invalidate()
      if generation == token {
        generation = nil
        isPreparing = false
        activity = nil
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
    guard !isBusy else {
      if host !== activeHost { host.invalidate() }
      return false
    }
    guard AskReadiness.isReady(provider, context: AskEndpointContext(configuration: configuration))
    else {
      lastError = AskReadiness.notReadyMessage(for: provider)
      host.invalidate()
      return false
    }
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      lastError = "Write a question before sending."
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
    phase = .streaming
    activity = "Working…"
    lastError = nil
    draft = ""
    let threadID = id.uuidString.lowercased()
    let attachmentStore = self.attachmentStore
    let sendTask = Task { [weak self] in
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
          let validationProbe = attachmentStore.validationProbe
          try await Task.detached(priority: .userInitiated) {
            if let validationProbe { try await validationProbe() }
            try AskAttachmentStore.validateForSend(attachments)
          }.value
          // A Stop landing while validation was detached cancels before the
          // Rust turn exists; without this re-check the finished validator
          // would still start a provider request after Stop.
          try Task.checkCancellation()
          guard let self, self.generation == token else { throw CancellationError() }
          guard let streaming = agent as? any AskAgentAttachmentStreaming else {
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
        self.inFlightPrompt = nil
        if let eventError = self.lastError {
          // A failure reported through listener events is a failed send even
          // when the call returned: keep the draft and every attachment.
          if self.draft.isEmpty { self.draft = prompt }
          self.complete(assistantID: assistantID, text: final, error: eventError)
        } else {
          // A completed send consumes its attachments so the same images
          // cannot be submitted twice; staged copies are released.
          attachmentStore.releaseSent(ids: attachments.map(\.id))
          self.complete(assistantID: assistantID, text: final, error: nil)
        }
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
    inFlightTask = sendTask
    lastSendTask = sendTask
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
    activity = "Stopped"
    phase = .idle
  }

  private func consume(
    _ event: AskStreamListener.Event, assistantID: UUID, agent: any AskAgentStreaming
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
        "The agent requested an action outside this conversation’s context. It was refused."
    case .activity(let text): activity = text
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
    activity = error == nil ? nil : "Failed"
    phase = error.map(AskThreadPhase.failed) ?? .completed
  }
}

/// Constructs the real FFI agent only on first send so XCTest hosts of
/// `ContentView` never touch a live `CodescribeAgent()` handle.
final class DeferredCodescribeAgent: AskAgentStreaming, @unchecked Sendable {
  private let lock = NSLock()
  private var boxed: (any AskAgentStreaming)?
  private let factory: @Sendable () -> any AskAgentStreaming

  init(factory: @escaping @Sendable () -> any AskAgentStreaming = { CodescribeAgent() }) {
    self.factory = factory
  }

  func streamWorkspace(
    text: String, threadId: String, workspace: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String {
    try await resolved().streamWorkspace(
      text: text, threadId: threadId, workspace: workspace, provider: provider, listener: listener)
  }

  func streamWorkspaceWithAttachments(
    text: String, threadId: String, attachments: [CsAttachment], workspace: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String {
    guard let streaming = resolved() as? any AskAgentAttachmentStreaming else {
      throw CsError.Agent(
        msg: "This Ask engine cannot send attachments. Remove them or update the app.")
    }
    return try await streaming.streamWorkspaceWithAttachments(
      text: text, threadId: threadId, attachments: attachments, workspace: workspace,
      provider: provider, listener: listener)
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

  private func resolved() -> any AskAgentStreaming {
    lock.lock()
    defer { lock.unlock() }
    if let boxed { return boxed }
    let created = factory()
    boxed = created
    return created
  }
}

extension DeferredCodescribeAgent: AskAgentAttachmentStreaming {}

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
    case "document_open": label = "Opening document…"
    case "workspace_search": label = "Searching context…"
    case "workspace_read": label = "Reading file…"
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
