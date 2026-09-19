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

  func testPaginationSplitsOversizedContextInsteadOfRefusing() {
    let prompt = "Summarise this note."
    let document = String(repeating: "x", count: AskPreflight.pageCharacterLimit * 2 + 50)
    let preflight = AskPreflight.make(prompt: prompt, document: document)

    XCTAssertGreaterThan(preflight.pageCount, 1)
    XCTAssertEqual(preflight.pages.count, preflight.pageCount)
    XCTAssertEqual(preflight.promptCharacters, prompt.count)
    XCTAssertEqual(preflight.documentCharacters, document.count)
    XCTAssertGreaterThan(preflight.totalCharacters, AskPreflight.pageCharacterLimit)
    XCTAssertTrue(preflight.summary.contains("will be processed"))
    XCTAssertFalse(preflight.summary.lowercased().contains("refus"))
  }

  func testStreamingPhaseIsObservableAndUsesTheDocumentThreadID() async throws {
    let agent = RecordingCodescribeAgent()
    let threadID = UUID()
    let thread = DocumentAskThread(id: threadID, agent: agent)
    thread.draft = "Say hello."

    XCTAssertEqual(thread.phase, .idle)
    XCTAssertTrue(thread.prepareSend(document: "note", provider: .apiKey("sk-test")) != nil)
    XCTAssertEqual(thread.phase, .awaitingConfirmation)
    XCTAssertTrue(thread.confirmAndSend(document: "note", provider: .apiKey("sk-test")))
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

  func testOversizedSendStreamsEveryPageOnTheSameThread() async throws {
    let agent = RecordingCodescribeAgent()
    let thread = DocumentAskThread(id: UUID(), agent: agent)
    let document = String(repeating: "x", count: AskPreflight.pageCharacterLimit * 2 + 20)
    thread.draft = "Continue."
    XCTAssertNotNil(thread.prepareSend(document: document, provider: .apiKey("sk-test")))
    XCTAssertGreaterThan(thread.preflight?.pageCount ?? 0, 1)
    XCTAssertTrue(thread.confirmAndSend(document: document, provider: .apiKey("sk-test")))

    let finished = await waitUntil(timeout: 1.0) { thread.phase == .completed }
    XCTAssertTrue(finished)
    XCTAssertGreaterThan(agent.texts.count, 1, "pagination must continue, not refuse")
    XCTAssertEqual(Set(agent.threadIDs).count, 1)
    XCTAssertEqual(agent.threadIDs.first, thread.id.uuidString.lowercased())
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
  }

  private let state = Mutex(State())

  var texts: [String] {
    state.withLock { $0.texts }
  }

  var threadIDs: [String] {
    state.withLock { $0.threadIDs }
  }

  func streamReply(text: String, threadId: String, listener: CsAgentListener) async throws
    -> String
  {
    state.withLock {
      $0.texts.append(text)
      $0.threadIDs.append(threadId)
    }
    listener.onTextDelta(delta: "Hel")
    listener.onTextDelta(delta: "lo")
    listener.onTextDone(text: "Hello there now")
    listener.onDone()
    return "Hello there now"
  }
}
