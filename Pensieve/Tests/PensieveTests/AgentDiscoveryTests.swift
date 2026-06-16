import XCTest

@testable import Pensieve

final class AgentDiscoveryTests: XCTestCase {
  func testParsesAgentStreamNamesInOrderIgnoringCliLines() {
    let doctor = """
      ok: agent-cli:claude - -> /Users/x/.local/bin/claude
      ok: agent-cli:codex - -> /opt/homebrew/bin/codex
      ok: agent-stream:claude - 2.1.177 (Claude Code)
      ok: agent-stream:codex - codex-cli 0.137.0
      ok: agent-stream:gemini - 0.46.0
      ok: agent-stream:agy - 1.0.8
      ok: agent-stream:junie - Junie version: 26.6.8
      ok: agent-stream:grok - grok 0.2.51 [stable]
      """
    XCTAssertEqual(
      AppController.agentStreamNames(in: doctor),
      ["claude", "codex", "gemini", "agy", "junie", "grok"],
      "only agent-stream:<name> lines, first-seen order")
  }

  func testDeduplicatesRepeatedAgents() {
    let doctor = """
      ok: agent-stream:codex - v1
      ok: agent-stream:codex - v1
      ok: agent-stream:claude - v2
      """
    XCTAssertEqual(AppController.agentStreamNames(in: doctor), ["codex", "claude"])
  }

  func testEmptyOrUnrelatedOutputYieldsNoAgents() {
    XCTAssertTrue(AppController.agentStreamNames(in: "").isEmpty)
    XCTAssertTrue(
      AppController.agentStreamNames(in: "fail: something broke\nok: snapshot fresh").isEmpty)
  }
}
