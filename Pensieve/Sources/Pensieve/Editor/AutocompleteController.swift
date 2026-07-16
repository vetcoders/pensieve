import Combine
import Foundation

final class AutocompleteController: ObservableObject, @unchecked Sendable {
  typealias EngineFactory = @Sendable () -> VistaEngineProtocol

  static let defaultDebounceNanoseconds: UInt64 = 400_000_000

  /// Surfaced when the controller was built without any engine source.
  /// Production wires a real factory at the MarkdownEditorSurface init site;
  /// only engine-less test/preview controllers ever report this.
  static let engineUnavailableMessage =
    "AI autocomplete is unavailable because no completion provider is configured."

  /// User-facing copy for a configured engine whose completion provider is
  /// unavailable. Keep kernel names and environment-variable implementation
  /// details out of the editor status surface.
  static let completionProviderUnavailableMessage =
    "AI autocomplete is unavailable because the completion provider is not configured."

  /// vista-kernel flattens every completion failure into
  /// `VistaError.ModelError`; the unavailable class (LLM endpoint/model env
  /// not configured) is the only permanent one and is identified by this
  /// stable message prefix (vista-kernel llm/ai_formatting.rs). Transient
  /// classes (request/parse) must not latch, or one network blip would kill
  /// autocomplete until the next deliberate cancel.
  static let typedUnavailablePrefix = "completion LLM unavailable"

  @Published private(set) var suggestion: String?
  @Published private(set) var lastError: String?

  private let engineFactory: EngineFactory?
  private let debounceNanoseconds: UInt64
  private let maxTokens: UInt32
  // Engine resolution happens post-debounce inside the completion task (the
  // FFI constructor never runs on the typing path), so the cache is guarded
  // by a lock rather than main-actor isolation.
  private let engineLock = NSLock()
  private var engine: VistaEngineProtocol?
  private var requestID: UInt64 = 0
  private var completionTask: Task<Void, Never>?
  // Typed-unavailable is engine-global state, deliberately NOT request-scoped:
  // once the kernel reports the completion LLM is not configured, asking again
  // on every keystroke cannot succeed. cancel() clears the latch so the user
  // keeps a deliberate retry path.
  private var engineUnavailable = false
  private var engineUnavailableDetail: String?

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

  /// True when a suggestion could ever be produced (injected engine or
  /// factory). Checked on the typing path instead of resolving the engine,
  /// so no FFI call happens between keystrokes.
  var hasEngineSource: Bool {
    engineLock.lock()
    defer { engineLock.unlock() }
    return engine != nil || engineFactory != nil
  }

  /// Starts a completion request for committed text. Composition updates are
  /// explicit so an in-flight request cannot publish state while an IME owns
  /// the caret; the default keeps existing non-IME call sites source-compatible.
  func textDidChange(prefix: String, isComposing: Bool = false) {
    requestID &+= 1
    let currentRequestID = requestID
    completionTask?.cancel()
    completionTask = nil
    suggestion = nil
    lastError = nil

    guard !isComposing else { return }

    guard !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }

    guard hasEngineSource else {
      lastError = Self.engineUnavailableMessage
      return
    }

    if engineUnavailable {
      lastError = engineUnavailableDetail
      return
    }

    let debounceNanoseconds = debounceNanoseconds
    let maxTokens = maxTokens
    completionTask = Task(priority: .userInitiated) { [weak self] in
      do {
        try await Task.sleep(nanoseconds: debounceNanoseconds)
        try Task.checkCancellation()
        // Resolve through the weak reference without retaining the controller
        // across the provider await. This lets deinit cancel a hung request.
        guard let engine = self?.resolveEngine() else { return }
        let completion = try await engine.complete(prefix: prefix, maxTokens: maxTokens)
        try Task.checkCancellation()

        await MainActor.run { [weak self] in
          guard let self else { return }
          guard self.requestID == currentRequestID else { return }
          self.completionTask = nil
          self.suggestion = Self.singleLineSuggestion(from: completion)
        }
      } catch is CancellationError {
        await MainActor.run { [weak self] in
          guard let self, self.requestID == currentRequestID else { return }
          self.completionTask = nil
        }
      } catch {
        let message = Self.displayMessage(for: error)
        let latchesUnavailable = Self.isTypedUnavailable(error)
        await MainActor.run { [weak self] in
          guard let self else { return }
          // Every completion outcome is request-scoped. In particular, a
          // cancelled request must never silently re-arm the unavailable latch
          // after cancel() opened the explicit retry path.
          guard self.requestID == currentRequestID else { return }
          self.completionTask = nil
          if latchesUnavailable {
            self.engineUnavailable = true
            self.engineUnavailableDetail = message
            DebugTrace.log("autocomplete provider unavailable: \(message)")
          }
          self.suggestion = nil
          self.lastError = message
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
    engineUnavailable = false
    engineUnavailableDetail = nil
  }

  /// The ghost renderer is a single-line floating field at the caret
  /// (MarkdownTextView, `lineBreakMode = .byClipping`); publishing a
  /// multi-line completion would paint its tail squeezed to the right of the
  /// caret while Tab inserts the whole block — text the user never saw. Cap
  /// the suggestion at the first non-blank line so what the ghost shows is
  /// exactly what accept inserts. Providers occasionally prefix completions
  /// with blank/whitespace-only lines; those are not useful ghost text.
  static func singleLineSuggestion(from completion: String) -> String? {
    completion.components(separatedBy: .newlines).first { line in
      !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  /// Resolves (and caches) the engine. Runs inside the completion task, after
  /// the debounce: the `VistaEngine()` FFI constructor — a thin handle; the
  /// heavy whisper model is a process-global singleton the completion path
  /// never touches (qube-ffi lib.rs `init_model` vs `complete`) — is paid at
  /// most once, off the typing path.
  private func resolveEngine() -> VistaEngineProtocol? {
    engineLock.lock()
    defer { engineLock.unlock() }
    if let engine {
      return engine
    }
    guard let engineFactory else { return nil }
    let created = engineFactory()
    engine = created
    return created
  }

  /// `VistaError.errorDescription` is `String(reflecting:)` — unfit for the
  /// status surface. Unwrap the kernel message; fall back to the platform
  /// description for non-FFI errors (tests, futures).
  private static func displayMessage(for error: Error) -> String {
    if case VistaError.ModelError(let msg) = error {
      if msg.hasPrefix(typedUnavailablePrefix) {
        return completionProviderUnavailableMessage
      }

      let requestFailurePrefix = "completion request failed: "
      if msg.hasPrefix(requestFailurePrefix) {
        return "AI autocomplete failed: \(msg.dropFirst(requestFailurePrefix.count))"
      }

      let responseFailurePrefix = "completion response parse failed: "
      if msg.hasPrefix(responseFailurePrefix) {
        return "AI autocomplete returned an invalid response: "
          + msg.dropFirst(responseFailurePrefix.count)
      }

      return "AI autocomplete failed: \(msg)"
    }
    return "AI autocomplete failed: \(error.localizedDescription)"
  }

  private static func isTypedUnavailable(_ error: Error) -> Bool {
    guard case VistaError.ModelError(let msg) = error else { return false }
    return msg.hasPrefix(typedUnavailablePrefix)
  }
}
