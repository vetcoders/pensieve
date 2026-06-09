import Combine
import Foundation

final class AutocompleteController: ObservableObject, @unchecked Sendable {
  typealias EngineFactory = @Sendable () -> VistaEngineProtocol

  static let defaultDebounceNanoseconds: UInt64 = 400_000_000

  @Published private(set) var suggestion: String?
  @Published private(set) var lastError: String?

  private let engineFactory: EngineFactory
  private let debounceNanoseconds: UInt64
  private let maxTokens: UInt32
  private var engine: VistaEngineProtocol?
  private var requestID: UInt64 = 0
  private var completionTask: Task<Void, Never>?

  init(
    engine: VistaEngineProtocol? = nil,
    engineFactory: @escaping EngineFactory = { MockVistaAutocompleteEngine() },
    debounceNanoseconds: UInt64 = AutocompleteController.defaultDebounceNanoseconds,
    maxTokens: UInt32 = 32
  ) {
    self.engine = engine
    self.engineFactory = engineFactory
    self.debounceNanoseconds = debounceNanoseconds
    self.maxTokens = maxTokens
  }

  deinit {
    completionTask?.cancel()
  }

  func textDidChange(prefix: String) {
    requestID &+= 1
    let currentRequestID = requestID
    completionTask?.cancel()
    suggestion = nil
    lastError = nil

    guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }

    let engine = activeEngine()
    let debounceNanoseconds = debounceNanoseconds
    let maxTokens = maxTokens
    completionTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: debounceNanoseconds)
        try Task.checkCancellation()
        let completion = try await engine.complete(prefix: prefix, maxTokens: maxTokens)
        try Task.checkCancellation()

        await MainActor.run { [weak self] in
          guard let self else { return }
          guard self.requestID == currentRequestID else { return }
          let cleaned = completion.trimmingCharacters(in: .newlines)
          self.suggestion = cleaned.isEmpty ? nil : cleaned
        }
      } catch is CancellationError {
        return
      } catch {
        await MainActor.run { [weak self] in
          guard let self else { return }
          guard self.requestID == currentRequestID else { return }
          self.suggestion = nil
          self.lastError = error.localizedDescription
        }
      }
    }
  }

  func cancel() {
    requestID &+= 1
    completionTask?.cancel()
    completionTask = nil
    suggestion = nil
  }

  private func activeEngine() -> VistaEngineProtocol {
    if let engine {
      return engine
    }
    let engine = engineFactory()
    self.engine = engine
    return engine
  }
}

final class MockVistaAutocompleteEngine: VistaEngineProtocol, @unchecked Sendable {
  typealias CompletionHandler = @Sendable (String, UInt32) async throws -> String
  typealias FormattingHandler = @Sendable (String, Bool) async throws -> String

  private let completionHandler: CompletionHandler
  private let formattingAvailable: Bool
  private let formattingHandler: FormattingHandler

  init(
    completionHandler: @escaping CompletionHandler =
      MockVistaAutocompleteEngine.defaultCompletionHandler,
    formattingAvailable: Bool = false,
    formattingHandler: @escaping FormattingHandler = { text, _ in text }
  ) {
    self.completionHandler = completionHandler
    self.formattingAvailable = formattingAvailable
    self.formattingHandler = formattingHandler
  }

  func complete(prefix: String, maxTokens: UInt32) async throws -> String {
    try await completionHandler(prefix, maxTokens)
  }

  private static let defaultCompletionHandler: CompletionHandler = { prefix, maxTokens in
    guard maxTokens > 0 else { return "" }
    guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
    return " continuation"
  }

  func configDir() -> String { "" }

  func formatText(text: String, assistive: Bool) async throws -> String {
    try await formattingHandler(text, assistive)
  }

  func getAssistivePrompt() -> String { "" }

  func getFormattingPrompt() -> String { "" }

  func hasActiveConversation() -> Bool { false }

  func initModel() throws {}

  func isFormattingAvailable() -> Bool { formattingAvailable }

  func isModelLoaded() -> Bool { true }

  func isRecording() -> Bool { false }

  func latestHistoryPath() throws -> String { "" }

  func loadConfig() -> VistaConfig {
    fatalError("MockVistaAutocompleteEngine.loadConfig is outside autocomplete scope")
  }

  func removeEventListener() {}

  func resetConversation() {}

  func resetConversationForMode(mode: VistaAiMode) {}

  func saveHistory(text: String) -> String { "" }

  func setEventListener(listener: VistaEventListener) {}

  func shouldShowOnboarding() -> Bool { false }

  func startPipeline(language: String?) throws {}

  func startRecording(language: String?) throws {}

  func stopPipeline() throws -> String { "" }

  func stopRecording() throws -> String { "" }

  func transcribeFile(audioPath: String) async throws -> TranscriptionResult {
    fatalError("MockVistaAutocompleteEngine.transcribeFile is outside autocomplete scope")
  }

  func updateConfig(key: String, value: String) throws {}
}
