import Foundation

struct AgentDispatchMetadata: Equatable, Sendable {
  let runID: String?
  let reportPath: String?
  let exitCode: Int32
  let output: String

  var statusLine: String {
    if exitCode != 0 {
      let prefix = "Dispatch failed (exit \(exitCode))"
      guard let detail = Self.failureDetail(in: output) else { return prefix }
      return "\(prefix): \(detail)"
    }

    switch (runID, reportPath) {
    case (let runID?, let reportPath?):
      return "Run started: \(runID) | \(reportPath)"
    case (let runID?, nil):
      return "Run started: \(runID)"
    case (nil, let reportPath?):
      return "Run started: \(reportPath)"
    case (nil, nil):
      return "Run started"
    }
  }

  static func parse(output: String, exitCode: Int32) -> AgentDispatchMetadata {
    AgentDispatchMetadata(
      runID: firstMatch(
        in: output,
        patterns: [
          #"(?m)^\s*run_id:\s*([^\s]+)\s*$"#,
          #"(?m)^\s*Run ID:\s*([^\s]+)\s*$"#,
        ]),
      reportPath: firstMatch(
        in: output,
        patterns: [
          #"(?m)^\s*Report path:\s*(\S+)\s*$"#,
          #"(?m)^\s*report_path:\s*(\S+)\s*$"#,
          // Last-resort fallback: an absolute local path; the lookbehind keeps it from
          // matching inside URLs ("https://host/reports/x.md") or protocol-relative refs.
          #"(?<![/:])(/[^/\s][^\s]*/reports/[^\s]+\.md)"#,
        ]),
      exitCode: exitCode,
      output: output
    )
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

  var errorDescription: String? {
    switch self {
    case .executableNotFound(let searchedPaths):
      let searched = searchedPaths.joined(separator: ", ")
      return
        "vibecrafted executable not found (searched: \(searched)). "
        + "Set the PENSIEVE_VIBECRAFTED_PATH environment variable to the full path "
        + "of the vibecrafted script, or install vibecrafted under "
        + "~/.local/share/vibecrafted/tools/vibecrafted-current/scripts/vibecrafted."
    }
  }
}

final class VibecraftedAgentPromptLauncher: AgentPromptLaunching, @unchecked Sendable {
  static let executablePathEnvironmentKey = "PENSIEVE_VIBECRAFTED_PATH"
  static let uvToolExecutableRelativePath =
    ".local/share/uv/tools/vibecrafted/bin/vibecrafted"
  static let defaultExecutableRelativePath =
    ".local/share/vibecrafted/tools/vibecrafted-current/scripts/vibecrafted"

  static func resolveExecutablePath() throws -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let candidates = executableCandidates(
      home: home,
      override: ProcessInfo.processInfo.environment[executablePathEnvironmentKey])

    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
      return candidate
    }
    throw AgentPromptLauncherError.executableNotFound(searchedPaths: candidates)
  }

  static func executableCandidates(home: URL, override: String?) -> [String] {
    var candidates: [String] = []
    if let override, !override.isEmpty {
      candidates.append(override)
    }
    // LaunchServices gives GUI apps a system-only PATH. Prefer uv's absolute
    // entrypoint, whose shebang names the tool's own Python, so a normal Finder/
    // Dock launch cannot fall through to Xcode's older /usr/bin/python3. The
    // ~/.local/bin link may target the interactive command deck and is therefore
    // only a compatibility fallback.
    candidates.append(home.appendingPathComponent(uvToolExecutableRelativePath).path)
    candidates.append(home.appendingPathComponent(".local/bin/vibecrafted").path)
    candidates.append(home.appendingPathComponent(defaultExecutableRelativePath).path)
    return candidates
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
    let executablePath = try Self.resolveExecutablePath()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = Self.arguments(workflow: workflow, agents: agents, payload: payload)
    process.currentDirectoryURL = workingDirectoryURL

    let stdout = Pipe()
    let stderr = Pipe()
    let buffer = ProcessOutputBuffer()
    process.standardOutput = stdout
    process.standardError = stderr

    stdout.fileHandleForReading.readabilityHandler = { handle in
      buffer.append(handle.availableData)
    }
    stderr.fileHandleForReading.readabilityHandler = { handle in
      buffer.append(handle.availableData)
    }

    try process.run()
    process.waitUntilExit()

    stdout.fileHandleForReading.readabilityHandler = nil
    stderr.fileHandleForReading.readabilityHandler = nil
    buffer.append(stdout.fileHandleForReading.availableData)
    buffer.append(stderr.fileHandleForReading.availableData)

    return AgentDispatchMetadata.parse(output: buffer.text(), exitCode: process.terminationStatus)
  }
}

private final class ProcessOutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  func append(_ next: Data) {
    guard !next.isEmpty else { return }
    lock.lock()
    data.append(next)
    lock.unlock()
  }

  func text() -> String {
    lock.lock()
    let snapshot = data
    lock.unlock()
    return String(data: snapshot, encoding: .utf8) ?? ""
  }
}
