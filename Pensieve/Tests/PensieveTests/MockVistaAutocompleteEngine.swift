import Foundation

@testable import Pensieve

/// Thrown by `MockVistaAutocompleteEngine` for operations outside its
/// autocomplete/formatting scope instead of crashing the test process.
struct MockVistaAutocompleteEngineUnsupportedOperation: Error, LocalizedError {
  let operation: String

  var errorDescription: String? {
    "MockVistaAutocompleteEngine does not support \(operation)"
  }
}

final class MockVistaAutocompleteEngine: VistaEngineProtocol, @unchecked Sendable {
  typealias CompletionHandler = @Sendable (String, UInt32) async throws -> String
  typealias FormattingHandler = @Sendable (String, Bool) async throws -> String
  typealias InitModelHandler = @Sendable () throws -> Void
  typealias IsRecordingHandler = @Sendable () -> Bool
  typealias RemoveEventListenerHandler = @Sendable () -> Void
  typealias StartRecordingHandler = @Sendable (String?) throws -> Void
  typealias StopRecordingHandler = @Sendable () throws -> String

  private let completionHandler: CompletionHandler
  private let formattingAvailable: Bool
  private let formattingHandler: FormattingHandler
  private let initModelHandler: InitModelHandler
  private let isRecordingHandler: IsRecordingHandler
  private let modelLoaded: Bool
  private let removeEventListenerHandler: RemoveEventListenerHandler
  private let startRecordingHandler: StartRecordingHandler
  private let stopRecordingHandler: StopRecordingHandler

  init(
    completionHandler: @escaping CompletionHandler =
      MockVistaAutocompleteEngine.defaultCompletionHandler,
    formattingAvailable: Bool = false,
    formattingHandler: @escaping FormattingHandler = { text, _ in text },
    modelLoaded: Bool = true,
    initModelHandler: @escaping InitModelHandler = {},
    isRecordingHandler: @escaping IsRecordingHandler = { false },
    removeEventListenerHandler: @escaping RemoveEventListenerHandler = {},
    startRecordingHandler: @escaping StartRecordingHandler = { _ in },
    stopRecordingHandler: @escaping StopRecordingHandler = { "" }
  ) {
    self.completionHandler = completionHandler
    self.formattingAvailable = formattingAvailable
    self.formattingHandler = formattingHandler
    self.modelLoaded = modelLoaded
    self.initModelHandler = initModelHandler
    self.isRecordingHandler = isRecordingHandler
    self.removeEventListenerHandler = removeEventListenerHandler
    self.startRecordingHandler = startRecordingHandler
    self.stopRecordingHandler = stopRecordingHandler
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

  func initModel() throws { try initModelHandler() }

  func isFormattingAvailable() -> Bool { formattingAvailable }

  func isModelLoaded() -> Bool { modelLoaded }

  func isRecording() -> Bool { isRecordingHandler() }

  func latestHistoryPath() throws -> String { "" }

  func loadConfig() -> VistaConfig {
    // Signature cannot throw; return a neutral config for the test double.
    VistaConfig(
      whisperLanguage: .english,
      useLocalStt: false,
      localModel: "",
      holdExclusive: false,
      beepOnStart: false,
      soundVolume: 0,
      aiFormattingEnabled: false
    )
  }

  func removeEventListener() { removeEventListenerHandler() }

  func resetConversation() {}

  func resetConversationForMode(mode: VistaAiMode) {}

  func saveHistory(text: String) -> String { "" }

  func setEventListener(listener: VistaEventListener) {}

  func shouldShowOnboarding() -> Bool { false }

  func startPipeline(language: String?) throws {}

  func startRecording(language: String?) throws { try startRecordingHandler(language) }

  func stopPipeline() throws -> String { "" }

  func stopRecording() throws -> String { try stopRecordingHandler() }

  func transcribeFile(audioPath: String) async throws -> TranscriptionResult {
    throw MockVistaAutocompleteEngineUnsupportedOperation(operation: "transcribeFile")
  }

  func updateConfig(key: String, value: String) throws {}
}
