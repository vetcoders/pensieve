import CodescribeBridge
import Synchronization
import XCTest

@testable import Pensieve

@MainActor
final class AskComposerPreflightTests: XCTestCase {
  func testPreflightListsPromptAndDocumentCharacterCounts() {
    let prompt = "What did I decide?\nSecond line."
    let document = "# Note\n\nBody of the document."
    let preflight = AskPreflight.make(prompt: prompt, document: document)

    XCTAssertEqual(preflight.promptCharacters, prompt.count)
    XCTAssertEqual(preflight.documentCharacters, document.count)
    XCTAssertTrue(preflight.summary.contains("\(prompt.count)"))
    XCTAssertTrue(preflight.summary.contains("\(document.count)"))
    XCTAssertTrue(preflight.summary.contains("undoable edits"))
    XCTAssertTrue(preflight.summary.contains("document save settings"))
  }

  func testSendIsBlockedWithoutConfirmEvenWhenReady() {
    let agent = ImmediateCodescribeAgent()
    let thread = DocumentAskThread(id: UUID(), agent: agent)
    thread.draft = "Please summarise."

    XCTAssertFalse(
      thread.sendWithoutConfirm(document: "doc", provider: .apiKey("sk-test")),
      "Ask must not send until the user confirms the preflight")
    XCTAssertEqual(thread.phase, .idle)
    XCTAssertTrue(agent.texts.isEmpty)
    XCTAssertEqual(thread.lastError, "Confirm document access before sending.")
  }

  func testPrepareThenConfirmSendsAndEmptyDraftIsBlocked() {
    let agent = ImmediateCodescribeAgent()
    let thread = DocumentAskThread(id: UUID(), agent: agent)

    XCTAssertNil(thread.prepareSend(document: "doc", provider: .apiKey("sk-test")))
    XCTAssertEqual(thread.lastError, "Write a question before sending.")

    thread.draft = "Please summarise."
    let preflight = thread.prepareSend(document: "doc", provider: .apiKey("sk-test"))
    XCTAssertNotNil(preflight)
    XCTAssertEqual(thread.phase, .awaitingConfirmation)
    XCTAssertEqual(preflight?.promptCharacters, "Please summarise.".count)
    XCTAssertEqual(preflight?.documentCharacters, 3)

    XCTAssertTrue(
      thread.confirmAndSend(
        document: "doc", provider: .apiKey("sk-test"), host: AskDocumentFixture.host(text: "doc")))
    XCTAssertEqual(thread.phase, .streaming)
  }

  func testPrepareIsBlockedWhenTheSelectedProviderIsNotReady() {
    let thread = DocumentAskThread(id: UUID(), agent: ImmediateCodescribeAgent())
    thread.draft = "Hello"

    XCTAssertNil(thread.prepareSend(document: "doc", provider: .apiKey("")))
    XCTAssertEqual(thread.lastError, AskReadiness.apiKeyNotReadyMessage)
    XCTAssertEqual(thread.phase, .idle)

    XCTAssertNil(thread.prepareSend(document: "doc", provider: .grok(accountAuthorized: false)))
    XCTAssertEqual(thread.lastError, AskReadiness.grokNotReadyMessage)
    XCTAssertEqual(thread.phase, .idle)
    XCTAssertFalse(
      thread.confirmAndSend(
        document: "doc", provider: .grok(accountAuthorized: false),
        host: AskDocumentFixture.host(text: "doc")),
      "an unauthorized Grok account must not reach the send path")
  }

  func testAuthorizedGrokPreparesConfirmsAndSendsWithoutAnAPIKey() async {
    let agent = ImmediateCodescribeAgent()
    let thread = DocumentAskThread(id: UUID(), agent: agent)
    thread.draft = "Please summarise."
    let grok = AskProvider.grok(accountAuthorized: true)

    XCTAssertNotNil(thread.prepareSend(document: "doc", provider: grok))
    XCTAssertEqual(thread.phase, .awaitingConfirmation)
    XCTAssertTrue(
      thread.confirmAndSend(
        document: "doc", provider: grok, host: AskDocumentFixture.host(text: "doc")))
    XCTAssertEqual(thread.phase, .streaming)

    let deadline = Date().addingTimeInterval(1)
    while thread.phase != .completed, Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(thread.phase, .completed)
    XCTAssertEqual(agent.texts.count, 1)
  }

  func testCancelPreflightReturnsToIdleWithoutSending() {
    let agent = ImmediateCodescribeAgent()
    let thread = DocumentAskThread(id: UUID(), agent: agent)
    thread.draft = "Keep this draft"
    XCTAssertNotNil(thread.prepareSend(document: "doc", provider: .apiKey("sk-test")))

    thread.cancelPreflight()

    XCTAssertEqual(thread.phase, .idle)
    XCTAssertNil(thread.preflight)
    XCTAssertEqual(thread.draft, "Keep this draft")
    XCTAssertTrue(agent.texts.isEmpty)
  }

  func testMultilineDraftCountsEveryCharacterIncludingNewlines() {
    let draft = "line one\nline two\n"
    let preflight = AskPreflight.make(prompt: draft, document: "")
    XCTAssertEqual(preflight.promptCharacters, 18)
    XCTAssertTrue(draft.contains("\n"))
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
