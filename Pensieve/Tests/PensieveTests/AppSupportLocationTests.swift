import XCTest

@testable import Pensieve

/// S5: a diagnostic run must be able to keep its Application Support state out
/// of the operator's. The override is the only lever that does that without
/// moving the operator's real directory aside, so its contract is pinned here:
/// silent by default, absolute-only, and ready to be written into.
final class AppSupportLocationTests: XCTestCase {

  func testAbsentVariableLeavesEveryCallerOnItsOwnDerivation() {
    XCTAssertNil(AppSupportLocation.overrideRoot(environment: [:]))
  }

  func testEmptyValueIsTreatedAsAbsent() {
    XCTAssertNil(
      AppSupportLocation.overrideRoot(
        environment: [AppSupportLocation.overrideEnvironmentKey: ""]))
  }

  /// A relative path would resolve against whatever working directory
  /// LaunchServices handed the app — an isolation switch that lands somewhere
  /// unpredictable is worse than no switch at all, so it is refused outright.
  func testRelativePathIsRefusedRatherThanResolvedAgainstTheWorkingDirectory() {
    XCTAssertNil(
      AppSupportLocation.overrideRoot(
        environment: [AppSupportLocation.overrideEnvironmentKey: "smoke-support"]))
  }

  func testAbsolutePathIsHonoredAndTheDirectoryExistsAfterwards() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent("pensieve-support-override-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }

    let resolved = AppSupportLocation.overrideRoot(
      environment: [AppSupportLocation.overrideEnvironmentKey: root.path])

    XCTAssertEqual(resolved?.standardizedFileURL, root.standardizedFileURL)
    // The four call sites write into this directory at wildly different points
    // in the launch; none of them should have to create it first.
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
  }

  func testTildeIsExpandedSoAnOperatorWrittenValueBehavesAsTyped() {
    let resolved = AppSupportLocation.overrideRoot(
      environment: [AppSupportLocation.overrideEnvironmentKey: "~"])

    XCTAssertEqual(resolved?.path, NSHomeDirectory())
  }
}
