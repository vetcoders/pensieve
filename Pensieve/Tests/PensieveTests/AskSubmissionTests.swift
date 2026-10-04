import CodescribeBridge
import Synchronization
import XCTest

@testable import Pensieve

@MainActor
final class AskSubmissionTests: XCTestCase {
  func testSendStartsWithoutTouching191000LineDocument() async {
    let agent = ImmediateCodescribeAgent()
    let id = UUID()
    let thread = DocumentAskThread(id: id, agent: agent)
    let document = String(repeating: "session content never added to the prompt\n", count: 191_000)
    var snapshots = 0
    let host = DocumentToolHost(
      documentID: id,
      snapshot: {
        snapshots += 1
        return AskDocumentSnapshot(id: id, title: "Large session", text: document)
      },
      replace: { _, _ in false })
    thread.draft = "Find the last decision"
    XCTAssertTrue(thread.send(provider: .apiKey("test"), host: host))
    XCTAssertEqual(thread.phase, .streaming)
    let deadline = Date().addingTimeInterval(2)
    while thread.isStreaming, Date() < deadline { await Task.yield() }
    XCTAssertEqual(thread.phase, .completed)
    XCTAssertEqual(
      snapshots, 0, "Sending must not even inspect the buffer before a tool asks for it")
    XCTAssertEqual(agent.texts, ["Find the last decision"])
  }

  func testEmptyQuestionAndUnreadyProviderDoNotStartTheAgent() {
    let agent = ImmediateCodescribeAgent()
    let thread = DocumentAskThread(id: UUID(), agent: agent)
    let host = AskDocumentFixture.host(text: "document")
    XCTAssertFalse(thread.send(provider: .apiKey("test"), host: host))
    XCTAssertEqual(thread.lastError, "Write a question before sending.")
    thread.draft = "Question"
    for provider in [
      AskProvider.apiKey(""), .grok(accountAuthorized: false), .codex(accountAuthorized: false),
    ] {
      XCTAssertFalse(thread.send(provider: provider, host: host))
      XCTAssertEqual(thread.lastError, AskReadiness.notReadyMessage(for: provider))
    }
    XCTAssertEqual(thread.draft, "Question")
    XCTAssertTrue(agent.texts.isEmpty)
    XCTAssertEqual(thread.phase, .idle)
  }

  func testAuthorizedAccountSendsDirectlyAndBlocksDuplicateSubmission() async {
    let agent = ImmediateCodescribeAgent()
    let thread = DocumentAskThread(id: UUID(), agent: agent)
    thread.draft = "line one\nline two"
    let host = AskDocumentFixture.host(text: "doc")
    XCTAssertTrue(thread.send(provider: .grok(accountAuthorized: true), host: host))
    thread.draft = "second"
    XCTAssertFalse(thread.send(provider: .grok(accountAuthorized: true), host: host))
    let deadline = Date().addingTimeInterval(2)
    while thread.isStreaming, Date() < deadline { await Task.yield() }
    XCTAssertEqual(thread.phase, .completed)
    XCTAssertEqual(agent.texts, ["line one\nline two"])
    XCTAssertEqual(thread.draft, "second")
  }
}

private final class ImmediateCodescribeAgent: CodescribeAgentStreaming, @unchecked Sendable {
  private struct State: Sendable {
    var texts: [String] = []
  }

  private let state = Mutex(State())

  var texts: [String] {
    state.withLock { $0.texts }
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
    state.withLock { $0.texts.append(text) }
    listener.onTextDelta(delta: "ok")
    listener.onTextDone(text: "ok")
    listener.onDone()
    return "ok"
  }
}
