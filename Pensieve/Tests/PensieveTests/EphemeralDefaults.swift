import Foundation
import XCTest

/// Central factory for test-only `UserDefaults` suites that leave no trace in
/// `~/Library/Preferences`.
///
/// A plain suite name (`"MyTests-<UUID>"`) names an *application domain* owned
/// by cfprefsd, and cfprefsd — not this process — decides when the backing
/// plist is written. Measured on macOS 26: a suite that was written to, then
/// emptied with `removePersistentDomain(forName:)`, flushed with
/// `synchronize()`, and whose file was deleted, still reappeared as a 42-byte
/// plist in `~/Library/Preferences` **14.2 s after the process had exited**.
/// No teardown block, settle loop or `atexit` hook can win that race, which is
/// why the previous file-deleting cleanup still stranded hundreds of empty
/// plists per test run.
///
/// The fix removes the race instead of trying to win it: an ABSOLUTE PATH used
/// as the suite name makes `CFPreferences` back the domain with that exact
/// file rather than `~/Library/Preferences/<name>.plist`. Every `UserDefaults`
/// semantic is preserved — reads, writes, `persistentDomain(forName:)`,
/// `removePersistentDomain(forName:)`, cross-instance sharing — only the
/// storage location changes, and it changes to a per-process directory under
/// the OS temp directory that is removed when the process exits.
enum EphemeralDefaults {

  /// `~/Library/Preferences` — the directory ephemeral suites must never touch.
  static let userPreferences: URL =
    FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library", isDirectory: true)
    .appendingPathComponent("Preferences", isDirectory: true)

  /// Per-process container holding every ephemeral suite's backing plist.
  ///
  /// Removed on process exit, so a late cfprefsd write-back — if it ever
  /// happened for a path-backed domain — would have no directory to land in.
  static let container: URL = {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(
        "PensieveEphemeralDefaults-\(ProcessInfo.processInfo.processIdentifier)",
        isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    atexit { EphemeralDefaults.removeContainer() }
    return url
  }()

  /// Unique per-call suite name: an absolute path `<container>/<prefix>-<UUID>`.
  static func suiteName(prefix: String) -> String {
    container
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: false)
      .path
  }

  /// Backing plist for a suite. Suite names produced by `suiteName(prefix:)`
  /// are absolute paths, so the backing file is `<suiteName>.plist` verbatim.
  static func plistURL(suiteName: String) -> URL {
    URL(fileURLWithPath: "\(suiteName).plist", isDirectory: false)
  }

  /// Removes the domain AND its backing plist file.
  static func destroy(suiteName: String) {
    if let defaults = UserDefaults(suiteName: suiteName) {
      defaults.removePersistentDomain(forName: suiteName)
      defaults.synchronize()
    }
    let plistURL = plistURL(suiteName: suiteName)
    // Path-backed domains are written eagerly, so no settle loop is needed:
    // a couple of attempts cover a file that is still being replaced.
    for _ in 0..<3 {
      guard FileManager.default.fileExists(atPath: plistURL.path) else { break }
      try? FileManager.default.removeItem(at: plistURL)
    }
  }

  /// Drops the whole per-process container. Registered with `atexit`.
  static func removeContainer() {
    try? FileManager.default.removeItem(at: container)
  }
}

extension XCTestCase {

  /// Fresh `UserDefaults` suite named `<prefix>-<UUID>`; the domain and its
  /// backing plist are deleted after the current test finishes.
  func makeEphemeralDefaults(prefix: String) -> UserDefaults {
    makeEphemeralDefaultsSuite(prefix: prefix).defaults
  }

  /// Same as `makeEphemeralDefaults(prefix:)`, for callers that also need the
  /// suite name. The force unwrap is safe: `UserDefaults(suiteName:)` returns
  /// nil only for the app's own bundle identifier or the global domain, which
  /// a UUID-suffixed path under the temp container can never collide with.
  ///
  /// The returned `suiteName` is an absolute path — it is a domain identifier,
  /// not a display name, so do not reuse it as a file or directory name.
  func makeEphemeralDefaultsSuite(prefix: String) -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = EphemeralDefaults.suiteName(prefix: prefix)
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    addTeardownBlock {
      EphemeralDefaults.destroy(suiteName: suiteName)
    }
    return (defaults, suiteName)
  }
}
