import AVFoundation
import CodescribeBridge
import Synchronization
import XCTest

@testable import Pensieve

/// Binding + capture-ready tests for the in-process codescribe_ffi seam.
/// UniFFI `NoHandle` objects free a null Rust handle on deinit and SIGSEGV,
/// so these tests stay on type-level proofs plus `DictationEngine` doubles.
@MainActor
final class CodescribeFFIBindingTests: XCTestCase {
  func testUniffiSeamExposesHotkeysTranscriptionListenerAndStreamReply() {
    let hotkeysType: CodescribeHotkeysProtocol.Type = CodescribeHotkeys.self
    XCTAssertEqual(String(describing: hotkeysType), "CodescribeHotkeys")

    let listenerType: CsTranscriptionListener.Type = CodescribeListenerBridge.self
    XCTAssertEqual(String(describing: listenerType), "CodescribeListenerBridge")

    XCTAssertEqual(String(describing: CodescribeAgent.self), "CodescribeAgent")
    let streaming: any CodescribeAgentStreaming = FakeCodescribeAgent()
    XCTAssertEqual(String(describing: type(of: streaming)), "FakeCodescribeAgent")
    XCTAssertEqual(String(describing: CodescribeSTTEngine.self), "CodescribeSTTEngine")
    XCTAssertNotEqual(String(describing: CodescribeSTTEngine.self), "VistaEngine")
  }

  func testTranscriptionServiceIsNotAVistaEventListener() {
    let service = TranscriptionService(
      engine: FakeDictationEngine(),
      cadenceCommitNanoseconds: 0)
    let listener: any DictationEventListener = service
    XCTAssertEqual(String(describing: type(of: listener)), "TranscriptionService")
    XCTAssertFalse(isVistaEventListener(service))
  }

  func testProductionEngineFactoryDefaultIsCodescribeNotVista() {
    XCTAssertEqual(
      String(describing: CodescribeSTTEngine.self),
      "CodescribeSTTEngine")
    let engine = FakeDictationEngine()
    let isolated = TranscriptionService(
      engineFactory: { engine },
      cadenceCommitNanoseconds: 0)
    XCTAssertTrue(isolated.activeEngine() === engine)
    XCTAssertNotEqual(
      String(describing: type(of: isolated.activeEngine())),
      "VistaEngine")
  }

  func testCaptureReadyRequiresMicrophoneAndSTTNotProviderOAuth() {
    struct Axes: Sendable {
      var microphoneStatus: AVAuthorizationStatus
      var sttReady: Bool
      var grokOAuthReady: Bool
    }
    let axes = Mutex(
      Axes(microphoneStatus: .denied, sttReady: true, grokOAuthReady: true))

    let service = TranscriptionService(
      engine: FakeDictationEngine(),
      microphoneAuthorizationProvider: { axes.withLock { $0.microphoneStatus } },
      sttReadinessProbe: { axes.withLock { $0.sttReady } },
      cadenceCommitNanoseconds: 0)

    service.refreshCaptureReadiness()
    XCTAssertFalse(
      service.isCaptureReady,
      "denied TCC must disable Record regardless of STT or OAuth")

    axes.withLock {
      $0.microphoneStatus = .authorized
      $0.sttReady = false
      $0.grokOAuthReady = true
    }
    service.refreshCaptureReadiness()
    XCTAssertFalse(
      service.isCaptureReady,
      "STT-not-ready must disable Record even with mic + dummy OAuth")

    axes.withLock {
      $0.sttReady = true
      $0.grokOAuthReady = false
    }
    service.refreshCaptureReadiness()
    XCTAssertTrue(service.isCaptureReady)
    XCTAssertFalse(
      axes.withLock { $0.grokOAuthReady },
      "OAuth/Grok flag is dummy state; readiness must ignore it")
    XCTAssertTrue(service.isCaptureReady, "flipping OAuth off must not disable ready")

    axes.withLock { $0.grokOAuthReady = true }
    service.refreshCaptureReadiness()
    XCTAssertTrue(service.isCaptureReady, "flipping OAuth on must not be what enables ready")
  }

