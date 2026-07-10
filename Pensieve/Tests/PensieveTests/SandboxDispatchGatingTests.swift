import Foundation
import XCTest

@testable import Pensieve

/// Sandbox gating of agent dispatch (App Store lane). The capability is a pure
/// predicate with an injected flag so both worlds are testable from the
/// non-sandboxed test runner; the UI enable-points and AppController funnels
/// consume the same predicate.
final class SandboxDispatchGatingTests: XCTestCase {
  func testSandboxedProcessMustNotDispatchExternalAgents() {
    XCTAssertFalse(SandboxCapabilities.allowsExternalAgentDispatch(isSandboxed: true))
  }

  func testNonSandboxedProcessKeepsDispatchAvailable() {
    XCTAssertTrue(SandboxCapabilities.allowsExternalAgentDispatch(isSandboxed: false))
  }

  func testDefaultDetectionFollowsProcessEnvironment() {
    // The test runner itself is the live specimen: the default argument must
    // mirror the APP_SANDBOX_CONTAINER_ID marker of THIS process, whatever the
    // host is. (SwiftPM test runs are not sandboxed, but the assertion holds
    // either way instead of hardcoding that assumption.)
    let markerPresent =
      ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    XCTAssertEqual(SandboxCapabilities.isSandboxed, markerPresent)
    XCTAssertEqual(
      SandboxCapabilities.allowsExternalAgentDispatch(),
      !markerPresent)
  }

  func testUnavailableExplanationIsUserFacing() {
    let message = SandboxCapabilities.dispatchUnavailableExplanation
    XCTAssertFalse(message.isEmpty)
    // The message is product surface: it must say WHY and point at the lane
    // that still supports dispatch, not leak internal identifiers.
    XCTAssertTrue(message.contains("App Store"))
    XCTAssertTrue(message.contains("Developer ID"))
    XCTAssertFalse(message.contains("APP_SANDBOX_CONTAINER_ID"))
  }
}
