import Foundation
import XCTest

@testable import Pensieve

/// Shared producer-shaped fixtures. The JSON below is a trimmed capture of a
/// REAL `vibecrafted capabilities --json` run (schema v1) under an isolated
/// config listing `grok, codex, gemini` — the CLI reports effective members
/// `[grok, codex]` and the dead `gemini` under `unsupported_configured`.
enum WorkflowCapabilitiesFixtures {
  static let isolatedGeminiJSON = """
    {
      "agents": ["agy", "claude", "codex", "grok", "junie", "swarm"],
      "research": {
        "default_agents": ["claude", "codex", "agy"],
        "supported_agents": ["claude", "codex", "agy", "junie", "grok"]
      },
      "schema": "vibecrafted.workflow_capabilities.v1",
      "schema_version": 1,
      "workflows": [
        {
          "aliases": ["justdo"],
          "cadence": "write",
          "can_modify_code": true,
          "default_agent": "claude",
          "execution_target": "single_agent",
          "input_policy": "required",
          "lifecycle_order": 20,
          "name": "implement",
          "requested_agent_policy": "honored",
          "runtime_kind": "direct_agent",
          "supports_count": false,
          "supports_depth": false,
          "terminal_layout": "",
          "tooling": ["vc-init", "vc-operator", "vc-agents"]
        },
        {
          "aliases": [],
          "cadence": "read",
          "can_modify_code": false,
          "default_agent": "swarm",
          "effective_agents": ["grok", "codex"],
          "execution_target": "swarm",
          "input_policy": "required",
          "lifecycle_order": 12,
          "name": "research",
          "positional_agent_semantics": {
            "execution_agent": "swarm",
            "multiple": "lanes_with_first_as_synthesizer",
            "single": "synthesizer_override",
            "unsupported_token": "launch_rejected"
          },
          "requested_agent_policy": "fail_closed",
          "runtime_kind": "supervised_research",
          "selection_source": "/tmp/isolated/vibecrafted/config.toml",
          "supports_count": false,
          "supports_depth": false,
          "synthesizer": {
            "agent": "",
            "fallback": "last_surviving_lane",
            "model": "",
            "source": ""
          },
          "terminal_layout": "research",
          "tooling": ["vc-init", "vc-research"],
          "unsupported_configured": ["gemini"]
        },
        {
          "aliases": [],
          "cadence": "write",
          "can_modify_code": true,
          "default_agent": "claude",
          "execution_target": "single_agent",
          "input_policy": "required",
          "lifecycle_order": 40,
          "name": "marbles",
          "requested_agent_policy": "honored",
          "runtime_kind": "supervised_marbles",
          "supports_count": true,
          "supports_depth": false,
          "swarm_agent_fallback": "codex",
          "terminal_layout": "marbles",
          "tooling": ["vc-marbles"]
        }
      ]
    }
    """

  static func decoded() throws -> WorkflowCapabilities {
    try WorkflowCapabilities.decode(from: Data(isolatedGeminiJSON.utf8))
  }
}

/// Injectable capability provider for controller tests: records the calling
/// thread and serves a canned result, so loading/loaded/failed sheet states
/// and the off-main contract are all drivable without the CLI.
final class FakeWorkflowCapabilitiesProvider: WorkflowCapabilitiesProviding, @unchecked Sendable {
  private let lock = NSLock()
  private let result: Result<WorkflowCapabilities, Error>
  private var fetchThreadsWereMain: [Bool] = []

  init(result: Result<WorkflowCapabilities, Error>) {
    self.result = result
  }

  func fetchCapabilities() throws -> WorkflowCapabilities {
    lock.lock()
    fetchThreadsWereMain.append(Thread.isMainThread)
    lock.unlock()
    return try result.get()
  }

  func recordedMainThreadFlags() -> [Bool] {
    lock.lock()
    defer { lock.unlock() }
    return fetchThreadsWereMain
  }
}

final class WorkflowCapabilitiesTests: XCTestCase {

  // MARK: - Versioned decoding (fail closed, never guess)

