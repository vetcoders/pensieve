import Foundation
import Synchronization
import XCTest

@testable import Pensieve

final class VibecraftedMCPClientTests: XCTestCase {
  func testExplicitModelAndWorktreeRemainTypedInTheToolRequest() throws {
    let transport = FakeVibecraftedMCPTransport(probeStatus: .connected)
    let client = makeClient(
      pointing: MemoryVibecraftedMCPPointing(), transport: transport,
      isExecutable: { _ in true })
    for worktree in [true, false] {
      _ = try client.dispatch(
        workflow: "implement", agents: ["codex"], payload: .prompt("bounded plan"),
        workingDirectoryURL: URL(fileURLWithPath: "/tmp/workspace"),
        options: AgentDispatchOptions(model: " gpt-6.1-sol ", worktree: worktree))
      let arguments = try XCTUnwrap(transport.toolCalls().last?.arguments)
      XCTAssertEqual(arguments["model"], .string("gpt-6.1-sol"))
      XCTAssertEqual(arguments["worktree"], .bool(worktree))
    }
  }

  func testStdioSchemaGateRefusesOldServerAndPreservesBooleanOnUpdatedServer() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pensieve-mcp-options-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let script = directory.appendingPathComponent("server.py")
    let schema = directory.appendingPathComponent("schema.json")
    let calls = directory.appendingPathComponent("calls.json")
    try """
    #!/usr/bin/env python3
    import json, sys
    from pathlib import Path
    root = Path(__file__).parent
    for line in sys.stdin:
        request = json.loads(line)
        method = request.get("method")
        if method == "notifications/initialized":
            continue
        if method == "initialize":
            result = {"protocolVersion": "2025-06-18", "capabilities": {}, "serverInfo": {"name": "fixture", "version": "1"}}
        elif method == "tools/list":
            result = {"tools": [{"name": "vc_run_launch", "inputSchema": {"type": "object", "properties": json.loads((root / "schema.json").read_text())}}]}
        elif method == "tools/call":
            (root / "calls.json").write_text(json.dumps(request["params"]["arguments"]))
            result = {"content": [{"type": "text", "text": json.dumps({"ok": True, "run_id": "fixture-run"})}]}
        else:
            raise RuntimeError(method)
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
    """.write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    let transport = StdioVibecraftedMCPTransport()
    let arguments: [String: VibecraftedMCPValue] = [
      "skill": "implement", "model": "gpt-6.1-sol", "worktree": .bool(true),
    ]
    try "{}".write(to: schema, atomically: true, encoding: .utf8)
    let refused = try transport.callTool(
      commandPath: script.path, name: "vc_run_launch", arguments: arguments)
    XCTAssertEqual(refused["ok"] as? Bool, false)
    XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path))
    try #"{"model":{"type":"string"},"worktree":{"type":"string"}}"#
      .write(to: schema, atomically: true, encoding: .utf8)
    let wrongType = try transport.callTool(
      commandPath: script.path, name: "vc_run_launch", arguments: arguments)
    XCTAssertEqual(wrongType["ok"] as? Bool, false)
    XCTAssertFalse(FileManager.default.fileExists(atPath: calls.path))
    try #"{"model":{"type":"string"},"worktree":{"anyOf":[{"type":"boolean"},{"type":"null"}]}}"#
      .write(to: schema, atomically: true, encoding: .utf8)
    let accepted = try transport.callTool(
      commandPath: script.path, name: "vc_run_launch", arguments: arguments)
    XCTAssertEqual(accepted["ok"] as? Bool, true)
    let wire = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: calls)) as? [String: Any])
    XCTAssertEqual(wire["model"] as? String, "gpt-6.1-sol")
    XCTAssertEqual(wire["worktree"] as? Bool, true)
    XCTAssertNil(wire["worktree"] as? String)
  }

  func testStatusIsNotConfiguredWhenNothingIsPointedOrDetected() {
    let transport = FakeVibecraftedMCPTransport(probeStatus: .connected)
    let client = makeClient(
      pointing: MemoryVibecraftedMCPPointing(),
      transport: transport,
      isExecutable: { _ in false })

    XCTAssertEqual(client.status(refresh: true), .notConfigured)
    XCTAssertFalse(client.isReady)
    XCTAssertTrue(client.detect().isEmpty)
  }

  func testDetectListsOnlyExecutableCandidatesInPreferenceOrder() {
    let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    let envPath = "/opt/custom/vibecrafted-mcp"
    let localPath = "/Users/tester/.local/bin/vibecrafted-mcp"
    let client = makeClient(
      pointing: MemoryVibecraftedMCPPointing(),
      transport: FakeVibecraftedMCPTransport(probeStatus: .connected),
      isExecutable: { $0 == envPath || $0 == localPath },
      home: home,
      environment: [VibecraftedMCPLocator.commandPathEnvironmentKey: envPath])

    XCTAssertEqual(client.detect(), [envPath, localPath])
  }

  func testPointThenStatusUsesThePointedCommand() {
    let transport = FakeVibecraftedMCPTransport(probeStatus: .connected)
    let client = makeClient(
      pointing: MemoryVibecraftedMCPPointing(),
      transport: transport,
      isExecutable: { $0 == "/tmp/pointed-mcp" })

    XCTAssertEqual(client.status(refresh: true), .notConfigured)
    client.point(to: "/tmp/pointed-mcp")
    XCTAssertEqual(client.pointedCommandPath(), "/tmp/pointed-mcp")
    XCTAssertEqual(client.status(refresh: true), .connected)
    XCTAssertEqual(transport.probedPaths(), ["/tmp/pointed-mcp"])
  }

  func testPointedMissingCommandIsUnreachableNotUnconfigured() {
    let client = makeClient(
      pointing: MemoryVibecraftedMCPPointing(path: "/missing/vibecrafted-mcp"),
      transport: FakeVibecraftedMCPTransport(probeStatus: .unreachable),
      isExecutable: { _ in false })

    XCTAssertEqual(client.status(refresh: true), .unreachable)
    XCTAssertEqual(
      client.status().refusalExplanation,
      VibecraftedMCPConnectionStatus.unreachable.refusalExplanation)
  }

  func testUnreachableProbeDoesNotPretendToBeReady() {
    let client = makeClient(
      pointing: MemoryVibecraftedMCPPointing(path: "/tmp/dead-mcp"),
      transport: FakeVibecraftedMCPTransport(probeStatus: .unreachable),
      isExecutable: { $0 == "/tmp/dead-mcp" })

    XCTAssertEqual(client.status(refresh: true), .unreachable)
    XCTAssertFalse(client.isReady)
  }

  func testDispatchThrowsWhenMCPIsNotConnected() {
    let client = makeClient(
      pointing: MemoryVibecraftedMCPPointing(),
      transport: FakeVibecraftedMCPTransport(probeStatus: .notConfigured),
      isExecutable: { _ in false })

    XCTAssertThrowsError(
      try client.dispatch(
        workflow: "review",
        agents: ["grok"],
        payload: .file("/tmp/plan.md"),
        workingDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true))
    ) { error in
      guard case AgentPromptLauncherError.mcpNotReady(let status) = error else {
        return XCTFail("expected mcpNotReady, got \(error)")
      }
      XCTAssertEqual(status, .notConfigured)
    }
  }

  func testDispatchCallsVcRunLaunchOnAConnectedFakeTransport() throws {
    let transport = FakeVibecraftedMCPTransport(
      probeStatus: .connected,
      toolResult: [
        "ok": true,
        "run_id": "impl-fake-1",
        "agent": "grok",
        "report": "/tmp/reports/impl-fake-1.md",
      ])
    let client = makeClient(
      pointing: MemoryVibecraftedMCPPointing(path: "/tmp/live-mcp"),
      transport: transport,
      isExecutable: { $0 == "/tmp/live-mcp" })
    let root = URL(fileURLWithPath: "/tmp/run-root", isDirectory: true)

    let metadata = try client.dispatch(
      workflow: "review",
      agents: ["grok"],
      payload: .file("/tmp/plan.md"),
      workingDirectoryURL: root)

    XCTAssertEqual(metadata.runID, "impl-fake-1")
    XCTAssertEqual(metadata.observeAgent, "grok")
    XCTAssertEqual(metadata.reportPath, "/tmp/reports/impl-fake-1.md")
    XCTAssertEqual(metadata.launchVerification, .workerSpawnRecorded)
    XCTAssertEqual(transport.toolCalls().map(\.name), [VibecraftedMCPClient.launchToolName])
    let arguments = try XCTUnwrap(transport.toolCalls().first?.arguments)
    XCTAssertEqual(arguments["skill"], "review")
    XCTAssertEqual(arguments["agent"], "grok")
    XCTAssertEqual(arguments["file"], "/tmp/plan.md")
    XCTAssertEqual(arguments["runtime"], "headless")
    XCTAssertEqual(arguments["root"], .string(root.path))
    XCTAssertNil(arguments["prompt"])
  }

  func testDispatchOmitsAgentForADefaultSwarmAndSendsPromptPayload() throws {
    let transport = FakeVibecraftedMCPTransport(
      probeStatus: .connected,
      toolResult: [
        "ok": true,
        "run_id": "research-fake",
        "agent": "swarm",
      ])
    let client = makeClient(
      pointing: MemoryVibecraftedMCPPointing(path: "/tmp/live-mcp"),
      transport: transport,
      isExecutable: { $0 == "/tmp/live-mcp" })

    let metadata = try client.dispatch(
      workflow: "research",
      agents: [],
      payload: .prompt("dig in"),
      workingDirectoryURL: URL(fileURLWithPath: "/tmp", isDirectory: true))

    XCTAssertEqual(metadata.observeAgent, "swarm")
    let arguments = try XCTUnwrap(transport.toolCalls().first?.arguments)
    XCTAssertNil(arguments["agent"])
    XCTAssertEqual(arguments["prompt"], "dig in")
    XCTAssertNil(arguments["file"])
  }

  func testMetadataMapsARefusedMCPPayloadWithoutInventingSuccess() {
    let metadata = VibecraftedMCPClient.metadata(from: [
      "ok": false,
      "status": "refused",
      "error": "control plane storage is read-only",
    ])
    XCTAssertEqual(metadata.launchVerification, .rejected)
    XCTAssertNil(metadata.runID)
    XCTAssertEqual(metadata.exitCode, 1)
    XCTAssertTrue(metadata.output.contains("control plane storage is read-only"))
  }

  func testLocatorPrefersEnvThenPointedThenInstallLocations() {
    let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    XCTAssertEqual(
      VibecraftedMCPLocator.detectCandidates(
        home: home,
        environment: [VibecraftedMCPLocator.commandPathEnvironmentKey: "/opt/custom/mcp"],
        pointed: "/tmp/pointed-mcp"),
      [
        "/opt/custom/mcp",
        "/tmp/pointed-mcp",
        "/Users/tester/.local/bin/vibecrafted-mcp",
        "/Users/tester/.local/share/uv/tools/vibecrafted/bin/vibecrafted-mcp",
        "/opt/homebrew/bin/vibecrafted-mcp",
        "/usr/local/bin/vibecrafted-mcp",
      ])
  }

  private func makeClient(
    pointing: any VibecraftedMCPPointing,
    transport: FakeVibecraftedMCPTransport,
    isExecutable: @escaping @Sendable (String) -> Bool,
    home: URL = URL(fileURLWithPath: "/Users/tester", isDirectory: true),
    environment: [String: String] = [:]
  ) -> VibecraftedMCPClient {
    VibecraftedMCPClient(
      pointing: pointing,
      transport: transport,
      isExecutable: isExecutable,
      home: home,
      environment: environment)
  }
}

