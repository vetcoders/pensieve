import Combine
import Foundation

final class AutocompleteController: ObservableObject, @unchecked Sendable {
  typealias EngineFactory = @Sendable () -> VistaEngineProtocol

  static let defaultDebounceNanoseconds: UInt64 = 400_000_000

  /// Surfaced when no completion engine exists. The vendored qube-ffi bridge has no
  /// `uniffi_qube_ffi_fn_method_vistaengine_complete` symbol — `VistaEngine.complete`
  /// is a hand-added stub returning "" — so defaulting to the real engine would pay
  /// the full model-load cost only to render nothing. Until vista-kernel ships the
  /// completion method, the default controller has no engine and says so.
  static let engineUnavailableMessage =
    "AI autocomplete is not available yet: the bundled vista-kernel build has no completion support."

  @Published private(set) var suggestion: String?
  @Published private(set) var lastError: String?

  private let engineFactory: EngineFactory?
  private let debounceNanoseconds: UInt64
  private let maxTokens: UInt32
  private var engine: VistaEngineProtocol?
  private var requestID: UInt64 = 0
  private var completionTask: Task<Void, Never>?
  // initModel is expensive; the latch is engine-global state, deliberately NOT
  // request-scoped: once init fails we stop retrying on every keystroke, and a
  // single-flight guard keeps overlapping debounced requests from stacking
  // concurrent blocking initModel calls on the cooperative pool. cancel()
  // clears the latch so the user has a deliberate retry path.
  private var modelInitFailed = false
  private var modelInitErrorMessage: String?
  private var modelInitInFlight = false

  init(
    engine: VistaEngineProtocol? = nil,
    engineFactory: EngineFactory? = nil,
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

    guard let engine = activeEngine() else {
      lastError = Self.engineUnavailableMessage
      return
    }

    if modelInitFailed {
      lastError = modelInitErrorMessage
      return
    }

    let debounceNanoseconds = debounceNanoseconds
    let maxTokens = maxTokens
    completionTask = Task(priority: .userInitiated) { [weak self] in
      do {
        try await Task.sleep(nanoseconds: debounceNanoseconds)
        try Task.checkCancellation()
        if !engine.isModelLoaded() {
          guard let self, await self.beginModelInit(currentRequestID: currentRequestID) else {
            // Another request is already loading the model (or init already
            // failed); this request bails and a later keystroke picks up.
            return
          }
          do {
            try engine.initModel()
            await MainActor.run { self.modelInitInFlight = false }
          } catch {
            await MainActor.run {
              // The latch is engine-global: record the failure even when this
              // request was superseded, otherwise continuous typing would keep
              // re-running the expensive init. Only the UI fields stay gated
              // on the request still being current.
              self.modelInitInFlight = false
              self.modelInitFailed = true
              self.modelInitErrorMessage = error.localizedDescription
              guard self.requestID == currentRequestID else { return }
              self.suggestion = nil
              self.lastError = error.localizedDescription
            }
            return
          }
        }
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
    lastError = nil
    modelInitFailed = false
    modelInitErrorMessage = nil
  }

  /// Claims the single-flight init slot on the main actor. Returns false when
  /// init is already running or has already failed (latch engaged meanwhile).
  @MainActor
  private func beginModelInit(currentRequestID: UInt64) -> Bool {
    if modelInitFailed {
      if requestID == currentRequestID {
        suggestion = nil
        lastError = modelInitErrorMessage
      }
      return false
    }
    guard !modelInitInFlight else { return false }
    modelInitInFlight = true
    return true
  }

  private func activeEngine() -> VistaEngineProtocol? {
    if let engine {
      return engine
    }
    guard let engineFactory else { return nil }
    let engine = engineFactory()
    self.engine = engine
    return engine
  }
}
