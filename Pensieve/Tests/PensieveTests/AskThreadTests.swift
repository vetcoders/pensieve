import CodescribeBridge
import Synchronization
import XCTest

@testable import Pensieve

@MainActor
final class AskThreadTests: XCTestCase {
  func testThreadUUIDOwnsHistoryAcrossDocumentAndContextChanges() {
    let store = AskThreadStore(makeAgent: { RecordingAskAgent() })
    let id = UUID()
    let file = DocumentRef(id: URL(fileURLWithPath: "/tmp/ask-first.md"))
    let first = store.thread(for: id, context: AskContext(files: [file]))
    first.appendDictation("keep this conversation")
    let same = store.thread(for: id, context: .empty)
    XCTAssertTrue(first === same)
    XCTAssertEqual(same.context, AskContext(files: [file]))
    XCTAssertEqual(same.turns.map(\.text), ["keep this conversation"])
  }

  func testNewThreadMintsDistinctUUIDEvenForSameContext() {
    let store = AskThreadStore(makeAgent: { RecordingAskAgent() })
    let context = AskContext(draftID: UUID())
    let first = store.newThread(context: context)
    let second = store.newThread(context: context)
    first.draft = "keep my draft"
    XCTAssertNotEqual(first.id, second.id)
    XCTAssertEqual(first.context, second.context)
    XCTAssertEqual(second.draft, "")
    XCTAssertEqual(context.draftPath, "draft:\(context.draftID!.uuidString.lowercased())")
  }

  func testRestorePreservesTurnIdentityAndTextWithoutResurrectingStream() {
    let turn = AskTurn(role: .assistant, text: "partial", isStreaming: true)
    let thread = AskThread()
    thread.restore(turns: [turn], draft: "retry")
    XCTAssertEqual(thread.turns.first?.id, turn.id)
    XCTAssertEqual(thread.turns.first?.text, "partial")
    XCTAssertEqual(thread.turns.first?.isStreaming, false)
    XCTAssertEqual(thread.draft, "retry")
    XCTAssertFalse(thread.isBusy)
    XCTAssertEqual(thread.phase, .idle)
  }

  func testRejectedContextPreparationKeepsDraftWithoutStartingTurn() {
    let agent = RecordingAskAgent()
    let thread = AskThread(makeAgent: { agent })
    thread.draft = "keep this question"
    XCTAssertFalse(thread.rejectSubmission("Original workspace is no longer open."))
    XCTAssertEqual(thread.lastError, "Original workspace is no longer open.")
    XCTAssertEqual(thread.phase, .failed("Original workspace is no longer open."))
    XCTAssertEqual(thread.draft, "keep this question")
    XCTAssertTrue(thread.turns.isEmpty)
    XCTAssertTrue(agent.texts.isEmpty)
  }

  func testAPIKeyProvidersKeepTheKeyRuleAndGrokNeedsItsAccount() {
    XCTAssertFalse(AskReadiness.isReady(.apiKey("")))
    XCTAssertFalse(AskReadiness.isReady(.apiKey("   ")))
    XCTAssertFalse(AskReadiness.isReady(.apiKey(nil)))
    XCTAssertTrue(AskReadiness.isReady(.apiKey("sk-test")))
    XCTAssertEqual(AskReadiness.chipLabel(for: .apiKey("")), "Needs API key")
    XCTAssertEqual(AskReadiness.chipLabel(for: .apiKey("sk-test")), "Ready")

    XCTAssertFalse(
      AskReadiness.isReady(.grok(accountAuthorized: false)),
      "Grok is gated on its OAuth account, never on an API key field")
    XCTAssertTrue(AskReadiness.isReady(.grok(accountAuthorized: true)))
    XCTAssertNotEqual(
      AskReadiness.notReadyMessage(for: .grok(accountAuthorized: false)),
      AskReadiness.notReadyMessage(for: .apiKey("")),
      "the blocked message names the credential that is actually missing")
  }

