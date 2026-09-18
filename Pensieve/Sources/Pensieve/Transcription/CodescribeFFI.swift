import CodescribeBridge
import Foundation
import Synchronization

/// Engine-neutral dictation callbacks. This is the seam `TranscriptionService`
/// conforms to; it replaces the Vista-specific `VistaEventListener` on the
/// dictation path. The status signal type stays `VistaStatusSignal` because the
/// HUD panel binds to that published shape.
protocol DictationEventListener: AnyObject, Sendable {
  func onTranscriptionPreview(text: String)
  func onTranscriptionFinal(text: String, language: String)
  func onStatusChanged(signal: VistaStatusSignal)
  func onError(msg: String)
}

/// The slice of engine behaviour dictation actually uses. Kept synchronous on
/// purpose: `TranscriptionService.stopRecording()` is a main-actor UI action,
/// and the codescribe FFI futures are bridged inside `CodescribeSTTEngine`
/// rather than pushing async up into the panel contract.
protocol DictationEngine: AnyObject, Sendable {
  func isRecording() -> Bool
  func isModelLoaded() -> Bool
  func initModel() throws
  func startRecording(language: String?) throws
  func stopRecording() throws -> String
  func setEventListener(listener: DictationEventListener)
  func removeEventListener()
  func isFormattingAvailable() -> Bool
  func formatText(text: String, assistive: Bool) async throws -> String
}

enum DictationEngineError: LocalizedError {
  case staleCaptureActive
  case formattingUnavailable

  var errorDescription: String? {
    switch self {
    case .staleCaptureActive:
      return "dictation unavailable: stale microphone capture is still active"
    case .formattingUnavailable:
      return "dictation engine does not format text; use the provider runtime"
    }
  }
}

/// Process-global codescribe facade. `CodescribeHotkeys()` initialises logging
/// only — it installs no hotkey tap, controller or listener, so constructing it
/// here is safe while Pensieve drives recording imperatively.
enum CodescribeSTTRuntime {
  static let hotkeys = CodescribeHotkeys()

  /// FFI-level STT readiness: reaching this getter means the vendored dylib
  /// loaded and the Rust core initialised. Deeper admission (input device,
  /// calibration) is verified when recording starts and surfaces as a visible
  /// error — never as a silent fallback.
  static var isSTTReady: Bool {
    _ = hotkeys
    return true
  }
}

/// Dictation engine backed in-process by `codescribe_ffi`. Transcript truth
/// arrives through the `CsTranscriptionListener` projection callbacks; the
/// codescribe stop call carries no text, so `stopRecording()` returns "" and
/// the terminal projection commits the final words.
final class CodescribeSTTEngine: DictationEngine, @unchecked Sendable {
  private struct State: Sendable {
    var recording = false
    var prepared = false
  }

  private let hotkeys: any CodescribeHotkeysProtocol
  private let state = Mutex(State())
  private let listenerBridge = Mutex<CodescribeListenerBridge?>(nil)

  init(hotkeys: any CodescribeHotkeysProtocol = CodescribeSTTRuntime.hotkeys) {
    self.hotkeys = hotkeys
  }

  func isRecording() -> Bool {
    state.withLock { $0.recording }
  }

  func isModelLoaded() -> Bool {
    state.withLock { $0.prepared }
  }

  func initModel() throws {
    // `prewarmRecording` front-loads the shared recorder/model setup without
    // opening a capture stream — the codescribe counterpart of a model load.
    try Self.blockingAwait { [hotkeys] in
      try await hotkeys.prewarmRecording()
    }
    state.withLock { $0.prepared = true }
  }

  func startRecording(language: String?) throws {
    // Recognition language is codescribe-settings-owned; the FFI start takes
    // no per-take language in this cut.
    try Self.blockingAwait { [hotkeys] in
      try await hotkeys.startRecording()
    }
    state.withLock { $0.recording = true }
  }

  func stopRecording() throws -> String {
    try Self.blockingAwait { [hotkeys] in
      try await hotkeys.stopRecording()
    }
    state.withLock { $0.recording = false }
    return ""
  }

  func setEventListener(listener: DictationEventListener) {
    let bridge = CodescribeListenerBridge(target: listener) { [weak self] in
      self?.state.withLock { $0.recording = false }
    }
    listenerBridge.withLock { $0 = bridge }
    hotkeys.setListener(listener: bridge)
  }

  func removeEventListener() {
    listenerBridge.withLock { $0?.detach() }
  }

  /// Formatting is routed through the provider-neutral AI runtime, not the
  /// dictation engine, so the engine reports no formatter of its own.
  func isFormattingAvailable() -> Bool {
    false
  }

  func formatText(text: String, assistive: Bool) async throws -> String {
    throw DictationEngineError.formattingUnavailable
  }

  /// Runs one async FFI call to completion on the cooperative pool while the
  /// caller blocks. Callers are the service's detached prepare task and the
  /// main-actor stop action; the Rust future never needs the blocked thread.
  private static func blockingAwait<T: Sendable>(
    _ operation: @escaping @Sendable () async throws -> T
  ) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let outcome = Mutex<Result<T, Error>?>(nil)
    Task.detached {
      let result: Result<T, Error>
      do {
        result = .success(try await operation())
      } catch {
        result = .failure(error)
      }
      outcome.withLock { $0 = result }
      semaphore.signal()
    }
    semaphore.wait()
    return try outcome.withLock { $0! }.get()
  }
}

/// Forwards the codescribe reducer projections onto the engine-neutral
/// dictation listener. A terminal projection is a committed final; anything
/// earlier is a live preview of the full in-flight document, which the
/// service's prefix-trimming accumulation already knows how to absorb.
final class CodescribeListenerBridge: CsTranscriptionListener, @unchecked Sendable {
  private let destination: Mutex<(any DictationEventListener)?>
  private let onStopped: @Sendable () -> Void

  init(target: DictationEventListener, onStopped: @escaping @Sendable () -> Void) {
    self.destination = Mutex(target)
    self.onStopped = onStopped
  }

  func detach() {
    destination.withLock { $0 = nil }
  }

  func onTranscriptProjection(event: CsTranscriptProjectionEvent) {
    let listener = destination.withLock { $0 }
    if event.terminal {
      listener?.onTranscriptionFinal(text: event.renderedText, language: "")
    } else {
      listener?.onTranscriptionPreview(text: event.renderedText)
    }
  }

  func onPresentationStatus(event: CsPresentationStatusEvent) {}

  func onCompactProjection(event: CsCompactProjection) {}

  func onRecordingPreparing() {
    destination.withLock { $0 }?.onStatusChanged(signal: .thinking)
  }

  func onRecordingStarted() {}

  func onRecordingStopped() {
    onStopped()
  }

  func onRecordingFinalising() {
    destination.withLock { $0 }?.onStatusChanged(signal: .thinking)
  }

  func onSessionFinalised(sessionId: String, layerSummary: CsLayerSummary) {}

  func onVadActive(active: Bool) {}

  func onAudioLevel(rms: Float) {}

  func onNoSpeech(reason: String) {}

  func onError(message: String) {
    destination.withLock { $0 }?.onError(msg: message)
  }
}

/// Ask-stream seam over the same vendored FFI. W5 streams Ask through this —
/// do not build a second pipe beside it.
protocol CodescribeAgentStreaming: AnyObject, Sendable {
  func streamReply(text: String, threadId: String, listener: CsAgentListener) async throws
    -> String
}

extension CodescribeAgent: CodescribeAgentStreaming {}
