import Foundation
import Synchronization

/// Connection truth for the single vibecrafted-mcp server Pensieve talks to.
/// Wizard v1 is detect / point / status — not a multi-server supermarket.
enum VibecraftedMCPConnectionStatus: String, Equatable, Sendable {
  case connected
  case unreachable
  case notConfigured

  var isReady: Bool { self == .connected }

  var shortLabel: String {
    switch self {
    case .connected: return "Connected"
    case .unreachable: return "Unreachable"
    case .notConfigured: return "Not configured"
    }
  }

  /// Why Dispatch stays disabled. One sentence, so the sheet and the wizard
  /// cannot drift from each other.
  var refusalExplanation: String {
    switch self {
    case .connected:
      return "vibecrafted-mcp is connected."
    case .unreachable:
      return
        "vibecrafted-mcp is unreachable. Point Settings ▸ MCP at a working command, then Detect."
    case .notConfigured:
      return
        "vibecrafted-mcp is not configured. Open Settings ▸ MCP to detect or point at the server."
    }
  }
}

/// Where the operator told Pensieve to find vibecrafted-mcp (a command path).
protocol VibecraftedMCPPointing: Sendable {
  func pointedCommandPath() -> String?
  func point(to path: String?)
}

/// In-memory pointer for tests. Never touches the operator's defaults.
final class MemoryVibecraftedMCPPointing: VibecraftedMCPPointing, Sendable {
  private let path: Mutex<String?>

  init(path: String? = nil) {
    self.path = Mutex(Self.normalized(path))
  }

  func pointedCommandPath() -> String? {
    path.withLock { $0 }
  }

  func point(to path: String?) {
    self.path.withLock { $0 = Self.normalized(path) }
  }

  private static func normalized(_ path: String?) -> String? {
    let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// Persists the pointed command so Detect / Point survives relaunch.
struct UserDefaultsVibecraftedMCPPointing: VibecraftedMCPPointing, @unchecked Sendable {
  static let commandPathKey = "Pensieve.vibecraftedMCPCommandPath"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func pointedCommandPath() -> String? {
    let trimmed =
      defaults.string(forKey: Self.commandPathKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  func point(to path: String?) {
    let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty {
      defaults.removeObject(forKey: Self.commandPathKey)
    } else {
      defaults.set(trimmed, forKey: Self.commandPathKey)
    }
  }
}

/// Candidate command paths for Detect. Order is preference: env override,
/// the pointed path, then the usual install locations.
enum VibecraftedMCPLocator {
  static let commandPathEnvironmentKey = "PENSIEVE_VIBECRAFTED_MCP_PATH"

  static func detectCandidates(
    home: URL,
    environment: [String: String],
    pointed: String?
  ) -> [String] {
    var candidates: [String] = []
    var seen = Set<String>()
    func append(_ path: String) {
      let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
      candidates.append(trimmed)
    }
    if let override = environment[commandPathEnvironmentKey] {
      append(override)
    }
    if let pointed {
      append(pointed)
    }
    append(home.appendingPathComponent(".local/bin/vibecrafted-mcp").path)
    append(
      home.appendingPathComponent(
        ".local/share/uv/tools/vibecrafted/bin/vibecrafted-mcp"
      ).path)
    append("/opt/homebrew/bin/vibecrafted-mcp")
    append("/usr/local/bin/vibecrafted-mcp")
    return candidates
  }
}

/// The wire the typed client speaks. Tests inject a fake; production speaks
/// stdio JSON-RPC to `vibecrafted-mcp`.
protocol VibecraftedMCPTransporting: Sendable {
  func probe(commandPath: String) -> VibecraftedMCPConnectionStatus
  func callTool(
    commandPath: String,
    name: String,
    arguments: [String: String]
  ) throws -> [String: Any]
}

/// Probe + `vc_run_launch` over MCP stdio. Process lives here — the fleet
/// brain is the tool call, not `vibecrafted <workflow>` CLI arguments.
struct StdioVibecraftedMCPTransport: VibecraftedMCPTransporting {
  var versionProbeTimeout: TimeInterval = 2
  var toolCallTimeout: TimeInterval = 15

  func probe(commandPath: String) -> VibecraftedMCPConnectionStatus {
    guard FileManager.default.isExecutableFile(atPath: commandPath) else {
      return .unreachable
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: commandPath)
    process.arguments = ["--version"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      return .unreachable
    }
    let deadline = Date().addingTimeInterval(versionProbeTimeout)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
      process.terminate()
      return .unreachable
    }
    return process.terminationStatus == 0 ? .connected : .unreachable
  }

  func callTool(
    commandPath: String,
    name: String,
    arguments: [String: String]
  ) throws -> [String: Any] {
    guard FileManager.default.isExecutableFile(atPath: commandPath) else {
      throw AgentPromptLauncherError.mcpNotReady(.unreachable)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: commandPath)
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = Pipe()
    try process.run()
    defer {
      if process.isRunning { process.terminate() }
    }

    try writeMCPMessage(
      [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
          "protocolVersion": "2025-06-18",
          "capabilities": [:] as [String: String],
          "clientInfo": ["name": "pensieve", "version": "w6-01"],
        ],
      ],
      to: stdin.fileHandleForWriting)
    _ = try readMCPMessage(
      from: stdout.fileHandleForReading, timeout: toolCallTimeout)

    try writeMCPMessage(
      [
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
      ],
      to: stdin.fileHandleForWriting)

    try writeMCPMessage(
      [
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": [
          "name": name,
          "arguments": arguments,
        ],
      ],
      to: stdin.fileHandleForWriting)
    let response = try readMCPMessage(
      from: stdout.fileHandleForReading, timeout: toolCallTimeout)
    try? stdin.fileHandleForWriting.close()
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
    }
    return Self.toolPayload(from: response)
  }

