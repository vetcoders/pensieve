import Darwin
import Foundation
import XCTest

@testable import Pensieve

/// Real pipes and disposable local executables, never the installed MCP server.
final class StdioVibecraftedMCPTransportTests: XCTestCase {
  /// The fixtures run under `/usr/bin/python3`. Its first launch on a cold
  /// runner can outlast the 1.5 s deadlines below, so the client would kill
  /// the child before the script's first line ran, and the test would measure
  /// interpreter start-up instead of the transport. Pay that cost once here.
  override class func setUp() {
    super.setUp()
    let warmUp = Process()
    warmUp.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    warmUp.arguments = ["-c", "import json, os, signal, sys, threading, time"]
    warmUp.standardOutput = FileHandle.nullDevice
    warmUp.standardError = FileHandle.nullDevice
    try? warmUp.run()
    warmUp.waitUntilExit()
  }

  func testSilentServerHonorsDeadlineAndReapsTermResistantChild() throws {
    let fixture = try server("signal.signal(signal.SIGTERM, signal.SIG_IGN)\ntime.sleep(8)")
    defer { fixture.remove() }
    let start = ProcessInfo.processInfo.systemUptime
    XCTAssertThrowsError(
      try transport().callTool(commandPath: fixture.path, name: "fixture", arguments: [:]))
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3.5)
    try fixture.assertStopped()
  }

  func testEOFWithIncompleteResponseFailsWithoutWaitingForDeadline() throws {
    let fixture = try server("sys.stdout.write('{\"jsonrpc\":'); sys.stdout.flush()")
    defer { fixture.remove() }
    let start = ProcessInfo.processInfo.systemUptime
    XCTAssertThrowsError(
      try StdioVibecraftedMCPTransport(toolCallTimeout: 5)
        .callTool(commandPath: fixture.path, name: "fixture", arguments: [:]))
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3.5)
  }

  func testPartialFrameCannotExtendTheDeadline() throws {
    let fixture = try server(
      "sys.stdout.write('Content-Length: 1000\\r\\n\\r\\n{'); sys.stdout.flush()\ntime.sleep(8)")
    defer { fixture.remove() }
    let start = ProcessInfo.processInfo.systemUptime
    XCTAssertThrowsError(
      try transport().callTool(commandPath: fixture.path, name: "fixture", arguments: [:]))
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3.5)
    try fixture.assertStopped()
  }

  func testNewlineRequestsAndCoalescedNotificationsMatchOnlyExpectedResponseID() throws {
    let fixture = try server(
      """
      request = json.loads(sys.stdin.buffer.readline())
      assert request['method'] == 'initialize' and request['id'] == 1
      send({'jsonrpc': '2.0', 'method': 'notifications/message', 'params': {}})
      send({'jsonrpc': '2.0', 'id': 99, 'result': {}})
      send({'jsonrpc': '2.0', 'id': 1, 'result': {}})
      initialized = json.loads(sys.stdin.buffer.readline())
      assert initialized['method'] == 'notifications/initialized'
      tool = json.loads(sys.stdin.buffer.readline())
      assert tool['method'] == 'tools/call' and tool['params']['name'] == 'fixture'
      send({'jsonrpc': '2.0', 'method': 'notifications/message', 'params': {}})
      send({'jsonrpc': '2.0', 'id': 1, 'result': {'wrong': True}})
      send({'jsonrpc': '2.0', 'id': 2, 'result': {'structuredContent': {'ok': True, 'label': 'żółw 🐢'}}})
      """)
    defer { fixture.remove() }
    let result = try transport().callTool(
      commandPath: fixture.path, name: "fixture", arguments: [:])
    XCTAssertEqual(result["label"] as? String, "żółw 🐢")
    XCTAssertEqual(result["ok"] as? Bool, true)
  }

  func testLegacyFramedResponseSurvivesSplitUTF8AndBufferedNextReply() throws {
    let fixture = try server(
      """
      json.loads(sys.stdin.buffer.readline())
      frame({'jsonrpc': '2.0', 'id': 1, 'result': {}})
      json.loads(sys.stdin.buffer.readline())
      json.loads(sys.stdin.buffer.readline())
      data = json.dumps({'jsonrpc': '2.0', 'id': 2, 'result': {'structuredContent': {'label': 'żółw 🐢'}}}, ensure_ascii=False).encode()
      prefix = ('Content-Length: %d\\r\\n\\r\\n' % len(data)).encode()
      split = data.index('🐢'.encode()) + 1
      sys.stdout.buffer.write(prefix + data[:split]); sys.stdout.buffer.flush()
      time.sleep(0.04)
      sys.stdout.buffer.write(data[split:]); sys.stdout.buffer.flush()
      """)
    defer { fixture.remove() }
    let result = try transport().callTool(
      commandPath: fixture.path, name: "fixture", arguments: [:])
    XCTAssertEqual(result["label"] as? String, "żółw 🐢")
  }

  func testMalformedAndOversizedFramesFailClosed() throws {
    for output in [
      "not-json\n", "Content-Length: 9000000\r\n\r\n", "Content-Length: -1\r\n\r\n",
    ] {
      let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(output), encoding: .utf8))
      let fixture = try server("sys.stdout.write(\(encoded)); sys.stdout.flush()\ntime.sleep(8)")
      defer { fixture.remove() }
      let start = ProcessInfo.processInfo.systemUptime
      XCTAssertThrowsError(
        try StdioVibecraftedMCPTransport(toolCallTimeout: 5).callTool(
          commandPath: fixture.path, name: "fixture", arguments: [:]))
      XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3.5)
      try fixture.assertStopped()
    }
  }

  func testStderrFloodDoesNotBlockProbeOrToolReply() throws {
    let fixture = try server(
      """
      sys.stderr.write('diagnostic' * 100000); sys.stderr.flush()
      if '--version' in sys.argv:
          sys.exit(0)
      json.loads(sys.stdin.buffer.readline())
      send({'jsonrpc': '2.0', 'id': 1, 'result': {}})
      json.loads(sys.stdin.buffer.readline())
      json.loads(sys.stdin.buffer.readline())
      send({'jsonrpc': '2.0', 'id': 2, 'result': {'structuredContent': {'ok': True}}})
      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      time.sleep(8)
      """)
    defer { fixture.remove() }
    XCTAssertEqual(transport().probe(commandPath: fixture.path), .connected)
    let start = ProcessInfo.processInfo.systemUptime
    let result = try transport().callTool(
      commandPath: fixture.path, name: "fixture", arguments: [:])
    XCTAssertEqual(result["ok"] as? Bool, true)
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3.5)
    try fixture.assertStopped()
  }

  func testServerThatStopsReadingCannotHangLargePromptWrite() throws {
    let fixture = try server(
      """
      json.loads(sys.stdin.buffer.readline())
      send({'jsonrpc': '2.0', 'id': 1, 'result': {}})
      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      time.sleep(8)
      """)
    defer { fixture.remove() }
    let start = ProcessInfo.processInfo.systemUptime
    XCTAssertThrowsError(
      try transport().callTool(
        commandPath: fixture.path, name: "fixture",
        arguments: ["prompt": .string(String(repeating: "x", count: 1024 * 1024))]))
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3.5)
    try fixture.assertStopped()
  }

  func testClosedServerInputDoesNotCrashClientWithSIGPIPE() throws {
    let fixture = try server(
      """
      json.loads(sys.stdin.buffer.readline())
      os.close(0)
      send({'jsonrpc': '2.0', 'id': 1, 'result': {}})
      time.sleep(8)
      """)
    defer { fixture.remove() }
    XCTAssertThrowsError(
      try transport().callTool(commandPath: fixture.path, name: "fixture", arguments: [:]))
    try fixture.assertStopped()
  }

  func testToolsListReportsJSONRPCErrorBeforeSchemaCheck() throws {
    let fixture = try server(
      """
      json.loads(sys.stdin.buffer.readline())
      send({'jsonrpc': '2.0', 'id': 1, 'result': {}})
      json.loads(sys.stdin.buffer.readline())
      list_req = json.loads(sys.stdin.buffer.readline())
      assert list_req['method'] == 'tools/list' and list_req['id'] == 2
      send({'jsonrpc': '2.0', 'id': 2, 'error': {'code': -32601, 'message': 'tools/list unavailable'}})
      """)
    defer { fixture.remove() }
    let result = try transport().callTool(
      commandPath: fixture.path,
      name: "vc_run_launch",
      arguments: ["model": .string("gpt-6.1-sol")])
    XCTAssertEqual(result["ok"] as? Bool, false)
    XCTAssertEqual(result["status"] as? String, "refused")
    XCTAssertEqual(result["error"] as? String, "tools/list unavailable")
  }

  func testToolsListFollowsNextCursorAcrossPagesWithDistinctRequestIDs() throws {
    let fixture = try server(
      """
      json.loads(sys.stdin.buffer.readline())
      send({'jsonrpc': '2.0', 'id': 1, 'result': {}})
      json.loads(sys.stdin.buffer.readline())
      page1 = json.loads(sys.stdin.buffer.readline())
      assert page1['method'] == 'tools/list' and page1['id'] == 2 and page1['params'] == {}
      send({'jsonrpc': '2.0', 'id': 2, 'result': {'tools': [{'name': 'vc_doctor'}], 'nextCursor': 'page-2'}})
      page2 = json.loads(sys.stdin.buffer.readline())
      assert page2['method'] == 'tools/list' and page2['id'] == 3 and page2['params'] == {'cursor': 'page-2'}
      send({
          'jsonrpc': '2.0',
          'id': 3,
          'result': {
              'tools': [{
                  'name': 'vc_run_launch',
                  'inputSchema': {
                      'properties': {
                          'model': {'type': 'string'},
                          'worktree': {'type': 'boolean'}
                      }
                  }
              }]
          }
      })
      call_req = json.loads(sys.stdin.buffer.readline())
      assert call_req['method'] == 'tools/call' and call_req['id'] == 4
      send({'jsonrpc': '2.0', 'id': 4, 'result': {'structuredContent': {'ok': True, 'run_id': 'run-paged'}}})
      """)
    defer { fixture.remove() }
    let result = try transport().callTool(
      commandPath: fixture.path,
      name: "vc_run_launch",
      arguments: ["model": .string("gpt-6.1-sol"), "worktree": .bool(true)])
    XCTAssertEqual(result["ok"] as? Bool, true)
    XCTAssertEqual(result["run_id"] as? String, "run-paged")
  }

  func testVersionProbeTimeoutKillsOnlyItsOwnStalledProcess() throws {
    let fixture = try server("signal.signal(signal.SIGTERM, signal.SIG_IGN)\ntime.sleep(8)")
    defer { fixture.remove() }
    let start = ProcessInfo.processInfo.systemUptime
    XCTAssertEqual(transport().probe(commandPath: fixture.path), .unreachable)
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3.5)
    try fixture.assertStopped()
  }

  private func transport() -> StdioVibecraftedMCPTransport {
    StdioVibecraftedMCPTransport(versionProbeTimeout: 1.5, toolCallTimeout: 1.5)
  }

  private func server(_ body: String) throws -> MCPTransportFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pensieve-mcp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let path = root.appendingPathComponent("server")
    let script = """
      #!/usr/bin/python3
      import json, os, signal, sys, threading, time
      # A broken client still cannot leave this fixture running indefinitely.
      watchdog = threading.Timer(8, lambda: os._exit(70))
      watchdog.daemon = True
      watchdog.start()
      with open(__file__ + '.pid', 'w') as receipt:
          receipt.write(str(os.getpid()))
      def send(message):
          sys.stdout.buffer.write(json.dumps(message, ensure_ascii=False).encode() + b'\\n')
          sys.stdout.buffer.flush()
      def frame(message):
          data = json.dumps(message, ensure_ascii=False).encode()
          sys.stdout.buffer.write(('Content-Length: %d\\r\\n\\r\\n' % len(data)).encode() + data)
          sys.stdout.buffer.flush()
      \(body)
      """
    try script.write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    return MCPTransportFixture(root: root, path: path.path)
  }
}

private struct MCPTransportFixture {
  let root: URL
  let path: String

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  func assertStopped(file: StaticString = #filePath, line: UInt = #line) throws {
    let pid = try XCTUnwrap(Int32(String(contentsOfFile: path + ".pid", encoding: .utf8)))
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    while Darwin.kill(pid, 0) == 0, ProcessInfo.processInfo.systemUptime < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    XCTAssertEqual(Darwin.kill(pid, 0), -1, "fixture child still running", file: file, line: line)
  }
}
