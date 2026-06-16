import AVFoundation
import Combine
import Foundation

enum TranscriptionFormatMode: String, CaseIterable, Identifiable, Sendable {
  case polish
  case kurier

  var id: String { rawValue }

  var title: String {
    switch self {
    case .polish:
      return "Polish"
    case .kurier:
      return "Kurier"
    }
  }

  var assistive: Bool {
    switch self {
    case .polish:
      return false
    case .kurier:
      return true
    }
  }
}

enum TranscriptionSendTarget: String, CaseIterable, Identifiable, Sendable {
  case editor
  case agent

  var id: String { rawValue }

  var title: String {
    switch self {
    case .editor:
      return "Editor"
    case .agent:
      return "Dispatch to agent"
    }
  }

  var failureMessage: String {
    switch self {
    case .editor:
      return "No active editor target."
    case .agent:
      return "Agent dispatch did not start."
    }
  }
}

@MainActor
final class TranscriptionService: ObservableObject, VistaEventListener, @unchecked Sendable {
  typealias EngineFactory = @Sendable () -> VistaEngineProtocol

  @Published private(set) var committed: String
  @Published private(set) var preview: String
  @Published private(set) var rendered: String
  @Published private(set) var isRecording: Bool
  @Published private(set) var isPreparingRecording: Bool = false
  @Published private(set) var isFormatting: Bool
  @Published private(set) var lastLanguage: String?
  @Published private(set) var lastStatus: VistaStatusSignal?
  @Published private(set) var lastError: String?
  @Published private(set) var dispatchStatus: String?

  private let engineFactory: EngineFactory
  private let cadenceCommitNanoseconds: UInt64
  private var engine: VistaEngineProtocol?
  private var cadenceCommitTask: Task<Void, Never>?
  private var startRecordingTask: Task<Void, Never>?
  private var lastRawPreview: String = ""
  private var promotedPreviewPrefix: String?

  init(
    engine: VistaEngineProtocol? = nil,
    engineFactory: @escaping EngineFactory = { VistaEngine() },
    cadenceCommitNanoseconds: UInt64 = 8_000_000_000
  ) {
    self.engine = engine
    self.engineFactory = engineFactory
    self.cadenceCommitNanoseconds = cadenceCommitNanoseconds
    self.committed = ""
    self.preview = ""
    self.rendered = ""
    self.isRecording = false
    self.isFormatting = false
  }

  deinit {
    cadenceCommitTask?.cancel()
    startRecordingTask?.cancel()
  }

  private enum MicrophonePermissionError: LocalizedError {
    case denied
    case restricted

    var errorDescription: String? {
      switch self {
      case .denied:
        return "Microphone permission is required for transcription. Enable it in System Settings → Privacy & Security → Microphone."
      case .restricted:
        return "Microphone access is restricted on this system."
      }
    }
  }

