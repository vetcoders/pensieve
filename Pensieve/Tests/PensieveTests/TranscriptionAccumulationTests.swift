import AppKit
import XCTest

@testable import Pensieve

@MainActor
final class TranscriptionAccumulationTests: XCTestCase {
  func testDictationOutputStylesDescribeFormattingInsteadOfPretendingToBeLanguages() {
    XCTAssertEqual(TranscriptionFormatMode.cleanUp.title, "Clean Up")
    XCTAssertEqual(TranscriptionFormatMode.writingAssistant.title, "Writing Assistant")
    XCTAssertFalse(TranscriptionFormatMode.cleanUp.assistive)
    XCTAssertTrue(TranscriptionFormatMode.writingAssistant.assistive)
  }

  func testDictationRecognitionLanguagesMapToExplicitLocales() {
    XCTAssertEqual(TranscriptionLanguageChoice.automatic.title, "Auto")
    XCTAssertNil(TranscriptionLanguageChoice.automatic.engineIdentifier)
    XCTAssertEqual(TranscriptionLanguageChoice.polish.title, "Polish")
    XCTAssertEqual(TranscriptionLanguageChoice.polish.engineIdentifier, "pl-PL")
    XCTAssertEqual(TranscriptionLanguageChoice.english.title, "English")
    XCTAssertEqual(TranscriptionLanguageChoice.english.engineIdentifier, "en-US")
  }

  func testPreviewTailReplacesWithoutDroppingCommittedText() {
    let service = TranscriptionService()

    service.receivePreview("opening thought")
    XCTAssertEqual(service.rendered, "opening thought")

    service.receiveFinal("opening thought", language: "en")
    XCTAssertEqual(service.committed, "opening thought")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "opening thought")

    service.receivePreview("second utterance")
    XCTAssertEqual(service.rendered, "opening thought second utterance")

    service.receivePreview("second utterance extended")
    XCTAssertEqual(service.committed, "opening thought")
    XCTAssertEqual(service.preview, "second utterance extended")
    XCTAssertEqual(service.rendered, "opening thought second utterance extended")
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
      "monologue part one growing still monologue part two keeps going"
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
    XCTAssertEqual(service.rendered, "alpha beta")
    service.commitActivePreviewForCadence()

