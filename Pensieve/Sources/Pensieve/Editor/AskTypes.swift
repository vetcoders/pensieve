import CodescribeBridge
import Foundation

enum AskThreadPhase: Equatable, Sendable {
  case idle
  case streaming
  case completed
  case failed(String)
}

struct AskTurn: Equatable, Identifiable, Sendable {
  enum Role: Equatable, Sendable {
    case user
    case assistant
    case dictation
  }

  let id: UUID
  var role: Role
  var text: String
  var isStreaming: Bool
  /// Exact pending-attachment IDs joined to this user turn at send time.
  var attachmentIDs: [UUID]

  init(
    id: UUID = UUID(), role: Role, text: String, isStreaming: Bool = false,
    attachmentIDs: [UUID] = []
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.isStreaming = isStreaming
    self.attachmentIDs = attachmentIDs
  }
}

/// The credential Ask is gated on. Which case applies is read from the lane Ask
/// actually streams through — Pensieve's embedded assistive lane (see
/// `GrokAccountSnapshot.askProvider(apiKey:)`) — so Pensieve keeps no provider
/// choice of its own that could disagree with where a question is sent.
enum AskProvider: Equatable, Sendable {
  /// OpenAI / Anthropic: the configured provider's API key (the W5 rule).
  case apiKey(String?)
  /// Grok (xAI), authenticated by device-code OAuth — never by an API key field.
  case grok(accountAuthorized: Bool)
  /// Codex (OpenAI account), authenticated by the provider's OAuth sign-in —
  /// never by the API-key field.
  case codex(accountAuthorized: Bool)
}

/// The endpoint and model an API-key send is actually configured with. Ask
/// readiness reads this so a genuinely loopback Responses endpoint can run
/// without a credential while remote providers keep the API-key rule.
struct AskEndpointContext: Equatable, Sendable {
  var endpoint: String
  var model: String

  init(endpoint: String, model: String) {
    self.endpoint = endpoint
    self.model = model
  }

  init?(configuration: CsDocumentProvider?) {
    guard let configuration else { return nil }
    self.init(endpoint: configuration.endpoint, model: configuration.model)
  }
}

/// API-key providers are ready when the key is non-empty, or when the
/// configured endpoint is a genuinely loopback HTTP(S) Responses endpoint
/// with a non-empty model (the donor's key-optional local lane). Grok and
/// Codex are ready only when the embedded engine reports that Pensieve
/// account authorized.
enum AskReadiness {
  static let apiKeyNotReadyMessage = "Add a provider API key in Settings before asking."
  static let grokNotReadyMessage = "Sign in to Grok in Settings ▸ AI before asking."
  static let codexNotReadyMessage = "Sign in to Codex in Settings ▸ AI before asking."

  static func isReady(_ provider: AskProvider, context: AskEndpointContext? = nil) -> Bool {
    switch provider {
    case .apiKey(let apiKey):
      let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !key.isEmpty { return true }
      return context.map { isKeylessLoopback(endpoint: $0.endpoint, model: $0.model) } ?? false
    case .grok(let accountAuthorized), .codex(let accountAuthorized):
      return accountAuthorized
    }
  }

  /// Keyless Ask is lawful only against a real loopback server: a valid
  /// http(s) URL whose host is exactly localhost / 127.0.0.1 / ::1 (the
  /// shared `ProviderSettings` set — no parallel parser), with a model to
  /// send. Lookalike hosts and non-HTTP schemes stay on the API-key rule.
  static func isKeylessLoopback(endpoint: String, model: String) -> Bool {
    guard let url = URL(string: endpoint),
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      url.host != nil
    else { return false }
    guard ProviderSettings.isLocalProviderEndpoint(endpoint) else { return false }
    return !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func notReadyMessage(for provider: AskProvider) -> String {
    switch provider {
    case .apiKey: return apiKeyNotReadyMessage
    case .grok: return grokNotReadyMessage
    case .codex: return codexNotReadyMessage
    }
  }

  /// The composer's chip names the credential that will actually be used.
  static func chipLabel(for provider: AskProvider, context: AskEndpointContext? = nil) -> String {
    switch provider {
    case .apiKey:
      guard isReady(provider, context: context) else { return "Needs API key" }
      return provider.apiKeyPresent ? "Ready" : "Local endpoint ready"
    case .grok: return isReady(provider) ? "Grok ready" : "Grok: sign in"
    case .codex: return isReady(provider) ? "Codex ready" : "Codex: sign in"
    }
  }
}

extension AskProvider {
  fileprivate var apiKeyPresent: Bool {
    guard case .apiKey(let key) = self else { return false }
    return !(key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
  }
}
