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
      intent: intent, workflow: "review", agent: "grok", rootURL: chosenRoot)

    guard case .success = outcome else {
      return XCTFail("Expected confirmed dispatch to succeed")
    }
    XCTAssertEqual(
      launcher.requests(),
      [
        GatewayRecordingLauncher.Request(
          workflow: "review",
          agent: "grok",
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
        intent: intent, workflow: "review", agent: "codex", rootURL: rootURL)
    }
    try await waitUntil { launcher.startedCount() == 1 }

    let second = await controller.confirmDispatch(
      intent: intent, workflow: "review", agent: "codex", rootURL: rootURL)
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
      intent: intent, workflow: "review", agent: "codex",
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

  // MARK: - Helpers

  @MainActor
  private func makeController()
    -> (AppController, AppState, GatewayRecordingLauncher)
  {
    let appState = AppState()
    let launcher = GatewayRecordingLauncher()
    let controller = AppController(
      appState: appState,
      folderManager: .shared,
      documentStore: .shared,
      transcriptionService: TranscriptionService(cadenceCommitNanoseconds: 0),
      agentPromptLauncher: launcher
    )
    return (controller, appState, launcher)
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
    let agent: String
    let payload: AgentDispatchPayload
    let workingDirectoryURL: URL
  }

  private let lock = NSLock()
  private var recordedRequests: [Request] = []

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
    return AgentDispatchMetadata(
      runID: "gateway-test", reportPath: nil, exitCode: 0, output: "receipt")
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
    agent: String,
    payload: AgentDispatchPayload,
    workingDirectoryURL: URL
  ) throws -> AgentDispatchMetadata {
    lock.lock()
    started += 1
    lock.unlock()
    gate.wait()
    return AgentDispatchMetadata(
      runID: "blocking-test", reportPath: nil, exitCode: 0, output: "receipt")
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
