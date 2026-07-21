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
    // Force cfprefsd to materialize the backing plist on disk, like a real
    // test run does.
    defaults.synchronize()

    let plistURL = EphemeralDefaults.plistURL(suiteName: suiteName)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: plistURL.path),
      "Writing to the suite should create \(plistURL.path)")

    EphemeralDefaults.destroy(suiteName: suiteName)

    XCTAssertNil(
      UserDefaults(suiteName: suiteName)?.object(forKey: "regression.marker"),
      "destroy must empty the domain")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: plistURL.path),
      "destroy must delete the backing plist, not just empty the domain")
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
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: plistPath),
        "teardown must leave no suite plist behind at \(plistPath)")
    }

    let (defaults, suiteName) = makeEphemeralDefaultsSuite(
      prefix: "PensieveEphemeralDefaultsTests")
    plistPath = EphemeralDefaults.plistURL(suiteName: suiteName).path
    defaults.set("value", forKey: "teardown.marker")
    defaults.synchronize()
  }
}
