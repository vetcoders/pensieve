import Foundation

/// CLI surface for Composer v2 Tor B (`pensieve --wait <file>`).
///
/// Pure value type — no AppKit — so unit tests can pin the contract without
/// spinning up `NSApplication`. The App entrypoint applies the result to
/// `LaunchIntentCoordinator` before launch intents settle.
struct ComposerLaunchArguments: Equatable, Sendable {
  /// When true, Pensieve quits after the last content window closes so a
  /// blocking caller (`open -W`, `$VC_COMPOSER`) can resume.
  var wait: Bool
  /// File paths supplied on the command line (not via Finder `open` URLs).
  var fileURLs: [URL]
  /// Print usage and exit before the UI comes up.
  var showHelp: Bool
  /// Unknown flag tokens that were ignored (kept for diagnostics).
  var unknownFlags: [String]

  static let usage = """
    Pensieve — native markdown editor

    Usage:
      Pensieve [--wait|-w] [file ...]
      Pensieve --help

    Options:
      --wait, -w   Open the given file(s) and quit when the last window closes.
                   Intended for $VC_COMPOSER / `open -W -n -a Pensieve --args …`.
      --help, -h   Show this help and exit.

    Files opened without --wait join a normal session (workspace restore disabled
    for the explicit file intent, same as Finder open).
    """

  static func parse(_ arguments: [String]) -> ComposerLaunchArguments {
    guard arguments.count > 1 else {
      return ComposerLaunchArguments(wait: false, fileURLs: [], showHelp: false, unknownFlags: [])
    }

    var wait = false
    var showHelp = false
    var fileURLs: [URL] = []
    var unknownFlags: [String] = []
    var parsingFlags = true

    // Drop argv[0] (executable path).
    for token in arguments.dropFirst() {
      if parsingFlags {
        switch token {
        case "--":
          parsingFlags = false
          continue
        case "--wait", "-w":
          wait = true
          continue
        case "--help", "-h":
          showHelp = true
          continue
        default:
          if token.hasPrefix("-") {
            unknownFlags.append(token)
            continue
          }
          parsingFlags = false
        }
      }

      if let url = resolveFileArgument(token) {
        fileURLs.append(url)
      }
    }

    return ComposerLaunchArguments(
      wait: wait,
      fileURLs: fileURLs,
      showHelp: showHelp,
      unknownFlags: unknownFlags)
  }

  /// Expand `~`, resolve relative paths against the process CWD, and
  /// standardize. Empty tokens are dropped.
  static func resolveFileArgument(_ token: String) -> URL? {
    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let expanded: String
    if trimmed == "~" {
      expanded = NSHomeDirectory()
    } else if trimmed.hasPrefix("~/") {
      let home = NSHomeDirectory() as NSString
      expanded = home.appendingPathComponent(String(trimmed.dropFirst(2)))
    } else {
      expanded = trimmed
    }

    if expanded.hasPrefix("/") {
      return URL(fileURLWithPath: expanded).standardizedFileURL
    }
    let cwd = FileManager.default.currentDirectoryPath
    return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: cwd))
      .standardizedFileURL
  }
}
