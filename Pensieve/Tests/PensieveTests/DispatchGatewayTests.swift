import Foundation
import XCTest

@testable import Pensieve

/// W3-A gateway contract: every UI dispatch surface raises a typed
/// `DispatchIntent` for the focused window's configuration sheet; the launcher
/// is reached only through an explicit sheet confirmation. These tests are the
/// negative-launch spy across every route plus the confirmation semantics.
final class DispatchGatewayTests: XCTestCase {

  // MARK: - Pure intent construction

  func testSavedDocumentAndFileSubjectsMapToFilePayload() {
    let url = URL(fileURLWithPath: "/tmp/plan.md")

    let saved = DispatchIntent(subject: .savedDocument(url), workflow: "review", source: .toolbar)
    XCTAssertEqual(saved.payload, .file(url.path))
    XCTAssertEqual(saved.subjectLabel, "plan.md")
    XCTAssertFalse(saved.subjectIsEmpty)

    let file = DispatchIntent(subject: .fileURL(url), workflow: "audit", source: .sidebar)
    XCTAssertEqual(file.payload, .file(url.path))
    XCTAssertEqual(file.subjectLabel, "plan.md")
  }

  func testUnsavedBufferSubjectMapsToPromptPayloadAndFlagsEmptiness() {
    let draft = DispatchIntent(
      subject: .unsavedBuffer(title: "Scratch.md", text: "ship it"),
      workflow: "implement",
      source: .agentsMenu)
    XCTAssertEqual(draft.payload, .prompt("ship it"))
    XCTAssertEqual(draft.subjectLabel, "Scratch.md (unsaved draft)")
    XCTAssertFalse(draft.subjectIsEmpty)

    let empty = DispatchIntent(
      subject: .unsavedBuffer(title: "Scratch.md", text: "  \n"),
      workflow: "implement",
      source: .agentsMenu)
    XCTAssertTrue(empty.subjectIsEmpty)
  }

  // MARK: - Negative launch spy: every route only presents the sheet

  @MainActor
  func testEveryCurrentDocumentRoutePresentsSheetWithoutLaunching() {
    let documentURL = URL(fileURLWithPath: "/tmp/gateway-route.md").standardizedFileURL
    let sources: [(DispatchIntent.Source, String)] = [
      (.toolbar, "implement"),
      (.agentsMenu, "implement"),
      (.agentsWorkflowMenu, "marbles"),
    ]

    for (source, workflow) in sources {
      let (controller, appState, launcher) = makeController()
      appState.documentSession = DocumentSession(
        document: DocumentRef(id: documentURL), text: "# Plan", isDirty: false)

      XCTAssertTrue(
        controller.requestCurrentDocumentDispatch(workflow: workflow, source: source),
        "route \(source.rawValue) must accept the request")
      XCTAssertTrue(
        launcher.requests().isEmpty,
        "route \(source.rawValue) must not launch before sheet confirmation")

      guard let intent = appState.pendingDispatchIntent else {
        return XCTFail("route \(source.rawValue) must raise a pending intent")
      }
      XCTAssertEqual(intent.source, source)
      XCTAssertEqual(intent.workflow, workflow, "clicked workflow must be preselected")
      XCTAssertEqual(intent.subject, .savedDocument(documentURL))
    }
  }

  @MainActor
  func testSidebarRoutePresentsSheetWithFileSubjectWithoutLaunching() {
    let fileURL = URL(fileURLWithPath: "/tmp/gateway-sidebar.md").standardizedFileURL
    let (controller, appState, launcher) = makeController()

    XCTAssertTrue(
      controller.requestFileDispatch(url: fileURL, workflow: "audit", source: .sidebar))
    XCTAssertTrue(launcher.requests().isEmpty)

    guard let intent = appState.pendingDispatchIntent else {
      return XCTFail("sidebar route must raise a pending intent")
    }
    XCTAssertEqual(intent.subject, .fileURL(fileURL))
    XCTAssertEqual(intent.workflow, "audit")
    XCTAssertEqual(intent.source, .sidebar)
  }

  // MARK: - Multi-window routing

