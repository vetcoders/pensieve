import CodescribeBridge
import Synchronization
import XCTest

@testable import Pensieve

/// Real-path integration for the assembled Ask UI: the production transcript
/// model (off-main, bounded, latest-wins), scoped attachment sends through
/// both threads, surface transitions that preserve conversation state, and
/// the keyless loopback readiness policy shared by both scopes.
@MainActor
final class AskConversationIntegrationTests: XCTestCase {
  private var scratch: URL!

  override func setUp() {
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ask-conversation-integration-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: scratch)
    scratch = nil
  }

  private func makeStore() -> AskAttachmentStore {
    AskAttachmentStore(
      stagingDirectory: scratch.appendingPathComponent("staging", isDirectory: true))
  }

  private func makeWorkspaceHost() -> WorkspaceToolHost {
    WorkspaceToolHost(
      search: { _, _ in #"{"matches":[]}"# },
      containsPath: { _ in false },
      readFile: { _ in throw CsError.Agent(msg: "no files in this fixture") })
  }

  private func drain(_ model: AskConversationModel) async {
    while model.hasPendingWork { await model.awaitParseWorker() }
  }

  // MARK: Production parse path

  /// A fast stream must not parse per delta: the coalescer publishes at most
  /// ten times a second and the worker is one latest-wins job. Every parse
  /// runs off the UI executor, and the final text is what gets parsed last.
  func testStreamingParseIsBoundedOffMainAndLatestWins() async {
    let now = Mutex(TimeInterval(0))
    let offMain = Mutex([Bool]())
    let model = AskConversationModel(
      clock: { now.withLock { $0 } },
      parse: { text in
        offMain.withLock { $0.append(!Thread.isMainThread) }
        return AskMarkdownParser.parse(text)
      })
    let turnID = UUID()
    for step in 0..<30 {
      now.withLock { $0 = TimeInterval(step) * 0.01 }
      model.observe(turns: [
        AskTurn(
          id: turnID, role: .assistant, text: String(repeating: "word ", count: step + 1),
          isStreaming: true)
      ])
    }
    now.withLock { $0 = 1.0 }
    model.observe(turns: [
      AskTurn(
        id: turnID, role: .assistant, text: String(repeating: "word ", count: 31),
        isStreaming: false)
    ])
    await drain(model)

    let id = turnID.uuidString
    let parses = model.parseCount(for: id)
    XCTAssertLessThanOrEqual(
      parses, 5,
      "30 deltas in 300ms coalesce to a handful of publications plus the final flush, got \(parses)"
    )
    XCTAssertGreaterThanOrEqual(parses, 1)
    XCTAssertFalse(offMain.withLock { $0 }.contains(false), "every parse ran off the main thread")
    XCTAssertEqual(model.document(for: id)?.source, String(repeating: "word ", count: 31))
    XCTAssertEqual(model.snapshot.turns.last?.roleLabel, "Pensieve")
  }

  /// A completed turn parses once per text revision; re-observing the same
  /// text costs nothing, and a stale result can never overwrite newer text.
  func testCompletedTurnParsesOncePerRevisionAndStaleLoses() async {
    let gate = ParseGate()
    let model = AskConversationModel(
      clock: { 0 },
      parse: { text in
        gate.wait()
        return AskMarkdownParser.parse(text)
      })
    let turnID = UUID()
    model.observe(turns: [AskTurn(id: turnID, role: .assistant, text: "first **draft**")])
    // Re-observing identical text must not request another parse.
    model.observe(turns: [AskTurn(id: turnID, role: .assistant, text: "first **draft**")])
    // A newer revision lands while the first parse is still suspended.
    model.observe(turns: [AskTurn(id: turnID, role: .assistant, text: "second **draft**")])
    gate.open()
    await drain(model)
    // Re-observe the settled text: still no new parse.
    model.observe(turns: [AskTurn(id: turnID, role: .assistant, text: "second **draft**")])
    await drain(model)

    let id = turnID.uuidString
    XCTAssertEqual(
      model.document(for: id)?.source, "second **draft**",
      "the newer revision wins; the stale first parse cannot overwrite it")
    XCTAssertLessThanOrEqual(
      model.parseCount(for: id), 2,
      "at most one parse per revision, none for unchanged re-observation")
  }

  /// A scope switch evicts turns from the visible list; coming back with
  /// unchanged text must reuse the cached document, not re-parse.
  func testScopeSwitchRoundTripReusesParsedDocuments() async {
    let model = AskConversationModel(clock: { 0 })
    let documentTurn = UUID()
    let workspaceTurn = UUID()
    model.observe(turns: [AskTurn(id: documentTurn, role: .assistant, text: "document answer")])
    await drain(model)
    XCTAssertEqual(model.parseCount(for: documentTurn.uuidString), 1)

    // Workspace scope becomes active: the document turn leaves the list.
    model.observe(turns: [AskTurn(id: workspaceTurn, role: .assistant, text: "workspace answer")])
    await drain(model)
    XCTAssertEqual(model.snapshot.turns.map(\.id), [workspaceTurn.uuidString])

    // Back to the document scope with the same text: cached, not re-parsed.
    model.observe(turns: [AskTurn(id: documentTurn, role: .assistant, text: "document answer")])
    await drain(model)
    XCTAssertEqual(model.snapshot.turns.map(\.id), [documentTurn.uuidString])
    XCTAssertEqual(
      model.parseCount(for: documentTurn.uuidString), 1,
      "an unchanged turn keeps its revision and its cached document")
  }

  // MARK: Scoped attachments through the real send path

  /// Document scope: a staged image reaches the scoped provider seam with its
  /// exact path, the sent turn carries the exact attachment ID, and the
  /// transcript model renders the completed conversation.
  func testDocumentScopedAttachmentSendIntegratesWithTranscript() async throws {
    let agent = IntegrationAttachmentAgent()
    let store = makeStore()
    let thread = DocumentAskThread(id: UUID(), agent: agent, attachmentStore: store)
    let model = AskConversationModel()
    let attachment = try await store.stageImage(
      data: Data([0x89, 0x50, 0x4E, 0x47]), fileExtension: "png")
    thread.draft = "What is in this image?"
    model.observe(turns: thread.turns)

    XCTAssertTrue(
      thread.send(provider: .apiKey("sk-test"), host: AskDocumentFixture.host(text: "note")))
    let sentTask = thread.lastSendTask
    await sentTask?.value

    XCTAssertEqual(agent.attachmentPaths, [attachment.url.path])
    XCTAssertEqual(agent.configurations.count, 0, "no API-key configuration was supplied")
    let userTurn = try XCTUnwrap(thread.turns.first { $0.role == .user })
    XCTAssertEqual(userTurn.attachmentIDs, [attachment.id])
    XCTAssertTrue(store.attachments.isEmpty, "a completed send consumes its attachments")
    XCTAssertEqual(thread.phase, .completed)

    model.observe(turns: thread.turns)
    await drain(model)
    XCTAssertEqual(model.snapshot.totalCount, 2)
    XCTAssertEqual(model.snapshot.turns.first?.roleLabel, "You")
    XCTAssertEqual(model.snapshot.turns.last?.roleLabel, "Pensieve")
    XCTAssertEqual(
      model.snapshot.turns.last?.document.blocks.isEmpty, false,
      "the assistant reply rendered through the off-main parse")
  }

  /// Workspace scope: the same delivery through the scoped workspace seam.
  func testWorkspaceScopedAttachmentSendIntegratesWithTranscript() async throws {
    let agent = IntegrationWorkspaceAttachmentAgent()
    let store = makeStore()
    let thread = WorkspaceAskThread(
      identity: WorkspaceIdentity.make(rootURL: scratch, bookmarkData: nil),
      makeAgent: { agent }, attachmentStore: store)
    let model = AskConversationModel()
    let attachment = try await store.stageImage(
      data: Data([0x89, 0x50, 0x4E, 0x47]), fileExtension: "png")

    XCTAssertTrue(
      thread.send(
        text: "Summarize the screenshot.", host: makeWorkspaceHost(),
        provider: .apiKey("sk-test")))
    let sentTask = thread.lastSendTask
    await sentTask?.value

    XCTAssertEqual(agent.attachmentPaths, [attachment.url.path])
    XCTAssertEqual(thread.turns.first { $0.role == .user }?.attachmentIDs, [attachment.id])
    XCTAssertTrue(store.attachments.isEmpty)
    XCTAssertFalse(thread.isStreaming)
    XCTAssertNil(thread.lastError)

    model.observe(turns: thread.turns)
    await drain(model)
    XCTAssertEqual(model.snapshot.totalCount, 2)
    XCTAssertEqual(model.snapshot.turns.last?.document.source, "workspace image reply")
  }

  /// Dock/float/expand/hide transitions rewrite the presentation only: the
  /// conversation, draft, attachments and provider ride along unchanged, and
  /// no transition duplicates the request or its stream subscription.
  func testSurfaceTransitionsPreserveScopedConversationState() throws {
    let userTurn = AskTurn(role: .user, text: "attached question", attachmentIDs: [UUID()])
    var carry = AskSurfaceCarry(
      conversation: [userTurn],
      draft: "unfinished follow-up",
      attachments: ["staged.png"],
      provider: "openai",
      requestID: UUID(),
      streamSubscribers: 1,
      presentation: .expandedDefault)
    let content = AskSurfaceLayout.referenceContent

    XCTAssertEqual(carry.apply(.float, content: content), .presented)
    XCTAssertEqual(carry.presentation.mode, .floating)
    XCTAssertEqual(carry.apply(.dock, content: content), .presented)
    XCTAssertEqual(carry.apply(.collapse, content: content), .presented)
    XCTAssertEqual(carry.apply(.expand, content: content), .presented)
    XCTAssertEqual(carry.presentation.mode, .docked)

    XCTAssertEqual(carry.conversation, [userTurn], "the conversation is untouched")
    XCTAssertEqual(carry.draft, "unfinished follow-up", "the draft is untouched")
    XCTAssertEqual(carry.attachments, ["staged.png"], "pending attachments are untouched")
    XCTAssertEqual(carry.provider, "openai")
    XCTAssertEqual(carry.streamSubscribers, 1, "no second subscriber appeared")

    XCTAssertEqual(carry.apply(.hide, content: content), .concealed)
    XCTAssertEqual(carry.conversation, [userTurn], "hide conceals; it does not stop the turn")
    XCTAssertEqual(carry.apply(.stop, content: content), .cancelTurn)
    XCTAssertNotEqual(AskCommandEffect.cancelTurn, .concealed, "Stop and Hide stay distinct")
  }

  // MARK: Gesture continuity (Founder resize steering review)

  /// A collapsed dock (preferred 398 remembered, 158 displayed) must drag
  /// from its DISPLAYED height: the first 1px upward sample grows it by
  /// exactly 1px, with no ~241px jump from the remembered preference. The
  /// view's gesture snapshot uses `displayedDockHeight`; this pins the
  /// continuity that choice guarantees.
  func testCollapsedDockFirstDragContinuesFromDisplayedHeight() {
    var state = AskPresentationState.expandedDefault
    state.isExpanded = false
    let content = AskSurfaceLayout.referenceContent
    let displayed = AskSurfaceLayout.displayedDockHeight(
      presentation: state, content: content)
    XCTAssertEqual(displayed, AskSurfaceLayout.collapsedDockHeight, accuracy: 0.001)
    XCTAssertLessThan(displayed, state.preferredDockHeight)

    AskPointerRoute.apply(
      .dockResize, to: &state, content: content,
      dockStart: displayed, originStart: state.floatOrigin,
      sizeStart: state.preferredFloatSize,
      translation: CGSize(width: 0, height: -1))
    XCTAssertEqual(
      AskSurfaceLayout.displayedDockHeight(presentation: state, content: content),
      displayed + 1, accuracy: 0.001,
      "the first small drag continues from the displayed height")
  }

  /// On a clamped small window (preferred 398, displayed 294) a downward
  /// first drag shrinks immediately — there is no dead interval while the
  /// remembered preference climbs down to the clamp.
  func testClampedDockDragHasNoDeadInterval() {
    var state = AskPresentationState.expandedDefault
    let content = CGSize(width: 640, height: 480)
    let displayed = AskSurfaceLayout.displayedDockHeight(
      presentation: state, content: content)
    XCTAssertLessThan(displayed, state.preferredDockHeight, "the dock is clamped here")

    AskPointerRoute.apply(
      .dockResize, to: &state, content: content,
      dockStart: displayed, originStart: state.floatOrigin,
      sizeStart: state.preferredFloatSize,
      translation: CGSize(width: 0, height: 10))
    XCTAssertEqual(
      AskSurfaceLayout.displayedDockHeight(presentation: state, content: content),
      displayed - 10, accuracy: 0.001,
      "dragging down from the clamped display height responds immediately")
  }

  /// A clamped float resizes from its displayed frame, not from a hidden
  /// larger preference: a 12px shrink shows exactly 12px.
  func testClampedFloatResizeContinuesFromDisplayedFrame() {
    var state = AskPresentationState.expandedDefault
    state.mode = .floating
    let content = CGSize(width: 480, height: 360)
    let displayed = AskSurfaceLayout.displayedFloatFrame(
      presentation: state, content: content)
    XCTAssertLessThan(
      displayed.size.height, state.preferredFloatSize.height, "the float is clamped here")

    AskPointerRoute.apply(
      .floatResize, to: &state, content: content,
      dockStart: state.preferredDockHeight, originStart: state.floatOrigin,
      sizeStart: displayed.size,
      translation: CGSize(width: 0, height: -12))
    let resized = AskSurfaceLayout.displayedFloatFrame(
      presentation: state, content: content)
    XCTAssertEqual(
      resized.size.height, displayed.size.height - 12, accuracy: 0.001,
      "the resize continues from the displayed frame size")
  }

  /// A float parked outside the safe area drags from its clamped displayed
  /// origin: the first 5px move actually moves the panel 5px instead of
  /// fighting the stored off-screen coordinate.
  func testOffscreenFloatDragContinuesFromDisplayedOrigin() {
    var state = AskPresentationState.expandedDefault
    state.mode = .floating
    state.floatOrigin = CGPoint(x: 5000, y: 4000)
    let content = AskSurfaceLayout.referenceContent
    let displayed = AskSurfaceLayout.displayedFloatFrame(
      presentation: state, content: content)
    XCTAssertNotEqual(displayed.origin, state.floatOrigin, "the float is clamped on screen")

    AskPointerRoute.apply(
      .floatDrag, to: &state, content: content,
      dockStart: state.preferredDockHeight, originStart: displayed.origin,
      sizeStart: state.preferredFloatSize,
      translation: CGSize(width: -5, height: -5))
    let dragged = AskSurfaceLayout.displayedFloatFrame(
      presentation: state, content: content)
    XCTAssertEqual(dragged.origin.x, displayed.origin.x - 5, accuracy: 0.001)
    XCTAssertEqual(dragged.origin.y, displayed.origin.y - 5, accuracy: 0.001)
  }

  // MARK: Keyless loopback readiness (both scopes share this policy)

  func testLoopbackEndpointWithoutKeyReadinessMatrix() {
    let positives = [
      "http://127.0.0.1:8000/v1/responses",
      "http://localhost:9000/v1/responses",
      "https://localhost:8443/v1/responses",
      "http://[::1]:8000/v1/responses",
    ]
    for endpoint in positives {
      let context = AskEndpointContext(endpoint: endpoint, model: "buddy")
      XCTAssertTrue(
        AskReadiness.isReady(.apiKey(""), context: context),
        "loopback \(endpoint) with a model runs keyless")
    }

    let remote = AskEndpointContext(endpoint: "https://api.openai.com/v1/responses", model: "gpt")
    XCTAssertFalse(
      AskReadiness.isReady(.apiKey(""), context: remote),
      "a remote endpoint still needs the API key")
    let lookalike = AskEndpointContext(
      endpoint: "http://127.0.0.1.evil.com/v1/responses", model: "buddy")
    XCTAssertFalse(
      AskReadiness.isReady(.apiKey(""), context: lookalike),
      "a loopback lookalike host is not loopback")
    let scheme = AskEndpointContext(endpoint: "ftp://127.0.0.1:8000/v1/responses", model: "buddy")
    XCTAssertFalse(
      AskReadiness.isReady(.apiKey(""), context: scheme),
      "only http(s) configuration qualifies")
    let noModel = AskEndpointContext(endpoint: "http://127.0.0.1:8000/v1/responses", model: " ")
    XCTAssertFalse(
      AskReadiness.isReady(.apiKey(""), context: noModel),
      "a keyless send still requires a model")
    XCTAssertFalse(
      AskReadiness.isReady(.apiKey("")),
      "without endpoint context the API-key rule is unchanged")
    XCTAssertTrue(
      AskReadiness.isReady(.apiKey("sk-live"), context: remote),
      "a real key is ready anywhere")
    XCTAssertEqual(
      AskReadiness.chipLabel(
        for: .apiKey(""),
        context: AskEndpointContext(endpoint: "http://127.0.0.1:8000/v1/responses", model: "m")),
      "Local endpoint ready")
  }

  /// The scoped send path with an empty key: the configured loopback
  /// endpoint and model reach the provider seam unchanged — no invented
  /// credential, no readiness block.
  func testDocumentSendToLoopbackWithEmptyKeySendsConfiguredEndpoint() async throws {
    let agent = IntegrationAttachmentAgent()
    let thread = DocumentAskThread(id: UUID(), agent: agent, attachmentStore: makeStore())
    thread.draft = "Hello, local model."
    let configuration = CsDocumentProvider(
      wire: "openai-responses",
      endpoint: "http://127.0.0.1:8000/v1/responses",
      model: "buddy",
      apiKey: "")

    XCTAssertTrue(
      thread.send(
        provider: .apiKey(""), host: AskDocumentFixture.host(text: "note"),
        configuration: configuration))
    let sentTask = thread.lastSendTask
    await sentTask?.value

    XCTAssertEqual(agent.texts, ["Hello, local model."])
    XCTAssertEqual(agent.configurations.count, 1)
    XCTAssertEqual(
      agent.configurations.first?.endpoint, "http://127.0.0.1:8000/v1/responses",
      "the configured endpoint is sent, not a substituted one")
    XCTAssertEqual(agent.configurations.first?.model, "buddy")
    XCTAssertEqual(
      agent.configurations.first?.apiKey, "",
      "the empty key is sent as configured — never an invented credential")
    XCTAssertEqual(thread.phase, .completed)
  }

  /// The same policy gates the workspace lane: a remote endpoint with an
  /// empty key is refused before any host work; loopback goes through.
  func testWorkspaceSendKeylessPolicyMatchesDocumentScope() async throws {
    let refused = WorkspaceAskThread(
      identity: WorkspaceIdentity.make(rootURL: scratch, bookmarkData: nil),
      makeAgent: { IntegrationWorkspaceAttachmentAgent() }, attachmentStore: makeStore())
    let remote = CsDocumentProvider(
      wire: "openai-responses", endpoint: "https://api.openai.com/v1/responses", model: "gpt",
      apiKey: "")
    let refusedSend = await refused.prepareAndSend(
      text: "question", documents: [],
      database: IndexDatabase(
        databaseURL: scratch.appendingPathComponent("refused.db")),
      provider: .apiKey(""), configuration: remote)
    XCTAssertFalse(refusedSend)
    XCTAssertEqual(refused.lastError, AskReadiness.apiKeyNotReadyMessage)

    let agent = IntegrationWorkspaceAttachmentAgent()
    let thread = WorkspaceAskThread(
      identity: WorkspaceIdentity.make(rootURL: scratch, bookmarkData: nil),
      makeAgent: { agent }, attachmentStore: makeStore())
    let local = CsDocumentProvider(
      wire: "openai-responses", endpoint: "http://localhost:8000/v1/responses", model: "buddy",
      apiKey: "")
    XCTAssertTrue(
      thread.send(
        text: "local question", host: makeWorkspaceHost(), provider: .apiKey(""),
        configuration: local))
    let sentTask = thread.lastSendTask
    await sentTask?.value
    XCTAssertEqual(agent.configurations.first?.endpoint, "http://localhost:8000/v1/responses")
    XCTAssertEqual(agent.configurations.first?.apiKey, "")
    XCTAssertNil(thread.lastError)
  }
}

