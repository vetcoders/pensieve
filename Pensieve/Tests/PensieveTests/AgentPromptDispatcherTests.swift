import Foundation
import XCTest

@testable import Pensieve

final class AgentPromptDispatcherTests: XCTestCase {
  func testBuildsArgumentsForFilePayloads() {
    let arguments = VibecraftedAgentPromptLauncher.arguments(
      workflow: "review",
      agent: "codex",
      payload: .file("/x.md")
    )

    XCTAssertEqual(arguments, ["review", "codex", "--file", "/x.md"])
  }
}
