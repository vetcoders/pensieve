import Foundation

enum AgentLaunchVerification: Equatable, Sendable {
  /// The runtime metadata recorded a positive worker PID. This proves that the
  /// detached launcher spawned a worker; it does not prove that worker is
  /// still alive when Pensieve reads the receipt.
  case workerSpawnRecorded
  /// Vibecrafted exited successfully and returned a run ID, but the detached
  /// worker's spawn record did not appear within Pensieve's bounded wait.
  case acceptedUnconfirmed
  /// The launcher exited non-zero or returned an invalid success receipt.
  case rejected
}

struct AgentDispatchMetadata: Equatable, Sendable {
  let runID: String?
  let reportPath: String?
  /// Canonical `agent:` token from the launch receipt. This is the authority
  /// for `vibecrafted <agent> observe`; it may differ from positional input
  /// (and a default swarm has no positional input at all).
  let observeAgent: String?
  let exitCode: Int32
  let output: String
  let launchVerification: AgentLaunchVerification

  init(
    runID: String?,
    reportPath: String?,
    exitCode: Int32,
    output: String,
    observeAgent: String? = nil,
    launchVerification: AgentLaunchVerification? = nil
  ) {
    self.runID = runID
    self.reportPath = reportPath
    self.observeAgent = observeAgent
    self.exitCode = exitCode
    self.output = output
    // Fail toward uncertainty. Only `classified(workerSpawnRecorded:)` — fed by
    // an actual worker spawn record — may promote a receipt to
    // `.workerSpawnRecorded`; metadata built directly carries no such proof, so
    // a well-formed success starts accepted-but-unconfirmed. A receipt that is
    // not even a well-formed success (non-zero exit, or no run ID) stays
    // rejected: that is a fact, not uncertainty. Every production path passes
    // `launchVerification` explicitly.
    self.launchVerification =
      launchVerification
      ?? (exitCode == 0 && runID != nil
        ? .acceptedUnconfirmed : .rejected)
  }

  /// The ONE explanation of an accepted-but-unconfirmed launch. The dispatch
  /// sheet paints it under an orange receipt; the dictation tafla has no such
  /// chrome and carries the same sentence in its status line. One copy, so
  /// neither surface can quietly downgrade the uncertainty.
  static let unconfirmedLaunchExplanation =
    "Vibecrafted accepted this run, but Pensieve did not see its worker spawn record "
    + "within the confirmation window. The run may still start or already be running. "
    + "Check its status before dispatching again."

  var statusLine: String {
    if launchVerification == .rejected {
      let prefix = exitCode == 0 ? "Dispatch rejected" : "Dispatch failed (exit \(exitCode))"
      guard let detail = Self.failureDetail(in: output) else { return prefix }
      return "\(prefix): \(detail)"
    }

    let prefix =
      launchVerification == .acceptedUnconfirmed
      ? "Run accepted (launch unconfirmed)"
      : "Run started"
    switch (runID, reportPath) {
    case (let runID?, let reportPath?):
      return "\(prefix): \(runID) | \(reportPath)"
    case (let runID?, nil):
      return "\(prefix): \(runID)"
    case (nil, let reportPath?):
      return "\(prefix): \(reportPath)"
    case (nil, nil):
      return prefix
    }
  }

  static func parse(output: String, exitCode: Int32) -> AgentDispatchMetadata {
    let runID = firstMatch(
      in: output,
      patterns: [
        #"(?m)^\s*run_id:\s*([^\s]+)\s*$"#,
        #"(?m)^\s*Run ID:\s*([^\s]+)\s*$"#,
      ])
    let reportPath = firstMatch(
      in: output,
      patterns: [
        #"(?m)^\s*report:\s*(\S+)\s*$"#,
        #"(?m)^\s*Report path:\s*(\S+)\s*$"#,
        #"(?m)^\s*report_path:\s*(\S+)\s*$"#,
        // Last-resort fallback: an absolute local path; the lookbehind keeps it from
        // matching inside URLs ("https://host/reports/x.md") or protocol-relative refs.
        #"(?<![/:])(/[^/\s][^\s]*/reports/[^\s]+\.md)"#,
      ])
    let observeAgent = firstMatch(
      in: output,
      patterns: [
        // The value is later composed into a Terminal command. Parse only the
        // CLI's shell-safe agent-token alphabet; malformed receipt values fail
        // closed and simply omit the optional status action.
        #"(?m)^\s*agent:\s*([A-Za-z0-9._-]+)\s*$"#
      ])
    return AgentDispatchMetadata(
      runID: runID,
      reportPath: reportPath,
      exitCode: exitCode,
      output: output,
      observeAgent: observeAgent,
      launchVerification: exitCode == 0 && runID != nil ? .acceptedUnconfirmed : .rejected
    )
  }

