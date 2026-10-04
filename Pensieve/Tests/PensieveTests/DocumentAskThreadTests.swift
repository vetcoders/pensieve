import CodescribeBridge
import Synchronization
import XCTest

@testable import Pensieve

@MainActor
final class DocumentAskThreadTests: XCTestCase {
  func testUntitledSessionsMintDistinctAskThreadIDsAtBirth() {
    let first = DocumentSession.untitled()
    let second = DocumentSession.untitled()

    XCTAssertNotEqual(first.askThreadID, second.askThreadID)
    XCTAssertNotEqual(first.identity, second.identity)
    XCTAssertEqual(first.askThreadID, first.askThreadID)
  }

  func testSaveAsAndRenameKeepTheBirthAskThreadID() {
    var session = DocumentSession.untitled(title: "Draft.md")
    let birth = session.askThreadID
    let saved = URL(fileURLWithPath: "/tmp/pensieve-ask/../saved.md")
    let renamed = URL(fileURLWithPath: "/tmp/pensieve-ask/renamed.md")

    session.document = DocumentRef(id: saved)
    XCTAssertEqual(session.askThreadID, birth)
    XCTAssertEqual(session.identity, .file(saved.standardizedFileURL))

    session.document = DocumentRef(id: renamed)
    XCTAssertEqual(session.askThreadID, birth)
    XCTAssertEqual(session.identity, .file(renamed.standardizedFileURL))
  }

  func testLoadFromUntitledKeepsAskThreadIDLikeIdentitySaveAs() {
    var session = DocumentSession.untitled(title: "Draft.md")
    let birth = session.askThreadID
    let saved = URL(fileURLWithPath: "/tmp/pensieve-ask-load/saved.md")

    session.load(document: DocumentRef(id: saved), text: "body")

    XCTAssertEqual(session.askThreadID, birth)
    XCTAssertEqual(session.identity, .file(saved.standardizedFileURL))
  }

  func testOpeningADifferentFileRemintsAskThreadID() {
    var session = DocumentSession(
      document: DocumentRef(id: URL(fileURLWithPath: "/tmp/pensieve-ask/a.md")),
      text: "alpha")
    let firstThread = session.askThreadID

    session.load(
      document: DocumentRef(id: URL(fileURLWithPath: "/tmp/pensieve-ask/b.md")),
      text: "beta")

    XCTAssertNotEqual(session.askThreadID, firstThread)
  }

  func testCreateUntitledRemintsAskThreadID() {
    var session = DocumentSession.untitled()
    let first = session.askThreadID
    session.createUntitled(title: "Untitled 2.md")
    XCTAssertNotEqual(session.askThreadID, first)
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

  func testStreamingPhaseIsObservableAndUsesTheDocumentThreadID() async throws {
    let agent = RecordingCodescribeAgent()
    let threadID = UUID()
    let thread = DocumentAskThread(id: threadID, agent: agent)
    thread.draft = "Say hello."

    XCTAssertEqual(thread.phase, .idle)
    XCTAssertTrue(
      thread.send(
        provider: .apiKey("sk-test"), host: AskDocumentFixture.host(text: "note"))
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
    let agent = RecordingCodescribeAgent()
    let thread = DocumentAskThread(id: UUID(), agent: agent)
    thread.appendDictation("  spoken note  ")
    thread.appendDictation("")

    XCTAssertEqual(thread.turns.map(\.role), [.dictation])
    XCTAssertEqual(thread.turns.map(\.text), ["spoken note"])
    XCTAssertEqual(thread.phase, .idle)
    XCTAssertTrue(agent.texts.isEmpty)
  }

  func testLargeDocumentUsesOneAgentTurn() async throws {
    let agent = RecordingCodescribeAgent()
    let thread = DocumentAskThread(id: UUID(), agent: agent)
    let document = String(repeating: "x", count: 8000 * 2 + 20)
    thread.draft = "Continue."
    XCTAssertTrue(
      thread.send(
        provider: .apiKey("sk-test"),
        host: AskDocumentFixture.host(text: document)))

    let finished = await waitUntil(timeout: 1.0) { thread.phase == .completed }
    XCTAssertTrue(finished)
    XCTAssertEqual(agent.texts.count, 1, "One instruction must not become independent page turns")
    XCTAssertEqual(Set(agent.threadIDs).count, 1)
    XCTAssertEqual(agent.threadIDs.first, thread.id.uuidString.lowercased())
  }

  func testSendReadsTheLiveDocumentOnDemand() async {
    let agent = RecordingCodescribeAgent()
    let thread = DocumentAskThread(id: UUID(), agent: agent)
    thread.draft = "Find the decision."
    XCTAssertTrue(
      thread.send(
        provider: .apiKey("test"),
        host: AskDocumentFixture.host(text: "CURRENT decision")))
    let finished = await waitUntil(timeout: 1) { thread.phase == .completed }
    XCTAssertTrue(finished)
    XCTAssertFalse(agent.texts.joined().contains("OLD decision"))
    XCTAssertTrue(agent.documentReads.joined().contains("CURRENT decision"))
  }

  func testStoreReusesTheSameThreadObjectForABirthID() {
    let store = DocumentAskThreadStore(makeAgent: { RecordingCodescribeAgent() })
    let id = UUID()
    let first = store.thread(for: id)
    first.appendDictation("keep me")
    let second = store.thread(for: id)

    XCTAssertTrue(first === second)
    XCTAssertEqual(second.turns.map(\.text), ["keep me"])
  }

  func testStopCancelsEngineAndIgnoresLateEvents() async {
    let agent = SuspendedDocumentAgent()
    let thread = DocumentAskThread(id: UUID(), agent: agent)
    let host = AskDocumentFixture.host(text: "unsaved")
    thread.draft = "Edit this"
    XCTAssertTrue(thread.send(provider: .apiKey("test"), host: host))
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

private final class RecordingCodescribeAgent: CodescribeAgentStreaming, @unchecked Sendable {
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

  func streamDocument(
    text: String, threadId: String, document: CsDocumentToolHost, provider: CsDocumentProvider?,
    listener: CsAgentListener
  ) async throws
    -> String
  {
    state.withLock {
      $0.texts.append(text)
      $0.threadIDs.append(threadId)
    }
    let read = try document.execute(
      name: "document_read", argumentsJson: "{\"offset\":0,\"limit\":8000}")
    state.withLock { $0.documentReads.append(read) }
    listener.onTextDelta(delta: "Hel")
    listener.onTextDelta(delta: "lo")
    listener.onTextDone(text: "Hello there now")
    listener.onDone()
    return "Hello there now"
  }
}

private final class SuspendedDocumentAgent: CodescribeAgentStreaming, Sendable {
  private struct State: Sendable {
    var listener: CsAgentListener?
    var completion: CheckedContinuation<String, Never>?
    var cancelledThread: String?
  }
  private let state = Mutex(State())
  var started: Bool { state.withLock { $0.completion != nil } }
  var cancelledThread: String? { state.withLock { $0.cancelledThread } }
  func streamDocument(
    text: String, threadId: String, document: CsDocumentToolHost, provider: CsDocumentProvider?,
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
