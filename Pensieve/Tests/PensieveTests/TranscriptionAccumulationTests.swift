import AppKit
import XCTest

@testable import Pensieve

@MainActor
final class TranscriptionAccumulationTests: XCTestCase {
  func testPreviewTailReplacesWithoutDroppingCommittedText() {
    let service = TranscriptionService()

    service.receivePreview("opening thought")
    XCTAssertEqual(service.rendered, "opening thought")

    service.receiveFinal("opening thought", language: "en")
    XCTAssertEqual(service.committed, "opening thought")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "opening thought")

    service.receivePreview("second utterance")
    XCTAssertEqual(service.rendered, "opening thought\nsecond utterance")

    service.receivePreview("second utterance extended")
    XCTAssertEqual(service.committed, "opening thought")
    XCTAssertEqual(service.preview, "second utterance extended")
    XCTAssertEqual(service.rendered, "opening thought\nsecond utterance extended")
  }

  func testSparseFinalContinuousSpeechCadenceAccumulatesEveryFinal() {
    let service = TranscriptionService()

    service.receivePreview("monologue part one")
    service.receivePreview("monologue part one growing")
    service.receivePreview("monologue part one growing still")
    service.receiveFinal("monologue part one growing still", language: "en")

    service.receivePreview("monologue part two")
    service.receivePreview("monologue part two keeps going")
    service.receiveFinal("monologue part two keeps going", language: "en")

    XCTAssertEqual(
      service.committed,
      """
      monologue part one growing still
      monologue part two keeps going
      """
    )
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, service.committed)
    XCTAssertEqual(service.lastLanguage, "en")
  }

  func testCadenceCommitPromotesSparsePreviewWithoutDuplicatingCumulativeEngineText() {
    let service = TranscriptionService(cadenceCommitNanoseconds: 0)

    service.receivePreview("alpha")
    service.commitActivePreviewForCadence()

    XCTAssertEqual(service.committed, "alpha")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "alpha")

    service.receivePreview("alpha beta")
    XCTAssertEqual(service.rendered, "alpha\nbeta")
    service.commitActivePreviewForCadence()

    XCTAssertEqual(service.committed, "alpha\nbeta")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "alpha\nbeta")

    service.receivePreview("alpha beta gamma")
    XCTAssertEqual(service.rendered, "alpha\nbeta\ngamma")
    service.receiveFinal("alpha beta gamma", language: "en")

    XCTAssertEqual(service.committed, "alpha\nbeta\ngamma")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "alpha\nbeta\ngamma")
  }

  func testCadenceCommitLeavesTailPreviewCadenceGrowing() {
    let service = TranscriptionService(cadenceCommitNanoseconds: 0)

    service.receivePreview("alpha")
    service.commitActivePreviewForCadence()
    service.receivePreview("beta")
    service.commitActivePreviewForCadence()
    service.receivePreview("gamma")

    XCTAssertEqual(service.committed, "alpha\nbeta")
    XCTAssertEqual(service.preview, "gamma")
    XCTAssertEqual(service.rendered, "alpha\nbeta\ngamma")
  }

  @MainActor
  func testStartRecordingLoadsModelOffMainAndEntersRecordingState() async {
    let engine = MockVistaAutocompleteEngine(modelLoaded: false, initModelHandler: {})
    let service = TranscriptionService(engine: engine, cadenceCommitNanoseconds: 0)

    service.startRecording()

    XCTAssertTrue(service.isPreparingRecording, "model load happens in the background")
    XCTAssertFalse(service.isRecording)

    for _ in 0..<200 where !service.isRecording {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertTrue(service.isRecording)
    XCTAssertFalse(service.isPreparingRecording)
    XCTAssertNil(service.lastError)
  }

  @MainActor
  func testTeardownDuringPreparationNeverStartsRecording() async {
    let modelLoadStarted = expectation(description: "model load entered")
    let releaseModelLoad = DispatchSemaphore(value: 0)
    let recordingStarted = LockedFlag()
    let engine = MockVistaAutocompleteEngine(
      modelLoaded: false,
      initModelHandler: {
        modelLoadStarted.fulfill()
        releaseModelLoad.wait()
      },
      startRecordingHandler: { _ in recordingStarted.set() }
    )

    var service: TranscriptionService? = TranscriptionService(
      engine: engine, cadenceCommitNanoseconds: 0)
    service?.startRecording()
    await fulfillment(of: [modelLoadStarted], timeout: 2)

    // Tear the owner down while the detached model load is still running;
    // deinit cancels the preparation, which must reach the detached task.
    service = nil
    releaseModelLoad.signal()

    // Give the detached task time to run past the cancellation check.
    try? await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertFalse(
      recordingStarted.isSet,
      "teardown during preparation must never start the microphone")
  }

  @MainActor
  func testStartRecordingSurfacesModelInitFailureWithoutEnteringRecording() async {
    struct ModelInitBoom: Error, LocalizedError {
      var errorDescription: String? { "model boom" }
    }
    let engine = MockVistaAutocompleteEngine(
      modelLoaded: false,
      initModelHandler: { throw ModelInitBoom() })
    let service = TranscriptionService(engine: engine, cadenceCommitNanoseconds: 0)

    service.startRecording()
    for _ in 0..<200 where service.lastError == nil {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(service.lastError, "model boom")
    XCTAssertFalse(service.isRecording)
    XCTAssertFalse(service.isPreparingRecording)
  }

  func testFormatCompositionUsesVistaEngineFormatterWhenAvailable() async {
    let engine = MockVistaAutocompleteEngine(
      formattingAvailable: true,
      formattingHandler: { text, assistive in
        XCTAssertFalse(assistive)
        return "formatted: \(text)"
      }
    )
    let service = TranscriptionService(engine: engine, cadenceCommitNanoseconds: 0)

    service.receivePreview("raw transcript")
    let formatted = await service.formatComposition()

    XCTAssertEqual(formatted, "formatted: raw transcript")
    XCTAssertEqual(service.committed, "formatted: raw transcript")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "formatted: raw transcript")
    XCTAssertFalse(service.isFormatting)
    XCTAssertNil(service.lastError)
  }

  func testFormatCompositionUsesKurierAssistiveFormatterWhenSelected() async {
    let engine = MockVistaAutocompleteEngine(
      formattingAvailable: true,
      formattingHandler: { text, assistive in
        XCTAssertTrue(assistive)
        return "kurier: \(text)"
      }
    )
    let service = TranscriptionService(engine: engine, cadenceCommitNanoseconds: 0)

    service.receivePreview("chaotic spoken mission")
    let formatted = await service.formatComposition(mode: .kurier)

    XCTAssertEqual(formatted, "kurier: chaotic spoken mission")
    XCTAssertEqual(service.committed, "kurier: chaotic spoken mission")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "kurier: chaotic spoken mission")
    XCTAssertFalse(service.isFormatting)
    XCTAssertNil(service.lastError)
  }

  func testFormatCompositionFallsBackToRawTextWhenFormatterUnavailable() async {
    let engine = MockVistaAutocompleteEngine(formattingAvailable: false)
    let service = TranscriptionService(engine: engine, cadenceCommitNanoseconds: 0)

    service.receivePreview("raw transcript")
    let formatted = await service.formatComposition()

    XCTAssertEqual(formatted, "raw transcript")
    XCTAssertEqual(service.committed, "")
    XCTAssertEqual(service.preview, "raw transcript")
    XCTAssertEqual(service.rendered, "raw transcript")
    XCTAssertFalse(service.isFormatting)
    XCTAssertNil(service.lastError)
  }

  func testMarkdownTextViewInsertsSentTranscriptionAtCaret() {
    let surface = MarkdownEditorSurface(text: "hello world", fontSize: 14)
    surface.textView.setSelectedRange(NSRange(location: 5, length: 0))

    XCTAssertTrue(surface.textView.insertTextAtSelection(" tafla"))
    XCTAssertEqual(surface.textStorage.string, "hello tafla world")
    XCTAssertEqual(surface.textView.selectedRange(), NSRange(location: 11, length: 0))
  }

  func testAppControllerSendsCompositionToProvidedActiveEditorAndClearsTafla() {
    let appState = AppState()
    appState.documentSession.createUntitled()
    let service = TranscriptionService(cadenceCommitNanoseconds: 0)
    let controller = AppController(
      appState: appState,
      folderManager: .shared,
      documentStore: .shared,
      transcriptionService: service
    )
    let surface = MarkdownEditorSurface(text: "target", fontSize: 14)
    surface.textView.setSelectedRange(NSRange(location: 6, length: 0))

    service.receiveFinal("tafla text", language: "en")

    XCTAssertTrue(controller.sendTranscriptionToActiveEditor(activeTextView: surface.textView))
    XCTAssertEqual(surface.textStorage.string, "targettafla text")
    XCTAssertEqual(service.rendered, "")
    XCTAssertNil(appState.lastError)
  }

  func testAppControllerRoutesEditorTargetWithoutLaunchingAgent() {
    let appState = AppState()
    appState.documentSession.createUntitled()
    let service = TranscriptionService(cadenceCommitNanoseconds: 0)
    let launcher = MockAgentPromptLauncher()
    let controller = AppController(
      appState: appState,
      folderManager: .shared,
      documentStore: .shared,
      transcriptionService: service,
      agentPromptLauncher: launcher
    )
    let surface = MarkdownEditorSurface(text: "target", fontSize: 14)
    surface.textView.setSelectedRange(NSRange(location: 6, length: 0))

    service.receiveFinal("editor route", language: "en")

    XCTAssertTrue(controller.sendTranscription(target: .editor, activeTextView: surface.textView))
    XCTAssertEqual(surface.textStorage.string, "targeteditor route")
    XCTAssertEqual(service.rendered, "")
    XCTAssertTrue(launcher.dispatchedPrompts().isEmpty)
  }

  func testAppControllerRoutesAgentTargetThroughLauncherWithoutRealDispatch() async {
    let appState = AppState()
    let service = TranscriptionService(cadenceCommitNanoseconds: 0)
    let reportPath =
      "/Users/maciejgad/.vibecrafted/artifacts/vetcoders/pensieve/2026_0609/reports/test.md"
    let launcher = MockAgentPromptLauncher(
      result: AgentDispatchMetadata.parse(
        output: """
          run_id: just-test-123
          Report path: \(reportPath)
          """,
        exitCode: 0
      )
    )
    let workspaceRoot = URL(fileURLWithPath: "/tmp/pensieve-agent-root")
    let controller = AppController(
      appState: appState,
      folderManager: .shared,
      documentStore: .shared,
      transcriptionService: service,
      agentPromptLauncher: launcher,
      agentWorkspaceRoot: workspaceRoot
    )

    service.receiveFinal("agent ready prompt", language: "en")

    XCTAssertTrue(controller.sendTranscription(target: .agent))
    XCTAssertEqual(service.dispatchStatus, "Dispatching to agent...")
    await waitForDispatchStatus(service, containing: "just-test-123")

    XCTAssertEqual(launcher.dispatchedPrompts(), ["agent ready prompt"])
    XCTAssertEqual(launcher.workingDirectoryURLs(), [workspaceRoot])
    XCTAssertEqual(service.rendered, "")
    XCTAssertEqual(service.dispatchStatus, "Dispatch completed: just-test-123 | \(reportPath)")
  }

  func testVistaEventListenerCallbacksMarshalIntoAccumulationState() async {
    let service = TranscriptionService()

    service.onTranscriptionPreview(text: "preview window")
    await Task.yield()
    XCTAssertEqual(service.rendered, "preview window")

    service.onTranscriptionPreview(text: "preview window rewritten")
    service.onTranscriptionFinal(text: "preview window rewritten", language: "en")
    await Task.yield()
    await Task.yield()

    XCTAssertEqual(service.committed, "preview window rewritten")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "preview window rewritten")
  }

  func testEmptyFinalClearsPreviewWithoutCommittingBlankUtterance() {
    let service = TranscriptionService()

    service.receivePreview("draft tail")
    service.receiveFinal("  \n", language: "en")

    XCTAssertEqual(service.committed, "")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "")
  }

  func testFinalUtterancesAccumulateInArrivalOrderWithTrimmedBoundaries() {
    let service = TranscriptionService()

    service.receiveFinal(" first utterance\n", language: "en")
    service.receiveFinal("\tsecond utterance", language: "pl")
    service.receiveFinal("third utterance  ", language: "de")

    XCTAssertEqual(
      service.committed,
      """
      first utterance
      second utterance
      third utterance
      """
    )
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, service.committed)
    XCTAssertEqual(service.lastLanguage, "de")
  }

  func testFinalFlushReplacesPreviewTailAndClearsBuffer() {
    let service = TranscriptionService()

    service.receivePreview("draft phrase")
    XCTAssertEqual(service.rendered, "draft phrase")

    service.receiveFinal("confirmed phrase", language: "en")

    XCTAssertEqual(service.committed, "confirmed phrase")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "confirmed phrase")
  }

  func testResetTranscriptClearsBuffersAndAllowsFreshAccumulation() {
    let service = TranscriptionService()

    service.receiveFinal("stale utterance", language: "en")
    service.receivePreview("stale preview")
    service.resetTranscript()

    XCTAssertEqual(service.committed, "")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "")
    XCTAssertNil(service.lastLanguage)
    XCTAssertNil(service.lastError)

    service.receivePreview("fresh preview")
    service.receiveFinal("fresh final", language: "es")

    XCTAssertEqual(service.committed, "fresh final")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "fresh final")
    XCTAssertEqual(service.lastLanguage, "es")
  }

  func testBlankPreviewAndBlankFinalKeepCommittedTextStable() {
    let service = TranscriptionService()

    service.receiveFinal("kept utterance", language: "en")
    service.receivePreview("")
    service.receiveFinal("", language: "en")

    XCTAssertEqual(service.committed, "kept utterance")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "kept utterance")
    XCTAssertEqual(service.lastLanguage, "en")
  }

  private func waitForDispatchStatus(
    _ service: TranscriptionService,
    containing needle: String,
    timeout: TimeInterval = 1.0
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if service.dispatchStatus?.contains(needle) == true {
        return
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for dispatch status containing \(needle)")
  }
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }

  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

private final class MockAgentPromptLauncher: AgentPromptLaunching, @unchecked Sendable {
  private let lock = NSLock()
  private let result: AgentDispatchMetadata
  private var prompts: [String] = []
  private var directories: [URL] = []

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

  func dispatch(prompt: String, workingDirectoryURL: URL) throws -> AgentDispatchMetadata {
    lock.lock()
    prompts.append(prompt)
    directories.append(workingDirectoryURL)
    lock.unlock()
    return result
  }

  func dispatchedPrompts() -> [String] {
    lock.lock()
    let snapshot = prompts
    lock.unlock()
    return snapshot
  }

  func workingDirectoryURLs() -> [URL] {
    lock.lock()
    let snapshot = directories
    lock.unlock()
    return snapshot
  }
}
