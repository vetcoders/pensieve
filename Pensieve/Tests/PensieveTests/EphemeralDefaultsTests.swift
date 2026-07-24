import Foundation
import XCTest

/// Regression guard for the test-plist leak.
///
/// Two distinct failure classes are pinned here:
///
/// 1. **In-process residue** — `removePersistentDomain(forName:)` empties a
///    domain but leaves its backing plist on disk, so `EphemeralDefaults`
///    must delete the file itself.
/// 2. **Post-exit residue** — cfprefsd writes an application domain's plist
///    back to `~/Library/Preferences` on its own schedule, measured at ~14 s
///    after the test process exited. That write cannot be observed, let alone
///    prevented, from inside the process. The only durable defence is
///    structural: never let an ephemeral suite be an application domain in the
///    first place. `testSuiteIsBackedOutsideUserPreferences` and
///    `testWrittenSuiteLeavesNothingInUserPreferences` pin that structure.
final class EphemeralDefaultsTests: XCTestCase {

  /// Structural guard for the post-exit class: the suite must be a path-backed
  /// domain inside the per-process temp container, never an application domain
  /// under `~/Library/Preferences`. cfprefsd only schedules write-backs for
  /// the latter, so satisfying this makes the post-exit leak unreachable.
  func testSuiteIsBackedOutsideUserPreferences() {
    let suiteName = EphemeralDefaults.suiteName(prefix: "PensieveEphemeralDefaultsTests")
    addTeardownBlock { EphemeralDefaults.destroy(suiteName: suiteName) }

    XCTAssertTrue(
      suiteName.hasPrefix("/"),
      "suite name must be an absolute path so CFPreferences backs it with that file")
    XCTAssertEqual(
      URL(fileURLWithPath: suiteName).deletingLastPathComponent().standardizedFileURL,
      EphemeralDefaults.container.standardizedFileURL,
      "suite must live in the per-process temp container")

    let plistPath = EphemeralDefaults.plistURL(suiteName: suiteName).standardizedFileURL.path
    let preferences = EphemeralDefaults.userPreferences.standardizedFileURL.path
    XCTAssertFalse(
      plistPath.hasPrefix(preferences + "/"),
      "backing plist must never live under \(preferences)")

    let container = EphemeralDefaults.container.standardizedFileURL.path
    XCTAssertTrue(
      container.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path),
      "container must live under the OS temp directory")
  }

  /// Behavioural guard for the post-exit class, as far as XCTest can reach:
  /// a suite that is written to, flushed, and destroyed must not put anything
  /// carrying its prefix into `~/Library/Preferences`.
  ///
  /// Limitation, deliberate: cfprefsd's write-back for an application domain
  /// lands after this process is gone, so a *failing* implementation could
  /// still pass this assertion in-process. The assertion above — backing file
  /// outside `~/Library/Preferences` — is the one that actually forecloses the
  /// leak; this one catches a regression that reintroduces a plain suite name
  /// and materializes the file eagerly. Full proof stays empirical: snapshot
  /// `~/Library/Preferences` before and after a complete `swift test` run.
  func testWrittenSuiteLeavesNothingInUserPreferences() throws {
    let prefix = "PensieveEphemeralDefaultsLeakProbe"
    let suiteName = EphemeralDefaults.suiteName(prefix: prefix)
    addTeardownBlock { EphemeralDefaults.destroy(suiteName: suiteName) }

    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.set("value", forKey: "leak.probe")
    defaults.synchronize()
    XCTAssertEqual(
      defaults.string(forKey: "leak.probe"), "value",
      "a path-backed suite must behave like any other UserDefaults suite")

    EphemeralDefaults.destroy(suiteName: suiteName)

    let stranded = (try? FileManager.default.contentsOfDirectory(
      atPath: EphemeralDefaults.userPreferences.path)) ?? []
    XCTAssertEqual(
      stranded.filter { $0.contains(prefix) }, [],
      "no file carrying the suite prefix may appear in ~/Library/Preferences")
  }

  func testDestroyRemovesDomainAndBackingPlist() {
    let suiteName = EphemeralDefaults.suiteName(prefix: "PensieveEphemeralDefaultsTests")
    // Safety net so this test never strands a plist itself, even if an
    // assertion below fails first.
    addTeardownBlock { EphemeralDefaults.destroy(suiteName: suiteName) }

    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(true, forKey: "regression.marker")
    // Materialize the backing plist on disk, like a real test run does.
    defaults.synchronize()

    let plistURL = EphemeralDefaults.plistURL(suiteName: suiteName)

    EphemeralDefaults.destroy(suiteName: suiteName)

    XCTAssertNil(
      UserDefaults(suiteName: suiteName)?.object(forKey: "regression.marker"),
      "destroy must empty the domain")
    assertPlistEventuallyGone(atPath: plistURL.path)
  }

  func testMakeEphemeralDefaultsCleansUpAfterTheTest() {
    var plistPath: String?
    // Registered FIRST so it runs LAST (teardown blocks are LIFO) — i.e.
    // after the cleanup block that makeEphemeralDefaultsSuite registers.
    addTeardownBlock {
      guard let plistPath else {
        XCTFail("plistPath was never set")
        return
      }
      self.assertPlistEventuallyGone(atPath: plistPath)
    }

    let (defaults, suiteName) = makeEphemeralDefaultsSuite(
      prefix: "PensieveEphemeralDefaultsTests")
    plistPath = EphemeralDefaults.plistURL(suiteName: suiteName).path
    defaults.set("value", forKey: "teardown.marker")
    defaults.synchronize()
  }

  /// Waits (up to `timeout`) for the suite plist to be gone. Re-deleting a
  /// reappearing file is `destroy`'s job — the test only waits and reports.
  private func assertPlistEventuallyGone(
    atPath path: String, timeout: TimeInterval = 5,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
      if !FileManager.default.fileExists(atPath: path) { return }
      Thread.sleep(forTimeInterval: 0.1)
    }
    XCTFail(
      "Suite plist still exists after \(timeout)s; cleanup must delete \(path)",
      file: file, line: line)
  }
}