  @MainActor
  func testRequestTargetsOnlyTheRequestingWindow() {
    let documentURL = URL(fileURLWithPath: "/tmp/gateway-window-b.md").standardizedFileURL
    let (_, appStateA, _) = makeController()
    let (controllerB, appStateB, _) = makeController()
    appStateB.documentSession = DocumentSession(
      document: DocumentRef(id: documentURL), text: "# Plan", isDirty: false)

    XCTAssertTrue(
      controllerB.requestCurrentDocumentDispatch(workflow: "review", source: .agentsMenu))

    XCTAssertNil(
      appStateA.pendingDispatchIntent,
      "a request raised in window B must never present a sheet in window A")
    XCTAssertEqual(appStateB.pendingDispatchIntent?.subject, .savedDocument(documentURL))
  }

  // MARK: - Confirmation semantics

  @MainActor
  func testConfirmDeliversExactAgentRootAndPayloadToLauncher() async {
    let fileURL = URL(fileURLWithPath: "/tmp/gateway-exact.md").standardizedFileURL
    let chosenRoot = URL(fileURLWithPath: "/tmp/gateway-chosen-root", isDirectory: true)
      .standardizedFileURL
    let (controller, _, launcher) = makeController()
    let intent = DispatchIntent(subject: .fileURL(fileURL), workflow: "audit", source: .sidebar)

    // The sheet lets the user override workflow and agent after preselection;
    // whatever it confirms with must reach the launcher untranslated.
    let outcome = await controller.confirmDispatch(
      intent: intent, workflow: "review", agents: ["grok"], rootURL: chosenRoot)

    guard case .success = outcome else {
      return XCTFail("Expected confirmed dispatch to succeed")
    }
    XCTAssertEqual(
      launcher.requests(),
      [
        GatewayRecordingLauncher.Request(
          workflow: "review",
          agents: ["grok"],
          payload: .file(fileURL.path),
          workingDirectoryURL: chosenRoot)
      ])
  }

  @MainActor
  func testSecondConfirmWhileFirstInFlightIsRefused() async throws {
    let fileURL = URL(fileURLWithPath: "/tmp/gateway-inflight.md").standardizedFileURL
    let rootURL = URL(fileURLWithPath: "/tmp/gateway-root", isDirectory: true).standardizedFileURL
    let appState = AppState()
    let launcher = BlockingLauncher()
    let controller = AppController(
      appState: appState,
      folderManager: .shared,
      documentStore: .shared,
      transcriptionService: TranscriptionService(cadenceCommitNanoseconds: 0),
      agentPromptLauncher: launcher
    )
    let intent = DispatchIntent(subject: .fileURL(fileURL), workflow: "review", source: .sidebar)

    let first = Task {
      await controller.confirmDispatch(
        intent: intent, workflow: "review", agents: ["codex"], rootURL: rootURL)
    }
    try await waitUntil { launcher.startedCount() == 1 }

    let second = await controller.confirmDispatch(
      intent: intent, workflow: "review", agents: ["codex"], rootURL: rootURL)
    guard case .failure(let message) = second else {
      launcher.release()
      return XCTFail("Expected the second confirm to be refused while one is in flight")
    }
    XCTAssertEqual(message, "A dispatch is already running. Wait for it to finish.")

    launcher.release()
    guard case .success = await first.value else {
      return XCTFail("Expected the first confirm to complete successfully")
    }
    XCTAssertEqual(launcher.startedCount(), 1, "exactly one launch may reach the launcher")
  }

  // MARK: - Sandbox (App Store) build fails closed without Process

  @MainActor
  func testSandboxedBuildRefusesRequestsAndConfirmations() async {
    let fileURL = URL(fileURLWithPath: "/tmp/gateway-sandbox.md").standardizedFileURL
    let (controller, appState, launcher) = makeController()
    appState.documentSession = DocumentSession(
      document: DocumentRef(id: fileURL), text: "# Plan", isDirty: false)

    XCTAssertFalse(
      controller.requestCurrentDocumentDispatch(
        workflow: "review", source: .agentsMenu, allowsExternalDispatch: false))
    XCTAssertNil(appState.pendingDispatchIntent)
    XCTAssertEqual(appState.lastError, SandboxCapabilities.dispatchUnavailableExplanation)

    appState.lastError = nil
    XCTAssertFalse(
      controller.requestFileDispatch(
        url: fileURL, workflow: "review", source: .sidebar, allowsExternalDispatch: false))
    XCTAssertNil(appState.pendingDispatchIntent)
    XCTAssertEqual(appState.lastError, SandboxCapabilities.dispatchUnavailableExplanation)

    let intent = DispatchIntent(subject: .fileURL(fileURL), workflow: "review", source: .sidebar)
    let outcome = await controller.confirmDispatch(
      intent: intent, workflow: "review", agents: ["codex"],
      rootURL: URL(fileURLWithPath: "/tmp"), allowsExternalDispatch: false)
    guard case .failure(let message) = outcome else {
      return XCTFail("Expected the sandboxed confirm to fail closed")
    }
    XCTAssertEqual(message, SandboxCapabilities.dispatchUnavailableExplanation)
    XCTAssertTrue(launcher.requests().isEmpty)
  }