    XCTAssertEqual(service.committed, "alpha beta")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "alpha beta")

    service.receivePreview("alpha beta gamma")
    XCTAssertEqual(service.rendered, "alpha beta gamma")
    service.receiveFinal("alpha beta gamma", language: "en")

    XCTAssertEqual(service.committed, "alpha beta gamma")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "alpha beta gamma")
  }

  func testCadenceCommitLeavesTailPreviewCadenceGrowing() {
    let service = TranscriptionService(cadenceCommitNanoseconds: 0)

    service.receivePreview("alpha")
    service.commitActivePreviewForCadence()
    service.receivePreview("beta")
    service.commitActivePreviewForCadence()
    service.receivePreview("gamma")

    XCTAssertEqual(service.committed, "alpha beta")
    XCTAssertEqual(service.preview, "gamma")
    XCTAssertEqual(service.rendered, "alpha beta gamma")
  }

  func testStopRecordingCommitsTheEngineFinalEvenWithoutAFinalCallback() throws {
    let engine = MockVistaAutocompleteEngine(stopRecordingHandler: { "confirmed final words" })
    let service = TranscriptionService(engine: engine, cadenceCommitNanoseconds: 0)

    service.receivePreview("draft words")
    let stoppedText = try service.stopRecording()

    XCTAssertEqual(stoppedText, "confirmed final words")
    XCTAssertEqual(service.committed, "confirmed final words")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "confirmed final words")
  }

  func testStopRecordingDoesNotDuplicateFinalAlreadyDeliveredByCallback() throws {
    let engine = MockVistaAutocompleteEngine(stopRecordingHandler: { "confirmed final words" })
    let service = TranscriptionService(engine: engine, cadenceCommitNanoseconds: 0)
    service.receiveFinal("confirmed final words", language: "en")

    let stoppedText = try service.stopRecording()

    XCTAssertEqual(stoppedText, "confirmed final words")
    XCTAssertEqual(service.committed, "confirmed final words")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "confirmed final words")
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
  func testStartRecordingRequestsMicrophoneBeforeRealEngineCapture() async {
    let events = LockedStringLog()
    let engine = MockVistaAutocompleteEngine(
      startRecordingHandler: { _ in events.append("startRecording") })
    let service = TranscriptionService(
      engine: engine,
      requiresMicrophonePermission: { _ in true },
      microphonePermissionRequester: {
        events.append("permission")
      },
      cadenceCommitNanoseconds: 0)

    service.startRecording()

    for _ in 0..<200 where !service.isRecording {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(events.values, ["permission", "startRecording"])
    XCTAssertTrue(service.isRecording)
    XCTAssertFalse(service.isPreparingRecording)
    XCTAssertNil(service.lastError)
  }

  @MainActor
  func testStartRecordingPassesSelectedRecognitionLanguageToEngine() async {
    let languages = LockedStringLog()
    let engine = MockVistaAutocompleteEngine(
      startRecordingHandler: { language in languages.append(language ?? "auto") })
    let service = TranscriptionService(engine: engine, cadenceCommitNanoseconds: 0)

    service.startRecording(language: TranscriptionLanguageChoice.polish.engineIdentifier)

    for _ in 0..<200 where !service.isRecording {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(languages.values, ["pl-PL"])
    XCTAssertTrue(service.isRecording)
  }

  @MainActor
  func testPartialCaptureStartFailureRollsBackAndAllowsRetry() async {
    let events = LockedStringLog()
    let recording = LockedFlag()
    let engine = MockVistaAutocompleteEngine(
      isRecordingHandler: { recording.isSet },
      removeEventListenerHandler: { events.append("removeListener") },
      startRecordingHandler: { _ in
        events.append("start")
        recording.set()
        if events.values.filter({ $0 == "start" }).count == 1 {
          throw DictationLifecycleTestError.partialStart
        }
      },
      stopRecordingHandler: {
        events.append("stop")
        recording.clear()
        return ""
      }
    )
    let service = TranscriptionService(engine: engine, cadenceCommitNanoseconds: 0)

    service.startRecording()
    for _ in 0..<200 where service.lastError == nil {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertFalse(service.isPreparingRecording)
    XCTAssertFalse(service.isRecording)
    XCTAssertEqual(events.values, ["start", "stop", "removeListener"])

    service.startRecording()
    for _ in 0..<200 where !service.isRecording {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertTrue(service.isRecording, "a rolled-back partial start must remain retryable")
    XCTAssertEqual(events.values.filter { $0 == "start" }.count, 2)
  }

  @MainActor
  func testStaleEngineCaptureIsStoppedBeforeFreshDictationStart() async {
    let events = LockedStringLog()
    let recording = LockedFlag()
    recording.set()
    let engine = MockVistaAutocompleteEngine(
      isRecordingHandler: { recording.isSet },
      startRecordingHandler: { _ in
        events.append("start")
        recording.set()
      },
      stopRecordingHandler: {
        events.append("stop")
        recording.clear()
        return ""
      }
    )
    let service = TranscriptionService(engine: engine, cadenceCommitNanoseconds: 0)

    service.startRecording()
    for _ in 0..<200 where !service.isRecording {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertTrue(service.isRecording)
    XCTAssertEqual(events.values, ["stop", "start"])
  }

  @MainActor
  func testStaleEngineStopFailureDetachesListenerAndDoesNotStartOverActiveCapture() async {
    let events = LockedStringLog()
    let engine = MockVistaAutocompleteEngine(
      isRecordingHandler: { true },
      removeEventListenerHandler: { events.append("removeListener") },
      startRecordingHandler: { _ in events.append("start") },
      stopRecordingHandler: {
        events.append("stop")
        throw DictationLifecycleTestError.staleStop
      }
    )
    let service = TranscriptionService(engine: engine, cadenceCommitNanoseconds: 0)

    service.startRecording()
    for _ in 0..<200 where service.lastError == nil {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertFalse(service.isPreparingRecording)
    XCTAssertFalse(service.isRecording)
    XCTAssertNotNil(service.lastError)
    XCTAssertEqual(events.values, ["stop", "removeListener"])
  }

  @MainActor
  func testAsynchronousEngineErrorStopsCaptureDetachesListenerAndDrainsFinalText() async {
    let events = LockedStringLog()
    let recording = LockedFlag()
    let engine = MockVistaAutocompleteEngine(
      isRecordingHandler: { recording.isSet },
      removeEventListenerHandler: { events.append("removeListener") },
      startRecordingHandler: { _ in recording.set() },
      stopRecordingHandler: {
        events.append("stop")
        recording.clear()
        return "confirmed recovery text"
      }
    )
    let service = TranscriptionService(engine: engine, cadenceCommitNanoseconds: 0)
    service.startRecording()
    for _ in 0..<200 where !service.isRecording {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    service.receivePreview("draft recovery text")

    service.onError(msg: "capture backend failed")
    for _ in 0..<200 where events.values.last != "removeListener" {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertFalse(service.isPreparingRecording)
    XCTAssertFalse(service.isRecording)
    XCTAssertEqual(service.lastError, "capture backend failed")
    XCTAssertEqual(events.values, ["stop", "removeListener"])
    XCTAssertEqual(service.committed, "confirmed recovery text")
    XCTAssertEqual(service.preview, "")
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
  func testCancelPreparationLeavesPreparingAndNeverStartsRecording() async {
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
    let service = TranscriptionService(engine: engine, cadenceCommitNanoseconds: 0)

    service.startRecording()
    await fulfillment(of: [modelLoadStarted], timeout: 2)

    service.cancelPreparation()
    XCTAssertFalse(
      service.isPreparingRecording,
      "cancel must leave the Preparing state immediately")
    releaseModelLoad.signal()

    try? await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertFalse(
      recordingStarted.isSet,
      "a cancelled preparation must never start the microphone")
    XCTAssertFalse(service.isRecording)
    XCTAssertNil(service.lastError, "user-initiated cancel is not an error")
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

  func testFormatCompositionUsesWritingAssistantFormatterWhenSelected() async {
    let engine = MockVistaAutocompleteEngine(
      formattingAvailable: true,
      formattingHandler: { text, assistive in
        XCTAssertTrue(assistive)
        return "assistant: \(text)"
      }
    )
    let service = TranscriptionService(engine: engine, cadenceCommitNanoseconds: 0)

    service.receivePreview("chaotic spoken mission")
    let formatted = await service.formatComposition(mode: .writingAssistant)

    XCTAssertEqual(formatted, "assistant: chaotic spoken mission")
    XCTAssertEqual(service.committed, "assistant: chaotic spoken mission")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "assistant: chaotic spoken mission")
    XCTAssertFalse(service.isFormatting)
    XCTAssertNil(service.lastError)
  }

  func testProductionFormattingSeamUsesProviderSafeResponsesBackend() async {
    let responder = MockAITextResponder(result: "rewritten transcript")
    let service = TranscriptionService(
      engine: MockVistaAutocompleteEngine(formattingAvailable: false),
      aiTextResponder: responder,
      cadenceCommitNanoseconds: 0)
    service.receivePreview("chaotic spoken mission")

    let formatted = await service.formatComposition(mode: .writingAssistant)

    XCTAssertEqual(formatted, "rewritten transcript")
    XCTAssertEqual(responder.lastInput, "chaotic spoken mission")
    XCTAssertTrue(responder.lastInstructions?.contains("voice-native writing assistant") == true)
    XCTAssertTrue(responder.lastInstructions?.contains("Return only the rewritten text") == true)
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

  func testAppControllerSendsCompositionToProvidedActiveEditorWithNaturalWordBoundary() {
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

    service.receiveFinal("dictated text", language: "en")

    XCTAssertTrue(controller.sendTranscriptionToActiveEditor(activeTextView: surface.textView))
    XCTAssertEqual(surface.textStorage.string, "target dictated text")
    XCTAssertEqual(service.rendered, "")
    XCTAssertNil(appState.lastError)
  }

  func testDictationInsertionPreservesPunctuationAndReplacesSelection() {
    let punctuationSurface = MarkdownEditorSurface(text: "Hello.", fontSize: 14)
    punctuationSurface.textView.setSelectedRange(NSRange(location: 5, length: 0))

    XCTAssertTrue(punctuationSurface.textView.insertDictationAtSelection("world"))
    XCTAssertEqual(punctuationSurface.textStorage.string, "Hello world.")
    XCTAssertEqual(punctuationSurface.textView.selectedRange(), NSRange(location: 11, length: 0))

    let replacementSurface = MarkdownEditorSurface(text: "before wrong after", fontSize: 14)
    replacementSurface.textView.setSelectedRange(NSRange(location: 7, length: 5))

    XCTAssertTrue(replacementSurface.textView.insertDictationAtSelection("dictated"))
    XCTAssertEqual(replacementSurface.textStorage.string, "before dictated after")
  }

  func testDictationInsertionAtMarkdownLineStartDoesNotAddIndentNoise() {
    let surface = MarkdownEditorSurface(text: "# Heading\n", fontSize: 14)
    surface.textView.setSelectedRange(NSRange(location: 10, length: 0))

    XCTAssertTrue(surface.textView.insertDictationAtSelection("A clean paragraph"))
    XCTAssertEqual(surface.textStorage.string, "# Heading\nA clean paragraph")
  }

  func testDictationInsertionParticipatesInTheEditorsUndoStack() throws {
    let surface = MarkdownEditorSurface(text: "Before after", fontSize: 14)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = surface.scrollView
    surface.textView.allowsUndo = true
    window.makeFirstResponder(surface.textView)
    surface.textView.setSelectedRange(NSRange(location: 7, length: 0))

    XCTAssertTrue(surface.textView.insertDictationAtSelection("dictated"))
    XCTAssertEqual(surface.textStorage.string, "Before dictated after")

    let undoManager = try XCTUnwrap(surface.textView.undoManager)
    undoManager.undo()
    XCTAssertEqual(surface.textStorage.string, "Before after")
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
    XCTAssertEqual(surface.textStorage.string, "target editor route")
    XCTAssertEqual(service.rendered, "")
    XCTAssertTrue(launcher.dispatchedPrompts().isEmpty)
  }

  func testAppControllerRoutesAgentTargetThroughLauncherWithoutRealDispatch() async {
    let appState = AppState()
    let service = TranscriptionService(cadenceCommitNanoseconds: 0)
    let reportPath =
      "/Users/tester/.vibecrafted/artifacts/vetcoders/pensieve/2026_0609/reports/test.md"
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
      "first utterance second utterance third utterance"
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
    service.updateDispatchStatus("Inserted into the active document.")
    service.resetTranscript()

    XCTAssertEqual(service.committed, "")
    XCTAssertEqual(service.preview, "")
    XCTAssertEqual(service.rendered, "")
    XCTAssertNil(service.lastLanguage)
    XCTAssertNil(service.lastError)
    XCTAssertNil(service.dispatchStatus)

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

private final class MockAITextResponder: AITextResponding, @unchecked Sendable {
  let isConfigured = true
  private let lock = NSLock()
  private let result: String
  private var storedInput: String?
  private var storedInstructions: String?

  init(result: String) {
    self.result = result
  }

  func respond(input: String, instructions: String) async throws -> String {
    lock.withLock {
      storedInput = input
      storedInstructions = instructions
    }
    return result
  }

  var lastInput: String? {
    lock.lock()
    defer { lock.unlock() }
    return storedInput
  }

  var lastInstructions: String? {
    lock.lock()
    defer { lock.unlock() }
    return storedInstructions
  }
}

private final class LockedStringLog: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []

  func append(_ value: String) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }

  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
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

  func clear() {
    lock.lock()
    value = false
    lock.unlock()
  }

  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

private enum DictationLifecycleTestError: Error {
  case partialStart
  case staleStop
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

  func dispatch(
    workflow: String,
    agents: [String],
    payload: AgentDispatchPayload,
    workingDirectoryURL: URL
  ) throws -> AgentDispatchMetadata {
    lock.lock()
    if case .prompt(let prompt) = payload {
      prompts.append(prompt)
    }
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