  func testDecodesProducerShapedPayload() throws {
    let capabilities = try WorkflowCapabilitiesFixtures.decoded()

    XCTAssertEqual(
      capabilities.agents, ["agy", "claude", "codex", "grok", "junie", "swarm"])
    XCTAssertEqual(
      capabilities.research?.supportedAgents,
      ["claude", "codex", "agy", "junie", "grok"])

    let research = try XCTUnwrap(capabilities.workflow(named: "research"))
    XCTAssertEqual(research.executionTarget, "swarm")
    XCTAssertEqual(research.requestedAgentPolicy, "fail_closed")
    XCTAssertEqual(research.effectiveAgents, ["grok", "codex"])
    XCTAssertEqual(research.unsupportedConfigured, ["gemini"])
    XCTAssertEqual(research.selectionSource, "/tmp/isolated/vibecrafted/config.toml")
    XCTAssertEqual(
      research.positionalAgentSemantics?["single"], "synthesizer_override")
    XCTAssertEqual(
      research.positionalAgentSemantics?["unsupported_token"], "launch_rejected")
    XCTAssertEqual(research.synthesizer?.agent, "")
    XCTAssertEqual(research.synthesizer?.fallback, "last_surviving_lane")
  }

  func testAliasLookupResolvesJustdoToImplement() throws {
    let capabilities = try WorkflowCapabilitiesFixtures.decoded()
    XCTAssertEqual(capabilities.workflow(named: "justdo")?.name, "implement")
  }

  func testUnknownExtraKeysAreForwardCompatible() throws {
    // `swarm_agent_fallback` on the marbles row is not modeled — decoding
    // must not reject producer additions.
    let capabilities = try WorkflowCapabilitiesFixtures.decoded()
    XCTAssertEqual(capabilities.workflow(named: "marbles")?.executionTarget, "single_agent")
  }

  func testRejectsUnknownSchemaName() {
    let payload = WorkflowCapabilitiesFixtures.isolatedGeminiJSON.replacingOccurrences(
      of: "vibecrafted.workflow_capabilities.v1",
      with: "vibecrafted.other_schema.v9")

    XCTAssertThrowsError(try WorkflowCapabilities.decode(from: Data(payload.utf8))) { error in
      guard case WorkflowCapabilitiesError.unsupportedSchema(let schema, let version) = error
      else {
        return XCTFail("Expected unsupportedSchema, got \(error)")
      }
      XCTAssertEqual(schema, "vibecrafted.other_schema.v9")
      XCTAssertEqual(version, 1)
    }
  }

  func testRejectsUnknownSchemaVersion() {
    let payload = WorkflowCapabilitiesFixtures.isolatedGeminiJSON.replacingOccurrences(
      of: "\"schema_version\": 1",
      with: "\"schema_version\": 2")

    XCTAssertThrowsError(try WorkflowCapabilities.decode(from: Data(payload.utf8))) { error in
      guard case WorkflowCapabilitiesError.unsupportedSchema(_, let version) = error else {
        return XCTFail("Expected unsupportedSchema, got \(error)")
      }
      XCTAssertEqual(version, 2)
    }
  }

  func testRejectsMalformedPayload() {
    XCTAssertThrowsError(
      try WorkflowCapabilities.decode(from: Data("not json at all".utf8))
    ) { error in
      guard case WorkflowCapabilitiesError.malformed = error else {
        return XCTFail("Expected malformed, got \(error)")
      }
    }
  }

  // MARK: - Dispatch plan derivation

  func testSingleAgentWorkflowPlansEditablePicker() throws {
    let state = WorkflowCapabilitiesState.loaded(try WorkflowCapabilitiesFixtures.decoded())
    XCTAssertEqual(WorkflowDispatchPlanner.plan(workflow: "implement", state: state), .singleAgent)
    XCTAssertEqual(WorkflowDispatchPlanner.plan(workflow: "justdo", state: state), .singleAgent)
  }

