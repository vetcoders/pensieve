import Combine
import Foundation

@MainActor
final class TranscriptionService: ObservableObject, VistaEventListener, @unchecked Sendable {
  typealias EngineFactory = @Sendable () -> VistaEngineProtocol

  @Published private(set) var committed: String
  @Published private(set) var preview: String
  @Published private(set) var rendered: String
  @Published private(set) var isRecording: Bool
  @Published private(set) var lastLanguage: String?
  @Published private(set) var lastStatus: VistaStatusSignal?
  @Published private(set) var lastError: String?

  private let engineFactory: EngineFactory
  private var engine: VistaEngineProtocol?

  init(
    engine: VistaEngineProtocol? = nil,
    engineFactory: @escaping EngineFactory = { VistaEngine() }
  ) {
    self.engine = engine
    self.engineFactory = engineFactory
    self.committed = ""
    self.preview = ""
    self.rendered = ""
    self.isRecording = false
  }

  func startRecording(language: String? = nil) throws {
    let engine = activeEngine()
    engine.setEventListener(listener: self)
    if !engine.isModelLoaded() {
      try engine.initModel()
    }
    try engine.startRecording(language: language)
    isRecording = true
    lastError = nil
  }

  @discardableResult
  func stopRecording() throws -> String {
    guard let engine else {
      isRecording = false
      return rendered
    }

    let finalText = try engine.stopRecording()
    isRecording = false
    return finalText
  }

  func resetTranscript() {
    committed = ""
    preview = ""
    rendered = ""
    lastLanguage = nil
    lastError = nil
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
    preview = text
    refreshRendered()
  }

  func receiveFinal(_ text: String, language: String) {
    let finalText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !finalText.isEmpty else {
      preview = ""
      refreshRendered()
      return
    }

    appendCommitted(finalText)
    preview = ""
    lastLanguage = language
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
}
