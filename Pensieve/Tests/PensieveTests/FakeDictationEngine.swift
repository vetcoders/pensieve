import Foundation

@testable import Pensieve

/// Dictation-only test double. Autocomplete keeps `MockVistaAutocompleteEngine`
/// on the Vista completion path; this cut must not extend that mock.
final class FakeDictationEngine: DictationEngine, @unchecked Sendable {
  typealias FormattingHandler = @Sendable (String, Bool) async throws -> String
  typealias InitModelHandler = @Sendable () throws -> Void
  typealias IsRecordingHandler = @Sendable () -> Bool
  typealias RemoveEventListenerHandler = @Sendable () -> Void
  typealias StartRecordingHandler = @Sendable (String?) throws -> Void
  typealias StopRecordingHandler = @Sendable () throws -> String

  private let formattingAvailable: Bool
  private let formattingHandler: FormattingHandler
  private let initModelHandler: InitModelHandler
  private let isRecordingHandler: IsRecordingHandler
  private let modelLoaded: Bool
  private let removeEventListenerHandler: RemoveEventListenerHandler
  private let startRecordingHandler: StartRecordingHandler
  private let stopRecordingHandler: StopRecordingHandler

  init(
    formattingAvailable: Bool = false,
    formattingHandler: @escaping FormattingHandler = { text, _ in text },
    modelLoaded: Bool = true,
    initModelHandler: @escaping InitModelHandler = {},
    isRecordingHandler: @escaping IsRecordingHandler = { false },
    removeEventListenerHandler: @escaping RemoveEventListenerHandler = {},
    startRecordingHandler: @escaping StartRecordingHandler = { _ in },
    stopRecordingHandler: @escaping StopRecordingHandler = { "" }
  ) {
    self.formattingAvailable = formattingAvailable
    self.formattingHandler = formattingHandler
    self.modelLoaded = modelLoaded
    self.initModelHandler = initModelHandler
    self.isRecordingHandler = isRecordingHandler
    self.removeEventListenerHandler = removeEventListenerHandler
    self.startRecordingHandler = startRecordingHandler
    self.stopRecordingHandler = stopRecordingHandler
  }

  func isRecording() -> Bool { isRecordingHandler() }
  func isModelLoaded() -> Bool { modelLoaded }
  func initModel() throws { try initModelHandler() }
  func startRecording(language: String?) throws { try startRecordingHandler(language) }
  func stopRecording() throws -> String { try stopRecordingHandler() }
  func setEventListener(listener: DictationEventListener) {}
  func removeEventListener() { removeEventListenerHandler() }
  func isFormattingAvailable() -> Bool { formattingAvailable }
  func formatText(text: String, assistive: Bool) async throws -> String {
    try await formattingHandler(text, assistive)
  }
}