  private func writeMCPMessage(
    _ object: [String: Any],
    to handle: FileHandle
  ) throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    let header = "Content-Length: \(data.count)\r\n\r\n"
    var payload = Data(header.utf8)
    payload.append(data)
    try handle.write(contentsOf: payload)
  }

  private func readMCPMessage(
    from handle: FileHandle,
    timeout: TimeInterval
  ) throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(timeout)
    var buffer = Data()
    while Date() < deadline {
      let next = handle.availableData
      if !next.isEmpty {
        buffer.append(next)
      }
      if let message = Self.parseFramedJSON(from: &buffer) {
        return message
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw AgentPromptLauncherError.mcpNotReady(.unreachable)
  }

  private static func parseFramedJSON(from buffer: inout Data) -> [String: Any]? {
    guard let text = String(data: buffer, encoding: .utf8) else { return nil }
    let headerSeparator = "\r\n\r\n"
    guard let separator = text.range(of: headerSeparator) else { return nil }
    let header = String(text[text.startIndex..<separator.lowerBound])
    var length: Int?
    for line in header.split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: ":", maxSplits: 1)
      if parts.count == 2,
        parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased() == "content-length",
        let value = Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
      {
        length = value
      }
    }
    guard let length else { return nil }
    let bodyStart = separator.upperBound
    let bodyUTF8 = Data(text[bodyStart...].utf8)
    guard bodyUTF8.count >= length else { return nil }
    let body = bodyUTF8.prefix(length)
    guard
      let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else {
      return nil
    }
    let consumed = Data(text[text.startIndex..<separator.upperBound].utf8).count + length
    if consumed <= buffer.count {
      buffer.removeSubrange(0..<consumed)
    } else {
      buffer.removeAll()
    }
    return object
  }

  private static func toolPayload(from response: [String: Any]) -> [String: Any] {
    if let error = response["error"] as? [String: Any] {
      let message = error["message"] as? String ?? "MCP tool call failed"
      return ["ok": false, "error": message, "status": "refused"]
    }
    let result = response["result"] as? [String: Any] ?? response
    if let structured = result["structuredContent"] as? [String: Any] {
      return structured
    }
    if let content = result["content"] as? [[String: Any]] {
      for item in content {
        if let text = item["text"] as? String,
          let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
          return object
        }
      }
    }
    return result
  }
}

/// Typed vibecrafted-mcp client: detect, point, status, and dispatch via
/// `vc_run_launch`. Ready = `.connected`. There is no silent CLI fallback.
final class VibecraftedMCPClient: Sendable {
  static let shared = VibecraftedMCPClient()
  static let launchToolName = "vc_run_launch"

  private struct State: Sendable {
    var lastStatus: VibecraftedMCPConnectionStatus?
  }

  private let pointing: any VibecraftedMCPPointing
  private let transport: any VibecraftedMCPTransporting
  private let isExecutable: @Sendable (String) -> Bool
  private let home: URL
  private let environment: [String: String]
  private let state = Mutex(State())

  init(
    pointing: any VibecraftedMCPPointing = UserDefaultsVibecraftedMCPPointing(),
    transport: any VibecraftedMCPTransporting = StdioVibecraftedMCPTransport(),
    isExecutable: @escaping @Sendable (String) -> Bool = {
      FileManager.default.isExecutableFile(atPath: $0)
    },
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.pointing = pointing
    self.transport = transport
    self.isExecutable = isExecutable
    self.home = home
    self.environment = environment
  }

