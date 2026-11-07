import Darwin
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
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return .unreachable
    }
    defer { MCPStdioConnection.stop(process) }
    let deadline = ProcessInfo.processInfo.systemUptime + versionProbeTimeout
    while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
      Thread.sleep(forTimeInterval: 0.05)
    }
    if process.isRunning {
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
    let connection = try MCPStdioConnection(commandPath: commandPath, timeout: toolCallTimeout)
    defer { connection.close() }

    try connection.write(
      [
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": [
          "protocolVersion": "2025-06-18",
          "capabilities": [:] as [String: String],
          "clientInfo": ["name": "pensieve", "version": "w6-01"],
        ],
      ])
    let initialization = try connection.readResponse(id: 1)
    guard initialization["error"] == nil else {
      throw AgentPromptLauncherError.mcpNotReady(.unreachable)
    }

    try connection.write(
      [
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
      ])

    try connection.write(
      [
        "jsonrpc": "2.0",
        "id": 2,
        "method": "tools/call",
        "params": [
          "name": name,
          "arguments": arguments,
        ],
      ])
    let response = try connection.readResponse(id: 2)
    return Self.toolPayload(from: response)
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

/// One bounded stdio exchange. Nonblocking descriptors make the deadline apply
/// to silent/partial stdout AND a server that stops consuming stdin. Keep the
/// buffer across responses: one read can contain notifications and both replies.
private final class MCPStdioConnection {
  private static let messageLimit = 8 * 1024 * 1024
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let deadline: TimeInterval
  private var buffer = Data()

  init(commandPath: String, timeout: TimeInterval) throws {
    deadline = ProcessInfo.processInfo.systemUptime + timeout
    process.executableURL = URL(fileURLWithPath: commandPath)
    process.standardInput = input
    process.standardOutput = output
    // MCP permits ignoring diagnostics. An unread stderr pipe can fill and
    // deadlock a server before it can answer initialize.
    process.standardError = FileHandle.nullDevice
    try process.run()
    try? input.fileHandleForReading.close()
    try? output.fileHandleForWriting.close()
    do {
      for handle in [input.fileHandleForWriting, output.fileHandleForReading] {
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
          throw AgentPromptLauncherError.mcpNotReady(.unreachable)
        }
      }
      // A peer may close stdin between poll and write. EPIPE must become a
      // visible dispatch refusal, never a SIGPIPE crash of the editor.
      guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
        throw AgentPromptLauncherError.mcpNotReady(.unreachable)
      }
    } catch {
      close()
      throw error
    }
  }

  func close() {
    try? input.fileHandleForWriting.close()
    try? output.fileHandleForReading.close()
    Self.stop(process)
  }

  static func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = ProcessInfo.processInfo.systemUptime + 0.2
    while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
      // Only the Process created for this exchange is ours. Do not wait without
      // a bound (a server may ignore TERM or a descendant may retain the pipe).
      _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
  }

  func write(_ object: [String: Any]) throws {
    var data = try JSONSerialization.data(withJSONObject: object)
    data.append(0x0a)  // MCP stdio uses newline-delimited JSON, not LSP headers.
    guard data.count <= Self.messageLimit else {
      throw AgentPromptLauncherError.mcpNotReady(.unreachable)
    }
    let descriptor = input.fileHandleForWriting.fileDescriptor
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        try wait(descriptor, events: Int16(POLLOUT))
        let count = Darwin.write(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        if count > 0 {
          offset += count
        } else if count < 0, errno == EINTR || errno == EAGAIN {
          continue
        } else {
          throw AgentPromptLauncherError.mcpNotReady(.unreachable)
        }
      }
    }
  }

  func readResponse(id: Int) throws -> [String: Any] {
    let descriptor = output.fileHandleForReading.fileDescriptor
    while ProcessInfo.processInfo.systemUptime < deadline {
      while let message = try nextMessage() {
        guard message["jsonrpc"] as? String == "2.0" else {
          throw AgentPromptLauncherError.mcpNotReady(.unreachable)
        }
        // Notifications and unrelated replies never satisfy our request.
        if message["method"] == nil,
          let responseID = message["id"] as? NSNumber,
          CFGetTypeID(responseID) != CFBooleanGetTypeID(),
          responseID == NSNumber(value: id),
          message["result"] != nil || message["error"] != nil
        {
          return message
        }
      }
      try wait(descriptor, events: Int16(POLLIN))
      var bytes = [UInt8](repeating: 0, count: 16 * 1024)
      let count = Darwin.read(descriptor, &bytes, bytes.count)
      if count > 0 {
        buffer.append(contentsOf: bytes.prefix(count))
        guard buffer.count <= Self.messageLimit else {
          throw AgentPromptLauncherError.mcpNotReady(.unreachable)
        }
      } else if count < 0, errno == EINTR || errno == EAGAIN {
        continue
      } else {
        // EOF, including an incomplete final frame, is a failure immediately.
        throw AgentPromptLauncherError.mcpNotReady(.unreachable)
      }
    }
    throw AgentPromptLauncherError.mcpNotReady(.unreachable)
  }

  private func wait(_ descriptor: Int32, events: Int16) throws {
    while true {
      let remaining = deadline - ProcessInfo.processInfo.systemUptime
      guard remaining > 0 else {
        throw AgentPromptLauncherError.mcpNotReady(.unreachable)
      }
      var descriptorState = pollfd(fd: descriptor, events: events, revents: 0)
      let milliseconds = Int32(min(remaining * 1000 + 1, 1000))
      let result = Darwin.poll(&descriptorState, 1, milliseconds)
      if result > 0 {
        guard descriptorState.revents & Int16(POLLNVAL) == 0 else {
          throw AgentPromptLauncherError.mcpNotReady(.unreachable)
        }
        return  // HUP/ERR also reach read/write to report EOF/EPIPE.
      }
      if result < 0, errno != EINTR {
        throw AgentPromptLauncherError.mcpNotReady(.unreachable)
      }
    }
  }

  private func nextMessage() throws -> [String: Any]? {
    guard let newline = buffer.firstIndex(of: 0x0a) else { return nil }
    let firstLine = buffer[..<newline]
    let body: Data
    let consumed: Int
    if String(decoding: firstLine, as: UTF8.self).lowercased().hasPrefix("content-length:") {
      // Accept responses from older framed servers, byte-for-byte; decoding an
      // incomplete UTF-8 body first would lose a split multibyte character.
      guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
      let header = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
      let lengthText = header.split(whereSeparator: \.isNewline).first?
        .split(separator: ":", maxSplits: 1).last?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let lengthText, let length = Int(lengthText), length > 0,
        length <= Self.messageLimit
      else {
        throw AgentPromptLauncherError.mcpNotReady(.unreachable)
      }
      let bodyStart = separator.upperBound
      guard buffer.count - bodyStart >= length else { return nil }
      body = Data(buffer[bodyStart..<(bodyStart + length)])
      consumed = bodyStart + length
    } else {
      body = Data(firstLine)
      consumed = newline + 1
    }
    guard let message = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      throw AgentPromptLauncherError.mcpNotReady(.unreachable)
    }
    // subdata rebases indices before the next frame's byte arithmetic.
    buffer = buffer.subdata(in: consumed..<buffer.count)
    return message
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
