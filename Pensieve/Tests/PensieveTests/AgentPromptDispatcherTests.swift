import Foundation
import XCTest

@testable import Pensieve

final class AgentPromptDispatcherTests: XCTestCase {
  func testExecutableCandidatesPreferOverrideThenEnvironmentIndependentUVEntrypoint() {
    let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    XCTAssertEqual(
      VibecraftedAgentPromptLauncher.executableCandidates(
        home: home, override: "/custom/vibecrafted"),
      [
        "/custom/vibecrafted",
        "/Users/tester/.local/share/uv/tools/vibecrafted/bin/vibecrafted",
        "/Users/tester/.local/bin/vibecrafted",
        "/Users/tester/.local/share/vibecrafted/tools/vibecrafted-current/scripts/vibecrafted",
      ])
  }

  func testLaunchEnvironmentPrependsAgentBinsToFinderPathWithoutDuplicates() {
    let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    let environment = VibecraftedAgentPromptLauncher.launchEnvironment(
      base: ["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "KEEP": "yes"],
      home: home)

    XCTAssertEqual(environment["KEEP"], "yes")
    XCTAssertEqual(
      environment["PATH"],
      [
        "/Users/tester/.local/bin",
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/Users/tester/.cargo/bin",
        "/Users/tester/.grok/bin",
        "/Users/tester/.vibecrafted/bin",
        "/usr/bin",
        "/bin",
      ].joined(separator: ":"))
  }

  func testRuntimeMetadataURLFollowsReceiptTranscriptPath() {
    let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    let url = VibecraftedAgentPromptLauncher.runtimeMetadataURL(
      runID: "impl-123",
      output: "transcript: /tmp/runtime/impl-123/transcript.log\n",
      home: home)

    XCTAssertEqual(url.path, "/tmp/runtime/impl-123/meta.json")
  }

  func testRuntimeMetadataURLFallbackRespectsVibecraftedHome() {
    let url = VibecraftedAgentPromptLauncher.runtimeMetadataURL(
      runID: "impl-456",
      output: "run_id: impl-456\n",
      home: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
      environment: ["VIBECRAFTED_HOME": "/var/tmp/custom-vibecrafted"])

    XCTAssertEqual(
      url.path,
      "/var/tmp/custom-vibecrafted/control_plane/runtime_runs/impl-456/meta.json")
  }

  func testWorkerSpawnRecordRequiresRecordedPositiveWorkerPID() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PensieveWorkerProofTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let metadataURL = directory.appendingPathComponent("meta.json")

    XCTAssertFalse(VibecraftedAgentPromptLauncher.workerSpawnRecorded(at: metadataURL))
    try Data(#"{"worker_pid":0}"#.utf8).write(to: metadataURL)
    XCTAssertFalse(VibecraftedAgentPromptLauncher.workerSpawnRecorded(at: metadataURL))
    try Data(#"{"worker_pid":12345}"#.utf8).write(to: metadataURL)
    XCTAssertTrue(VibecraftedAgentPromptLauncher.workerSpawnRecorded(at: metadataURL))
  }

  func testBuildsArgumentsForFilePayloads() {
    let arguments = VibecraftedAgentPromptLauncher.arguments(
      workflow: "review",
      agents: ["codex"],
      payload: .file("/x.md")
    )

    XCTAssertEqual(arguments, ["review", "codex", "--file", "/x.md"])
  }

  func testBuildsArgumentsForPromptPayloads() {
    let arguments = VibecraftedAgentPromptLauncher.arguments(
      workflow: "workflow",
      agents: ["codex"],
      payload: .prompt("ship the proof")
    )

    XCTAssertEqual(arguments, ["workflow", "codex", "--prompt", "ship the proof"])
  }

  func testBuildsSwarmArgumentsWithoutFabricatingAnAgent() {
    // A default swarm run launches the workflow with NO positional agent —
    // the CLI resolves its own configured members.
    XCTAssertEqual(
      VibecraftedAgentPromptLauncher.arguments(
        workflow: "research", agents: [], payload: .file("/x.md")),
      ["research", "--file", "/x.md"])
    // A chosen synthesizer is one positional agent, in CLI order.
    XCTAssertEqual(
      VibecraftedAgentPromptLauncher.arguments(
        workflow: "research", agents: ["grok"], payload: .prompt("dig in")),
      ["research", "grok", "--prompt", "dig in"])
  }

  func testDispatchMetadataParsesRunIDReportPathAndStatusLineFromReceipt() {
    let metadata = AgentDispatchMetadata.parse(
      output: """
        warmup noise
        run_id: work-260615-123456
        agent: swarm
        report: /Users/tester/.vibecrafted/artifacts/vetcoders/pensieve/output/report.md
        tail noise
        """,
      exitCode: 0
    )

    XCTAssertEqual(metadata.runID, "work-260615-123456")
    XCTAssertEqual(
      metadata.reportPath,
      "/Users/tester/.vibecrafted/artifacts/vetcoders/pensieve/output/report.md")
    XCTAssertEqual(metadata.observeAgent, "swarm")
    XCTAssertEqual(metadata.exitCode, 0)
    XCTAssertEqual(metadata.launchVerification, .acceptedUnconfirmed)
    let expectedStatus =
      "Run accepted (launch unconfirmed): work-260615-123456"
      + " | /Users/tester/.vibecrafted/artifacts/vetcoders/pensieve/output/report.md"
    XCTAssertEqual(
      metadata.statusLine,
      expectedStatus)
  }

  func testDispatchMetadataRejectsUnsafeObserveAgentFromReceipt() {
    let metadata = AgentDispatchMetadata.parse(
      output: """
        run_id: work-260810-unsafe
        agent: swarm;open-terminal
        report: /tmp/artifacts/report.md
        """,
      exitCode: 0)

    XCTAssertNil(metadata.observeAgent)
    XCTAssertEqual(metadata.runID, "work-260810-unsafe")
    XCTAssertEqual(metadata.reportPath, "/tmp/artifacts/report.md")
  }

  func testMissingWorkerSpawnRecordKeepsSuccessfulExitAndReceiptIdentifiers() {
    let parsed = AgentDispatchMetadata.parse(
      output: """
        run_id: impl-260810-123456-11111
        agent: swarm
        report: /tmp/artifacts/report.md
        """,
      exitCode: 0)

    let metadata = parsed.classified(workerSpawnRecorded: false)

    XCTAssertEqual(metadata.exitCode, 0)
    XCTAssertEqual(metadata.runID, "impl-260810-123456-11111")
    XCTAssertEqual(metadata.reportPath, "/tmp/artifacts/report.md")
    XCTAssertEqual(metadata.observeAgent, "swarm")
    XCTAssertEqual(metadata.launchVerification, .acceptedUnconfirmed)
    XCTAssertEqual(
      metadata.statusLine,
      "Run accepted (launch unconfirmed): impl-260810-123456-11111 | /tmp/artifacts/report.md")
    XCTAssertTrue(metadata.output.contains("detached run may still start or already be running"))
  }

  func testRecordedWorkerSpawnPromotesAcceptedReceiptWithoutClaimingLiveness() {
    let parsed = AgentDispatchMetadata.parse(
      output: "run_id: impl-260810-123456-22222\n",
      exitCode: 0)

    let metadata = parsed.classified(workerSpawnRecorded: true)

    XCTAssertEqual(metadata.exitCode, 0)
    XCTAssertEqual(metadata.launchVerification, .workerSpawnRecorded)
    XCTAssertEqual(metadata.statusLine, "Run started: impl-260810-123456-22222")
  }

  func testSuccessfulProcessWithoutRunIDIsRejectedWithoutInventingANonzeroExit() {
    let parsed = AgentDispatchMetadata.parse(output: "status: launching\n", exitCode: 0)

    let metadata = parsed.classified(workerSpawnRecorded: false)

    XCTAssertEqual(metadata.exitCode, 0)
    XCTAssertEqual(metadata.launchVerification, .rejected)
    XCTAssertNil(metadata.runID)
    XCTAssertEqual(
      metadata.statusLine,
      "Dispatch rejected: Vibecrafted exited successfully without a run ID.")
  }

  func testDispatchMetadataFailureStatusIncludesActionableLastOutputLine() {
    let metadata = AgentDispatchMetadata.parse(
      output: """
        run_id: work-failed
        report_path: /tmp/reports/failed.md
        Traceback (most recent call last):
        ImportError: cannot import name 'Self' from 'typing'
        """,
      exitCode: 42
    )

    XCTAssertEqual(metadata.runID, "work-failed")
    XCTAssertEqual(metadata.reportPath, "/tmp/reports/failed.md")
    XCTAssertEqual(metadata.launchVerification, .rejected)
    XCTAssertEqual(
      metadata.statusLine,
      "Dispatch failed (exit 42): ImportError: cannot import name 'Self' from 'typing'")
  }

  func testDispatchMetadataFailureStatusFallsBackWhenOutputIsEmpty() {
    let metadata = AgentDispatchMetadata.parse(output: " \n", exitCode: 42)
    XCTAssertEqual(metadata.statusLine, "Dispatch failed (exit 42)")
  }

  func testDispatchMetadataFailureStatusStripsANSIAndBoundsDetail() {
    let longDetail = "\u{001B}[31m" + String(repeating: "x", count: 400) + "\u{001B}[0m"
    let metadata = AgentDispatchMetadata.parse(output: longDetail, exitCode: 1)

    XCTAssertFalse(metadata.statusLine.contains("\u{001B}"))
    XCTAssertTrue(metadata.statusLine.hasPrefix("Dispatch failed (exit 1): "))
    XCTAssertTrue(metadata.statusLine.hasSuffix("…"))
    XCTAssertLessThanOrEqual(metadata.statusLine.count, 307)
  }

  @MainActor
  func testConfirmDispatchRefusesEmptyDraftWithoutLaunching() async {
    let appState = AppState()
    let launcher = RecordingAgentPromptLauncher()
    let controller = AppController(
      appState: appState,
      folderManager: .shared,
      documentStore: .shared,
      transcriptionService: TranscriptionService(cadenceCommitNanoseconds: 0),
      agentPromptLauncher: launcher
    )
    let emptyDraft = DispatchIntent(
      subject: .unsavedBuffer(title: "Untitled", text: "   \n"),
      workflow: "workflow",
      source: .toolbar)

    let outcome = await controller.confirmDispatch(
      intent: emptyDraft,
      workflow: "workflow",
      agents: ["codex"],
      rootURL: URL(fileURLWithPath: "/tmp/pensieve-dispatch-root", isDirectory: true))

    guard case .failure(let message) = outcome else {
      return XCTFail("Expected an empty draft to fail dispatch")
    }
    XCTAssertEqual(message, "There is nothing to dispatch — the document is empty.")
    XCTAssertTrue(launcher.requests().isEmpty)
  }

  @MainActor
  func testConfirmDispatchReturnsSuccessOutcomeAndUpdatesStatus() async {
    let documentURL = URL(fileURLWithPath: "/tmp/pensieve-dispatch-note.md").standardizedFileURL
    let rootURL = URL(fileURLWithPath: "/tmp/pensieve-dispatch-root", isDirectory: true)
      .standardizedFileURL
    let reportPath = "/tmp/reports/pensieve-dispatch.md"
    let appState = AppState()
    appState.documentSession = DocumentSession(
      document: DocumentRef(id: documentURL),
      text: "# Plan",
      isDirty: false)
    let service = TranscriptionService(cadenceCommitNanoseconds: 0)
    let launcher = RecordingAgentPromptLauncher(
      result: AgentDispatchMetadata(
        runID: "work-260615-success",
        reportPath: reportPath,
        exitCode: 0,
        output: "receipt",
        observeAgent: "codex"
      )
    )
    let controller = AppController(
      appState: appState,
      folderManager: .shared,
      documentStore: .shared,
      transcriptionService: service,
      agentPromptLauncher: launcher
    )

    let outcome = await controller.confirmDispatch(
      intent: DispatchIntent(
        subject: .savedDocument(documentURL), workflow: "workflow", source: .toolbar),
      workflow: "workflow",
      agents: ["codex"],
      rootURL: rootURL)

    guard
      case .success(let runID, let receivedReportPath, let observeAgent, let statusLine) = outcome
    else {
      return XCTFail("Expected saved document dispatch to succeed")
    }
    XCTAssertEqual(runID, "work-260615-success")
    XCTAssertEqual(receivedReportPath, reportPath)
    XCTAssertEqual(observeAgent, "codex")
    let expectedStatusLine =
      "Started pensieve-dispatch-note.md → workflow (codex) in pensieve-dispatch-root"
    XCTAssertEqual(statusLine, expectedStatusLine)
    XCTAssertNil(appState.lastError)
    XCTAssertEqual(
      service.dispatchStatus,
      "\(expectedStatusLine) · run: work-260615-success")
    XCTAssertEqual(
      launcher.requests(),
      [
        RecordingAgentPromptLauncher.Request(
          workflow: "workflow",
          agents: ["codex"],
          payload: .file(documentURL.path),
          workingDirectoryURL: rootURL)
      ])
  }

  @MainActor
  func testConfirmDispatchKeepsAcceptedUnconfirmedRunInspectable() async {
    let documentURL = URL(fileURLWithPath: "/tmp/pensieve-dispatch-unconfirmed.md")
      .standardizedFileURL
    let rootURL = URL(fileURLWithPath: "/tmp/pensieve-dispatch-root", isDirectory: true)
      .standardizedFileURL
    let reportPath = "/tmp/artifacts/pensieve-dispatch-unconfirmed.md"
    let appState = AppState()
    appState.documentSession = DocumentSession(
      document: DocumentRef(id: documentURL),
      text: "# Plan",
      isDirty: false)
    let service = TranscriptionService(cadenceCommitNanoseconds: 0)
    let launcher = RecordingAgentPromptLauncher(
      result: AgentDispatchMetadata(
        runID: "work-260810-unconfirmed",
        reportPath: reportPath,
        exitCode: 0,
        output: "accepted receipt",
        observeAgent: "codex",
        launchVerification: .acceptedUnconfirmed
      )
    )
    let controller = AppController(
      appState: appState,
      folderManager: .shared,
      documentStore: .shared,
      transcriptionService: service,
      agentPromptLauncher: launcher
    )

    let outcome = await controller.confirmDispatch(
      intent: DispatchIntent(
        subject: .savedDocument(documentURL), workflow: "workflow", source: .toolbar),
      workflow: "workflow",
      agents: ["codex"],
      rootURL: rootURL)

    guard
      case .acceptedUnconfirmed(
        let runID, let receivedReportPath, let observeAgent, let statusLine) = outcome
    else {
      return XCTFail("Expected a valid unconfirmed receipt to remain inspectable")
    }
    XCTAssertEqual(runID, "work-260810-unconfirmed")
    XCTAssertEqual(receivedReportPath, reportPath)
    XCTAssertEqual(observeAgent, "codex")
    XCTAssertEqual(
      statusLine,
      "Accepted pensieve-dispatch-unconfirmed.md → workflow (codex) in "
        + "pensieve-dispatch-root; worker launch unconfirmed")
    XCTAssertNil(appState.lastError)
    XCTAssertEqual(
      service.dispatchStatus,
      "\(statusLine) · run: work-260810-unconfirmed")
  }

  @MainActor
  func testConfirmDispatchReturnsFailureOutcomeForNonZeroLauncherExit() async {
    let documentURL = URL(fileURLWithPath: "/tmp/pensieve-dispatch-failure.md").standardizedFileURL
    let rootURL = URL(fileURLWithPath: "/tmp/pensieve-dispatch-root", isDirectory: true)
      .standardizedFileURL
    let appState = AppState()
    appState.documentSession = DocumentSession(
      document: DocumentRef(id: documentURL),
      text: "# Plan",
      isDirty: false)
    let service = TranscriptionService(cadenceCommitNanoseconds: 0)
    let launcher = RecordingAgentPromptLauncher(
      result: AgentDispatchMetadata(
        runID: "work-260615-failed",
        reportPath: "/tmp/reports/failed.md",
        exitCode: 2,
        output: "failed receipt",
        observeAgent: "codex"
      )
    )
    let controller = AppController(
      appState: appState,
      folderManager: .shared,
      documentStore: .shared,
      transcriptionService: service,
      agentPromptLauncher: launcher
    )

    let outcome = await controller.confirmDispatch(
      intent: DispatchIntent(
        subject: .savedDocument(documentURL), workflow: "workflow", source: .toolbar),
      workflow: "workflow",
      agents: ["codex"],
      rootURL: rootURL)

    guard
      case .rejected(let message, let runID, let receivedReportPath, let observeAgent) = outcome
    else {
      return XCTFail("Expected non-zero launcher exit to fail dispatch")
    }
    XCTAssertEqual(message, "Dispatch failed (exit 2): failed receipt")
    XCTAssertEqual(runID, "work-260615-failed")
    XCTAssertEqual(receivedReportPath, "/tmp/reports/failed.md")
    XCTAssertEqual(observeAgent, "codex")
    XCTAssertEqual(
      DispatchPopover.resolvedPhase(for: outcome),
      .failed(
        "Dispatch failed (exit 2): failed receipt",
        runID: "work-260615-failed",
        reportPath: "/tmp/reports/failed.md",
        observeAgent: "codex"))
    XCTAssertEqual(appState.lastError, "Dispatch failed (exit 2): failed receipt")
    XCTAssertEqual(service.dispatchStatus, "Dispatch failed (exit 2): failed receipt")
    XCTAssertEqual(launcher.requests().map(\.payload), [.file(documentURL.path)])
  }

  // MARK: - Current-document gateway request (Agents menu / toolbar routes)

  @MainActor
  func testRequestCurrentDocumentDispatchRefusesWithoutEditableBuffer() {
    let appState = AppState()
    let launcher = RecordingAgentPromptLauncher()
    let controller = AppController(
      appState: appState,
      folderManager: .shared,
      documentStore: .shared,
      transcriptionService: TranscriptionService(cadenceCommitNanoseconds: 0),
      agentPromptLauncher: launcher
    )

    // The Agents menu items disable on this exact predicate; the request must
    // refuse on the same state so a stale menu can never surface a dead sheet.
    XCTAssertFalse(appState.documentHasEditableBuffer)
    XCTAssertFalse(
      controller.requestCurrentDocumentDispatch(workflow: "review", source: .agentsMenu))
    XCTAssertEqual(
      appState.lastError, "Open an editable document before dispatching to an agent.")
    XCTAssertNil(appState.pendingDispatchIntent)
    XCTAssertTrue(launcher.requests().isEmpty)
  }

  @MainActor
  func testRequestThenConfirmRoutesActiveFileAsFilePayload() async {
    let documentURL = URL(fileURLWithPath: "/tmp/pensieve-current-doc.md").standardizedFileURL
    let workspaceRoot = URL(fileURLWithPath: "/tmp/pensieve-dispatch-root", isDirectory: true)
      .standardizedFileURL
    let appState = AppState()
    appState.documentSession = DocumentSession(
      document: DocumentRef(id: documentURL),
      text: "# Plan",
      isDirty: false)
    let service = TranscriptionService(cadenceCommitNanoseconds: 0)
    let launcher = RecordingAgentPromptLauncher(
      result: AgentDispatchMetadata(
        runID: "work-current-doc",
        reportPath: nil,
        exitCode: 0,
        output: "receipt"
      )
    )
    let controller = AppController(
      appState: appState,
      folderManager: .shared,
      documentStore: .shared,
      transcriptionService: service,
      agentPromptLauncher: launcher,
      agentWorkspaceRoot: workspaceRoot
    )

    // The menu click only raises the intent — nothing may launch yet.
    XCTAssertTrue(appState.documentHasEditableBuffer)
    XCTAssertTrue(
      controller.requestCurrentDocumentDispatch(workflow: "review", source: .agentsMenu))
    XCTAssertTrue(launcher.requests().isEmpty)
    guard let intent = appState.pendingDispatchIntent else {
      return XCTFail("Expected the request to raise a pending dispatch intent")
    }
    XCTAssertEqual(intent.subject, .savedDocument(documentURL))
    XCTAssertEqual(intent.workflow, "review")
    XCTAssertEqual(intent.source, .agentsMenu)

    // Only the sheet's confirmation reaches the launcher.
    let outcome = await controller.confirmDispatch(
      intent: intent,
      workflow: intent.workflow,
      agents: [controller.defaultAgent],
      rootURL: controller.defaultDispatchRoot())
    guard case .success = outcome else {
      return XCTFail("Expected confirmed dispatch to succeed")
    }
    XCTAssertEqual(
      launcher.requests(),
      [
        RecordingAgentPromptLauncher.Request(
          workflow: "review",
          agents: [controller.defaultAgent],
          payload: .file(documentURL.path),
          workingDirectoryURL: workspaceRoot)
      ])
  }

  @MainActor
  func testRequestThenConfirmRoutesUntitledBufferAsPromptPayload() async {
    let workspaceRoot = URL(fileURLWithPath: "/tmp/pensieve-dispatch-root", isDirectory: true)
      .standardizedFileURL
    let appState = AppState()
    appState.documentSession.createUntitled(title: "Scratch.md")
    appState.documentSession.text = "ship the plan"
    let service = TranscriptionService(cadenceCommitNanoseconds: 0)
    let launcher = RecordingAgentPromptLauncher(
      result: AgentDispatchMetadata(
        runID: "work-untitled-doc",
        reportPath: nil,
        exitCode: 0,
        output: "receipt"
      )
    )
    let controller = AppController(
      appState: appState,
      folderManager: .shared,
      documentStore: .shared,
      transcriptionService: service,
      agentPromptLauncher: launcher,
      agentWorkspaceRoot: workspaceRoot
    )

    XCTAssertTrue(appState.documentHasEditableBuffer)
    XCTAssertTrue(
      controller.requestCurrentDocumentDispatch(workflow: "workflow", source: .agentsWorkflowMenu))
    XCTAssertTrue(launcher.requests().isEmpty)
    guard let intent = appState.pendingDispatchIntent else {
      return XCTFail("Expected the request to raise a pending dispatch intent")
    }
    XCTAssertEqual(
      intent.subject, .unsavedBuffer(title: "Scratch.md", text: "ship the plan"))

    let outcome = await controller.confirmDispatch(
      intent: intent,
      workflow: intent.workflow,
      agents: [controller.defaultAgent],
      rootURL: controller.defaultDispatchRoot())
    guard case .success = outcome else {
      return XCTFail("Expected confirmed dispatch to succeed")
    }
    XCTAssertEqual(
      launcher.requests(),
      [
        RecordingAgentPromptLauncher.Request(
          workflow: "workflow",
          agents: [controller.defaultAgent],
          payload: .prompt("ship the plan"),
          workingDirectoryURL: workspaceRoot)
      ])
  }
}

private final class RecordingAgentPromptLauncher: AgentPromptLaunching, @unchecked Sendable {
  struct Request: Equatable {
    let workflow: String
    let agents: [String]
    let payload: AgentDispatchPayload
    let workingDirectoryURL: URL
  }

  private let lock = NSLock()
  private let result: AgentDispatchMetadata
  private var recordedRequests: [Request] = []

  init(
    result: AgentDispatchMetadata = AgentDispatchMetadata(
      runID: nil,
      reportPath: nil,
      exitCode: 0,
      output: ""
    )
  ) {
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
  }

  func requests() -> [Request] {
    lock.lock()
    defer { lock.unlock() }
    return recordedRequests
  }
}