  func classified(workerSpawnRecorded: Bool) -> AgentDispatchMetadata {
    guard exitCode == 0 else {
      return replacingVerification(with: .rejected)
    }
    guard let runID else {
      return replacingVerification(
        with: .rejected,
        appending: "Vibecrafted exited successfully without a run ID.")
    }
    guard workerSpawnRecorded else {
      return replacingVerification(
        with: .acceptedUnconfirmed,
        appending:
          "Vibecrafted accepted run \(runID), but its worker spawn record did not appear "
          + "within the confirmation window. The detached run may still start "
          + "or already be running.")
    }
    return replacingVerification(with: .workerSpawnRecorded)
  }

  private func replacingVerification(
    with launchVerification: AgentLaunchVerification,
    appending detail: String? = nil
  ) -> AgentDispatchMetadata {
    let combinedOutput: String
    if let detail {
      combinedOutput = output.isEmpty ? detail : output + "\n" + detail
    } else {
      combinedOutput = output
    }
    return AgentDispatchMetadata(
      runID: runID,
      reportPath: reportPath,
      exitCode: exitCode,
      output: combinedOutput,
      observeAgent: observeAgent,
      launchVerification: launchVerification)
  }

  private static func firstMatch(in text: String, patterns: [String]) -> String? {
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
        let matchRange = Range(match.range(at: 1), in: text)
      else {
        continue
      }
      return String(text[matchRange])
    }
    return nil
  }

  /// Preserve the actionable end of launcher stderr without flooding the
  /// dispatch sheet with a traceback or terminal colour escapes.
  private static func failureDetail(in text: String) -> String? {
    let escapePattern = "\u{001B}\\[[0-?]*[ -/]*[@-~]"
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    let plain =
      (try? NSRegularExpression(pattern: escapePattern))?
      .stringByReplacingMatches(in: text, range: range, withTemplate: "") ?? text
    guard
      let lastLine = plain.split(whereSeparator: \.isNewline).reversed()
        .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        .first(where: { !$0.isEmpty })
    else {
      return nil
    }
    let compact = lastLine.replacingOccurrences(
      of: #"\s+"#, with: " ", options: .regularExpression)
    let limit = 280
    guard compact.count > limit else { return compact }
    return String(compact.prefix(limit - 1)) + "…"
  }
}

protocol AgentPromptLaunching: Sendable {
  /// `agents` are the POSITIONAL agent tokens, in CLI order. One token is a
  /// single-agent (or synthesizer-override) run; an empty list launches the
  /// workflow's own default — for a swarm workflow that is the honest
  /// "no positional agent" invocation, never a fabricated single agent.
  func dispatch(
    workflow: String,
    agents: [String],
    payload: AgentDispatchPayload,
    workingDirectoryURL: URL
  ) throws -> AgentDispatchMetadata
}

enum AgentDispatchPayload: Equatable, Sendable {
  case prompt(String)
  case file(String)

  var isEmpty: Bool {
    switch self {
    case .prompt(let value), .file(let value):
      return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }
}

enum AgentPromptLauncherError: LocalizedError {
  case executableNotFound(searchedPaths: [String])
  case mcpNotReady(VibecraftedMCPConnectionStatus)

  var errorDescription: String? {
    switch self {
    case .executableNotFound(let searchedPaths):
      let searched = searchedPaths.joined(separator: ", ")
      return
        "vibecrafted executable not found (searched: \(searched)). "
        + "Set the PENSIEVE_VIBECRAFTED_PATH environment variable to the full path "
        + "of the vibecrafted script, or install vibecrafted at "
        + "~/.local/bin/vibecrafted."
    case .mcpNotReady(let status):
      return status.refusalExplanation
    }
  }
}

final class VibecraftedAgentPromptLauncher: AgentPromptLaunching, Sendable {
  static let executablePathEnvironmentKey = "PENSIEVE_VIBECRAFTED_PATH"
  static let vibecraftedHomeEnvironmentKey = "VIBECRAFTED_HOME"
  static let workerSpawnRecordTimeout: TimeInterval = 3
  /// User-level CLI. The uv tool entry under `~/.local/share/uv/tools` is a
  /// different binary and is not a candidate.
  static let userBinExecutableRelativePath = ".local/bin/vibecrafted"
  static let defaultExecutableRelativePath =
    ".local/share/vibecrafted/tools/vibecrafted-current/scripts/vibecrafted"

  private let mcpClient: VibecraftedMCPClient

  init(mcpClient: VibecraftedMCPClient = .shared) {
    self.mcpClient = mcpClient
  }

