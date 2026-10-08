import CodescribeBridge
import Synchronization
import XCTest

@testable import Pensieve

@MainActor
final class AskSubmissionTests: XCTestCase {
  func testSendStartsWithoutTouching191000LineDocument() async {
    let agent = ImmediateAskAgent()
    let id = UUID()
    let file = DocumentRef(id: URL(fileURLWithPath: "/fixture/large-session.md"), isAdHoc: true)
    let thread = AskThread(id: id, context: AskContext(files: [file]), makeAgent: { agent })
    let document = String(repeating: "session content never added to the prompt\n", count: 191_000)
    var snapshots = 0
    let documentHost = DocumentToolHost(
      documentID: id,
      snapshot: {
        snapshots += 1
        return AskDocumentSnapshot(id: id, title: "Large session", text: document)
      },
      replace: { _, _ in false })
    let reads = Mutex(0)
    let host = WorkspaceToolHost(
      search: { _, _ in #"{"matches":[]}"# },
      containsPath: { $0 == file.url.path },
      readFile: { _ in
        reads.withLock { $0 += 1 }
        return document
      },
      initialDocument: (path: file.url.path, host: documentHost))
    thread.draft = "Find the last decision"
    XCTAssertTrue(thread.send(text: thread.draft, host: host, provider: .apiKey("test")))
    XCTAssertEqual(thread.phase, .streaming)
    let deadline = Date().addingTimeInterval(2)
    while thread.isStreaming, Date() < deadline { await Task.yield() }
    XCTAssertEqual(thread.phase, .completed)
    XCTAssertEqual(
      snapshots, 0, "Sending must not even inspect the buffer before a tool asks for it")
    XCTAssertEqual(reads.withLock { $0 }, 0, "sending never reads the file eagerly")
    XCTAssertEqual(agent.texts, ["Find the last decision"])
  }

  private func makeHost() -> WorkspaceToolHost {
    WorkspaceToolHost(
      search: { _, _ in #"{"matches":[]}"# }, containsPath: { _ in false },
      readFile: { _ in throw CsError.Agent(msg: "no files in this fixture") })
  }

  func testEmptyQuestionAndUnreadyProviderDoNotStartTheAgent() {
    let agent = ImmediateAskAgent()
    let thread = AskThread(makeAgent: { agent })
    XCTAssertFalse(thread.send(text: thread.draft, host: makeHost(), provider: .apiKey("test")))
    XCTAssertEqual(thread.lastError, "Write a question before sending.")
    thread.draft = "Question"
    for provider in [
      AskProvider.apiKey(""), .grok(accountAuthorized: false), .codex(accountAuthorized: false),
    ] {
      XCTAssertFalse(thread.send(text: thread.draft, host: makeHost(), provider: provider))
      XCTAssertEqual(thread.lastError, AskReadiness.notReadyMessage(for: provider))
    }
    XCTAssertEqual(thread.draft, "Question")
    XCTAssertTrue(agent.texts.isEmpty)
    XCTAssertEqual(thread.phase, .idle)
  }

  func testAuthorizedAccountSendsDirectlyAndBlocksDuplicateSubmission() async {
    let agent = ImmediateAskAgent()
    let thread = AskThread(makeAgent: { agent })
    thread.draft = "line one\nline two"
    XCTAssertTrue(
      thread.send(text: thread.draft, host: makeHost(), provider: .grok(accountAuthorized: true)))
    thread.draft = "second"
    XCTAssertFalse(
      thread.send(text: thread.draft, host: makeHost(), provider: .grok(accountAuthorized: true)))
    let deadline = Date().addingTimeInterval(2)
    while thread.isStreaming, Date() < deadline { await Task.yield() }
    XCTAssertEqual(thread.phase, .completed)
    XCTAssertEqual(agent.texts, ["line one\nline two"])
    XCTAssertEqual(thread.draft, "second")
  }
}

private final class ImmediateAskAgent: AskAgentStreaming, @unchecked Sendable {
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

  func streamWorkspace(
    text: String, threadId: String, workspace: CsDocumentToolHost, provider: CsDocumentProvider?,
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
