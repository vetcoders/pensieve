import AppKit
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
      XCTAssertNotNil(bytes.range(of: Data("document_open".utf8)))
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

  func testWorkspaceOpensLiveBufferEditsWithUndoAndDoesNotWriteDisk() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let original = String(repeating: "session line\n", count: 10_001) + "FINAL_DECISION"
    let ref = try fixture.document("session.md", text: original)
    let defaults = makeEphemeralDefaults(prefix: "workspace-agent-open")
    let state = AppState(defaults: defaults)
    state.workspaceRoots = [WorkspaceRoot(id: fixture.root)]
    state.documents = [ref]
    let database = IndexDatabase(databaseURL: fixture.base.appendingPathComponent("index.db"))
    let bookmarks = BookmarkStore(defaults: defaults)
    let recents = FakeWorkspaceRecents()
    let store = makeTestDocumentStore(
      indexDatabase: database, bookmarkStore: bookmarks,
      savingSettings: makeAutoSaveSettings(enabled: false), indexDocument: { _, _, _ in })
    let controller = AppController(
      appState: state,
      folderManager: FolderManager(
        metadataStore: WorkspaceMetadataStore(
          metadataURL: fixture.base.appendingPathComponent("workspace.json")),
        indexDatabase: database, bookmarkStore: bookmarks),
      documentStore: store, indexDatabase: database,
      documentWindowRegistry: DocumentWindowRegistry(scheduleLauncherWindowSweep: { _ in }),
      recentDocuments: RecentDocumentsStore(controller: recents))
    let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    controller.hostWindowProvider = { window }
    let undo = try XCTUnwrap(window.undoManager)
    undo.groupsByEvent = false
    let thread = WorkspaceAskThread(identity: fixture.identity)
    let host = await thread.makeHost(
      documents: [ref], database: database,
      openDocument: { ref, isActive in
        try await controller.openAgentDocument(ref, isActive: isActive)
      })
    let open = try await invoke(host, "document_open", ["path": ref.url.path])
    XCTAssertEqual(open["opened"] as? Bool, true)
    XCTAssertNil(open["text"], "Opening selects tools; it must not send the full buffer")
    XCTAssertEqual(state.selectedDocumentID, ref.url)
    XCTAssertEqual(state.documentSession.text, original)
    // An unsaved change belongs to the live editor, not the on-disk read.
    state.documentSession.text += " UNSAVED"
    let read = try await invoke(
      host, "document_read", ["offset": 30, "limit": 30, "from_end": true])
    let tail = try XCTUnwrap(read["text"] as? String)
    XCTAssertTrue(tail.contains("FINAL_DECISION UNSAVED"))
    XCTAssertLessThanOrEqual(tail.count, 30)
    let revision = try XCTUnwrap(read["revision"] as? String)
    undo.beginUndoGrouping()
    let edited = try await invoke(
      host, "document_replace",
      ["revision": revision, "old_text": "FINAL_DECISION", "new_text": "REVISED_DECISION"])
    undo.endUndoGrouping()
    XCTAssertEqual(edited["edited"] as? Bool, true)
    XCTAssertTrue(state.documentSession.text.hasSuffix("REVISED_DECISION UNSAVED"))
    XCTAssertTrue(state.documentSession.isDirty)
    XCTAssertEqual(try String(contentsOf: ref.url, encoding: .utf8), original)
    let live = try await invoke(
      host, "workspace_read",
      ["path": ref.url.path, "offset": state.documentSession.text.count - 24, "limit": 24])
    XCTAssertTrue((live["text"] as? String)?.contains("REVISED_DECISION") == true)
    undo.undo()
    XCTAssertTrue(state.documentSession.text.hasSuffix("FINAL_DECISION UNSAVED"))
    state.documentSession = .untitled()
    do {
      _ = try await invoke(host, "document_read", ["offset": 0, "limit": 20])
      XCTFail("A replaced or closed tab must revoke access")
    } catch {}
    host.invalidate()
  }

  func testOpenBindsExistingTargetControllerAndPreservesSourceDraft() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let ref = try fixture.document("target.md", text: "DISK")
    let defaults = makeEphemeralDefaults(prefix: "workspace-cross-tab")
    let sourceState = AppState(defaults: defaults)
    sourceState.workspaceRoots = [WorkspaceRoot(id: fixture.root)]
    sourceState.documents = [ref]
    sourceState.documentSession = .untitled()
    sourceState.documentSession.text = "SOURCE_UNSAVED"
    sourceState.documentSession.isDirty = true
    let targetState = AppState(defaults: defaults)
    targetState.documentSession = DocumentSession(document: ref, text: "TARGET_UNSAVED")
    let window = NSWindow(
      contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: .zero)
    defer { window.close() }
    XCTAssertTrue(DocumentWindowOwnership.claimDocumentHost(window))
    let registry = DocumentWindowRegistry(
      canMutateWindowTabs: { false }, scheduleDeferredMainWork: { _ in },
      scheduleLauncherWindowSweep: { _ in }, orderAndActivateWindow: { _ in },
      applicationWindows: { [window] })
    let database = IndexDatabase(databaseURL: fixture.base.appendingPathComponent("index.db"))
    let bookmarks = BookmarkStore(defaults: defaults)
    func owner(_ state: AppState) -> AppController {
      AppController(
        appState: state,
        folderManager: FolderManager(
          metadataStore: WorkspaceMetadataStore(
            metadataURL: fixture.base.appendingPathComponent("workspace.json")),
          indexDatabase: database, bookmarkStore: bookmarks),
        documentStore: makeTestDocumentStore(
          indexDatabase: database, bookmarkStore: bookmarks,
          savingSettings: makeAutoSaveSettings(enabled: false)),
        indexDatabase: database, documentWindowRegistry: registry,
        recentDocuments: RecentDocumentsStore(controller: FakeWorkspaceRecents()))
    }
    let source = owner(sourceState)
    let target = owner(targetState)
    target.hostWindowProvider = { window }
    registry.registerController(target, for: window)
    XCTAssertTrue(registry.attach(window, documentID: ref.url, hasEditableBuffer: true))
    var routed = 0
    source.requestOpenDocumentWindow = { requested in
      XCTAssertEqual(requested.id, ref.id)
      routed += 1
    }
    let host = try await source.openAgentDocument(ref, isActive: { true })
    let read = try await Task.detached {
      try host.execute(name: "document_read", argumentsJson: #"{"offset":0,"limit":8000}"#)
    }.value
    XCTAssertTrue(read.contains("TARGET_UNSAVED"))
    XCTAssertFalse(read.contains("SOURCE_UNSAVED"))
    XCTAssertFalse(read.contains("DISK"))
    XCTAssertEqual(routed, 1)
    XCTAssertEqual(sourceState.documentSession.text, "SOURCE_UNSAVED")
    XCTAssertTrue(sourceState.documentSession.isDirty)
    XCTAssertEqual(targetState.documentSession.text, "TARGET_UNSAVED")
  }

  func testOpenOutsideWorkspaceNeverInvokesTheApplication() async throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let ref = try fixture.document("inside.md", text: "inside")
    let outside = fixture.base.appendingPathComponent("outside.md")
    try "outside".write(to: outside, atomically: true, encoding: .utf8)
    let calls = Mutex(0)
    let thread = WorkspaceAskThread(identity: fixture.identity)
    let database = IndexDatabase(databaseURL: fixture.base.appendingPathComponent("index.db"))
    let host = await thread.makeHost(
      documents: [ref], database: database,
      openDocument: { _, _ in
        calls.withLock { $0 += 1 }
        return AskDocumentFixture.host(text: "inside")
      })
    do {
      _ = try await invoke(host, "document_open", ["path": outside.path])
      XCTFail("Outside workspace open must fail")
    } catch {}
    XCTAssertEqual(calls.withLock { $0 }, 0)
  }

  private func invoke(_ host: WorkspaceToolHost, _ name: String, _ arguments: [String: Any])
    async throws -> [String: Any]
  {
    let json = String(
      decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
    let result = try await Task.detached { try host.execute(name: name, argumentsJson: json) }.value
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
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

  func testReadRejectsAdHocAndEscapingSymlinkAndEditsRequireOpen() async throws {
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

@MainActor
private final class FakeWorkspaceRecents: RecentDocumentsControlling {
  var recentDocumentURLs: [URL] = []
  func noteNewRecentDocumentURL(_ url: URL) { recentDocumentURLs.append(url) }
  func clearRecentDocuments(_ sender: Any?) { recentDocumentURLs = [] }
}
