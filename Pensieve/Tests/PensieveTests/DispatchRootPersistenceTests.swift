import Foundation
import XCTest

@testable import Pensieve

final class DispatchRootPersistenceTests: XCTestCase {
  private var temporaryRoot: URL!
  private var defaultsSuites: [String] = []

  override func setUpWithError() throws {
    temporaryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveDispatchRootTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: temporaryRoot, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    for suiteName in defaultsSuites {
      UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
    try? FileManager.default.removeItem(at: temporaryRoot)
  }

  @MainActor
  func testChosenRootPersistsImmediatelyAcrossStoreReconstruction() throws {
    let defaults = try makeDefaults()
    let chosenRoot = try makeDirectory("chosen/../chosen")
    let workspaceFallback = try makeDirectory("workspace")
    let homeFallback = try makeDirectory("home")

    let firstStore = WorkspaceStore(defaults: defaults)
    XCTAssertTrue(firstStore.rememberDispatchRoot(chosenRoot))

    // No dispatch occurs between choosing and reconstructing the preference
    // owner: closing the sheet or relaunching must still retain the choice.
    let relaunchedStore = WorkspaceStore(defaults: defaults)
    XCTAssertEqual(
      relaunchedStore.resolveDispatchRoot(
        workspaceRoot: workspaceFallback,
        documentURL: nil,
        homeDirectory: homeFallback),
      chosenRoot.standardizedFileURL)
  }

  @MainActor
  func testDeletedOrReplacedRememberedRootFallsBackWithoutCrashing() throws {
    let defaults = try makeDefaults()
    let rememberedRoot = try makeDirectory("remembered")
    let workspaceFallback = try makeDirectory("workspace")
    let documentDirectory = try makeDirectory("document")
    let documentURL = documentDirectory.appendingPathComponent("note.md")
    let homeFallback = try makeDirectory("home")
    let store = WorkspaceStore(defaults: defaults)
    XCTAssertTrue(store.rememberDispatchRoot(rememberedRoot))

    try FileManager.default.removeItem(at: rememberedRoot)
    XCTAssertEqual(
      store.resolveDispatchRoot(
        workspaceRoot: workspaceFallback,
        documentURL: documentURL,
        homeDirectory: homeFallback),
      workspaceFallback.standardizedFileURL)

    try Data("not a directory".utf8).write(to: rememberedRoot)
    XCTAssertEqual(
      store.resolveDispatchRoot(
        workspaceRoot: nil,
        documentURL: documentURL,
        homeDirectory: homeFallback),
      documentDirectory.standardizedFileURL)
  }

  @MainActor
  func testResolverPrecedenceCoversEveryFallbackBranch() throws {
    let explicitOverride = try makeDirectory("explicit")
    let rememberedRoot = try makeDirectory("remembered")
    let workspaceRoot = try makeDirectory("workspace")
    let documentDirectory = try makeDirectory("document")
    let documentURL = documentDirectory.appendingPathComponent("note.md")
    let homeDirectory = try makeDirectory("home")

    let rememberedStore = WorkspaceStore(defaults: try makeDefaults())
    XCTAssertTrue(rememberedStore.rememberDispatchRoot(rememberedRoot))
    XCTAssertEqual(
      rememberedStore.resolveDispatchRoot(
        explicitOverride: explicitOverride,
        workspaceRoot: workspaceRoot,
        documentURL: documentURL,
        homeDirectory: homeDirectory),
      explicitOverride.standardizedFileURL)
    XCTAssertEqual(
      rememberedStore.resolveDispatchRoot(
        workspaceRoot: workspaceRoot,
        documentURL: documentURL,
        homeDirectory: homeDirectory),
      rememberedRoot.standardizedFileURL)

    let fallbackStore = WorkspaceStore(defaults: try makeDefaults())
    XCTAssertEqual(
      fallbackStore.resolveDispatchRoot(
        workspaceRoot: workspaceRoot,
        documentURL: documentURL,
        homeDirectory: homeDirectory),
      workspaceRoot.standardizedFileURL)
    XCTAssertEqual(
      fallbackStore.resolveDispatchRoot(
        workspaceRoot: nil,
        documentURL: documentURL,
        homeDirectory: homeDirectory),
      documentDirectory.standardizedFileURL)
    XCTAssertEqual(
      fallbackStore.resolveDispatchRoot(
        workspaceRoot: nil,
        documentURL: nil,
        homeDirectory: homeDirectory),
      homeDirectory.standardizedFileURL)
  }

  @MainActor
  func testInjectedAgentWorkspaceRootOverridesPersistedPreference() async throws {
    let defaults = try makeDefaults()
    let persistedRoot = try makeDirectory("persisted")
    let injectedRoot = try makeDirectory("injected")
    let documentURL = temporaryRoot.appendingPathComponent("plan.md").standardizedFileURL
    let appState = AppState(defaults: defaults)
    XCTAssertTrue(appState.rememberDispatchRoot(persistedRoot))
    appState.documentSession = DocumentSession(
      document: DocumentRef(id: documentURL),
      text: "# Plan",
      isDirty: false)
    let launcher = DispatchRootRecordingLauncher()
    let service = TranscriptionService(cadenceCommitNanoseconds: 0)
    let controller = AppController(
      appState: appState,
      folderManager: .shared,
      documentStore: .shared,
      transcriptionService: service,
      agentPromptLauncher: launcher,
      agentWorkspaceRoot: injectedRoot)

    // The injected override must reach the gateway's default root and, once
    // the sheet confirms with it, the launcher receipt exactly.
    XCTAssertTrue(
      controller.requestCurrentDocumentDispatch(workflow: "review", source: .agentsMenu))
    let intent = try XCTUnwrap(appState.pendingDispatchIntent)
    XCTAssertEqual(controller.defaultDispatchRoot(), injectedRoot.standardizedFileURL)

    let outcome = await controller.confirmDispatch(
      intent: intent,
      workflow: intent.workflow,
      agent: "codex",
      rootURL: controller.defaultDispatchRoot())
    guard case .success = outcome else {
      return XCTFail("Expected confirmed dispatch to succeed")
    }
    XCTAssertEqual(launcher.workingDirectories(), [injectedRoot.standardizedFileURL])
  }

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "Pensieve.DispatchRootPersistenceTests.\(UUID().uuidString)"
    defaultsSuites.append(suiteName)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func makeDirectory(_ relativePath: String) throws -> URL {
    let url = temporaryRoot.appendingPathComponent(relativePath, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func waitUntil(
    timeout: TimeInterval = 1,
    condition: @escaping @Sendable () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for dispatch")
  }
}

private final class DispatchRootRecordingLauncher: AgentPromptLaunching, @unchecked Sendable {
  private let lock = NSLock()
  private var directories: [URL] = []

  func dispatch(
    workflow: String,
    agent: String,
    payload: AgentDispatchPayload,
    workingDirectoryURL: URL
  ) throws -> AgentDispatchMetadata {
    lock.lock()
    directories.append(workingDirectoryURL.standardizedFileURL)
    lock.unlock()
    return AgentDispatchMetadata(
      runID: "dispatch-root-test",
      reportPath: nil,
      exitCode: 0,
      output: "receipt")
  }

  func workingDirectories() -> [URL] {
    lock.lock()
    defer { lock.unlock() }
    return directories
  }
}
