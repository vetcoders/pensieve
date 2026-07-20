import Combine
import Foundation

protocol AutocompleteCompleting: Sendable {
  func complete(context: AutocompleteContext, maxTokens: UInt32) async throws -> String
}

private final class VistaAutocompleteAdapter: AutocompleteCompleting, @unchecked Sendable {
  private let engine: VistaEngineProtocol

  init(engine: VistaEngineProtocol) {
    self.engine = engine
  }

  func complete(context: AutocompleteContext, maxTokens: UInt32) async throws -> String {
    try await engine.complete(prefix: context.beforeCursor, maxTokens: maxTokens)
  }
}

final class AutocompleteController: ObservableObject, @unchecked Sendable {
  typealias EngineFactory = @Sendable () -> VistaEngineProtocol
  typealias CompletionFactory = @Sendable () -> any AutocompleteCompleting

  static let defaultDebounceNanoseconds: UInt64 = 400_000_000

  /// Surfaced when the controller was built without any engine source.
  /// Production wires a real factory at the MarkdownEditorSurface init site;
  /// only engine-less test/preview controllers ever report this.
  static let engineUnavailableMessage =
    "AI autocomplete needs a completion provider. Configure one in Settings."

  /// User-facing copy for a configured engine whose completion provider is
  /// unavailable. Keep kernel names and environment-variable implementation
  /// details out of the editor status surface.
  static let completionProviderUnavailableMessage =
    "AI autocomplete needs a completion provider. Configure one in Settings."

  /// vista-kernel flattens every completion failure into
  /// `VistaError.ModelError`; the unavailable class (LLM endpoint/model env
  /// not configured) is the only permanent one and is identified by this
  /// stable message prefix (vista-kernel llm/ai_formatting.rs). Transient
  /// classes (request/parse) must not latch, or one network blip would kill
  /// autocomplete until the next deliberate cancel.
  static let typedUnavailablePrefix = "completion LLM unavailable"

  @Published private(set) var suggestion: String?
  @Published private(set) var lastError: String?

  private let completionFactory: CompletionFactory?
  private let debounceNanoseconds: UInt64
  private let maxTokens: UInt32
  // Backend resolution happens post-debounce inside the completion task, so
  // the cache is guarded by a lock rather than main-actor isolation.
  private let completionLock = NSLock()
  private var completionBackend: (any AutocompleteCompleting)?
  private var requestID: UInt64 = 0
  private var completionTask: Task<Void, Never>?
  private var providerSettingsCancellable: AnyCancellable?
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
    if let engine {
      self.completionBackend = VistaAutocompleteAdapter(engine: engine)
    } else {
      self.completionBackend = nil
    }
    if let engineFactory {
      self.completionFactory = { VistaAutocompleteAdapter(engine: engineFactory()) }
    } else {
      self.completionFactory = nil
    }
    self.debounceNanoseconds = debounceNanoseconds
    self.maxTokens = maxTokens
    observeProviderSettings()
  }

  init(
    completionFactory: @escaping CompletionFactory,
    debounceNanoseconds: UInt64 = AutocompleteController.defaultDebounceNanoseconds,
    maxTokens: UInt32 = 32
  ) {
    self.completionBackend = nil
    self.completionFactory = completionFactory
    self.debounceNanoseconds = debounceNanoseconds
    self.maxTokens = maxTokens
    observeProviderSettings()
  }

  private func observeProviderSettings() {
    self.providerSettingsCancellable = NotificationCenter.default.publisher(
      for: .completionProviderSettingsDidChange
    ).sink { [weak self] _ in
      // The live backend resolves provider env on every request. Saving settings
      // only needs to clear the permanent-unavailable latch; the next keystroke
      // immediately observes the new process values.
      self?.cancel()
    }
  }

  deinit {
    completionTask?.cancel()
    providerSettingsCancellable?.cancel()
  }

  /// True when a suggestion could ever be produced (injected engine or
  /// factory). Checked on the typing path instead of resolving the engine,
  /// so no FFI call happens between keystrokes.
  var hasEngineSource: Bool {
    completionLock.lock()
    defer { completionLock.unlock() }
    return completionBackend != nil || completionFactory != nil
  }

  /// Starts a completion request for committed text. Composition updates are
  /// explicit so an in-flight request cannot publish state while an IME owns
  /// the caret; the default keeps existing non-IME call sites source-compatible.
  func textDidChange(context: AutocompleteContext, isComposing: Bool = false) {
    requestID &+= 1
    let currentRequestID = requestID
    completionTask?.cancel()
    completionTask = nil
    suggestion = nil
    lastError = nil

    guard !isComposing else { return }

    guard !context.beforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
        guard let backend = self?.resolveCompletionBackend() else { return }
        let completion = try await backend.complete(context: context, maxTokens: maxTokens)
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

  /// Compatibility seam for focused tests and non-editor callers that only
  /// own a prefix. Production editor requests always include suffix context.
  func textDidChange(prefix: String, isComposing: Bool = false) {
    textDidChange(
      context: AutocompleteContext(beforeCursor: prefix, afterCursor: ""),
      isComposing: isComposing)
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

  /// Resolves and caches the completion backend after the debounce. Production
  /// uses a small Responses client; the Vista adapter remains for focused tests
  /// and compatible injected engines without coupling autocomplete to STT.
  private func resolveCompletionBackend() -> (any AutocompleteCompleting)? {
    completionLock.lock()
    defer { completionLock.unlock() }
    if let completionBackend {
      return completionBackend
    }
    guard let completionFactory else { return nil }
    let created = completionFactory()
    completionBackend = created
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