  func testFailingSTTFactoryDoesNotConstructVistaEngine() async {
    let factoryCalls = BindingLockedCounter()
    let failing = FakeDictationEngine(
      modelLoaded: false,
      initModelHandler: {
        struct CodescribeSTTUnavailable: Error, LocalizedError {
          var errorDescription: String? { "codescribe stt unavailable" }
        }
        throw CodescribeSTTUnavailable()
      })
    let service = TranscriptionService(
      engineFactory: {
        factoryCalls.add(1)
        return failing
      },
      requiresMicrophonePermission: { _ in false },
      cadenceCommitNanoseconds: 0)

    service.startRecording()
    for _ in 0..<200 where service.lastError == nil {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(service.lastError, "codescribe stt unavailable")
    XCTAssertFalse(service.isRecording)
    XCTAssertFalse(service.isPreparingRecording)
    XCTAssertEqual(factoryCalls.value, 1)
    XCTAssertTrue(service.activeEngine() === failing)
    XCTAssertNotEqual(String(describing: type(of: service.activeEngine())), "VistaEngine")
  }

  func testListenerBridgeForwardsPreviewFinalStatusAndError() {
    let listener = RecordingDictationListener()
    let stopped = BindingLockedCounter()
    let bridge = CodescribeListenerBridge(target: listener) {
      stopped.add(1)
    }

    bridge.onRecordingPreparing()
    bridge.onTranscriptProjection(event: Self.projection(text: "draft take", terminal: false))
    bridge.onTranscriptProjection(event: Self.projection(text: "final take", terminal: true))
    bridge.onRecordingFinalising()
    bridge.onError(message: "mic failed")
    bridge.onRecordingStopped()

    XCTAssertEqual(listener.previews, ["draft take"])
    XCTAssertEqual(listener.finals.map(\.text), ["final take"])
    XCTAssertEqual(listener.statuses, [.thinking, .thinking])
    XCTAssertEqual(listener.errors, ["mic failed"])
    XCTAssertEqual(stopped.value, 1)
  }

  func testStreamReplySeamForwardsDeltasWithoutASecondPipe() async throws {
    let agent = FakeCodescribeAgent()
    let collector = CollectingAgentListener()

    let final = try await agent.streamReply(
      text: "Say hello in exactly three words.",
      threadId: "ask-thread-1",
      listener: collector)

    XCTAssertEqual(agent.lastText, "Say hello in exactly three words.")
    XCTAssertEqual(agent.lastThreadId, "ask-thread-1")
    XCTAssertEqual(collector.deltas, ["Hel", "lo"])
    XCTAssertEqual(collector.doneText, "Hello there now")
    XCTAssertTrue(collector.finished)
    XCTAssertEqual(final, "Hello there now")
  }

  func testAccumulationCadenceWorksAgainstCodescribeEngineFake() {
    let engine = FakeDictationEngine()
    let service = TranscriptionService(engine: engine, cadenceCommitNanoseconds: 0)

    service.receivePreview("opening thought")
    service.receiveFinal("opening thought", language: "en")
    service.receivePreview("second utterance extended")

    XCTAssertEqual(service.committed, "opening thought")
    XCTAssertEqual(service.preview, "second utterance extended")
    XCTAssertEqual(service.rendered, "opening thought second utterance extended")
    XCTAssertTrue(service.activeEngine() === engine)
    XCTAssertNotEqual(String(describing: type(of: service.activeEngine())), "VistaEngine")
  }

  private static func projection(text: String, terminal: Bool) -> CsTranscriptProjectionEvent {
    CsTranscriptProjectionEvent(
      schema: "cs.transcript.projection",
      sequence: 1,
      emittedAt: "2026-09-18T00:00:00Z",
      sessionId: "session",
      mode: "dictation",
      reducerRevision: 1,
      reducerAction: terminal ? "seal" : "append",
      occurrenceSessionId: "session",
      captureEpoch: 0,
      sampleStart: 0,
      sampleEnd: 0,
      documentIndex: 0,
      label: "",
      renderedText: text,
      phase: terminal ? "final" : "live",
      canPaste: false,
      canInsert: false,
      canCopy: false,
      canRetranscribe: false,
      canFormat: false,
      canSendToAgent: false,
      terminal: terminal,
      lifecycleTerminal: terminal,
      delivery: .unattempted,
      acousticReceipts: [],
      sealCoverage: nil,
      consultationPresentations: [])
  }
}

private final class RecordingDictationListener: DictationEventListener, @unchecked Sendable {
  struct Final: Equatable {
    var text: String
    var language: String
  }

  var previews: [String] = []
  var finals: [Final] = []
  var statuses: [VistaStatusSignal] = []
  var errors: [String] = []

  func onTranscriptionPreview(text: String) { previews.append(text) }
  func onTranscriptionFinal(text: String, language: String) {
    finals.append(Final(text: text, language: language))
  }
  func onStatusChanged(signal: VistaStatusSignal) { statuses.append(signal) }
  func onError(msg: String) { errors.append(msg) }
}

private final class FakeCodescribeAgent: CodescribeAgentStreaming, @unchecked Sendable {
  var lastText: String?
  var lastThreadId: String?

  func streamReply(text: String, threadId: String, listener: CsAgentListener) async throws
    -> String
  {
    lastText = text
    lastThreadId = threadId
    listener.onTextDelta(delta: "Hel")
    listener.onTextDelta(delta: "lo")
    listener.onTextDone(text: "Hello there now")
    listener.onDone()
    return "Hello there now"
  }
}

private final class CollectingAgentListener: CsAgentListener, @unchecked Sendable {
  var deltas: [String] = []
  var doneText: String?
  var finished = false

  func onTextDelta(delta: String) { deltas.append(delta) }
  func onTextDone(text: String) { doneText = text }
  func onReasoningDelta(delta: String) {}
  func onToolExecuting(name: String, id: String) {}
  func onToolApprovalRequested(request: CsToolApprovalRequest) {}
  func onToolResult(name: String, id: String, summary: String, isError: Bool) {}
  func onDone() { finished = true }
  func onError(message: String) {}
}

private func isVistaEventListener(_ value: Any) -> Bool {
  value is VistaEventListener
}

private final class BindingLockedCounter: Sendable {
  private struct State: Sendable {
    var value = 0
  }
  private let state = Mutex(State())

  func add(_ delta: Int) {
    state.withLock { $0.value += delta }
  }

  var value: Int {
    state.withLock { $0.value }
  }
}