  // MARK: - Agent picker universe

  @MainActor
  func testAgentPickerUniverseMatchesLiveCliAndPreselectsCodex() {
    let (controller, _, _) = makeController()

    XCTAssertEqual(
      controller.availableAgents, ["claude", "codex", "agy", "junie", "grok"],
      "picker universe must match the deployed CLI AGENTS set")
    XCTAssertFalse(
      controller.availableAgents.contains("gemini"),
      "gemini was removed from the live CLI and must not be offered")
    XCTAssertEqual(controller.defaultAgent, "codex")
  }

  // MARK: - Capability truth (W2-C consumption)

  @MainActor
  func testCapabilityProbeRunsOffMainAndAdoptsAgentUniverse() async throws {
    let provider = FakeWorkflowCapabilitiesProvider(
      result: .success(try WorkflowCapabilitiesFixtures.decoded()))
    let (controller, _, _) = makeController(capabilities: provider)

    XCTAssertEqual(controller.workflowCapabilitiesState, .idle, "no probe before the sheet asks")
    controller.refreshWorkflowCapabilities(force: true)
    try await waitForCapabilityState(controller)

    XCTAssertEqual(provider.recordedMainThreadFlags(), [false], "probe must run off-main")
    guard case .loaded = controller.workflowCapabilitiesState else {
      return XCTFail("Expected the fake payload to load")
    }
    // The capability universe replaces the seed (same tokens here, seed order
    // kept; `swarm` is an execution target, not a pickable lane).
    XCTAssertEqual(
      controller.availableAgents, ["claude", "codex", "agy", "junie", "grok"])
  }

  @MainActor
  func testResearchConfirmFailsClosedWhenCapabilityTruthUnavailable() async throws {
    let provider = FakeWorkflowCapabilitiesProvider(
      result: .failure(WorkflowCapabilitiesError.probeFailed("`capabilities` not in the deck")))
    let (controller, _, launcher) = makeController(capabilities: provider)
    controller.refreshWorkflowCapabilities(force: true)
    try await waitForCapabilityState(controller)

    let fileURL = URL(fileURLWithPath: "/tmp/gateway-research.md").standardizedFileURL
    let intent = DispatchIntent(subject: .fileURL(fileURL), workflow: "research", source: .sidebar)

    // No capability truth → research must NOT silently fall back to codex or
    // hardcoded members, with or without a positional agent.
    for agents in [[], ["codex"]] {
      let outcome = await controller.confirmDispatch(
        intent: intent, workflow: "research", agents: agents,
        rootURL: URL(fileURLWithPath: "/tmp"))
      guard case .failure = outcome else {
        return XCTFail("Expected research confirm to fail closed for agents \(agents)")
      }
    }
    XCTAssertTrue(launcher.requests().isEmpty, "nothing may reach the launcher")

    // Normal workflows keep their known single-agent contract even though the
    // capability probe failed.
    let review = await controller.confirmDispatch(
      intent: DispatchIntent(subject: .fileURL(fileURL), workflow: "review", source: .sidebar),
      workflow: "review", agents: ["codex"], rootURL: URL(fileURLWithPath: "/tmp"))
    guard case .success = review else {
      return XCTFail("Expected a single-agent workflow to remain usable")
    }
    XCTAssertEqual(launcher.requests().map(\.agents), [["codex"]])
  }

