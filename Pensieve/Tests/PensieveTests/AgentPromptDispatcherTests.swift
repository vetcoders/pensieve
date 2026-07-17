import Foundation
import XCTest

@testable import Pensieve

final class AgentPromptDispatcherTests: XCTestCase {
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
        Report path: /Users/tester/.vibecrafted/artifacts/vetcoders/pensieve/reports/report.md
        tail noise
        """,
      exitCode: 0
    )

    XCTAssertEqual(metadata.runID, "work-260615-123456")
    XCTAssertEqual(
      metadata.reportPath,
      "/Users/tester/.vibecrafted/artifacts/vetcoders/pensieve/reports/report.md")
    let expectedStatus =
      "Dispatch completed: work-260615-123456"
      + " | /Users/tester/.vibecrafted/artifacts/vetcoders/pensieve/reports/report.md"
    XCTAssertEqual(
      metadata.statusLine,
      expectedStatus)
  }

  func testDispatchMetadataFailureStatusIgnoresSuccessfulReceiptFields() {
    let metadata = AgentDispatchMetadata.parse(
      output: """
        run_id: work-failed
        report_path: /tmp/reports/failed.md
        """,
      exitCode: 42
    )

    XCTAssertEqual(metadata.runID, "work-failed")
    XCTAssertEqual(metadata.reportPath, "/tmp/reports/failed.md")
    XCTAssertEqual(metadata.statusLine, "Dispatch failed (exit 42)")
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
        output: "receipt"
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

    guard case .success(let runID, let receivedReportPath, let statusLine) = outcome else {
      return XCTFail("Expected saved document dispatch to succeed")
    }
    XCTAssertEqual(runID, "work-260615-success")
    XCTAssertEqual(receivedReportPath, reportPath)
    let expectedStatusLine =
      "Dispatched pensieve-dispatch-note.md → workflow (codex) in pensieve-dispatch-root"
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
        output: "failed receipt"
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

    guard case .failure(let message) = outcome else {
      return XCTFail("Expected non-zero launcher exit to fail dispatch")
    }
    XCTAssertEqual(message, "Dispatch failed (exit 2)")
    XCTAssertEqual(appState.lastError, "Dispatch failed (exit 2)")
    XCTAssertEqual(service.dispatchStatus, "Dispatch failed (exit 2)")
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
