import Foundation
import XCTest

/// Regression guard for the test-plist leak: `removePersistentDomain(forName:)`
/// empties a domain but leaves its backing plist in `~/Library/Preferences`,
/// so `EphemeralDefaults.destroy` must also delete the file itself.
final class EphemeralDefaultsTests: XCTestCase {

  func testDestroyRemovesDomainAndBackingPlist() {
    let suiteName = EphemeralDefaults.suiteName(prefix: "PensieveEphemeralDefaultsTests")
    // Safety net so this test never strands a plist itself, even if an
    // assertion below fails first.
    addTeardownBlock { EphemeralDefaults.destroy(suiteName: suiteName) }

    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(true, forKey: "regression.marker")
    // Encourage cfprefsd to materialize the backing plist on disk, like a
    // real test run does. Deliberately NOT asserted: cfprefsd may flush
    // lazily, so the file's presence here is timing-dependent. The invariant
    // that matters is that nothing is left behind after destroy.
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

  /// Waits (up to `timeout`) for cfprefsd's lazy write-back to settle and the
  /// suite plist to be gone. Re-deleting a reappearing file is `destroy`'s
  /// job — the test only waits and reports.
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
