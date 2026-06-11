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
  // request-scoped: once init fails we stop retrying on every keystroke.
  // cancel() clears the latch so the user has a deliberate retry path.
  private var modelInitFailed = false
  private var modelInitErrorMessage: String?
  // Single-flight init as a SHARED task: overlapping debounced requests all
  // await the same init instead of bailing, so the newest request gets its
  // completion the moment the model is ready rather than silently dying and
  // waiting for another keystroke.
  private var modelInitTask: Task<Void, Error>?

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
          guard let self,
            let initTask = await self.sharedModelInitTask(
              engine: engine, currentRequestID: currentRequestID)
          else {
            // Init already failed (latch engaged); sharedModelInitTask
            // surfaced the latched error if this request is still current.
            return
          }
          // Awaiting the shared init keeps THIS request alive through the
          // model load: a request that arrives while another one is already
          // initializing must not bail, or the current prefix would never
          // get a suggestion until the next keystroke. An init failure
          // rethrows here and lands in the catch below (UI gated on the
          // request still being current).
          try await initTask.value
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

  /// Claims or joins the single-flight model init on the main actor. Returns
  /// nil when init has already failed (latch engaged) and surfaces the latched
  /// error if the request is still current. The latch is engine-global,
  /// deliberately NOT request-scoped: the init task arms it even when every
  /// awaiting request was superseded, otherwise continuous typing would keep
  /// re-running the expensive init.
  @MainActor
  private func sharedModelInitTask(
    engine: VistaEngineProtocol, currentRequestID: UInt64
  ) -> Task<Void, Error>? {
    if modelInitFailed {
      if requestID == currentRequestID {
        suggestion = nil
        lastError = modelInitErrorMessage
      }
      return nil
    }
    if let modelInitTask {
      return modelInitTask
    }
    let task = Task.detached(priority: .userInitiated) { [weak self] in
      do {
        try engine.initModel()
        await MainActor.run { [weak self] in
          self?.modelInitTask = nil
        }
      } catch {
        await MainActor.run { [weak self] in
          guard let self else { return }
          self.modelInitTask = nil
          self.modelInitFailed = true
          self.modelInitErrorMessage = error.localizedDescription
        }
        throw error
      }
    }
    modelInitTask = task
    return task
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
