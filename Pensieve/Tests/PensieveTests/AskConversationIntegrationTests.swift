import AppKit
import CodescribeBridge
import SwiftUI
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

  /// A mounted SwiftUI observer must reevaluate an extracted slot when the
  /// document thread changes. No window or WindowServer fixture is allocated.
  func testMountedDocumentSlotObservesDraftAndTurnsWithoutRemount() async {
    let thread = DocumentAskThread(id: UUID(), agent: IntegrationAttachmentAgent())
    let seen = Mutex([String]())
    let hosting = NSHostingView(
      rootView: AskDocumentThreadObservation(thread: thread) { observed in
        let text = observed.draft + "|" + (observed.turns.last?.text ?? "")
        seen.withLock { $0.append(text) }
        return Text(text)
      })
    hosting.frame = CGRect(x: 0, y: 0, width: 400, height: 100)
    _ = hosting.fittingSize
    XCTAssertTrue(seen.withLock { $0.contains("|") })
    thread.draft = "question"
    thread.appendDictation("reply")
    for _ in 0..<20 {
      await Task.yield()
      _ = hosting.fittingSize
      if seen.withLock({ $0.contains("question|reply") }) { break }
    }
    XCTAssertTrue(
      seen.withLock { $0.contains("question|reply") },
      "thread changes must reach the mounted slot without hiding or resizing Ask")
  }

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

  // MARK: Publication budget (production UI work, not only parser count)

  /// Fifty provider deltas inside 250ms must not become fifty snapshot
  /// emissions or fifty scroll requests: the UI publishes on structure,
  /// coalesced publications, the terminal flush and accepted parse results.
  func testSubintervalDeltaBurstDoesNotBurstSnapshotsOrScrolls() async {
    let now = Mutex(TimeInterval(0))
    let model = AskConversationModel(clock: { now.withLock { $0 } })
    let turnID = UUID()
    for step in 0..<50 {
      now.withLock { $0 = TimeInterval(step) * 0.005 }
      model.observe(turns: [
        AskTurn(
          id: turnID, role: .assistant, text: String(repeating: "x", count: step + 1),
          isStreaming: true)
      ])
    }
    now.withLock { $0 = 1.0 }
    model.observe(turns: [
      AskTurn(id: turnID, role: .assistant, text: "final text", isStreaming: false)
    ])
    await drain(model)

    XCTAssertLessThanOrEqual(
      model.snapshotEmissions, 15,
      "50 subinterval deltas coalesce to a handful of UI publications, got \(model.snapshotEmissions)"
    )
    XCTAssertLessThanOrEqual(
      model.snapshot.scrollRequests, 15,
      "follow-tail scrolling is tied to visible publications, not delta rate")
    XCTAssertEqual(model.snapshot.turns.last?.document.source, "final text")
  }

  // MARK: Genuine user scroll routing

  /// Programmatic motion (own scrollTo, content growth, resize) never
  /// produces a user-scroll intent; only real gesture phases do.
  func testScrollIntentRoutingIgnoresProgrammaticMotion() {
    var router = AskScrollIntentRouter()
    XCTAssertEqual(router.geometryChanged(isAtLiveEdge: false), [])
    XCTAssertEqual(router.phaseChanged(to: .programmatic), [])
    XCTAssertEqual(router.geometryChanged(isAtLiveEdge: true), [])
    XCTAssertFalse(router.userDriven, "geometry alone is never a gesture")

    XCTAssertEqual(router.phaseChanged(to: .userActive), [.userScrollBegan])
    XCTAssertEqual(router.geometryChanged(isAtLiveEdge: false), [])
    XCTAssertEqual(router.phaseChanged(to: .idle), [.userScrollEnded(isAtLiveEdge: false)])

    XCTAssertEqual(router.phaseChanged(to: .programmatic), [])
    XCTAssertEqual(router.geometryChanged(isAtLiveEdge: true), [])
    XCTAssertEqual(
      router.phaseChanged(to: .idle), [],
      "settling after our own scrollTo is not the user resuming follow")

    XCTAssertEqual(router.phaseChanged(to: .userActive), [.userScrollBegan])
    _ = router.geometryChanged(isAtLiveEdge: true)
    XCTAssertEqual(router.phaseChanged(to: .idle), [.userScrollEnded(isAtLiveEdge: true)])
  }

  /// A reader who scrolled up stays parked through the stream; Jump to
  /// latest is the only automatic resume.
  func testManuallyPausedFollowStaysPausedThroughStreaming() async {
    let model = AskConversationModel(clock: { 0 })
    let turnID = UUID()
    model.observe(turns: [
      AskTurn(id: turnID, role: .assistant, text: "one", isStreaming: true)
    ])
    await drain(model)
    let baseline = model.snapshot.scrollRequests

    model.userScrollBegan()
    model.userScrollEnded(isAtLiveEdge: false)
    model.observe(turns: [
      AskTurn(id: turnID, role: .assistant, text: "one two", isStreaming: true)
    ])
    await drain(model)

    XCTAssertEqual(
      model.snapshot.scrollRequests, baseline,
      "streaming growth cannot drag a reader who scrolled up")
    XCTAssertTrue(model.snapshot.showsJumpToLatest)
    model.jumpToLatest()
    XCTAssertGreaterThan(
      model.snapshot.scrollRequests, baseline,
      "Jump to latest is the explicit resume")
  }

  // MARK: Lazy history and bounded AST retention

  /// A 10000-turn history opens without parsing hidden turns: only the
  /// visible window parses eagerly, and reveal pulls the next bounded page.
  func testLargeHistoryParsesOnlyTheVisibleWindowUntilReveal() async {
    let model = AskConversationModel(clock: { 0 })
    let total = 10_000
    let ids = (0..<total).map { _ in UUID() }
    model.observe(
      turns: ids.map { AskTurn(id: $0, role: .assistant, text: "answer \($0.uuidString)") })
    await drain(model)

    var parses = ids.reduce(0) { $0 + model.parseCount(for: $1.uuidString) }
    XCTAssertLessThanOrEqual(
      parses, AskTranscriptWindow.pageSize,
      "hidden history is not parsed on observe, got \(parses)")
    XCTAssertLessThanOrEqual(model.retainedDocumentCount, AskTranscriptWindow.pageSize)
    XCTAssertEqual(model.snapshot.totalCount, total)
    XCTAssertGreaterThan(model.snapshot.hiddenCount, 0, "history stays behind the window")

    model.revealEarlier()
    await drain(model)
    parses = ids.reduce(0) { $0 + model.parseCount(for: $1.uuidString) }
    XCTAssertLessThanOrEqual(
      parses, AskTranscriptWindow.pageSize * 2,
      "reveal pulls exactly the newly visible page, got \(parses)")
    XCTAssertLessThanOrEqual(
      model.retainedDocumentCount,
      AskConversationModel.retentionBudget + AskTranscriptWindow.pageSize)

    // Re-observing the identical history is semantically free: no new
    // parses, no new snapshot emissions, no scroll churn.
    let emissionsBefore = model.snapshotEmissions
    model.observe(
      turns: ids.map { AskTurn(id: $0, role: .assistant, text: "answer \($0.uuidString)") })
    await drain(model)
    parses = ids.reduce(0) { $0 + model.parseCount(for: $1.uuidString) }
    XCTAssertLessThanOrEqual(parses, AskTranscriptWindow.pageSize * 2)
    XCTAssertEqual(
      model.snapshotEmissions, emissionsBefore,
      "an unchanged history re-observation publishes nothing")
  }

  /// A parse suspended while its thread is replaced must land nowhere: the
  /// old epoch's result is dropped, never reinserted into the cache, and the
  /// retired pending request leaves no work behind.
  func testRetiredInFlightParseResultIsDroppedAfterThreadReplacement() async {
    let gate = ParseGate()
    let model = AskConversationModel(
      clock: { 0 },
      parse: { text in
        gate.wait()
        return AskMarkdownParser.parse(text)
      })
    let oldID = UUID()
    model.observe(turns: [AskTurn(id: oldID, role: .assistant, text: "old thread reply")])
    // The parse is in flight, suspended at the gate.
    model.replaceThread()
    gate.open()
    await drain(model)

    XCTAssertNil(
      model.document(for: oldID.uuidString),
      "a retired thread's in-flight result is dropped")
    XCTAssertFalse(model.hasPendingWork, "retired pending work leaves nothing behind")

    let newID = UUID()
    model.observe(turns: [AskTurn(id: newID, role: .assistant, text: "new thread reply")])
    await drain(model)
    XCTAssertNil(
      model.document(for: oldID.uuidString),
      "the retired result never reappears after the new thread settles")
    XCTAssertEqual(model.document(for: newID.uuidString)?.source, "new thread reply")
  }

  /// Requests queued for the NEW thread while the retired round was still in
  /// flight must drain right behind it — the old round drops, the worker
  /// continues, and the new thread's AST arrives with no extra observation.
  func testParseQueuedDuringRetiredRoundDrainsWithoutExtraObservation() async {
    let gate = ParseGate()
    let model = AskConversationModel(
      clock: { 0 },
      parse: { text in
        gate.wait()
        return AskMarkdownParser.parse(text)
      })
    let oldID = UUID()
    model.observe(turns: [AskTurn(id: oldID, role: .assistant, text: "old thread reply")])
    // The old thread's parse is suspended at the gate when the replacement
    // and the new thread's first observation land.
    model.replaceThread()
    let newID = UUID()
    model.observe(turns: [AskTurn(id: newID, role: .assistant, text: "new thread reply")])
    gate.open()
    await drain(model)

    XCTAssertNil(
      model.document(for: oldID.uuidString),
      "the retired round still drops")
    XCTAssertEqual(
      model.document(for: newID.uuidString)?.source, "new thread reply",
      "the new thread's queued parse drains behind the retired round")
    XCTAssertFalse(model.hasPendingWork, "no request is stranded")
  }

  /// Fifty thread replacements cannot pile up ASTs: every visible turn still
  /// parses once, but retention stays inside the budget and stale pending
  /// work for retired threads is dropped.
  func testThreadReplacementsKeepAstRetentionBounded() async {
    let model = AskConversationModel(clock: { 0 })
    var totalParses = 0
    for round in 0..<50 {
      let roundIDs = (0..<30).map { _ in UUID() }
      model.replaceThread()
      model.observe(
        turns: roundIDs.map {
          AskTurn(id: $0, role: .assistant, text: "round \(round) \($0.uuidString)")
        })
      await drain(model)
      totalParses += roundIDs.reduce(0) { $0 + model.parseCount(for: $1.uuidString) }
    }
    XCTAssertEqual(totalParses, 50 * 30, "each visible turn parses exactly once")
    XCTAssertLessThanOrEqual(
      model.retainedDocumentCount,
      AskConversationModel.retentionBudget + AskTranscriptWindow.pageSize,
      "retired threads cannot accumulate stale documents")
  }

  // MARK: Table work budget

  /// The production width flow: the real slot width minus the transcript's
  /// own padding feeds the markdown layout, so the readable column and the
  /// code/table viewports use actual geometry — never the 280pt minimum or
  /// the zero-width collapse the containerWidth:0 integration produced.
  func testTranscriptWidthPolicyUsesRealConfiguredWidth() {
    let slot: CGFloat = 640
    let configured = slot - AskConversationTranscript.horizontalPadding * 2
    XCTAssertEqual(configured, 616)
    XCTAssertEqual(
      AskTranscriptWidthPolicy.documentWidth(for: configured), 616,
      "the real width beats the 280pt minimum")
    let content = AskTranscriptWidthPolicy.contentWidth(for: configured)
    XCTAssertEqual(content, 576)
    let plan = AskMarkdownOverflow.plan(
      containerWidth: content, codeCharacters: 40, tableColumns: 3)
    XCTAssertGreaterThan(plan.codeViewportWidth, 0, "code keeps a real viewport")
    XCTAssertGreaterThan(plan.tableViewportWidth, 0, "tables keep a real viewport")
    XCTAssertTrue(plan.wideContentScrollsInsideMessage)
    XCTAssertEqual(
      AskTranscriptWidthPolicy.contentWidth(for: 0), 0,
      "the zero-width defect this guards against is measurable")
  }

  /// One huge table below the inline cap: the block page cannot bound it, so
  /// the table budget does — bounded first page, bounded weight scan, every
  /// row still reachable, full source intact for copy.
  func testSingleHugeTableBelowInlineCapIsBounded() {
    let source =
      (["| a | b | c |", "| - | - | - |"]
      + Array(repeating: "| 1 | 2 | 3 |", count: 1200)).joined(separator: "\n")
    XCTAssertLessThan(source.utf8.count, OversizedBubblePolicy.inlineUTF8Cap)
    let document = AskMarkdownParser.parse(source)
    guard case .table(_, let rows, let columns) = document.blocks.first else {
      return XCTFail("expected a table block")
    }
    XCTAssertEqual(rows.count, 1200)

    let visible = AskMarkdownTableBudget.visibleRowCount(total: rows.count, revealed: nil)
    XCTAssertEqual(visible, AskMarkdownTableBudget.rowPageSize)
    let scan = AskMarkdownTableBudget.weightScanCount(visible: visible, total: rows.count)
    XCTAssertLessThanOrEqual(
      scan, AskMarkdownTableBudget.weightScanRowLimit,
      "column weights never scan the whole grid in a view body")
    XCTAssertEqual(
      (visible + 1) * columns, (AskMarkdownTableBudget.rowPageSize + 1) * 3,
      "materialized cells are bounded to the page plus the header")

    var revealed = visible
    var pages = 1
    while revealed < rows.count {
      revealed = AskMarkdownTableBudget.nextReveal(current: revealed, total: rows.count)
      pages += 1
    }
    XCTAssertEqual(revealed, rows.count, "every row stays reachable through reveal")
    XCTAssertEqual(pages, 30)
    XCTAssertEqual(document.copyableSource, source, "the exact full source survives")
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
      dockStart: displayed,
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
      dockStart: displayed,
      translation: CGSize(width: 0, height: 10))
    XCTAssertEqual(
      AskSurfaceLayout.displayedDockHeight(presentation: state, content: content),
      displayed - 10, accuracy: 0.001,
      "dragging down from the clamped display height responds immediately")
  }

  /// Native panel allocation is independent of the editor floor and owner window.
  func testFloatingPanelAllocationSupportsIndependentSize() {
    var state = AskPresentationState.expandedDefault
    state.mode = .floating
    let panelSize = CGSize(width: 720, height: 560)
    let layout = AskSurfaceLayout.allocate(content: panelSize, presentation: state)
    XCTAssertEqual(layout.askRegion.size, panelSize)
    XCTAssertEqual(layout.editor, .zero)
    XCTAssertEqual(layout.status, .zero)
    XCTAssertTrue(layout.controls.contains { $0.role == .alwaysOnTop })
  }

  /// Always on top toggle maintains floating mode and updates presentation level.
  func testFloatingPanelAlwaysOnTopLevel() {
    var state = AskPresentationState.expandedDefault
    state.mode = .floating
    XCTAssertTrue(state.isAlwaysOnTop)
    state.isAlwaysOnTop = false
    XCTAssertFalse(state.isAlwaysOnTop)
    XCTAssertEqual(state.mode, .floating)
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