  private static func ensureMicrophonePermission() async throws {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      return
    case .notDetermined:
      let granted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          continuation.resume(returning: granted)
        }
      }
      if !granted {
        throw MicrophonePermissionError.denied
      }
    case .denied:
      throw MicrophonePermissionError.denied
    case .restricted:
      throw MicrophonePermissionError.restricted
    @unknown default:
      throw MicrophonePermissionError.denied
    }
  }

  func startRecording(language: String? = nil) {
    guard !isRecording, !isPreparingRecording else { return }
    let engine = activeEngine()
    engine.setEventListener(listener: self)
    isPreparingRecording = true
    lastError = nil
    startRecordingTask = Task { [weak self] in
      do {
        if engine is VistaEngine {
          try await Self.ensureMicrophonePermission()
        }
        try Task.checkCancellation()
      } catch {
        guard let self, !(error is CancellationError) else { return }
        self.isPreparingRecording = false
        self.lastError = error.localizedDescription
        return
      }
      // Model init (whisper weights dequantization — seconds of CPU) and
      // capture start run OFF the main actor; doing this inline froze the
      // whole UI for the model load (1.77s+ hang reports from the field).
      // Task.detached does NOT inherit cancellation from this task, so a
      // teardown-time cancel (deinit) must be bridged explicitly — otherwise
      // the detached work could still start the microphone after the owning
      // service/window is gone, with no visible control left to stop it.
      let prepareTask = Task.detached(priority: .userInitiated) {
        if !engine.isModelLoaded() {
          try engine.initModel()
        }
        // Owner torn down while the model was loading: never start capture.
        try Task.checkCancellation()
        try engine.startRecording(language: language)
      }
      do {
        try await withTaskCancellationHandler {
          try await prepareTask.value
        } onCancel: {
          prepareTask.cancel()
        }
        guard let self, !Task.isCancelled else {
          // Capture already started but the owner went away mid-await: stop
          // the engine so the microphone is not left running unowned.
          Task.detached { _ = try? engine.stopRecording() }
          return
        }
        self.isPreparingRecording = false
        self.isRecording = true
        self.startCadenceCommitLoop()
      } catch {
        guard let self, !(error is CancellationError) else { return }
        self.isPreparingRecording = false
        self.lastError = error.localizedDescription
      }
    }
  }

  /// Cancels an in-flight preparation (model load / capture start) so the
  /// panel never strands the user in Preparing with no enabled control. The
  /// bridged cancellation reaches the detached prepare task; if capture
  /// already began, the prepare task's rollback stops the engine.
  func cancelPreparation() {
    guard isPreparingRecording else { return }
    startRecordingTask?.cancel()
    startRecordingTask = nil
    isPreparingRecording = false
  }

  @discardableResult
  func stopRecording() throws -> String {
    // Always clear recording state, even when engine.stopRecording() throws;
    // otherwise the UI stays in "Recording" and the cadence loop never stops.
    defer {
      isRecording = false
      stopCadenceCommitLoop()
    }

    guard let engine else {
      return rendered
    }

    let finalText = try engine.stopRecording()
    commitActivePreviewForCadence()
    return finalText
  }

  func resetTranscript() {
    committed = ""
    preview = ""
    rendered = ""
    lastRawPreview = ""
    promotedPreviewPrefix = nil
    lastLanguage = nil
    lastError = nil
  }

  var hasComposedText: Bool {
    !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var isFormattingAvailable: Bool {
    activeEngine().isFormattingAvailable()
  }

  func updateDispatchStatus(_ status: String?) {
    dispatchStatus = status
  }

  @discardableResult
  func formatComposition(mode: TranscriptionFormatMode = .polish) async -> String {
    let source = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !source.isEmpty else { return "" }

    let engine = activeEngine()
    guard engine.isFormattingAvailable() else {
      lastError = nil
      return source
    }

    isFormatting = true
    defer { isFormatting = false }

    do {
      let formatted = try await engine.formatText(text: source, assistive: mode.assistive)
      let cleaned = formatted.trimmingCharacters(in: .whitespacesAndNewlines)
      replaceComposition(with: cleaned.isEmpty ? source : cleaned)
      lastError = nil
      return rendered
    } catch {
      lastError = error.localizedDescription
      return source
    }
  }

  func replaceComposition(with text: String) {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    committed = cleaned
    preview = ""
    lastRawPreview = ""
    promotedPreviewPrefix = nil
    refreshRendered()
  }

  nonisolated func onTranscriptionPreview(text: String) {
    Task { @MainActor [weak self] in
      self?.receivePreview(text)
    }
  }

  nonisolated func onTranscriptionFinal(text: String, language: String) {
    Task { @MainActor [weak self] in
      self?.receiveFinal(text, language: language)
    }
  }

  nonisolated func onStatusChanged(signal: VistaStatusSignal) {
    Task { @MainActor [weak self] in
      self?.lastStatus = signal
    }
  }

  nonisolated func onError(msg: String) {
    Task { @MainActor [weak self] in
      self?.lastError = msg
    }
  }

  func receivePreview(_ text: String) {
    lastRawPreview = text.trimmingCharacters(in: .whitespacesAndNewlines)
    preview = uncommittedTail(from: lastRawPreview)
    refreshRendered()
  }

  func receiveFinal(_ text: String, language: String) {
    let finalText = uncommittedTail(from: text)
    guard !finalText.isEmpty else {
      preview = ""
      lastRawPreview = ""
      promotedPreviewPrefix = nil
      refreshRendered()
      return
    }

    appendCommitted(finalText)
    preview = ""
    lastRawPreview = ""
    promotedPreviewPrefix = nil
    lastLanguage = language
    refreshRendered()
  }

  func commitActivePreviewForCadence() {
    let previewText = preview.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !previewText.isEmpty else { return }
    appendCommitted(previewText)
    promotedPreviewPrefix = lastRawPreview.isEmpty ? previewText : lastRawPreview
    preview = ""
    refreshRendered()
  }

  private func activeEngine() -> VistaEngineProtocol {
    if let engine {
      return engine
    }
    let engine = engineFactory()
    self.engine = engine
    return engine
  }

  private func startCadenceCommitLoop() {
    guard cadenceCommitNanoseconds > 0 else { return }
    cadenceCommitTask?.cancel()
    cadenceCommitTask = Task { [weak self, cadenceCommitNanoseconds] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(nanoseconds: cadenceCommitNanoseconds)
        } catch {
          return
        }
        await self?.commitActivePreviewForCadence()
      }
    }
  }

  private func stopCadenceCommitLoop() {
    cadenceCommitTask?.cancel()
    cadenceCommitTask = nil
  }

  private func appendCommitted(_ text: String) {
    if committed.isEmpty {
      committed = text
    } else {
      committed.append("\n")
      committed.append(text)
    }
  }

  private func refreshRendered() {
    if committed.isEmpty {
      rendered = preview
    } else if preview.isEmpty {
      rendered = committed
    } else {
      rendered = committed + "\n" + preview
    }
  }

  private func uncommittedTail(from text: String) -> String {
    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return "" }

    if let promotedPreviewPrefix,
      let tail = tailByRemovingPrefix(promotedPreviewPrefix, from: cleaned)
    {
      return tail
    }

    if let tail = tailByRemovingPrefix(committed, from: cleaned) {
      return tail
    }

    return cleaned
  }

  private func tailByRemovingPrefix(_ prefix: String, from text: String) -> String? {
    let cleanedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanedPrefix.isEmpty else { return nil }

    if text == cleanedPrefix {
      return ""
    }

    if text.hasPrefix(cleanedPrefix) {
      let index = text.index(text.startIndex, offsetBy: cleanedPrefix.count)
      return String(text[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    let normalizedPrefix = Self.normalizedSpeechText(cleanedPrefix)
    let normalizedText = Self.normalizedSpeechText(text)
    guard !normalizedPrefix.isEmpty else { return nil }

    if normalizedText == normalizedPrefix {
      return ""
    }

    let prefixWithBoundary = normalizedPrefix + " "
    guard normalizedText.hasPrefix(prefixWithBoundary) else { return nil }
    let index = normalizedText.index(normalizedText.startIndex, offsetBy: prefixWithBoundary.count)
    return String(normalizedText[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func normalizedSpeechText(_ text: String) -> String {
    text
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
