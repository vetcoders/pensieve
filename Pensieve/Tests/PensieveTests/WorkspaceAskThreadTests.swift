import CodescribeBridge
import Darwin
import Foundation
import Synchronization
import XCTest

@testable import Pensieve

@MainActor
final class WorkspaceAskThreadTests: XCTestCase {
  /// Admission uses the delivered library, independently of the test agent.
  func testVendoredWorkspaceSessionActuallyExists() throws {
    let package = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for profile in ["debug", "release"] {
      let library = package.appendingPathComponent(
        "Vendor/codescribe-ffi/\(profile)/libcodescribe_ffi.dylib")
      let handle = try XCTUnwrap(dlopen(library.path, RTLD_LAZY | RTLD_LOCAL))
      defer { dlclose(handle) }
      XCTAssertNotNil(
        dlsym(handle, "uniffi_codescribe_ffi_fn_method_codescribeagent_stream_workspace"))
      XCTAssertNotNil(
        dlsym(handle, "uniffi_codescribe_ffi_fn_method_codescribeagent_stream_document"))
      let bytes = try Data(contentsOf: library, options: .mappedIfSafe)
      XCTAssertNotNil(bytes.range(of: Data("workspace_search".utf8)))
      XCTAssertNotNil(bytes.range(of: Data("workspace_read".utf8)))
    }
  }

