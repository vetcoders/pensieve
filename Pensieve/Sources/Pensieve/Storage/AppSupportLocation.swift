import Foundation

/// The single place that answers "was this process told to keep its Application
/// Support state somewhere other than the user's real one?".
///
/// Four call sites derive the `Application Support/Pensieve` subtree
/// independently — `RecoveryStore`, `WorkspaceMetadataStore` (which
/// `WorkspaceCacheStore` builds on), `IndexDatabase` and `DocumentAISession` —
/// and each carries its own fallback for the day the directory cannot be
/// resolved. There is no shared base URL to redirect, so the override lives
/// here and every site consults it in one line before running the code it
/// always ran. With the variable unset `overrideRoot` returns nil and each
/// site's behavior is unchanged, byte for byte.
///
/// Why an explicit variable rather than `HOME`: `NSHomeDirectory()` reads
/// `getpwuid`, not the environment, so
/// `FileManager.url(for: .applicationSupportDirectory, …)` always resolves to
/// the real user's `~/Library/Application Support` no matter what a harness
/// exports. Before this existed, a diagnostic run (`scripts/ui-smoke.sh`,
/// `scripts/smoke_search_memory.sh`) could only isolate its index, drafts and
/// workspace metadata by symlink-swapping the operator's own directory aside —
/// which loses the operator's state outright if the run dies between the swap
/// and the restore.
enum AppSupportLocation {
  /// Absolute path to use in place of `Application Support/Pensieve`.
  static let overrideEnvironmentKey = "PENSIEVE_SUPPORT_DIR"

  /// The replacement root, or `nil` when the caller should derive its own.
  ///
  /// Only an absolute path is honored: a relative one would resolve against
  /// whatever working directory LaunchServices happened to hand the app, which
  /// is exactly the kind of surprise an isolation switch must not introduce.
  static func overrideRoot(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL? {
    guard let raw = environment[overrideEnvironmentKey] else { return nil }
    let expanded = (raw as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/") else { return nil }
    let root = URL(fileURLWithPath: expanded, isDirectory: true)
    try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  /// True when the current executable is an XCTest host.
  ///
  /// Tests occasionally reach a production singleton by mistake. That is a
  /// test bug, but it must never turn into writes under the operator's real
  /// Application Support directory. The checks intentionally overlap: SwiftPM
  /// and Xcode do not expose exactly the same environment, while a loaded
  /// XCTest runtime is the stable final signal for both.
  static func isRunningTests(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    processName: String = ProcessInfo.processInfo.processName,
    isXCTestRuntimeLoaded: Bool =
      NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil
  ) -> Bool {
    environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestBundlePath"] != nil
      || processName.hasSuffix(".xctest")
      || isXCTestRuntimeLoaded
  }

  /// Process-scoped fallback for a test that forgot to inject its own store.
  /// Explicit `PENSIEVE_SUPPORT_DIR` still wins so canary runs can inspect one
  /// known root after the suite exits.
  static func testProcessRoot(fileManager: FileManager = .default) -> URL {
    let root = fileManager.temporaryDirectory.appendingPathComponent(
      "PensieveTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
