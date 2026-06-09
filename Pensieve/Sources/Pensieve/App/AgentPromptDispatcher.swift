import Foundation

struct AgentDispatchMetadata: Equatable, Sendable {
  let runID: String?
  let reportPath: String?
  let exitCode: Int32
  let output: String

  var statusLine: String {
    if exitCode != 0 {
      return "Dispatch failed (exit \(exitCode))"
    }

    switch (runID, reportPath) {
    case (let runID?, let reportPath?):
      return "Dispatch completed: \(runID) | \(reportPath)"
    case (let runID?, nil):
      return "Dispatch completed: \(runID)"
    case (nil, let reportPath?):
      return "Dispatch completed: \(reportPath)"
    case (nil, nil):
      return "Dispatch completed"
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
          #"(/Users/[^\s]+/reports/[^\s]+\.md)"#,
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
}

protocol AgentPromptLaunching: Sendable {
  func dispatch(prompt: String, workingDirectoryURL: URL) throws -> AgentDispatchMetadata
}

final class VibecraftedAgentPromptLauncher: AgentPromptLaunching, @unchecked Sendable {
  static let executablePath =
    "/Users/maciejgad/.local/share/vibecrafted/tools/vibecrafted-current/scripts/vibecrafted"

  func dispatch(prompt: String, workingDirectoryURL: URL) throws -> AgentDispatchMetadata {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: Self.executablePath)
    process.arguments = ["implement", "codex", "--prompt", prompt]
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