  @MainActor
  func testSwarmConfirmLaunchesOnlyDescriptorSanctionedArguments() async throws {
    let provider = FakeWorkflowCapabilitiesProvider(
      result: .success(try WorkflowCapabilitiesFixtures.decoded()))
    let (controller, _, launcher) = makeController(capabilities: provider)
    controller.refreshWorkflowCapabilities(force: true)
    try await waitForCapabilityState(controller)

    let fileURL = URL(fileURLWithPath: "/tmp/gateway-swarm.md").standardizedFileURL
    let rootURL = URL(fileURLWithPath: "/tmp", isDirectory: true).standardizedFileURL
    let intent = DispatchIntent(subject: .fileURL(fileURL), workflow: "research", source: .sidebar)

    // Default swarm run: NO positional agent — the CLI runs its configured
    // members; the launcher request is the receipt the UI summary promised.
    let swarmRun = await controller.confirmDispatch(
      intent: intent, workflow: "research", agents: [], rootURL: rootURL)
    guard case .success = swarmRun else {
      return XCTFail("Expected the default swarm confirm to succeed")
    }

    // Positional synthesizer: sanctioned because the descriptor declares
    // single-positional = synthesizer override and grok is a supported agent.
    let synthesizerRun = await controller.confirmDispatch(
      intent: intent, workflow: "research", agents: ["grok"], rootURL: rootURL)
    guard case .success = synthesizerRun else {
      return XCTFail("Expected the synthesizer confirm to succeed")
    }

    // The dead configured token is NOT a sanctioned positional agent — the
    // producer would reject the launch, so the gateway refuses first.
    let rejected = await controller.confirmDispatch(
      intent: intent, workflow: "research", agents: ["gemini"], rootURL: rootURL)
    guard case .failure(let message) = rejected else {
      return XCTFail("Expected the unsupported token to be refused")
    }
    XCTAssertTrue(message.contains("gemini"), "refusal must name the token: \(message)")

    XCTAssertEqual(
      launcher.requests().map(\.agents), [[], ["grok"]],
      "only descriptor-sanctioned launches may reach the launcher")
    XCTAssertEqual(launcher.requests().map(\.workflow), ["research", "research"])
  }

  @MainActor
  func testDefaultSwarmCarriesReceiptObserveAgentThroughControllerAndPhase() async throws {
    let provider = FakeWorkflowCapabilitiesProvider(
      result: .success(try WorkflowCapabilitiesFixtures.decoded()))
    let receipt = AgentDispatchMetadata.parse(
      output: """
        run_id: research-default-swarm
        agent: swarm
        report: /tmp/reports/research-default-swarm.md
        """,
      exitCode: 0
    ).classified(workerSpawnRecorded: false)
    let (controller, _, launcher) = makeController(
      capabilities: provider,
      launcherResult: receipt)
    controller.refreshWorkflowCapabilities(force: true)
    try await waitForCapabilityState(controller)

    let fileURL = URL(fileURLWithPath: "/tmp/gateway-swarm-receipt.md").standardizedFileURL
    let rootURL = URL(fileURLWithPath: "/tmp", isDirectory: true).standardizedFileURL
    let outcome = await controller.confirmDispatch(
      intent: DispatchIntent(
        subject: .fileURL(fileURL), workflow: "research", source: .sidebar),
      workflow: "research",
      agents: [],
      rootURL: rootURL)

    guard
      case .acceptedUnconfirmed(let runID, let reportPath, let observeAgent, _) = outcome
    else {
      return XCTFail("Expected the accepted default swarm receipt to remain inspectable")
    }
    XCTAssertEqual(runID, "research-default-swarm")
    XCTAssertEqual(reportPath, "/tmp/reports/research-default-swarm.md")
    XCTAssertEqual(observeAgent, "swarm")
    XCTAssertEqual(launcher.requests().map(\.agents), [[]])
    XCTAssertEqual(
      DispatchPopover.resolvedPhase(for: outcome),
      .acceptedUnconfirmed(
        runID: "research-default-swarm",
        reportPath: "/tmp/reports/research-default-swarm.md",
        observeAgent: "swarm"))
  }

  // MARK: - Receipt actions (what a launch receipt earns)