  func testResearchPlansSwarmWithMembersUnsupportedAndSynthesizerChoices() throws {
    let state = WorkflowCapabilitiesState.loaded(try WorkflowCapabilitiesFixtures.decoded())

    guard case .swarm(let plan) = WorkflowDispatchPlanner.plan(workflow: "research", state: state)
    else {
      return XCTFail("research must plan as a swarm")
    }
    XCTAssertEqual(plan.members, ["grok", "codex"], "effective members, producer order")
    XCTAssertEqual(plan.unsupportedConfigured, ["gemini"], "dead tokens surfaced, not hidden")
    XCTAssertEqual(plan.selectionSource, "/tmp/isolated/vibecrafted/config.toml")
    XCTAssertEqual(
      plan.synthesizerChoices, ["claude", "codex", "agy", "junie", "grok"],
      "positional-synthesizer policy declared → the supported universe is offered")
    XCTAssertEqual(plan.defaultSynthesizerDescription, "the last agent to finish")
  }

  func testSwarmWithoutPositionalSynthesizerPolicyOffersNoChoice() throws {
    let payload = WorkflowCapabilitiesFixtures.isolatedGeminiJSON.replacingOccurrences(
      of: "\"single\": \"synthesizer_override\"",
      with: "\"single\": \"some_future_semantics\"")
    let state = WorkflowCapabilitiesState.loaded(
      try WorkflowCapabilities.decode(from: Data(payload.utf8)))

    guard case .swarm(let plan) = WorkflowDispatchPlanner.plan(workflow: "research", state: state)
    else {
      return XCTFail("research must still plan as a swarm")
    }
    XCTAssertEqual(
      plan.synthesizerChoices, [],
      "an undeclared positional policy must not invent a synthesizer picker")
  }

  func testUnknownExecutionTargetFailsClosed() throws {
    let payload = WorkflowCapabilitiesFixtures.isolatedGeminiJSON.replacingOccurrences(
      of: "\"execution_target\": \"swarm\"",
      with: "\"execution_target\": \"quantum_mesh\"")
    let state = WorkflowCapabilitiesState.loaded(
      try WorkflowCapabilities.decode(from: Data(payload.utf8)))

    guard case .unavailable = WorkflowDispatchPlanner.plan(workflow: "research", state: state)
    else {
      return XCTFail("an unknown execution target must never be launchable")
    }
  }

  func testSwarmWithNoEffectiveMembersFailsClosed() throws {
    let payload = WorkflowCapabilitiesFixtures.isolatedGeminiJSON.replacingOccurrences(
      of: "\"effective_agents\": [\"grok\", \"codex\"]",
      with: "\"effective_agents\": []")
    let state = WorkflowCapabilitiesState.loaded(
      try WorkflowCapabilities.decode(from: Data(payload.utf8)))

    guard case .unavailable = WorkflowDispatchPlanner.plan(workflow: "research", state: state)
    else {
      return XCTFail("a swarm with zero members must never be launchable")
    }
  }

  func testResearchWithoutCapabilityTruthNeverGuessesMembers() {
    // Probe in flight → explicit loading, Dispatch disabled.
    XCTAssertEqual(
      WorkflowDispatchPlanner.plan(workflow: "research", state: .loading), .loading)
    XCTAssertEqual(
      WorkflowDispatchPlanner.plan(workflow: "research", state: .idle), .loading)
    // Probe failed → fail closed with the actionable reason, no codex fallback.
    guard
      case .unavailable(let reason) = WorkflowDispatchPlanner.plan(
        workflow: "research", state: .failed("CLI too old"))
    else {
      return XCTFail("research without capability truth must be unavailable")
    }
    XCTAssertEqual(reason, "CLI too old")
  }

  func testSingleAgentWorkflowsRemainUsableWhenCapabilityProbeFails() {
    // Only the swarm semantics need capability truth; the single-agent
    // contract of the other workflows is valid descriptor knowledge.
    for workflow in ["implement", "review", "audit", "marbles"] {
      XCTAssertEqual(
        WorkflowDispatchPlanner.plan(workflow: workflow, state: .failed("CLI too old")),
        .singleAgent)
      XCTAssertEqual(
        WorkflowDispatchPlanner.plan(workflow: workflow, state: .loading),
        .singleAgent)
    }
  }
}
