import Foundation
import XCTest

/// Central factory for test-only `UserDefaults` suites that leave no trace in
/// `~/Library/Preferences`.
///
/// `removePersistentDomain(forName:)` alone is NOT enough: it empties the
/// domain through cfprefsd but does not reliably delete the backing plist
/// file, so every test run stranded a `<suiteName>.plist` (often empty, 42
/// bytes — thousands accumulated on dev machines). Cleanup here removes the
/// domain, flushes it, and then deletes the backing file itself.
enum EphemeralDefaults {

  /// Unique per-call suite name: `<prefix>-<UUID>`.
  static func suiteName(prefix: String) -> String {
    "\(prefix)-\(UUID().uuidString)"
  }

  /// Backing plist for a suite. Dot-separated suite names (`Foo.Bar.UUID`)
  /// also map to a single `<suiteName>.plist` — the name is used verbatim.
  static func plistURL(suiteName: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Preferences", isDirectory: true)
      .appendingPathComponent("\(suiteName).plist", isDirectory: false)
  }

  /// Removes the domain AND its backing plist file.
  static func destroy(suiteName: String) {
    if let defaults = UserDefaults(suiteName: suiteName) {
      defaults.removePersistentDomain(forName: suiteName)
      // Flush the now-empty domain so cfprefsd does not rewrite the file
      // after we delete it.
      defaults.synchronize()
    }
    try? FileManager.default.removeItem(at: plistURL(suiteName: suiteName))
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
  /// nil only for the app's own bundle identifier or the global domain,
  /// which a UUID-suffixed name can never collide with.
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