/// A suspended first parse, so a newer revision provably lands mid-parse.
private final class ParseGate: @unchecked Sendable {
  private let state = Mutex((opened: false, waiters: [@Sendable () -> Void]()))

  func wait() {
    var action: (@Sendable () -> Void)?
    state.withLock { current in
      if current.opened {
        action = {}
      } else {
        let semaphore = DispatchSemaphore(value: 0)
        current.waiters.append { semaphore.signal() }
        action = { semaphore.wait() }
      }
    }
    action?()
  }

  func open() {
    let waiters = state.withLock { current -> [@Sendable () -> Void] in
      current.opened = true
      let pending = current.waiters
      current.waiters = []
      return pending
    }
    for waiter in waiters { waiter() }
  }
}

/// Records plain and attachment sends plus the provider configurations the
/// scoped seams actually received.
private final class IntegrationAttachmentAgent: CodescribeAgentAttachmentStreaming,
  @unchecked Sendable
{
  private struct State: Sendable {
    var texts: [String] = []
    var attachmentPaths: [String] = []
    var configurations: [CsDocumentProvider] = []
  }

  private let state = Mutex(State())
  var texts: [String] { state.withLock { $0.texts } }
  var attachmentPaths: [String] { state.withLock { $0.attachmentPaths } }
  var configurations: [CsDocumentProvider] { state.withLock { $0.configurations } }

  func streamDocument(
    text: String, threadId: String, document: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String {
    state.withLock {
      $0.texts.append(text)
      if let provider { $0.configurations.append(provider) }
    }
    listener.onTextDone(text: "plain reply")
    listener.onDone()
    return "plain reply"
  }

  func streamDocumentWithAttachments(
    text: String, threadId: String, attachments: [CsAttachment], document: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String {
    state.withLock {
      $0.texts.append(text)
      $0.attachmentPaths.append(contentsOf: attachments.map(\.path))
      if let provider { $0.configurations.append(provider) }
    }
    listener.onTextDone(text: "image reply")
    listener.onDone()
    return "image reply"
  }

  func cancelTurn(threadId: String) -> Bool { true }
  func resolveToolApproval(
    sessionId: String, threadId: String, callId: String, approved: Bool, remember: Bool
  ) -> Bool { false }
}

/// Workspace twin of `IntegrationAttachmentAgent`.
private final class IntegrationWorkspaceAttachmentAgent: WorkspaceAgentAttachmentStreaming,
  @unchecked Sendable
{
  private struct State: Sendable {
    var attachmentPaths: [String] = []
    var configurations: [CsDocumentProvider] = []
  }

  private let state = Mutex(State())
  var attachmentPaths: [String] { state.withLock { $0.attachmentPaths } }
  var configurations: [CsDocumentProvider] { state.withLock { $0.configurations } }

  func streamWorkspace(
    text: String, threadId: String, workspace: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String {
    state.withLock {
      if let provider { $0.configurations.append(provider) }
    }
    listener.onTextDone(text: "plain workspace reply")
    listener.onDone()
    return "plain workspace reply"
  }

  func streamWorkspaceWithAttachments(
    text: String, threadId: String, attachments: [CsAttachment], workspace: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String {
    state.withLock {
      $0.attachmentPaths.append(contentsOf: attachments.map(\.path))
      if let provider { $0.configurations.append(provider) }
    }
    listener.onTextDone(text: "workspace image reply")
    listener.onDone()
    return "workspace image reply"
  }

  func cancelTurn(threadId: String) -> Bool { true }
  func resolveToolApproval(
    sessionId: String, threadId: String, callId: String, approved: Bool, remember: Bool
  ) -> Bool { false }
}
