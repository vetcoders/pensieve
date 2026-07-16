import AVFoundation
import Combine
import Foundation

enum TranscriptionLanguageChoice: String, CaseIterable, Identifiable, Sendable {
  case automatic
  case polish
  case english

  var id: String { rawValue }

  var title: String {
    switch self {
    case .automatic:
      return "Auto"
    case .polish:
      return "Polish"
    case .english:
      return "English"
    }
  }

  /// Locale identifiers accepted by the native speech engine. `nil` keeps
  /// provider-side automatic language detection enabled.
  var engineIdentifier: String? {
    switch self {
    case .automatic:
      return nil
    case .polish:
      return "pl-PL"
    case .english:
      return "en-US"
    }
  }
}

enum TranscriptionFormatMode: String, CaseIterable, Identifiable, Sendable {
  case polish
  case kurier

  var id: String { rawValue }

  var title: String {
    switch self {
    case .polish:
      return "Clean Up"
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
  typealias MicrophonePermissionPolicy = @Sendable (VistaEngineProtocol) -> Bool
  typealias MicrophonePermissionRequester = @Sendable () async throws -> Void

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
  private let requiresMicrophonePermission: MicrophonePermissionPolicy
  private let microphonePermissionRequester: MicrophonePermissionRequester
  private let cadenceCommitNanoseconds: UInt64
  private var engine: VistaEngineProtocol?
  private var cadenceCommitTask: Task<Void, Never>?
  private var errorCleanupTask: Task<Void, Never>?
  private var startRecordingTask: Task<Void, Never>?
  private var isStoppingRecording = false
  private var lastRawPreview: String = ""
  private var promotedPreviewPrefix: String?

  init(
    engine: VistaEngineProtocol? = nil,
    engineFactory: @escaping EngineFactory = { VistaEngine() },
    requiresMicrophonePermission: @escaping MicrophonePermissionPolicy = { $0 is VistaEngine },
    microphonePermissionRequester: @escaping MicrophonePermissionRequester = {
      try await TranscriptionService.ensureMicrophonePermission()
    },
    cadenceCommitNanoseconds: UInt64 = 8_000_000_000
  ) {
    self.engine = engine
    self.engineFactory = engineFactory
    self.requiresMicrophonePermission = requiresMicrophonePermission
    self.microphonePermissionRequester = microphonePermissionRequester
    self.cadenceCommitNanoseconds = cadenceCommitNanoseconds
    self.committed = ""
    self.preview = ""
    self.rendered = ""
    self.isRecording = false
    self.isFormatting = false
  }

  deinit {
    cadenceCommitTask?.cancel()
    errorCleanupTask?.cancel()
    startRecordingTask?.cancel()
  }

  private static func ensureMicrophonePermission() async throws {
    try await AppPermissionService.ensureMicrophonePermission(openSettingsOnFailure: true)
  }

  func startRecording(language: String? = nil) {
    guard !isRecording, !isPreparingRecording else { return }
    let engine = activeEngine()
    isPreparingRecording = true
    lastError = nil
    let requiresMicrophonePermission = self.requiresMicrophonePermission
    let microphonePermissionRequester = self.microphonePermissionRequester
    startRecordingTask = Task {
      [weak self, requiresMicrophonePermission, microphonePermissionRequester] in
      do {
        if requiresMicrophonePermission(engine) {
          try await microphonePermissionRequester()
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
      let prepareTask = Task.detached(priority: .userInitiated) { [weak self] in
        // A previous crashed/cancelled owner can leave the shared capture
        // engine active. Drain that stale session before attaching this
        // service, so old callbacks cannot leak into a fresh transcript.
        if engine.isRecording() {
          _ = try engine.stopRecording()
        }
        if !engine.isModelLoaded() {
          try engine.initModel()
        }
        // Owner torn down while the model was loading: never start capture.
        try Task.checkCancellation()
        guard let listener = self else { throw CancellationError() }
        engine.setEventListener(listener: listener)
        do {
          try engine.startRecording(language: language)
        } catch {
          if engine.isRecording() {
            _ = try? engine.stopRecording()
          }
          engine.removeEventListener()
          throw error
        }
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
          Task.detached {
            _ = try? engine.stopRecording()
            engine.removeEventListener()
          }
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
    isStoppingRecording = true
    // Always clear recording state, even when engine.stopRecording() throws;
    // otherwise the UI stays in "Recording" and the cadence loop never stops.
    defer {
      isRecording = false
      isStoppingRecording = false
      stopCadenceCommitLoop()
    }

    guard let engine else {
      return rendered
    }

    defer { engine.removeEventListener() }
    let finalText = try engine.stopRecording()
    if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      commitActivePreviewForCadence()
    } else {
      commitFinalText(finalText, language: nil)
    }
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
    dispatchStatus = nil
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
      self?.handleEngineError(msg)
    }
  }

  private func handleEngineError(_ message: String) {
    lastError = message
    guard !isStoppingRecording else { return }

    let wasPreparing = isPreparingRecording
    let wasRecording = isRecording
    isPreparingRecording = false
    isRecording = false
    stopCadenceCommitLoop()

    if wasPreparing {
      // The preparation task owns its detached capture attempt. Cancellation
      // drives its existing rollback path without racing a second stop call.
      startRecordingTask?.cancel()
      startRecordingTask = nil
      return
    }

    guard wasRecording, let engine else { return }
    errorCleanupTask?.cancel()
    errorCleanupTask = Task.detached(priority: .userInitiated) { [weak self] in
      // Error callbacks can arrive before the engine publishes its final
      // transcript. Stop is the drain barrier; failure still must detach the
      // listener and leave the UI idle.
      let finalText = (try? engine.stopRecording()) ?? ""
      engine.removeEventListener()
      await self?.finishEngineErrorCleanup(finalText: finalText)
    }
  }

  private func finishEngineErrorCleanup(finalText: String) {
    errorCleanupTask = nil
    if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      commitActivePreviewForCadence()
    } else {
      commitFinalText(finalText, language: nil)
    }
  }

  func receivePreview(_ text: String) {
    lastRawPreview = text.trimmingCharacters(in: .whitespacesAndNewlines)
    preview = uncommittedTail(from: lastRawPreview)
    refreshRendered()
  }

  func receiveFinal(_ text: String, language: String) {
    commitFinalText(text, language: language)
  }

  private func commitFinalText(_ text: String, language: String?) {
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
    if let language, !language.isEmpty {
      lastLanguage = language
    }
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
        self?.commitActivePreviewForCadence()
      }
    }
  }

  private func stopCadenceCommitLoop() {
    cadenceCommitTask?.cancel()
    cadenceCommitTask = nil
  }

  private func appendCommitted(_ text: String) {
    committed = joiningTranscript(committed, text)
  }

  private func refreshRendered() {
    if committed.isEmpty {
      rendered = preview
    } else if preview.isEmpty {
      rendered = committed
    } else {
      rendered = joiningTranscript(committed, preview)
    }
  }

  /// Dictation callbacks describe consecutive pieces of one spoken passage.
  /// Join them as prose instead of leaking the engine's callback cadence into
  /// the Markdown document as artificial paragraph breaks.
  private func joiningTranscript(_ leading: String, _ trailing: String) -> String {
    guard !leading.isEmpty else { return trailing }
    guard !trailing.isEmpty else { return leading }

    let punctuationWithoutLeadingSpace = CharacterSet(charactersIn: ".,!?;:)]}»”’…")
    let openingWithoutTrailingSpace = CharacterSet(charactersIn: "([{«“‘")
    let trailingStartsWithPunctuation =
      trailing.unicodeScalars.first.map {
        punctuationWithoutLeadingSpace.contains($0)
      } ?? false
    let leadingEndsWithOpeningPunctuation =
      leading.unicodeScalars.last.map {
        openingWithoutTrailingSpace.contains($0)
      } ?? false

    let separator = trailingStartsWithPunctuation || leadingEndsWithOpeningPunctuation ? "" : " "
    return leading + separator + trailing
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