  /// An older/trimmed receipt may omit `agent:`, but a single-agent dispatch
  /// still has one explicit positional authority. That dispatched token — not
  /// the first item in the configured-agent list — is what the status action
  /// must observe.
  @MainActor
  func testSingleAgentReceiptWithoutAgentUsesTheExplicitDispatchedAgentForStatus() async {
    let receipt = AgentDispatchMetadata.parse(
      output: """
        run_id: work-no-agent-line
        report: /tmp/reports/work-no-agent-line.md
        """,
      exitCode: 0
    ).classified(workerSpawnRecorded: false)
    XCTAssertNil(receipt.observeAgent, "precondition: the receipt names no observe agent")

    let (controller, _, launcher) = makeController(launcherResult: receipt)
    XCTAssertEqual(
      controller.availableAgents.first, "claude",
      "precondition: production ordering starts with a different agent than the default")
    XCTAssertEqual(controller.defaultAgent, "codex", "precondition: the explicit default lane")

    let fileURL = URL(fileURLWithPath: "/tmp/gateway-no-agent-line.md").standardizedFileURL
    let outcome = await controller.confirmDispatch(
      intent: DispatchIntent(subject: .fileURL(fileURL), workflow: "review", source: .sidebar),
      workflow: "review",
      agents: ["codex"],
      rootURL: URL(fileURLWithPath: "/tmp", isDirectory: true))

    guard
      case .acceptedUnconfirmed(let runID, let reportPath, let observeAgent, _) = outcome
    else {
      return XCTFail("Expected the accepted single-agent receipt to remain inspectable")
    }
    XCTAssertEqual(observeAgent, "codex")
    XCTAssertEqual(launcher.requests().map(\.agents), [["codex"]])

    let actions = DispatchPopover.receiptActions(
      runID: runID,
      reportPath: reportPath,
      observeAgent: observeAgent,
      runIsLaunched: true)
    XCTAssertEqual(actions.revealReportPath, "/tmp/reports/work-no-agent-line.md")
    XCTAssertEqual(
      actions.observe,
      DispatchPopover.ReceiptActions.Observe(agent: "codex", runID: "work-no-agent-line"))
  }

  /// A default swarm has no positional agent. If its receipt also omits
  /// `agent:`, neither the controller nor the view may guess an observer from
  /// the configured-agent order; the report remains a real, revealable artifact.
  @MainActor
  func testDefaultSwarmReceiptWithoutAgentOffersNoStatusButKeepsTheReport() async throws {
    let provider = FakeWorkflowCapabilitiesProvider(
      result: .success(try WorkflowCapabilitiesFixtures.decoded()))
    let receipt = AgentDispatchMetadata.parse(
      output: """
        run_id: research-default-no-agent
        report: /tmp/reports/research-default-no-agent.md
        """,
      exitCode: 0
    ).classified(workerSpawnRecorded: false)
    XCTAssertNil(receipt.observeAgent, "precondition: the receipt names no observe agent")

    let (controller, _, launcher) = makeController(
      capabilities: provider,
      launcherResult: receipt)
    controller.refreshWorkflowCapabilities(force: true)
    try await waitForCapabilityState(controller)

    let fileURL = URL(fileURLWithPath: "/tmp/gateway-default-no-agent.md").standardizedFileURL
    let outcome = await controller.confirmDispatch(
      intent: DispatchIntent(
        subject: .fileURL(fileURL), workflow: "research", source: .sidebar),
      workflow: "research",
      agents: [],
      rootURL: URL(fileURLWithPath: "/tmp", isDirectory: true))

    guard
      case .acceptedUnconfirmed(let runID, let reportPath, let observeAgent, _) = outcome
    else {
      return XCTFail("Expected the accepted default swarm receipt to remain inspectable")
    }
    XCTAssertNil(observeAgent, "a default swarm has no positional observer authority")
    XCTAssertEqual(launcher.requests().map(\.agents), [[]])

    let actions = DispatchPopover.receiptActions(
      runID: runID,
      reportPath: reportPath,
      observeAgent: observeAgent,
      runIsLaunched: true)
    XCTAssertNil(actions.observe, "no receipt or positional agent means no status action")
    XCTAssertEqual(actions.revealReportPath, "/tmp/reports/research-default-no-agent.md")

    XCTAssertEqual(
      DispatchPopover.resolvedPhase(for: outcome),
      .acceptedUnconfirmed(
        runID: "research-default-no-agent",
        reportPath: "/tmp/reports/research-default-no-agent.md",
        observeAgent: nil))
  }