  func pointedCommandPath() -> String? {
    pointing.pointedCommandPath()
  }

  /// Remember a command path. Empty string clears the pointer.
  func point(to path: String) {
    pointing.point(to: path)
    state.withLock { $0.lastStatus = nil }
  }

  /// Existing candidate executables, in preference order.
  func detect() -> [String] {
    VibecraftedMCPLocator.detectCandidates(
      home: home,
      environment: environment,
      pointed: pointing.pointedCommandPath()
    ).filter(isExecutable)
  }

  func status(refresh: Bool = false) -> VibecraftedMCPConnectionStatus {
    if !refresh, let cached = state.withLock({ $0.lastStatus }) {
      return cached
    }
    let resolved = refreshStatus()
    return resolved
  }

  @discardableResult
  func refreshStatus() -> VibecraftedMCPConnectionStatus {
    let resolved = resolveStatus()
    state.withLock { $0.lastStatus = resolved }
    return resolved
  }

  var isReady: Bool { status().isReady }

  /// Production confirm path. Throws when MCP is not connected — fail visible,
  /// never fall back to `vibecrafted` CLI Process.
  func dispatch(
    workflow: String,
    agents: [String],
    payload: AgentDispatchPayload,
    workingDirectoryURL: URL
  ) throws -> AgentDispatchMetadata {
    let current = refreshStatus()
    guard current == .connected, let commandPath = resolvedCommandPath() else {
      throw AgentPromptLauncherError.mcpNotReady(current)
    }
    var arguments: [String: String] = [
      "skill": workflow,
      "runtime": "headless",
      "root": workingDirectoryURL.path,
      "source_dir": workingDirectoryURL.path,
    ]
    if let agent = agents.first, !agent.isEmpty {
      arguments["agent"] = agent
    }
    switch payload {
    case .prompt(let prompt):
      arguments["prompt"] = prompt
    case .file(let path):
      arguments["file"] = path
    }
    let payloadJSON = try transport.callTool(
      commandPath: commandPath,
      name: Self.launchToolName,
      arguments: arguments)
    return Self.metadata(from: payloadJSON)
  }

  static func metadata(from payload: [String: Any]) -> AgentDispatchMetadata {
    let ok = boolValue(payload["ok"], default: true)
    let runID = stringValue(payload, keys: ["run_id", "runID"])
    let reportPath = stringValue(payload, keys: ["report", "report_path", "reportPath"])
    let observeAgent = stringValue(payload, keys: ["agent", "observe_agent", "observeAgent"])
    let error = stringValue(payload, keys: ["error", "message"])
    let outputLines = [
      runID.map { "run_id: \($0)" },
      observeAgent.map { "agent: \($0)" },
      reportPath.map { "report: \($0)" },
      error.map { $0 },
    ].compactMap { $0 }
    let output = outputLines.isEmpty ? "mcp: vc_run_launch" : outputLines.joined(separator: "\n")
    if !ok || runID == nil {
      return AgentDispatchMetadata(
        runID: runID,
        reportPath: reportPath,
        exitCode: 1,
        output: output,
        observeAgent: observeAgent,
        launchVerification: .rejected)
    }
    // The MCP server accepted the launch. That is the fleet brain's receipt;
    // Pensieve no longer waits on a CLI Process spawn record.
    return AgentDispatchMetadata(
      runID: runID,
      reportPath: reportPath,
      exitCode: 0,
      output: output,
      observeAgent: observeAgent,
      launchVerification: .workerSpawnRecorded)
  }

  private func resolveStatus() -> VibecraftedMCPConnectionStatus {
    guard let commandPath = resolvedCommandPath() else {
      return .notConfigured
    }
    return transport.probe(commandPath: commandPath)
  }

  private func resolvedCommandPath() -> String? {
    if let pointed = pointing.pointedCommandPath(), isExecutable(pointed) {
      return pointed
    }
    if let pointed = pointing.pointedCommandPath(), !pointed.isEmpty {
      // Pointed but missing — still the operator's choice; probe reports
      // unreachable rather than pretending nothing was configured.
      return pointed
    }
    return detect().first
  }

  private static func stringValue(_ payload: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = payload[key] as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
    }
    return nil
  }

  private static func boolValue(_ value: Any?, default defaultValue: Bool) -> Bool {
    if let flag = value as? Bool { return flag }
    if let number = value as? NSNumber { return number.boolValue }
    if let text = value as? String {
      switch text.lowercased() {
      case "true", "1", "yes": return true
      case "false", "0", "no": return false
      default: break
      }
    }
    return defaultValue
  }
}