  func testStreamingPhaseIsObservableAndUsesTheConversationUUID() async throws {
    let agent = RecordingAskAgent()
    let threadID = UUID()
    let thread = AskThread(id: threadID, makeAgent: { agent })
    thread.draft = "Say hello."

    XCTAssertEqual(thread.phase, .idle)
    XCTAssertTrue(
      thread.send(
        text: thread.draft, host: AskCoreFixture.host(text: "note"), provider: .apiKey("sk-test"))
    )
    XCTAssertEqual(thread.phase, .streaming)
    XCTAssertTrue(thread.isStreaming)
    XCTAssertTrue(thread.turns.contains(where: { $0.role == .assistant && $0.isStreaming }))

    let finished = await waitUntil(timeout: 1.0) { thread.phase == .completed }
    XCTAssertTrue(finished, "stream should complete")
    XCTAssertEqual(thread.phase, .completed)
    XCTAssertFalse(thread.isStreaming)
    XCTAssertEqual(agent.threadIDs, [threadID.uuidString.lowercased()])
    XCTAssertEqual(thread.turns.filter { $0.role == .assistant }.last?.text, "Hello there now")
    XCTAssertFalse(
      String(describing: thread.phase).contains("alert"),
      "Ask send is a visible turn, not a one-line alert")
  }

  func testDictationAppendsAnUtteranceWithoutSending() {
    let agent = RecordingAskAgent()
    let thread = AskThread(id: UUID(), makeAgent: { agent })
    thread.appendDictation("  spoken note  ")
    thread.appendDictation("")

    XCTAssertEqual(thread.turns.map(\.role), [.dictation])
    XCTAssertEqual(thread.turns.map(\.text), ["spoken note"])
    XCTAssertEqual(thread.phase, .idle)
    XCTAssertTrue(agent.texts.isEmpty)
  }

  func testLargeDocumentUsesOneAgentTurn() async throws {
    let agent = RecordingAskAgent()
    let thread = AskThread(id: UUID(), makeAgent: { agent })
    let document = String(repeating: "x", count: 8000 * 2 + 20)
    thread.draft = "Continue."
    XCTAssertTrue(
      thread.send(
        text: thread.draft, host: AskCoreFixture.host(text: document), provider: .apiKey("sk-test"))
    )

    let finished = await waitUntil(timeout: 1.0) { thread.phase == .completed }
    XCTAssertTrue(finished)
    XCTAssertEqual(agent.texts.count, 1, "One instruction must not become independent page turns")
    XCTAssertEqual(Set(agent.threadIDs).count, 1)
    XCTAssertEqual(agent.threadIDs.first, thread.id.uuidString.lowercased())
  }

  func testSendReadsTheLiveDocumentOnDemand() async {
    let agent = RecordingAskAgent()
    let thread = AskThread(id: UUID(), makeAgent: { agent })
    thread.draft = "Find the decision."
    XCTAssertTrue(
      thread.send(
        text: thread.draft, host: AskCoreFixture.host(text: "CURRENT decision"),
        provider: .apiKey("test")))
    let finished = await waitUntil(timeout: 1) { thread.phase == .completed }
    XCTAssertTrue(finished)
    XCTAssertFalse(agent.texts.joined().contains("OLD decision"))
    XCTAssertTrue(agent.documentReads.joined().contains("CURRENT decision"))
  }

  func testStoreReusesTheSameThreadObjectForAConversationUUID() {
    let store = AskThreadStore(makeAgent: { RecordingAskAgent() })
    let id = UUID()
    let first = store.thread(for: id)
    first.appendDictation("keep me")
    let second = store.thread(for: id)

    XCTAssertTrue(first === second)
    XCTAssertEqual(second.turns.map(\.text), ["keep me"])
  }

