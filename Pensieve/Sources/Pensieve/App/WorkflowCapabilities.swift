import Foundation

/// Typed, version-checked view of `vibecrafted capabilities --json`
/// (schema `vibecrafted.workflow_capabilities.v1`).
///
/// The CLI JSON is the ONLY authority on how a workflow executes — Pensieve
/// never parses human help text and never duplicates the operator's config.
/// Decoding fails closed: an unknown schema name or version is rejected, not
/// guessed at. Unknown EXTRA keys are ignored (forward-compatible), and the
/// producer's vocabulary (`execution_target`, `positional_agent_semantics`
/// values) is carried as opaque strings so a new producer word degrades into
/// an explicit "unavailable" plan instead of a wrong launch.
struct WorkflowCapabilities: Equatable, Sendable {
  static let supportedSchema = "vibecrafted.workflow_capabilities.v1"
  static let supportedSchemaVersion = 1

  struct Synthesizer: Equatable, Sendable, Decodable {
    let agent: String
    let model: String
    let source: String
    let fallback: String
  }

  struct Research: Equatable, Sendable {
    let supportedAgents: [String]
    let defaultAgents: [String]
  }

  struct Workflow: Equatable, Sendable {
    let name: String
    let aliases: [String]
    let executionTarget: String
    let defaultAgent: String
    let requestedAgentPolicy: String
    let runtimeKind: String
    let effectiveAgents: [String]?
    let unsupportedConfigured: [String]?
    let selectionSource: String?
    let synthesizer: Synthesizer?
    let positionalAgentSemantics: [String: String]?
  }

  /// Live single-agent universe (`cli.AGENTS`); includes the `swarm` token.
  let agents: [String]
  let research: Research?
  let workflows: [Workflow]

  /// Descriptor lookup by canonical name or alias (`justdo` → `implement`).
  func workflow(named name: String) -> Workflow? {
    workflows.first { $0.name == name || $0.aliases.contains(name) }
  }

  static func decode(from data: Data) throws -> WorkflowCapabilities {
    struct Envelope: Decodable {
      let schema: String?
      let schemaVersion: Int?
      enum CodingKeys: String, CodingKey {
        case schema
        case schemaVersion = "schema_version"
      }
    }
    let decoder = JSONDecoder()
    let envelope: Envelope
    do {
      envelope = try decoder.decode(Envelope.self, from: data)
    } catch {
      throw WorkflowCapabilitiesError.malformed(String(describing: error))
    }
    guard envelope.schema == supportedSchema,
      envelope.schemaVersion == supportedSchemaVersion
    else {
      throw WorkflowCapabilitiesError.unsupportedSchema(
        schema: envelope.schema ?? "(missing)",
        version: envelope.schemaVersion ?? -1)
    }
    do {
      return try decoder.decode(WorkflowCapabilities.self, from: data)
    } catch {
      throw WorkflowCapabilitiesError.malformed(String(describing: error))
    }
  }
}

extension WorkflowCapabilities: Decodable {
  enum CodingKeys: String, CodingKey {
    case agents, research, workflows
  }
}

extension WorkflowCapabilities.Research: Decodable {
  enum CodingKeys: String, CodingKey {
    case supportedAgents = "supported_agents"
    case defaultAgents = "default_agents"
  }
}

extension WorkflowCapabilities.Workflow: Decodable {
  enum CodingKeys: String, CodingKey {
    case name, aliases, synthesizer
    case executionTarget = "execution_target"
    case defaultAgent = "default_agent"
    case requestedAgentPolicy = "requested_agent_policy"
    case runtimeKind = "runtime_kind"
    case effectiveAgents = "effective_agents"
    case unsupportedConfigured = "unsupported_configured"
    case selectionSource = "selection_source"
    case positionalAgentSemantics = "positional_agent_semantics"
  }
}

enum WorkflowCapabilitiesError: LocalizedError, Equatable {
  case unsupportedSchema(schema: String, version: Int)
  case malformed(String)
  case probeFailed(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedSchema(let schema, let version):
      return
        "The vibecrafted CLI reported workflow capabilities Pensieve doesn't "
        + "understand (\(schema) v\(version)). Update Pensieve or the CLI so "
        + "they match."
    case .malformed(let detail):
      return "The vibecrafted CLI returned unreadable workflow capabilities. (\(detail))"
    case .probeFailed(let detail):
      return "Couldn't ask the vibecrafted CLI how workflows run. \(detail)"
    }
  }
}

/// Capability truth lifecycle for the dispatch sheet: probed fresh on every
/// sheet presentation (never cached across config edits), refreshable from the
/// sheet's Retry button.
enum WorkflowCapabilitiesState: Equatable {
  case idle
  case loading
  case loaded(WorkflowCapabilities)
  case failed(String)
}