  func testWorkspaceThreadBindsSearch() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let document = try fixture.document("decision.md", text: "alpha beta shared decision")
    let foreignRoot = fixture.base.appendingPathComponent("foreign", isDirectory: true)
    try FileManager.default.createDirectory(at: foreignRoot, withIntermediateDirectories: true)
    let foreign = DocumentRef(
      id: foreignRoot.appendingPathComponent("private.md"), rootURL: foreignRoot,
      relativePath: "private.md")
    try "alpha beta private decision".write(to: foreign.url, atomically: true, encoding: .utf8)
    let database = IndexDatabase(databaseURL: fixture.base.appendingPathComponent("index.db"))
    database.open()
    await database.upsertWorkspace(
      identity: fixture.identity, roots: [fixture.root], documents: [document])
    await database.upsertWorkspace(
      identity: WorkspaceIdentity.make(rootURL: foreignRoot, bookmarkData: nil),
      roots: [foreignRoot], documents: [foreign])
    let agent = ToolCallingAgent()
    let thread = WorkspaceAskThread(identity: fixture.identity, makeAgent: { agent })
    let host = await thread.makeHost(documents: [document, foreign], database: database)
    XCTAssertTrue(thread.send(text: "alpha beta", host: host, provider: .apiKey("test-key")))
    try await waitUntil { !thread.isStreaming }
    let json = try XCTUnwrap(agent.searchResult.withLock { $0 })
    let payload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    let matches = try XCTUnwrap(payload["matches"] as? [[String: Any]])
    XCTAssertEqual(matches.count, 1)
    XCTAssertEqual(matches.first?["path"] as? String, document.url.path)
    XCTAssertEqual(agent.readResult.withLock { $0 }, "alpha beta shared decision")
    XCTAssertEqual(thread.turns.last?.text, "Found the workspace decision.")
    XCTAssertNil(thread.lastError)
    XCTAssertFalse(host.isActive(), "completion must revoke tool authority")
    XCTAssertEqual(
      try String(contentsOf: document.url, encoding: .utf8), "alpha beta shared decision")
  }

  func testOneConversationPerRootSetAcrossDocumentsAndRootOrder() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let other = fixture.base.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    let store = WorkspaceAskThreadStore()
    let first = store.thread(
      for: WorkspaceIdentity.make(roots: [fixture.root, other], bookmarkData: nil))
    let same = store.thread(
      for: WorkspaceIdentity.make(roots: [other, fixture.root], bookmarkData: Data([1])))
    XCTAssertTrue(first === same)
    first.draft = "Keep this workspace question"
    XCTAssertEqual(same.draft, first.draft)
    XCTAssertFalse(first === store.thread(for: fixture.identity))
  }

  func testReadRejectsAdHocAndEscapingSymlinkAndNeverAllowsWrites() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let outside = fixture.base.appendingPathComponent("outside.md")
    try "private".write(to: outside, atomically: true, encoding: .utf8)
    let link = fixture.root.appendingPathComponent("escape.md")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let symlink = DocumentRef(id: link, rootURL: fixture.root, relativePath: "escape.md")
    let adHoc = DocumentRef(id: outside, isAdHoc: true)
    let database = IndexDatabase(databaseURL: fixture.base.appendingPathComponent("index.db"))
    let thread = WorkspaceAskThread(identity: fixture.identity)
    let host = await thread.makeHost(documents: [symlink, adHoc], database: database)
    for path in [link.path, outside.path] {
      let args = String(
        decoding: try JSONSerialization.data(withJSONObject: ["path": path]), as: UTF8.self)
      XCTAssertThrowsError(try host.execute(name: "workspace_read", argumentsJson: args))
    }
    XCTAssertThrowsError(try host.execute(name: "document_replace", argumentsJson: "{}"))
    XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private")
  }

  func testSearchRefusesMainThreadInsteadOfBlockingTheUI() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let database = IndexDatabase(databaseURL: fixture.base.appendingPathComponent("index.db"))
    let thread = WorkspaceAskThread(identity: fixture.identity)
    let host = await thread.makeHost(documents: [], database: database)
    XCTAssertThrowsError(
      try host.execute(name: "workspace_search", argumentsJson: #"{"query":"alpha"}"#))
  }

  func testCancelRevokesHostAndIgnoresLateReply() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let agent = HeldAgent()
    let thread = WorkspaceAskThread(identity: fixture.identity, makeAgent: { agent })
    let database = IndexDatabase(databaseURL: fixture.base.appendingPathComponent("index.db"))
    let host = await thread.makeHost(documents: [], database: database)
    XCTAssertTrue(thread.send(text: "wait", host: host, provider: .codex(accountAuthorized: true)))
    try await waitUntil { agent.pending.withLock { $0 != nil } }
    thread.cancel()
    XCTAssertFalse(host.isActive())
    XCTAssertFalse(thread.isStreaming)
    agent.pending.withLock { pending in
      pending?.resume(returning: "late reply")
      pending = nil
    }
    for _ in 0..<20 { await Task.yield() }
    XCTAssertEqual(thread.turns.last?.text, "")
    XCTAssertNil(thread.lastError)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "workspace operation did not settle")
  }

  private struct Fixture {
    let base: URL
    let root: URL
    var identity: WorkspaceIdentity { WorkspaceIdentity.make(rootURL: root, bookmarkData: nil) }

    init() throws {
      base = FileManager.default.temporaryDirectory.appendingPathComponent(
        "WorkspaceAsk-\(UUID())", isDirectory: true)
      root = base.appendingPathComponent("workspace", isDirectory: true).standardizedFileURL
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func document(_ name: String, text: String) throws -> DocumentRef {
      let url = root.appendingPathComponent(name)
      try text.write(to: url, atomically: true, encoding: .utf8)
      return DocumentRef(id: url, rootURL: root, relativePath: name)
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
  }
}

private final class ToolCallingAgent: WorkspaceAgentStreaming, Sendable {
  let searchResult = Mutex<String?>(nil)
  let readResult = Mutex<String?>(nil)

  func streamWorkspace(
    text: String, threadId: String, workspace: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String {
    let json = try await Task.detached {
      try workspace.execute(name: "workspace_search", argumentsJson: #"{"query":"alpha beta"}"#)
    }.value
    searchResult.withLock { $0 = json }
    let payload = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    guard let matches = payload?["matches"] as? [[String: Any]],
      let path = matches.first?["path"] as? String
    else { throw CsError.Agent(msg: "Missing bound search result") }
    let args = String(
      decoding: try JSONSerialization.data(withJSONObject: ["path": path]), as: UTF8.self)
    let read = try await Task.detached {
      try workspace.execute(name: "workspace_read", argumentsJson: args)
    }.value
    let readPayload = try JSONSerialization.jsonObject(with: Data(read.utf8)) as? [String: Any]
    readResult.withLock { $0 = readPayload?["text"] as? String }
    listener.onTextDelta(delta: "Found the workspace decision.")
    return "Found the workspace decision."
  }

  func cancelTurn(threadId: String) -> Bool { true }
  func resolveToolApproval(
    sessionId: String, threadId: String, callId: String, approved: Bool, remember: Bool
  ) -> Bool { false }
}

private final class HeldAgent: WorkspaceAgentStreaming, Sendable {
  let pending = Mutex<CheckedContinuation<String, any Error>?>(nil)

  func streamWorkspace(
    text: String, threadId: String, workspace: CsDocumentToolHost,
    provider: CsDocumentProvider?, listener: CsAgentListener
  ) async throws -> String {
    try await withCheckedThrowingContinuation { continuation in
      pending.withLock { $0 = continuation }
    }
  }

  func cancelTurn(threadId: String) -> Bool { true }
  func resolveToolApproval(
    sessionId: String, threadId: String, callId: String, approved: Bool, remember: Bool
  ) -> Bool { false }
}
