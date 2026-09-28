import AppKit
import CodescribeBridge
import XCTest

@testable import Pensieve

@MainActor
enum AskDocumentFixture {
  static func host(text: String) -> DocumentToolHost {
    let id = UUID()
    return DocumentToolHost(
      documentID: id,
      snapshot: { AskDocumentSnapshot(id: id, title: "Test", text: text) },
      replace: { _, _ in false })
  }
}

@MainActor
final class DocumentToolHostTests: XCTestCase {
  @MainActor
  private final class Buffer {
    var id = UUID()
    var text = "Unsaved 🧠 decision"
    var edits = 0
    func host() -> DocumentToolHost {
      DocumentToolHost(
        documentID: id,
        snapshot: { [self] in AskDocumentSnapshot(id: id, title: "Draft", text: text) },
        replace: { [self] expected, replacement in
          guard text == expected else { return false }
          text = replacement
          edits += 1
          return true
        })
    }
  }

  private func invoke(_ host: DocumentToolHost, _ name: String, _ args: [String: Any]) throws
    -> [String: Any]
  {
    let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
    let output = try host.execute(name: name, argumentsJson: json)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  }

  func testReadsLiveUnsavedTextAndUnicodeOffsets() throws {
    let buffer = Buffer()
    let host = buffer.host()
    buffer.text = "🧠 Now changed"
    let first = try invoke(host, "document_read", ["offset": 0, "limit": 2])
    XCTAssertEqual(first["text"] as? String, "🧠 ")
    XCTAssertEqual(first["next_offset"] as? Int, 2)
    let tail = try invoke(host, "document_read", ["offset": 2, "limit": 8000])
    XCTAssertEqual(tail["text"] as? String, "Now changed")
    XCTAssertTrue(tail["next_offset"] is NSNull)
  }

  func testRevisionCheckedEditAndStaleOrAmbiguousEditsAreRejected() throws {
    let buffer = Buffer()
    let host = buffer.host()
    let read = try invoke(host, "document_read", ["offset": 0, "limit": 8000])
    let revision = try XCTUnwrap(read["revision"] as? String)
    let args: [String: Any] = ["revision": revision, "old_text": "decision", "new_text": "result"]
    let receipt = try invoke(host, "document_replace", args)
    XCTAssertEqual(buffer.text, "Unsaved 🧠 result")
    XCTAssertEqual(receipt["direct_file_write"] as? Bool, false)
    XCTAssertThrowsError(try invoke(host, "document_replace", args))
    XCTAssertEqual(buffer.edits, 1)
    buffer.text = "same same"
    let current = try invoke(host, "document_read", ["offset": 0, "limit": 8000])
    XCTAssertThrowsError(
      try invoke(
        host, "document_replace",
        [
          "revision": try XCTUnwrap(current["revision"]), "old_text": "same", "new_text": "changed",
        ]))
    XCTAssertEqual(buffer.edits, 1)
  }

  func testCancellationAndDifferentDocumentRefuseAccess() throws {
    let buffer = Buffer()
    let host = buffer.host()
    buffer.id = UUID()
    XCTAssertThrowsError(try invoke(host, "document_read", ["offset": 0, "limit": 20]))
    let current = buffer.host()
    current.invalidate()
    XCTAssertThrowsError(try invoke(current, "document_search", ["query": "decision"]))
  }

  func testEmptyDocumentCanBeWrittenAndSearchFindsTail() throws {
    let buffer = Buffer()
    buffer.text = ""
    let host = buffer.host()
    let read = try invoke(host, "document_read", ["offset": 0, "limit": 8000])
    _ = try invoke(
      host, "document_replace",
      [
        "revision": try XCTUnwrap(read["revision"]), "old_text": "",
        "new_text": String(repeating: "a", count: 20_000) + "needle",
      ])
    let result = try invoke(host, "document_search", ["query": "needle"])
    let matches = try XCTUnwrap(result["matches"] as? [[String: Any]])
    XCTAssertEqual(matches.first?["offset"] as? Int, 20_000)
  }

  func testBackgroundCallbackReadsTheMainActorBuffer() async throws {
    let buffer = Buffer()
    let host = buffer.host()
    let result = try await Task.detached {
      try host.execute(name: "document_read", argumentsJson: "{\"offset\":0,\"limit\":8000}")
    }.value
    XCTAssertTrue(result.contains("Unsaved"))
  }

  func testControllerEditIsDirtyUndoableAndBoundToDocument() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let state = AppState()
    state.documentSession = .untitled()
    state.documentSession.text = "original"
    let controller = AppController(
      appState: state,
      folderManager: FolderManager(
        metadataStore: WorkspaceMetadataStore(
          metadataURL: root.appendingPathComponent("workspace.json"))),
      documentStore: makeTestDocumentStore())
    let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    controller.hostWindowProvider = { window }
    let undo = try XCTUnwrap(window.undoManager)
    undo.groupsByEvent = false
    let id = state.documentSession.askThreadID
    undo.beginUndoGrouping()
    XCTAssertTrue(
      controller.applyAgentDocumentEdit(id: id, expected: "original", replacement: "edited"))
    undo.endUndoGrouping()
    XCTAssertEqual(state.documentSession.text, "edited")
    XCTAssertTrue(state.documentSession.isDirty)
    XCTAssertTrue(undo.canUndo)
    undo.undo()
    XCTAssertEqual(state.documentSession.text, "original")
    undo.redo()
    XCTAssertEqual(state.documentSession.text, "edited")
    state.documentSession = .untitled()
    XCTAssertFalse(
      controller.applyAgentDocumentEdit(id: id, expected: "", replacement: "wrong document"))
    XCTAssertEqual(state.documentSession.text, "")
  }

  func testEngineIdentityUsesPensieveAndHonorsIsolatedProfile() {
    let production = PensieveEngineHost.identity(environment: [:], isTestProcess: false)
    XCTAssertTrue(production.directory.path.hasSuffix("Pensieve/Agent"))
    XCTAssertEqual(production.keychainService, "io.vetcoders.pensieve.completion-provider")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let isolated = PensieveEngineHost.identity(environment: [
      "PENSIEVE_SUPPORT_DIR": root.path, "PENSIEVE_KEYCHAIN_SERVICE": "test.agent.service",
    ])
    XCTAssertEqual(isolated.directory, root.appendingPathComponent("Agent", isDirectory: true))
    XCTAssertEqual(isolated.keychainService, "test.agent.service")
    let testHost = PensieveEngineHost.identity(environment: [:], isTestProcess: true)
    XCTAssertNotEqual(testHost.keychainService, production.keychainService)
  }
}
