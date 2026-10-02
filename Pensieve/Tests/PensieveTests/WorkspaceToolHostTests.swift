import CodescribeBridge
import Synchronization
import XCTest

@testable import Pensieve

@MainActor
final class WorkspaceToolHostTests: XCTestCase {
  private struct CallState: Sendable {
    var searches = 0
    var reads = 0
    var lastQuery = ""
    var lastLimit = 0
  }

  private final class Calls: Sendable {
    private let state = Mutex(CallState())

    func recordSearch(query: String, limit: Int) {
      state.withLock {
        $0.searches += 1
        $0.lastQuery = query
        $0.lastLimit = limit
      }
    }

    func recordRead() { state.withLock { $0.reads += 1 } }

    var searches: Int { state.withLock { $0.searches } }
    var reads: Int { state.withLock { $0.reads } }
    var lastQuery: String { state.withLock { $0.lastQuery } }
    var lastLimit: Int { state.withLock { $0.lastLimit } }
  }

  private func host(
    calls: Calls,
    allowed: Set<String> = ["notes/a.md"],
    fileText: @escaping @Sendable (String) -> String = { _ in "body" }
  ) -> WorkspaceToolHost {
    WorkspaceToolHost(
      search: { query, limit in
        calls.recordSearch(query: query, limit: limit)
        return #"{"query":"\#(query)","count":1}"#
      },
      containsPath: { allowed.contains($0) },
      readFile: { path in
        calls.recordRead()
        return fileText(path)
      })
  }

  private func invoke(_ host: WorkspaceToolHost, _ name: String, _ args: [String: Any]) throws
    -> [String: Any]
  {
    let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
    let output = try host.execute(name: name, argumentsJson: json)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
  }

  private func agentMessage(_ error: any Error) -> String? {
    guard case .Agent(let message) = error as? CsError else { return nil }
    return message
  }

  func testSearchCallsTheInjectedClosureAndReturnsItsJSON() throws {
    let calls = Calls()
    let toolHost = host(calls: calls)
    let output = try toolHost.execute(
      name: "workspace_search", argumentsJson: #"{"query":"alpha beta","limit":7}"#)
    XCTAssertEqual(output, #"{"query":"alpha beta","count":1}"#)
    XCTAssertEqual(calls.searches, 1)
    XCTAssertEqual(calls.lastQuery, "alpha beta")
    XCTAssertEqual(calls.lastLimit, 7)
    XCTAssertEqual(calls.reads, 0)
  }

  func testOmittedSearchLimitIsFiveAndOutOfRangeDoesNotSearch() throws {
    let calls = Calls()
    let toolHost = host(calls: calls)
    _ = try toolHost.execute(name: "workspace_search", argumentsJson: #"{"query":"alpha"}"#)
    XCTAssertEqual(calls.lastLimit, 5)
    XCTAssertThrowsError(
      try toolHost.execute(
        name: "workspace_search", argumentsJson: #"{"query":"alpha","limit":21}"#)
    ) { error in
      XCTAssertEqual(agentMessage(error), "Limit must be from 1 to 20.")
    }
    XCTAssertEqual(calls.searches, 1)
  }

  func testEmptyQueryIsRejectedBeforeSearch() throws {
    let calls = Calls()
    let toolHost = host(calls: calls)
    for arguments in [#"{"query":""}"#, #"{"query":"  "}"#] {
      XCTAssertThrowsError(try toolHost.execute(name: "workspace_search", argumentsJson: arguments))
      { error in
        XCTAssertEqual(agentMessage(error), "Missing required non-empty string field 'query'")
      }
    }
    XCTAssertEqual(calls.searches, 0)
  }

  func testReadOutsideWorkspaceDoesNotReadTheFile() throws {
    let calls = Calls()
    let toolHost = host(calls: calls)
    XCTAssertThrowsError(
      try toolHost.execute(name: "workspace_read", argumentsJson: #"{"path":"../secret.md"}"#)
    ) { error in
      XCTAssertEqual(agentMessage(error), "Path is outside this workspace.")
    }
    XCTAssertEqual(calls.reads, 0)
    XCTAssertEqual(calls.searches, 0)
  }

  func testAllowedReadReturnsAtMostEightThousandCharacters() throws {
    let calls = Calls()
    let toolHost = host(calls: calls, fileText: { _ in String(repeating: "a", count: 9_000) })
    let result = try invoke(toolHost, "workspace_read", ["path": "notes/a.md"])
    let text = try XCTUnwrap(result["text"] as? String)
    XCTAssertEqual(text.count, 8_000)
    XCTAssertEqual(result["total_characters"] as? Int, 9_000)
    XCTAssertEqual(result["next_offset"] as? Int, 8_000)
    XCTAssertEqual(calls.reads, 1)
    let window = try invoke(
      toolHost, "workspace_read", ["path": "notes/a.md", "offset": 8_900, "limit": 8_000])
    XCTAssertEqual((window["text"] as? String)?.count, 100)
  }

  func testDocumentReplaceIsUnknownOnTheWorkspaceHost() throws {
    let calls = Calls()
    let toolHost = host(calls: calls)
    XCTAssertThrowsError(
      try toolHost.execute(
        name: "document_replace",
        argumentsJson: #"{"revision":"x","old_text":"a","new_text":"b"}"#)
    ) { error in
      XCTAssertEqual(agentMessage(error), "Unknown workspace tool.")
    }
    XCTAssertEqual(calls.searches, 0)
    XCTAssertEqual(calls.reads, 0)
  }

  func testDocumentHostRejectsWorkspaceSearch() throws {
    let document = AskDocumentFixture.host(text: "open buffer")
    XCTAssertThrowsError(
      try document.execute(name: "workspace_search", argumentsJson: #"{"query":"open"}"#)
    ) { error in
      XCTAssertEqual(error as? CsError, .Agent(msg: "Unknown document tool."))
    }
  }
}