  static func resolveExecutablePath() throws -> String {
    try resolveExecutablePath(
      home: FileManager.default.homeDirectoryForCurrentUser,
      override: ProcessInfo.processInfo.environment[executablePathEnvironmentKey],
      isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
  }

  static func resolveExecutablePath(
    home: URL,
    override: String?,
    isExecutable: (String) -> Bool
  ) throws -> String {
    let candidates = executableCandidates(home: home, override: override)
    for candidate in candidates where isExecutable(candidate) {
      return candidate
    }
    throw AgentPromptLauncherError.executableNotFound(searchedPaths: candidates)
  }

  static func executableCandidates(home: URL, override: String?) -> [String] {
    var candidates: [String] = []
    if let override, !override.isEmpty {
      candidates.append(override)
    }
    // LaunchServices gives GUI apps a system-only PATH, so the CLI is an
    // absolute path under the user's home. Prefer ~/.local/bin/vibecrafted.
    // The uv tool entry is a different, often broken, entrypoint and is not
    // searched.
    candidates.append(home.appendingPathComponent(userBinExecutableRelativePath).path)
    candidates.append(home.appendingPathComponent(defaultExecutableRelativePath).path)
    return candidates
  }

  /// Finder/Dock launches inherit a system-only PATH. Vibecrafted's first
  /// process has an absolute uv shebang, but its detached dispatcher launches
  /// the selected agent by name (`codex`, `claude`, and so on). Supply the
  /// standard tool locations without invoking a login shell or sourcing user
  /// startup files.
  static func launchEnvironment(base: [String: String], home: URL) -> [String: String] {
    var environment = base
    let preferred = [
      home.appendingPathComponent(".local/bin", isDirectory: true).path,
      "/opt/homebrew/bin",
      "/opt/homebrew/sbin",
      "/usr/local/bin",
      home.appendingPathComponent(".cargo/bin", isDirectory: true).path,
      home.appendingPathComponent(".grok/bin", isDirectory: true).path,
      home.appendingPathComponent(".vibecrafted/bin", isDirectory: true).path,
    ]
    let inherited = (base["PATH"] ?? "").split(separator: ":").map(String.init)
    var seen = Set<String>()
    environment["PATH"] = (preferred + inherited)
      .filter { !$0.isEmpty && seen.insert($0).inserted }
      .joined(separator: ":")
    return environment
  }

  static func runtimeMetadataURL(
    runID: String,
    output: String,
    home: URL,
    environment: [String: String] = [:]
  ) -> URL {
    if let transcriptPath = receiptValue(label: "transcript", in: output),
      transcriptPath.hasPrefix("/")
    {
      return URL(fileURLWithPath: transcriptPath).deletingLastPathComponent()
        .appendingPathComponent("meta.json")
    }
    let configuredHome = environment[vibecraftedHomeEnvironmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let runtimeHome: URL
    if let configuredHome, !configuredHome.isEmpty {
      runtimeHome = URL(
        fileURLWithPath: (configuredHome as NSString).expandingTildeInPath,
        isDirectory: true)
    } else {
      runtimeHome = home.appendingPathComponent(".vibecrafted", isDirectory: true)
    }
    return runtimeHome.appendingPathComponent("control_plane/runtime_runs", isDirectory: true)
      .appendingPathComponent(runID, isDirectory: true)
      .appendingPathComponent("meta.json")
  }

  static func workerSpawnRecorded(at metadataURL: URL) -> Bool {
    guard
      let data = try? Data(contentsOf: metadataURL),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let workerPID = object["worker_pid"] as? NSNumber
    else {
      return false
    }
    return workerPID.intValue > 0
  }

  private static func receiptValue(label: String, in output: String) -> String? {
    let escapedLabel = NSRegularExpression.escapedPattern(for: label)
    guard
      let regex = try? NSRegularExpression(
        pattern: "(?m)^\\s*\(escapedLabel):\\s*(\\S+)\\s*$"),
      let match = regex.firstMatch(
        in: output, range: NSRange(output.startIndex..<output.endIndex, in: output)),
      match.numberOfRanges > 1,
      let valueRange = Range(match.range(at: 1), in: output)
    else {
      return nil
    }
    return String(output[valueRange])
  }

  static func arguments(
    workflow: String,
    agents: [String],
    payload: AgentDispatchPayload
  ) -> [String] {
    switch payload {
    case .prompt(let prompt):
      return [workflow] + agents + ["--prompt", prompt]
    case .file(let path):
      return [workflow] + agents + ["--file", path]
    }
  }

  func dispatch(
    workflow: String,
    agents: [String],
    payload: AgentDispatchPayload,
    workingDirectoryURL: URL
  ) throws -> AgentDispatchMetadata {
    try mcpClient.dispatch(
      workflow: workflow,
      agents: agents,
      payload: payload,
      workingDirectoryURL: workingDirectoryURL)
  }
}