final class FakeVibecraftedMCPTransport: VibecraftedMCPTransporting, @unchecked Sendable {
  struct ToolCall: Equatable, Sendable {
    let commandPath: String
    let name: String
    let arguments: [String: VibecraftedMCPValue]
  }

  private struct State: Sendable {
    var probed: [String] = []
    var calls: [ToolCall] = []
  }

  private let probeStatus: VibecraftedMCPConnectionStatus
  private let toolResult: [String: Any]
  private let toolError: AgentPromptLauncherError?
  private let state = Mutex(State())

  init(
    probeStatus: VibecraftedMCPConnectionStatus,
    toolResult: [String: Any] = [
      "ok": true, "run_id": "fake-run", "agent": "codex",
    ],
    toolError: AgentPromptLauncherError? = nil
  ) {
    self.probeStatus = probeStatus
    self.toolResult = toolResult
    self.toolError = toolError
  }

  func probe(commandPath: String) -> VibecraftedMCPConnectionStatus {
    state.withLock { $0.probed.append(commandPath) }
    return probeStatus
  }

  func callTool(
    commandPath: String,
    name: String,
    arguments: [String: VibecraftedMCPValue]
  ) throws -> [String: Any] {
    state.withLock {
      $0.calls.append(
        ToolCall(commandPath: commandPath, name: name, arguments: arguments))
    }
    if let toolError { throw toolError }
    return toolResult
  }

  func probedPaths() -> [String] {
    state.withLock { $0.probed }
  }

  func toolCalls() -> [ToolCall] {
    state.withLock { $0.calls }
  }
}
