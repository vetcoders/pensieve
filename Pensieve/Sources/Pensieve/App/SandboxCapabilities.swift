import Foundation

/// Runtime capability probe for the App Sandbox (Mac App Store build).
///
/// Agent dispatch launches external processes (the `vibecrafted` CLI,
/// Terminal via osascript) — impossible inside an App Sandbox container,
/// where spawning arbitrary executables outside the bundle is denied.
/// Rather than let a dispatch die deep inside `Process.run()`, the dispatch
/// surfaces degrade honestly: controls stay VISIBLE but disabled with an
/// explanation, and the dispatch funnels fail closed with the same message.
/// The Developer ID (non-sandboxed) build sees zero behavior change:
/// `isSandboxed` is false there, so every predicate call collapses to today's
/// behavior.
enum SandboxCapabilities {
  /// True when the current process runs inside an App Sandbox container.
  /// macOS injects APP_SANDBOX_CONTAINER_ID into the environment of every
  /// sandboxed process; SwiftPM targets have no entitlement-query API, so the
  /// environment marker is the canonical detection.
  static let isSandboxed: Bool =
    ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

  /// Whether this process may launch external agent tooling. Pure predicate
  /// with an injectable flag so tests exercise both worlds without a sandbox.
  static func allowsExternalAgentDispatch(isSandboxed: Bool = Self.isSandboxed) -> Bool {
    !isSandboxed
  }

  /// User-facing explanation shown at the disabled dispatch controls and
  /// returned by the dispatch funnels when a sandboxed process tries anyway.
  static let dispatchUnavailableExplanation =
    "Agent dispatch runs external tools (vibecrafted, Terminal) and is not available "
    + "in the App Store version. Use the Developer ID build of Pensieve for agent workflows."
}
