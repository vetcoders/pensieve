import Foundation
import Synchronization

/// The single place that answers "was this process told to keep its Application
/// Support state somewhere other than the user's real one?".
///
/// Four call sites derive the `Application Support/Pensieve` subtree
/// independently — `RecoveryStore`, `WorkspaceMetadataStore` (which
/// `WorkspaceCacheStore` builds on), `IndexDatabase` and `DocumentAISession` —
/// and each carries its own fallback for the day the directory cannot be
/// resolved. There is no shared base URL to redirect, so the isolation choice
/// lives here and every site consults it before running its ordinary fallback.
/// With the variable unset in a production process, `isolationRoot` returns
/// nil and each site's behavior is unchanged. Inside XCTest, all four stores
/// share one process-scoped temporary root so an accidentally reached
/// production singleton cannot touch the operator's state.
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
  private static let testProcessNonce = UUID().uuidString

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

  /// Shared isolation decision for every store that otherwise derives the
  /// operator's `Application Support/Pensieve` directory. The explicit smoke
  /// root wins; an accidental production singleton inside XCTest then falls
  /// back to one process-scoped temporary root; ordinary production gets nil.
  static func isolationRoot(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default,
    isTestProcess: Bool? = nil
  ) -> URL? {
    if let overrideRoot = overrideRoot(environment: environment, fileManager: fileManager) {
      return overrideRoot
    }
    guard isTestProcess ?? isRunningTests(environment: environment) else { return nil }
    return testProcessRoot(fileManager: fileManager)
  }

  /// Process-scoped fallback for a test that forgot to inject its own store.
  /// Explicit `PENSIEVE_SUPPORT_DIR` still wins so canary runs can inspect one
  /// known root after the suite exits.
  ///
  /// The directory is registered for removal when the process exits. Nothing
  /// else ever deletes it — it is named per pid AND per process nonce, so a
  /// later run cannot recognize an earlier one's — and every test process that
  /// reached a production singleton once left one behind in `$TMPDIR` forever.
  /// Cleanup is deliberately hung off process exit rather than a suite
  /// teardown: the root is shared by every store in the process, so no single
  /// test owns the moment it stops being needed.
  static func testProcessRoot(fileManager: FileManager = .default) -> URL {
    let root = fileManager.temporaryDirectory.appendingPathComponent(
      "PensieveTests-\(ProcessInfo.processInfo.processIdentifier)-\(testProcessNonce)",
      isDirectory: true)
    try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    let registered = registerForRemovalAtProcessExit(
      root,
      registrar: { handler in atexit_b(handler) },
      removeItem: { path in try? fileManager.removeItem(atPath: path) })
    if !registered {
      DebugTrace.log("test support cleanup registration failed path=\(root.path)")
    }
    return root
  }

  /// Roots this process has asked the runtime to delete on exit.
  ///
  /// Exposed because the REGISTRATION is the only half a test can observe: a
  /// pin on the removal itself would have to outlive the process doing the
  /// asserting. Nothing in the app reads this.
  static var rootsRegisteredForRemovalAtExit: Set<String> {
    registeredRoots.withLock { $0 }
  }

  typealias ProcessExitHandler = @convention(block) () -> Void

  // Registration invokes caller-owned synchronous closures while holding the lock.
  // Mutex keeps that operation on the caller's isolation domain; only the Set is shared.
  private static let registeredRoots = Mutex(Set<String>())

  /// Hands one directory to `atexit`, exactly once per path.
  ///
  /// Unreachable from a shipping process by construction: the only caller is
  /// `testProcessRoot`, and the only route into that is `isolationRoot` AFTER
  /// `isRunningTests` said yes. An `atexit` handler that deleted a directory in
  /// a production launch would be a far worse bug than the leak it fixes, so
  /// the guard stays where it already is rather than being duplicated into a
  /// second, drift-prone copy here.
  /// Returns true when this path already had a handler or this call registered
  /// one successfully. Kept internal so tests can drive registration failure
  /// and execute the captured callback without terminating the test process.
  @discardableResult
  static func registerForRemovalAtProcessExit(
    _ root: URL,
    registrar: (_ handler: @escaping ProcessExitHandler) -> Int32,
    removeItem: @escaping (String) -> Void
  ) -> Bool {
    let path = root.path
    return registeredRoots.withLock { roots in
      guard !roots.contains(path) else { return true }
      let result = registrar { removeItem(path) }
      guard result == 0 else { return false }
      roots.insert(path)
      return true
    }
  }
}