/// What the dispatch sheet may honestly offer for one workflow, derived from
/// capability truth — never from a hardcoded member list.
enum WorkflowDispatchPlan: Equatable {
  /// Editable Agent picker; launch carries exactly the picked agent.
  case singleAgent
  /// Swarm run: show the effective members, launch with no positional agent
  /// (or one synthesizer choice when the descriptor sanctions it).
  case swarm(SwarmDispatchPlan)
  /// Capability probe in flight — Dispatch stays disabled for this workflow.
  case loading
  /// Capability truth missing or rejecting — Dispatch disabled, Retry offered.
  case unavailable(reason: String)

  var isLaunchable: Bool {
    switch self {
    case .singleAgent, .swarm: return true
    case .loading, .unavailable: return false
    }
  }
}

struct SwarmDispatchPlan: Equatable, Sendable {
  /// Effective configured members, in producer order — the lanes that run.
  let members: [String]
  /// Where the member selection came from (config path), for the sheet caption.
  let selectionSource: String?
  /// Configured tokens the CLI does not support — surfaced, never hidden.
  let unsupportedConfigured: [String]
  /// Agents the user may pick as the report writer. Non-empty ONLY when the
  /// descriptor declares `positional_agent_semantics.single ==
  /// "synthesizer_override"`; empty means the sheet offers no such choice.
  let synthesizerChoices: [String]
  /// Human copy for who writes the final report when no choice is made.
  let defaultSynthesizerDescription: String
}

enum WorkflowDispatchPlanner {
  /// Semantic floor when capability truth is unavailable: these workflows are
  /// NOT single-agent, and without the JSON we refuse to guess their members —
  /// fail closed. Every other workflow keeps its known single-agent contract.
  /// Loaded capability truth always overrides this set.
  static let capabilityRequiredWorkflows: Set<String> = ["research"]

  static func plan(
    workflow: String, state: WorkflowCapabilitiesState
  ) -> WorkflowDispatchPlan {
    switch state {
    case .loaded(let capabilities):
      guard let descriptor = capabilities.workflow(named: workflow) else {
        if capabilityRequiredWorkflows.contains(workflow) {
          return .unavailable(
            reason: "The vibecrafted CLI doesn't offer \(workflow) on this machine.")
        }
        return .singleAgent
      }
      switch descriptor.executionTarget {
      case "single_agent":
        return .singleAgent
      case "swarm":
        return swarmPlan(descriptor: descriptor, capabilities: capabilities)
      default:
        return .unavailable(
          reason:
            "Pensieve doesn't understand how \(workflow) runs "
            + "(\(descriptor.executionTarget)). Update Pensieve before dispatching it.")
      }
    case .idle, .loading:
      return capabilityRequiredWorkflows.contains(workflow) ? .loading : .singleAgent
    case .failed(let message):
      return capabilityRequiredWorkflows.contains(workflow)
        ? .unavailable(reason: message)
        : .singleAgent
    }
  }

  private static func swarmPlan(
    descriptor: WorkflowCapabilities.Workflow,
    capabilities: WorkflowCapabilities
  ) -> WorkflowDispatchPlan {
    let members = descriptor.effectiveAgents ?? []
    guard !members.isEmpty else {
      return .unavailable(
        reason: "No supported agents are configured for \(descriptor.name).")
    }
    let synthesizerChoices: [String]
    if descriptor.positionalAgentSemantics?["single"] == "synthesizer_override" {
      synthesizerChoices = capabilities.research?.supportedAgents ?? members
    } else {
      synthesizerChoices = []
    }
    let defaultSynthesizerDescription: String
    if let configured = descriptor.synthesizer?.agent, !configured.isEmpty {
      defaultSynthesizerDescription = configured
    } else if descriptor.synthesizer?.fallback == "last_surviving_lane" {
      defaultSynthesizerDescription = "the last agent to finish"
    } else {
      defaultSynthesizerDescription = "the workflow default"
    }
    return .swarm(
      SwarmDispatchPlan(
        members: members,
        selectionSource: descriptor.selectionSource,
        unsupportedConfigured: descriptor.unsupportedConfigured ?? [],
        synthesizerChoices: synthesizerChoices,
        defaultSynthesizerDescription: defaultSynthesizerDescription))
  }
}

/// Capability discovery seam. The controller always calls this OFF the main
/// thread; tests inject a fake to drive loading/error/loaded sheet states.
protocol WorkflowCapabilitiesProviding: Sendable {
  func fetchCapabilities() throws -> WorkflowCapabilities
}

struct VibecraftedWorkflowCapabilitiesProvider: WorkflowCapabilitiesProviding {
  func fetchCapabilities() throws -> WorkflowCapabilities {
    let executablePath = try VibecraftedAgentPromptLauncher.resolveExecutablePath()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = ["capabilities", "--json"]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    do {
      try process.run()
    } catch {
      throw WorkflowCapabilitiesError.probeFailed(error.localizedDescription)
    }
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let detail =
        String(data: errorOutput, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      throw WorkflowCapabilitiesError.probeFailed(
        "`vibecrafted capabilities` exited \(process.terminationStatus)"
          + (detail.isEmpty ? "." : ": \(detail)"))
    }
    return try WorkflowCapabilities.decode(from: output)
  }
}
