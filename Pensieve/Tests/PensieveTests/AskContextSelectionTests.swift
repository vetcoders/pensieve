import Foundation
import GRDB
import XCTest

@testable import Pensieve

@MainActor
final class AskContextSelectionTests: XCTestCase {
  func testSelectionIsCapturedOnceUntilNewThread() {
    let state = AppState(defaults: makeEphemeralDefaults(prefix: "ask-context-selection"))
    let first = DocumentRef(id: URL(fileURLWithPath: "/fixture/first.md"), isAdHoc: true)
    let second = DocumentRef(id: URL(fileURLWithPath: "/fixture/second.md"), isAdHoc: true)
    state.documentSession = DocumentSession(document: first, text: "first")
    let store = AskThreadStore()
    let panel = AskPanelController(threads: store)
    let captured = panel.ensureThread(context: AskContextSelection.current(in: state))
    captured.draft = "Keep this question"
    captured.appendDictation("Keep this transcript")

    state.documentSession = DocumentSession(document: second, text: "second")
    let same = panel.ensureThread(context: AskContextSelection.current(in: state))
    XCTAssertTrue(same === captured)
    XCTAssertEqual(same.context.files.map(\.url), [first.url])
    XCTAssertEqual(same.draft, "Keep this question")
    panel.newThread(context: AskContextSelection.current(in: state))
    let next = panel.ensureThread(context: .empty)
    XCTAssertNotEqual(next.id, captured.id)
    XCTAssertEqual(next.context.files.map(\.url), [second.url])
    XCTAssertTrue(next.turns.isEmpty)
    panel.activateThread(captured.id)
    XCTAssertTrue(panel.ensureThread(context: .empty) === captured)
    XCTAssertEqual(captured.turns.first?.text, "Keep this transcript")
  }

  func testEmptyWindowAndWorkspaceSelection() {
    let state = AppState(defaults: makeEphemeralDefaults(prefix: "ask-context-roots"))
    XCTAssertTrue(AskContextSelection.current(in: state).isEmpty)
    let roots = [URL(fileURLWithPath: "/fixture/a"), URL(fileURLWithPath: "/fixture/b")]
    state.workspaceRoots = roots.map { WorkspaceRoot(id: $0) }
    let context = AskContextSelection.current(in: state)
    XCTAssertEqual(context.roots, Set(roots))
    XCTAssertTrue(context.files.isEmpty)
    state.documentSession = .untitled()
    let draft = AskContextSelection.current(in: state)
    XCTAssertTrue(draft.roots.isEmpty)
    XCTAssertEqual(draft.draftID, state.documentSession.askThreadID)
    state.documentSession = .untitled()
    XCTAssertNotEqual(draft.draftID, AskContextSelection.current(in: state).draftID)
  }

  func testFirstAutomaticThreadRestoresAfterRestart() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = makeEphemeralDefaults(prefix: "ask-first-thread")
    let url = directory.appendingPathComponent("history.sqlite")
    let firstStore = AskThreadStore(history: try AskHistoryStore(databaseURL: url))
    let firstPanel = AskPanelController(defaults: defaults, threads: firstStore)
    let first = firstPanel.ensureThread(context: .empty)
    first.draft = "Saved first question"
    first.appendDictation("Saved first transcript")
    XCTAssertTrue(firstStore.flushHistory())

    let reopenedStore = AskThreadStore(history: try AskHistoryStore(databaseURL: url))
    let reopenedPanel = AskPanelController(defaults: defaults, threads: reopenedStore)
    XCTAssertEqual(reopenedPanel.activeThreadID, first.id)
    let restored = reopenedPanel.ensureThread(context: .empty)
    XCTAssertEqual(restored.draft, "Saved first question")
    XCTAssertEqual(restored.turns, first.turns)
    XCTAssertTrue(restored.context.isEmpty)
  }

  func testFailedHistoryWriteVetoesQuitBeforeDocumentConsentAndCanRetry() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let history = try AskHistoryStore(databaseURL: url)
    let store = AskThreadStore(history: history)
    let panel = AskPanelController(threads: store)
    let thread = panel.ensureThread(context: .empty)
    thread.draft = "Keep this unsaved question"
    let writer = try DatabaseQueue(path: url.path)
    try writer.write { db in
      try db.execute(
        sql: """
          CREATE TRIGGER refuse_ask_history BEFORE UPDATE ON ask_threads
          BEGIN SELECT RAISE(ABORT, 'fixture refusal'); END
          """)
    }
    var documentConsentCalls = 0
    XCTAssertEqual(
      panel.prepareForTermination {
        documentConsentCalls += 1
        return .terminateNow
      }, .terminateCancel)
    XCTAssertEqual(documentConsentCalls, 0)
    XCTAssertEqual(thread.draft, "Keep this unsaved question")
    XCTAssertNotNil(store.historyError)
    try writer.write { db in try db.execute(sql: "DROP TRIGGER refuse_ask_history") }
    XCTAssertEqual(
      panel.prepareForTermination {
        documentConsentCalls += 1
        return .terminateNow
      }, .terminateNow)
    XCTAssertEqual(documentConsentCalls, 1)
    XCTAssertEqual(try history.load(id: thread.id)?.draft, thread.draft)
  }

  func testUnavailableHistoryVetoesQuitWithoutDiscardingDraft() {
    let store = AskThreadStore()
    store.reportHistoryError(NSError(domain: "History fixture", code: 1))
    let panel = AskPanelController(threads: store)
    let thread = panel.ensureThread(context: .empty)
    thread.draft = "Keep me"
    XCTAssertEqual(panel.prepareForTermination { .terminateNow }, .terminateCancel)
    XCTAssertEqual(thread.draft, "Keep me")
  }

  func testQuitWithoutSavedHistoryRequiresExplicitConsent() {
    let store = AskThreadStore()
    store.reportHistoryError(NSError(domain: "History fixture", code: 1))
    let panel = AskPanelController(threads: store)
    let thread = panel.ensureThread(context: .empty)
    thread.draft = "Unsaved question"
    var confirmations = 0
    XCTAssertEqual(
      panel.prepareForTermination(
        confirmUnsavedHistoryQuit: { message in
          XCTAssertTrue(message.contains("Ask history"))
          confirmations += 1
          return true
        }, resolveDocuments: { .terminateNow }), .terminateNow)
    XCTAssertEqual(confirmations, 1)
    XCTAssertEqual(thread.draft, "Unsaved question")
  }

}