  func testStopCancelsEngineAndIgnoresLateEvents() async {
    let agent = SuspendedAskAgent()
    let thread = AskThread(id: UUID(), makeAgent: { agent })
    let host = AskCoreFixture.host(text: "unsaved")
    thread.draft = "Edit this"
    XCTAssertTrue(thread.send(text: thread.draft, host: host, provider: .apiKey("test")))
    let started = await waitUntil(timeout: 1) { agent.started }
    XCTAssertTrue(started)
    thread.cancel()
    XCTAssertEqual(agent.cancelledThread, thread.id.uuidString.lowercased())
    XCTAssertFalse(host.isActive())
    agent.finishLate()
    for _ in 0..<10 { await Task.yield() }
    XCTAssertEqual(thread.phase, .idle)
    XCTAssertFalse(thread.turns.contains { $0.text.contains("late reply") })
  }

  private func waitUntil(timeout: TimeInterval, predicate: @escaping () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return predicate()
  }
}

private final class RecordingAskAgent: AskAgentStreaming, @unchecked Sendable {
  private struct State: Sendable {
    var texts: [String] = []
    var threadIDs: [String] = []
    var documentReads: [String] = []
  }

  private let state = Mutex(State())

  var texts: [String] {
    state.withLock { $0.texts }
  }

  var documentReads: [String] { state.withLock { $0.documentReads } }

  var threadIDs: [String] {
    state.withLock { $0.threadIDs }
  }

  func cancelTurn(threadId: String) -> Bool { true }
  func resolveToolApproval(
    sessionId: String, threadId: String, callId: String, approved: Bool, remember: Bool
  ) -> Bool { false }

  func streamWorkspace(
    text: String, threadId: String, workspace: CsDocumentToolHost, provider: CsDocumentProvider?,
    listener: CsAgentListener
  ) async throws
    -> String
  {
    state.withLock {
      $0.texts.append(text)
      $0.threadIDs.append(threadId)
    }
    let read = try workspace.execute(
      name: "document_read", argumentsJson: "{\"offset\":0,\"limit\":8000}")
    state.withLock { $0.documentReads.append(read) }
    listener.onTextDelta(delta: "Hel")
    listener.onTextDelta(delta: "lo")
    listener.onTextDone(text: "Hello there now")
    listener.onDone()
    return "Hello there now"
  }
}

private final class SuspendedAskAgent: AskAgentStreaming, Sendable {
  private struct State: Sendable {
    var listener: CsAgentListener?
    var completion: CheckedContinuation<String, Never>?
    var cancelledThread: String?
  }
  private let state = Mutex(State())
  var started: Bool { state.withLock { $0.completion != nil } }
  var cancelledThread: String? { state.withLock { $0.cancelledThread } }
  func streamWorkspace(
    text: String, threadId: String, workspace: CsDocumentToolHost, provider: CsDocumentProvider?,
    listener: CsAgentListener
  ) async throws -> String {
    await withCheckedContinuation { completion in
      state.withLock {
        $0.listener = listener
        $0.completion = completion
      }
      listener.onToolExecuting(name: "document_read", id: "read")
    }
  }
  func cancelTurn(threadId: String) -> Bool {
    state.withLock { $0.cancelledThread = threadId }
    return true
  }
  func resolveToolApproval(
    sessionId: String, threadId: String, callId: String, approved: Bool, remember: Bool
  ) -> Bool { false }
  func finishLate() {
    let pending = state.withLock { current in
      let pending = (current.listener, current.completion)
      current.listener = nil
      current.completion = nil
      return pending
    }
    pending.0?.onTextDelta(delta: "late reply")
    pending.0?.onTextDone(text: "late reply")
    pending.1?.resume(returning: "late reply")
  }
}

@MainActor
private enum AskCoreFixture {
  static func host(text: String) -> WorkspaceToolHost {
    WorkspaceToolHost(
      search: { _, _ in "{}" }, containsPath: { _ in false }, readFile: { _ in text },
      initialDocument: ("fixture", AskDocumentFixture.host(text: text)))
  }
}
