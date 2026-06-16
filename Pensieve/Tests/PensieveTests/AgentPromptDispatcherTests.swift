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

  func testBuildsArgumentsForPromptPayloads() {
    let arguments = VibecraftedAgentPromptLauncher.arguments(
      workflow: "workflow",
      agent: "codex",
      payload: .prompt("ship the proof")
    )

    XCTAssertEqual(arguments, ["workflow", "codex", "--prompt", "ship the proof"])
  }

  func testDispatchMetadataParsesRunIDReportPathAndStatusLineFromReceipt() {
    let metadata = AgentDispatchMetadata.parse(
      output: """
        warmup noise
        run_id: work-260615-123456
        Report path: /Users/maciejgad/.vibecrafted/artifacts/vetcoders/pensieve/reports/report.md
        tail noise
        """,
      exitCode: 0
    )

    XCTAssertEqual(metadata.runID, "work-260615-123456")
    XCTAssertEqual(
      metadata.reportPath,
      "/Users/maciejgad/.vibecrafted/artifacts/vetcoders/pensieve/reports/report.md")
    let expectedStatus =
      "Dispatch completed: work-260615-123456"
      + " | /Users/maciejgad/.vibecrafted/artifacts/vetcoders/pensieve/reports/report.md"
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
  func testDispatchOpenDocumentReturnsFailureWithoutSavedDocument() async {
    let appState = AppState()
    let launcher = RecordingAgentPromptLauncher()
    let controller = AppController(
      appState: appState,
      folderManager: .shared,
      documentStore: .shared,
      transcriptionService: TranscriptionService(cadenceCommitNanoseconds: 0),
      agentPromptLauncher: launcher
    )

    let outcome = await controller.dispatchOpenDocument(
      workflow: "workflow",
      agent: "codex",
      rootURL: URL(fileURLWithPath: "/tmp/pensieve-dispatch-root", isDirectory: true))

    guard case .failure(let message) = outcome else {
      return XCTFail("Expected unsaved documents to fail dispatch")
    }
    XCTAssertEqual(message, "Save the document before dispatching it to an agent.")
    XCTAssertTrue(launcher.requests().isEmpty)
  }

  @MainActor
  func testDispatchOpenDocumentReturnsSuccessOutcomeAndUpdatesStatus() async {
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

    let outcome = await controller.dispatchOpenDocument(
      workflow: "workflow",
      agent: "codex",
      rootURL: rootURL)

    guard case .success(let runID, let receivedReportPath, let statusLine) = outcome else {
      return XCTFail("Expected saved document dispatch to succeed")
    }
    XCTAssertEqual(runID, "work-260615-success")
    XCTAssertEqual(receivedReportPath, reportPath)
    let expectedStatusLine =
      "Dispatched pensieve-dispatch-note → workflow (codex) in pensieve-dispatch-root"
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
          agent: "codex",
          payload: .file(documentURL.path),
          workingDirectoryURL: rootURL)
      ])
  }

  @MainActor
  func testDispatchOpenDocumentReturnsFailureOutcomeForNonZeroLauncherExit() async {
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

    let outcome = await controller.dispatchOpenDocument(
      workflow: "workflow",
      agent: "codex",
      rootURL: rootURL)

    guard case .failure(let message) = outcome else {
      return XCTFail("Expected non-zero launcher exit to fail dispatch")
    }
    XCTAssertEqual(message, "Dispatch failed (exit 2)")
    XCTAssertEqual(appState.lastError, "Dispatch failed (exit 2)")
    XCTAssertEqual(service.dispatchStatus, "Dispatch failed (exit 2)")
    XCTAssertEqual(launcher.requests().map(\.payload), [.file(documentURL.path)])
  }
}

private final class RecordingAgentPromptLauncher: AgentPromptLaunching, @unchecked Sendable {
  struct Request: Equatable {
    let workflow: String
    let agent: String
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
    agent: String,
    payload: AgentDispatchPayload,
    workingDirectoryURL: URL
  ) throws -> AgentDispatchMetadata {
    lock.lock()
    recordedRequests.append(
      Request(
        workflow: workflow,
        agent: agent,
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