  /// A rejected launch never started a run. Its receipt may still carry a run
  /// ID and a report the launcher wrote — the report is real and stays
  /// revealable — but "Check status" would point at a run that does not exist.
  @MainActor
  func testRejectedReceiptRevealsItsReportButOffersNoStatusCheck() {
    let rejected = AgentDispatchMetadata.parse(
      output: """
        run_id: work-rejected
        agent: codex
        report: /tmp/reports/work-rejected.md
        refused: workflow gate
        """,
      exitCode: 2)
    XCTAssertEqual(rejected.launchVerification, .rejected, "precondition")

    let phase = DispatchPopover.resolvedPhase(
      for: .rejected(
        message: rejected.statusLine,
        runID: rejected.runID,
        reportPath: rejected.reportPath,
        observeAgent: rejected.observeAgent))
    guard case .failed(_, let runID, let reportPath, let observeAgent) = phase else {
      return XCTFail("Expected a rejected outcome to render as the failed phase")
    }

    let actions = DispatchPopover.receiptActions(
      runID: runID,
      reportPath: reportPath,
      observeAgent: observeAgent,
      runIsLaunched: false)
    XCTAssertEqual(actions.revealReportPath, "/tmp/reports/work-rejected.md")
    XCTAssertNil(actions.observe, "a run that never started has no status to check")

    // The same identifiers on a launched run DO earn the status action — the
    // difference is the launch, not the receipt.
    XCTAssertNotNil(
      DispatchPopover.receiptActions(
        runID: runID,
        reportPath: reportPath,
        observeAgent: observeAgent,
        runIsLaunched: true
      ).observe)
  }

  // MARK: - Helpers

  @MainActor
  private func makeController(
    capabilities: WorkflowCapabilitiesProviding? = nil,
    launcherResult: AgentDispatchMetadata? = nil
  )
    -> (AppController, AppState, GatewayRecordingLauncher)
  {
    let appState = AppState()
    let launcher = GatewayRecordingLauncher(result: launcherResult)
    let controller = AppController(
      appState: appState,
      folderManager: .shared,
      documentStore: .shared,
      transcriptionService: TranscriptionService(cadenceCommitNanoseconds: 0),
      agentPromptLauncher: launcher,
      workflowCapabilitiesProvider: capabilities
        ?? FakeWorkflowCapabilitiesProvider(
          result: .failure(WorkflowCapabilitiesError.probeFailed("not probed in this test")))
    )
    return (controller, appState, launcher)
  }

  @MainActor
  private func waitForCapabilityState(
    _ controller: AppController, timeout: TimeInterval = 2
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      switch controller.workflowCapabilitiesState {
      case .loaded, .failed:
        return
      case .idle, .loading:
        try await Task.sleep(nanoseconds: 10_000_000)
      }
    }
    XCTFail("Timed out waiting for the capability probe to settle")
  }

  private func waitUntil(
    timeout: TimeInterval = 2,
    condition: @escaping @Sendable () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for condition")
  }
}

private final class GatewayRecordingLauncher: AgentPromptLaunching, @unchecked Sendable {
  struct Request: Equatable {
    let workflow: String
    let agents: [String]
    let payload: AgentDispatchPayload
    let workingDirectoryURL: URL
  }

  private let lock = NSLock()
  private let result: AgentDispatchMetadata?
  private var recordedRequests: [Request] = []

  init(result: AgentDispatchMetadata? = nil) {
    self.result = result
  }

  func dispatch(
    workflow: String,
    agents: [String],
    payload: AgentDispatchPayload,
    workingDirectoryURL: URL
  ) throws -> AgentDispatchMetadata {
    lock.lock()
    recordedRequests.append(
      Request(
        workflow: workflow,
        agents: agents,
        payload: payload,
        workingDirectoryURL: workingDirectoryURL.standardizedFileURL))
    lock.unlock()
    return result
      ?? AgentDispatchMetadata(
        runID: "gateway-test", reportPath: nil, exitCode: 0, output: "receipt",
        // Explicit: metadata built directly carries no spawn proof, so the
        // started-run path has to be asked for.
        launchVerification: .workerSpawnRecorded)
  }

  func requests() -> [Request] {
    lock.lock()
    defer { lock.unlock() }
    return recordedRequests
  }
}

/// Holds the launch open until released so the in-flight guard is observable
/// deterministically (no timing races).
private final class BlockingLauncher: AgentPromptLaunching, @unchecked Sendable {
  private let lock = NSLock()
  private let gate = DispatchSemaphore(value: 0)
  private var started = 0

  func dispatch(
    workflow: String,
    agents: [String],
    payload: AgentDispatchPayload,
    workingDirectoryURL: URL
  ) throws -> AgentDispatchMetadata {
    lock.lock()
    started += 1
    lock.unlock()
    gate.wait()
    return AgentDispatchMetadata(
      runID: "blocking-test", reportPath: nil, exitCode: 0, output: "receipt",
      launchVerification: .workerSpawnRecorded)
  }

  func startedCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return started
  }

  func release() {
    gate.signal()
  }
}
