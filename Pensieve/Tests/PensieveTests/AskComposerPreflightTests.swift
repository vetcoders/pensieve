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
    XCTAssertEqual(preflight.pageCount, 1)
    XCTAssertTrue(preflight.summary.contains("\(prompt.count)"))
    XCTAssertTrue(preflight.summary.contains("\(document.count)"))
    XCTAssertTrue(preflight.summary.contains("will be processed"))
    XCTAssertTrue(preflight.summary.contains("20 minutes"))
  }

  func testOversizedDocumentBecomesMoreThanOnePage() {
    let document = String(repeating: "d", count: 20_000)
    let preflight = AskPreflight.make(prompt: "Explain.", document: document)

    XCTAssertGreaterThan(preflight.pageCount, 1)
    XCTAssertEqual(preflight.pages.count, preflight.pageCount)
    XCTAssertTrue(preflight.pages[1].contains("[continued"))
  }

  func testSendIsBlockedWithoutConfirmEvenWhenReady() {
    let agent = ImmediateCodescribeAgent()
    let thread = DocumentAskThread(id: UUID(), agent: agent)
    thread.draft = "Please summarise."

    XCTAssertFalse(
      thread.sendWithoutConfirm(document: "doc", apiKey: "sk-test"),
      "Ask must not send until the user confirms the preflight")
    XCTAssertEqual(thread.phase, .idle)
    XCTAssertTrue(agent.texts.isEmpty)
    XCTAssertEqual(thread.lastError, "Confirm the character counts before sending.")
  }

  func testPrepareThenConfirmSendsAndEmptyDraftIsBlocked() {
    let agent = ImmediateCodescribeAgent()
    let thread = DocumentAskThread(id: UUID(), agent: agent)

    XCTAssertNil(thread.prepareSend(document: "doc", apiKey: "sk-test"))
    XCTAssertEqual(thread.lastError, "Write a question before sending.")

    thread.draft = "Please summarise."
    let preflight = thread.prepareSend(document: "doc", apiKey: "sk-test")
    XCTAssertNotNil(preflight)
    XCTAssertEqual(thread.phase, .awaitingConfirmation)
    XCTAssertEqual(preflight?.promptCharacters, "Please summarise.".count)
    XCTAssertEqual(preflight?.documentCharacters, 3)

    XCTAssertTrue(thread.confirmAndSend(document: "doc", apiKey: "sk-test"))
    XCTAssertEqual(thread.phase, .streaming)
  }

  func testPrepareIsBlockedWhenAPIKeyIsMissingEvenWithOAuth() {
    let thread = DocumentAskThread(id: UUID(), agent: ImmediateCodescribeAgent())
    thread.draft = "Hello"

    XCTAssertNil(thread.prepareSend(document: "doc", apiKey: "", oauthToken: "oauth-dummy"))
    XCTAssertEqual(thread.lastError, AskReadiness.notReadyMessage)
    XCTAssertEqual(thread.phase, .idle)
  }

  func testCancelPreflightReturnsToIdleWithoutSending() {
    let agent = ImmediateCodescribeAgent()
    let thread = DocumentAskThread(id: UUID(), agent: agent)
    thread.draft = "Keep this draft"
    XCTAssertNotNil(thread.prepareSend(document: "doc", apiKey: "sk-test"))

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

  func streamReply(text: String, threadId: String, listener: CsAgentListener) async throws
    -> String
  {
    state.withLock { $0.texts.append(text) }
    listener.onTextDelta(delta: "ok")
    listener.onTextDone(text: "ok")
    listener.onDone()
    return "ok"
  }
}
