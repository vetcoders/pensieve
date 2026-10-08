import CodescribeBridge
import Foundation
import GRDB
import Synchronization
import XCTest

@testable import Pensieve

final class AskHistoryStoreTests: XCTestCase {
  func testRoundTripAcrossReopenPreservesUUIDContextTurnsAndDraft() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
    let file = workspace.appendingPathComponent("notes.md")
    let external = directory.appendingPathComponent("other.md")
    let context = AskContext(
      roots: [workspace],
      files: [
        DocumentRef(id: file, rootURL: workspace, relativePath: "notes.md"),
        DocumentRef(id: external, isAdHoc: true),
      ], draftID: UUID())
    let turns = [
      AskTurn(role: .dictation, text: "My dictated question"),
      AskTurn(role: .user, text: "A question with an image", attachmentIDs: [UUID()]),
      AskTurn(role: .assistant, text: "The answer"),
    ]
    let record = AskHistoryRecord(
      id: UUID(), context: context, turns: turns, draft: "Next question",
      createdAt: Date(timeIntervalSince1970: 123), updatedAt: Date(timeIntervalSince1970: 456))
    try AskHistoryStore(databaseURL: url).save(record)

    let reopened = try AskHistoryStore(databaseURL: url)
    let restored = try XCTUnwrap(reopened.load(id: record.id))
    XCTAssertEqual(restored.id, record.id)
    XCTAssertEqual(restored.context.roots, context.roots)
    XCTAssertEqual(restored.context.files, context.files)
    XCTAssertEqual(restored.context.draftID, context.draftID)
    XCTAssertEqual(restored.turns, turns)
    XCTAssertEqual(restored.draft, record.draft)
    XCTAssertEqual(restored.createdAt, record.createdAt)
    XCTAssertEqual(restored.updatedAt, record.updatedAt)
  }

  func testDirectoryMarkerDoesNotChangeContextIdentityAcrossReopen() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let marked = URL(fileURLWithPath: directory.path, isDirectory: true)
    let unmarked = URL(fileURLWithPath: directory.path, isDirectory: false)
    let context = AskContext(roots: [marked, unmarked])
    XCTAssertEqual(context.roots.count, 1)
    XCTAssertEqual(context, AskContext(roots: [unmarked]))
    let store = try AskHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let record = AskHistoryRecord(id: UUID(), context: context)
    try store.save(record)
    XCTAssertEqual(try store.load(id: record.id)?.context, context)
  }

  func testNonFileContextIsRefusedWithoutFabricatingFilesystemAuthority() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let remote = try XCTUnwrap(URL(string: "https://example.invalid/fixture"))
    let context = AskContext(roots: [remote], files: [DocumentRef(id: remote)])
    XCTAssertEqual(context.roots, [remote])
    XCTAssertFalse(try XCTUnwrap(context.files.first).url.isFileURL)
    let store = try AskHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
    XCTAssertThrowsError(try store.save(AskHistoryRecord(id: UUID(), context: context)))
    XCTAssertTrue(try store.list().isEmpty)
  }

  func testInterruptedAssistantKeepsPartialTextWithoutResumingStream() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AskHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let partial = AskTurn(role: .assistant, text: "Saved delta", isStreaming: true)
    let record = AskHistoryRecord(id: UUID(), context: .empty, turns: [partial])
    try store.save(record)

    let restored = try XCTUnwrap(store.load(id: record.id))
    XCTAssertEqual(restored.turns.first?.id, partial.id)
    XCTAssertEqual(restored.turns.first?.text, "Saved delta")
    XCTAssertEqual(restored.turns.first?.isStreaming, false)
  }

  func testMigrationCreatesOnlyNewHistoryAndPreservesExistingDatabaseData() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let original = try DatabaseQueue(path: url.path)
    try original.write { db in
      try db.execute(sql: "CREATE TABLE sentinel (value TEXT NOT NULL)")
      try db.execute(sql: "INSERT INTO sentinel VALUES ('existing-data')")
    }

    let store = try AskHistoryStore(databaseURL: url)
    XCTAssertTrue(try store.list().isEmpty)
    let record = AskHistoryRecord(id: UUID(), context: .empty, draft: "Still here")
    try store.save(record)
    let reopened = try AskHistoryStore(databaseURL: url)
    XCTAssertEqual(try reopened.list().map(\.id), [record.id])
    try original.read { db in
      XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM sentinel"), "existing-data")
      XCTAssertEqual(
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations"), ["ask_history_v1"])
    }
  }

  func testUpdateRetainsBirthTimeAndListOrdersByRecentChange() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AskHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let first = AskHistoryRecord(
      id: UUID(), context: .empty, draft: "First", createdAt: Date(timeIntervalSince1970: 1))
    let second = AskHistoryRecord(
      id: UUID(), context: .empty, draft: "Second", createdAt: Date(timeIntervalSince1970: 2))
    try store.save(first)
    try store.save(second)
    XCTAssertEqual(try store.list().map(\.id), [second.id, first.id])

    let updated = AskHistoryRecord(
      id: first.id, context: first.context, turns: [AskTurn(role: .user, text: "Sent")],
      draft: "Changed", createdAt: Date(timeIntervalSince1970: 900),
      updatedAt: Date(timeIntervalSince1970: 3))
    try store.save(updated)
    let loaded = try XCTUnwrap(store.load(id: first.id))
    XCTAssertEqual(loaded.createdAt, first.createdAt)
    XCTAssertEqual(loaded.draft, updated.draft)
    XCTAssertEqual(loaded.turns, updated.turns)
    XCTAssertEqual(try store.list().map(\.id), [first.id, second.id])
  }

  func testSameUUIDCannotChangeContextAndFailedWriteKeepsOriginalHistory() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AskHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let record = AskHistoryRecord(id: UUID(), context: .empty, draft: "Original")
    try store.save(record)
    let changed = AskHistoryRecord(
      id: record.id, context: AskContext(roots: [directory]), draft: "Changed")

    XCTAssertThrowsError(try store.save(changed)) { error in
      guard case AskHistoryError.contextChanged(let id) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(id, record.id)
    }
    XCTAssertEqual(try store.load(id: record.id)?.draft, "Original")
    XCTAssertEqual(try store.load(id: record.id)?.context.roots, [])
  }

  func testCanonicalPathsCollapseSymlinkAliasesWithoutChangingThreadID() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
    let alias = directory.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: workspace)
    let file = workspace.appendingPathComponent("notes.md")
    try "Hello".write(to: file, atomically: true, encoding: .utf8)
    let context = AskContext(
      roots: [workspace, alias],
      files: [
        DocumentRef(
          id: alias.appendingPathComponent("notes.md"), rootURL: alias, relativePath: "notes.md")
      ])
    let store = try AskHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let record = AskHistoryRecord(id: UUID(), context: context)
    try store.save(record)

    let restored = try XCTUnwrap(store.load(id: record.id))
    XCTAssertEqual(restored.id, record.id)
    XCTAssertEqual(restored.context.roots.map(\.path), [workspace.resolvingSymlinksInPath().path])
    XCTAssertEqual(restored.context.files.first?.url, file.resolvingSymlinksInPath())
    XCTAssertEqual(
      restored.context.files.first?.rootURL?.path, workspace.resolvingSymlinksInPath().path)
    try store.save(restored)
  }

  @MainActor
  func testRestartKeepsSelectedFilePinAfterPathBecomesSymlinkAndHostDeniesTarget() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let selected = directory.appendingPathComponent("selected.md")
    let outside = directory.appendingPathComponent("outside.md")
    try "Selected content".write(to: selected, atomically: true, encoding: .utf8)
    try "Outside content".write(to: outside, atomically: true, encoding: .utf8)
    let context = AskContext(files: [DocumentRef(id: selected, isAdHoc: true)])
    var record = AskHistoryRecord(id: UUID(), context: context)
    try AskHistoryStore(databaseURL: url).save(record)
    try FileManager.default.removeItem(at: selected)
    try FileManager.default.createSymbolicLink(at: selected, withDestinationURL: outside)

    let reopened = try AskHistoryStore(databaseURL: url)
    let restored = try XCTUnwrap(reopened.load(id: record.id))
    XCTAssertEqual(restored.context.files.first?.url, selected)
    XCTAssertNotEqual(restored.context.files.first?.url, outside)
    record.draft = "Changed after replacement"
    try reopened.save(record)
    XCTAssertEqual(try reopened.load(id: record.id)?.context.files.first?.url, selected)
    try reopened.save(restored)

    let store = AskThreadStore(makeAgent: { HistoryTestAgent() }, history: reopened)
    let thread = store.thread(for: record.id)
    let database = IndexDatabase(databaseURL: directory.appendingPathComponent("index.db"))
    let host = await thread.makeHost(documents: [], database: database)
    defer { host.invalidate() }
    for path in [selected.path, outside.path] {
      let arguments = try JSONSerialization.data(withJSONObject: ["path": path])
      XCTAssertThrowsError(
        try host.execute(
          name: "workspace_read", argumentsJson: String(decoding: arguments, as: UTF8.self)))
    }
  }

  @MainActor
  func testRestartKeepsRootPinAfterPathBecomesSymlinkAndHostExcludesDocuments() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let selectedRoot = directory.appendingPathComponent("workspace", isDirectory: true)
    let retiredRoot = directory.appendingPathComponent("retired", isDirectory: true)
    let outsideRoot = directory.appendingPathComponent("outside", isDirectory: true)
    for root in [selectedRoot, outsideRoot] {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    let outsideFile = outsideRoot.appendingPathComponent("secret.md")
    try "Outside content".write(to: outsideFile, atomically: true, encoding: .utf8)
    let context = AskContext(roots: [selectedRoot])
    var record = AskHistoryRecord(id: UUID(), context: context)
    try AskHistoryStore(databaseURL: url).save(record)
    try FileManager.default.moveItem(at: selectedRoot, to: retiredRoot)
    try FileManager.default.createSymbolicLink(at: selectedRoot, withDestinationURL: outsideRoot)

    let reopened = try AskHistoryStore(databaseURL: url)
    let restored = try XCTUnwrap(reopened.load(id: record.id))
    XCTAssertEqual(restored.context.roots, context.roots)
    XCTAssertFalse(restored.context.roots.contains(outsideRoot.resolvingSymlinksInPath()))
    record.draft = "Changed after replacement"
    try reopened.save(record)
    XCTAssertEqual(try reopened.load(id: record.id)?.context.roots, context.roots)
    try reopened.save(restored)

    let store = AskThreadStore(makeAgent: { HistoryTestAgent() }, history: reopened)
    let thread = store.thread(for: record.id)
    let aliasFile = selectedRoot.appendingPathComponent("secret.md")
    let ref = DocumentRef(id: aliasFile, rootURL: selectedRoot, relativePath: "secret.md")
    let database = IndexDatabase(databaseURL: directory.appendingPathComponent("index.db"))
    let host = await thread.makeHost(documents: [ref], database: database)
    defer { host.invalidate() }
    for path in [aliasFile.path, outsideFile.path] {
      let arguments = try JSONSerialization.data(withJSONObject: ["path": path])
      XCTAssertThrowsError(
        try host.execute(
          name: "workspace_read", argumentsJson: String(decoding: arguments, as: UTF8.self)))
    }
  }

  func testCorruptAndFuturePayloadsThrowInsteadOfReturningEmptyHistory() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let store = try AskHistoryStore(databaseURL: url)
    let record = AskHistoryRecord(id: UUID(), context: .empty)
    try store.save(record)
    let writer = try DatabaseQueue(path: url.path)
    try writer.write { db in
      try db.execute(sql: "UPDATE ask_threads SET turns = ?", arguments: [Data("broken".utf8)])
    }
    XCTAssertThrowsError(try store.load(id: record.id))
    XCTAssertThrowsError(try store.list())
    XCTAssertThrowsError(try store.save(record))
    try writer.write { db in
      try db.execute(sql: "UPDATE ask_threads SET payload_version = 'bad-type'")
    }
    XCTAssertThrowsError(try store.load(id: record.id)) { error in
      guard case AskHistoryError.invalidColumn("payload_version") = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    try writer.read { db in
      XCTAssertEqual(
        try Data.fetchOne(db, sql: "SELECT turns FROM ask_threads"), Data("broken".utf8))
    }
    try writer.write { db in
      try db.execute(sql: "UPDATE ask_threads SET payload_version = 99")
    }
    XCTAssertThrowsError(try store.load(id: record.id)) { error in
      guard case AskHistoryError.unsupportedPayloadVersion(99) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
    XCTAssertThrowsError(try store.save(record))
  }

  func testDeleteRetiresOnlySelectedThread() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AskHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite"))
    let first = AskHistoryRecord(id: UUID(), context: .empty)
    let second = AskHistoryRecord(id: UUID(), context: .empty)
    try store.save(first)
    try store.save(second)

    try store.delete(id: first.id)
    XCTAssertNil(try store.load(id: first.id))
    XCTAssertEqual(try store.list().map(\.id), [second.id])
  }

  func testDefaultDatabaseUsesExplicitSmokeAndImplicitTestIsolation() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    XCTAssertEqual(
      AskHistoryStore.defaultDatabaseURL(
        environment: [AppSupportLocation.overrideEnvironmentKey: directory.path],
        isTestProcess: false),
      directory.appendingPathComponent("AskHistory.sqlite"))
    XCTAssertEqual(
      AskHistoryStore.defaultDatabaseURL(environment: [:], isTestProcess: true),
      AppSupportLocation.testProcessRoot().appendingPathComponent("AskHistory.sqlite"))
  }

  @MainActor
  func testThreadStoreFlushAndRestoreKeepConversationWithoutCreatingAgent() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = try AskHistoryStore(
      databaseURL: directory.appendingPathComponent("history.sqlite"))
    let creations = Mutex(0)
    let makeAgent: @Sendable () -> any AskAgentStreaming = {
      creations.withLock { $0 += 1 }
      return HistoryTestAgent()
    }
    let context = AskContext(draftID: UUID())
    let store = AskThreadStore(makeAgent: makeAgent, history: history)
    let thread = store.newThread(context: context)
    let originalBirth = try XCTUnwrap(history.load(id: thread.id)).createdAt
    thread.draft = "Unsent question"
    thread.appendDictation("Dictated content")
    XCTAssertTrue(store.flushHistory())

    let reopened = AskThreadStore(makeAgent: makeAgent, history: history)
    let restored = reopened.thread(for: thread.id, context: .empty)
    XCTAssertEqual(restored.id, thread.id)
    XCTAssertEqual(restored.context, context)
    XCTAssertEqual(restored.draft, "Unsent question")
    XCTAssertEqual(restored.turns, thread.turns)
    XCTAssertFalse(restored.isBusy)
    XCTAssertEqual(reopened.historyRecords.map(\.id), [thread.id])
    restored.draft = "Another question"
    XCTAssertTrue(reopened.flushHistory())
    XCTAssertEqual(try history.load(id: thread.id)?.createdAt, originalBirth)
    XCTAssertEqual(creations.withLock { $0 }, 0)
  }

  @MainActor
  func testUnreadableHistoryRefusesFlushWithoutOverwritingItsTranscript() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("history.sqlite")
    let history = try AskHistoryStore(databaseURL: url)
    let record = AskHistoryRecord(id: UUID(), context: .empty)
    try history.save(record)
    let writer = try DatabaseQueue(path: url.path)
    let corrupt = Data("broken-original".utf8)
    try writer.write { db in
      try db.execute(sql: "UPDATE ask_threads SET turns = ?", arguments: [corrupt])
    }
    let store = AskThreadStore(makeAgent: { HistoryTestAgent() }, history: history)
    let unreadable = store.thread(for: record.id)
    unreadable.draft = "Replacement that must stay in memory"

    XCTAssertFalse(store.flushHistory())
    XCTAssertNotNil(store.historyError)
    try writer.read { db in
      XCTAssertEqual(try Data.fetchOne(db, sql: "SELECT turns FROM ask_threads"), corrupt)
    }
  }

  @MainActor
  func testContinuousDraftChangesCheckpointBeforeTypingStopsAndFlushSavesLatest() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = try AskHistoryStore(
      databaseURL: directory.appendingPathComponent("history.sqlite"))
    let store = AskThreadStore(makeAgent: { HistoryTestAgent() }, history: history)
    let thread = store.newThread()
    var savedWhileTyping = false
    // Keep editing faster than the checkpoint interval. A trailing debounce would never
    // save during this activity; bounded polling observes a real disk receipt instead.
    for index in 0..<100 {
      thread.draft = "Draft \(index)"
      try await Task.sleep(for: .milliseconds(20))
      if try history.load(id: thread.id)?.draft.isEmpty == false {
        savedWhileTyping = true
        break
      }
    }
    XCTAssertTrue(savedWhileTyping)
    thread.draft = "Final text"
    XCTAssertTrue(store.flushHistory())
    XCTAssertEqual(try history.load(id: thread.id)?.draft, "Final text")
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveAskHistoryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.resolvingSymlinksInPath()
  }
}

/// The persistence path must remain inert even if a future regression eagerly asks for an agent.
private final class HistoryTestAgent: AskAgentStreaming, Sendable {
  func streamWorkspace(
    text: String, threadId: String, workspace: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String {
    throw CsError.Agent(msg: "Persistence tests do not submit requests.")
  }

  func cancelTurn(threadId: String) -> Bool { false }

  func resolveToolApproval(
    sessionId: String, threadId: String, callId: String, approved: Bool, remember: Bool
  ) -> Bool { false }
}
