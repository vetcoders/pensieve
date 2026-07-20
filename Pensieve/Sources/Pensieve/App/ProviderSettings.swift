import Combine
import Darwin
import Foundation
import Security

extension Notification.Name {
  /// Posted after provider settings have been persisted and applied to the
  /// process environment. Autocomplete controllers use it to clear the
  /// typed-unavailable latch before the next request.
  static let completionProviderSettingsDidChange = Notification.Name(
    "io.vetcoders.pensieve.completion-provider-settings-did-change")
}

protocol ProviderAPIKeyStoring {
  func loadAPIKey() throws -> String?
  func storeAPIKey(_ apiKey: String) throws
  func deleteAPIKey() throws
}

protocol ProviderEnvironmentManaging {
  func value(forKey key: String) -> String?
  func setValue(_ value: String, forKey key: String) throws
  func removeValue(forKey key: String) throws
}

enum CompletionProviderShape: String, CaseIterable, Identifiable {
  case openAIResponses = "openai-responses"
  case anthropicMessages = "anthropic-messages"

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .openAIResponses:
      return "OpenAI Responses"
    case .anthropicMessages:
      return "Anthropic Messages"
    }
  }

  var endpointPrompt: String {
    switch self {
    case .openAIResponses:
      return "https://api.example.com/v1/responses"
    case .anthropicMessages:
      return "https://api.example.com/v1/messages"
    }
  }

  /// This is the single product gate to flip after vista-kernel gains a real
  /// Anthropic Messages request/header/response implementation.
  var isSupportedByCompletionEngine: Bool {
    switch self {
    case .openAIResponses:
      return true
    case .anthropicMessages:
      return false
    }
  }

  var unsupportedMessage: String? {
    guard !isSupportedByCompletionEngine else { return nil }
    return "Anthropic Messages support is coming in an upcoming update."
  }
}

enum ProviderSettingsError: LocalizedError {
  case endpointRequired
  case modelRequired
  case unsupportedProviderShape(CompletionProviderShape)
  case invalidKeychainData
  case keychain(OSStatus)
  case environment(operation: String, key: String, code: Int32)

  var errorDescription: String? {
    switch self {
    case .endpointRequired:
      return "Enter a provider endpoint."
    case .modelRequired:
      return "Enter a provider model."
    case .unsupportedProviderShape(let shape):
      return
        "\(shape.displayName) requires a completion-engine update and was not saved or applied."
    case .invalidKeychainData:
      return "The saved provider API key could not be read."
    case .keychain(let status):
      let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
      return "The provider API key could not be accessed in Keychain (\(detail))."
    case .environment(let operation, let key, let code):
      return "Could not \(operation) the live provider setting \(key) (errno \(code))."
    }
  }
}

struct KeychainProviderAPIKeyStore: ProviderAPIKeyStoring {
  static let service = "io.vetcoders.pensieve.completion-provider"
  static let account = "api-key"

  let service: String
  let account: String

  init(service: String = Self.service, account: String = Self.account) {
    self.service = service
    self.account = account
  }

  func loadAPIKey() throws -> String? {
    var query = baseQuery
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw ProviderSettingsError.keychain(status) }
    guard let data = result as? Data, let apiKey = String(data: data, encoding: .utf8) else {
      throw ProviderSettingsError.invalidKeychainData
    }
    return apiKey
  }

  func storeAPIKey(_ apiKey: String) throws {
    let data = Data(apiKey.utf8)
    let attributes = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw ProviderSettingsError.keychain(updateStatus)
    }

    var item = baseQuery
    item[kSecValueData as String] = data
    // nosemgrep: swift.biometrics-and-auth.missing-user-auth.keychain-without-user-auth
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else { throw ProviderSettingsError.keychain(addStatus) }
  }

  func deleteAPIKey() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ProviderSettingsError.keychain(status)
    }
  }

  private var baseQuery: [String: Any] {
    // Keep the macOS Keychain default accessibility (`WhenUnlocked`). This app
    // only reads provider credentials in the foreground; `AfterFirstUnlock`
    // would unnecessarily expose them while the Mac is locked. Explicit
    // `kSecAttrAccessible` also requires opting into the Data Protection
    // Keychain on macOS, which is a separate storage migration.
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}

struct ProcessProviderEnvironment: ProviderEnvironmentManaging {
  func value(forKey key: String) -> String? {
    guard let value = getenv(key) else { return nil }
    return String(cString: value)
  }

  func setValue(_ value: String, forKey key: String) throws {
    guard setenv(key, value, 1) == 0 else {
      throw ProviderSettingsError.environment(operation: "apply", key: key, code: errno)
    }
  }

  func removeValue(forKey key: String) throws {
    guard unsetenv(key) == 0 else {
      throw ProviderSettingsError.environment(operation: "remove", key: key, code: errno)
    }
  }
}

final class ProviderSettings: ObservableObject {
  static let shared = ProviderSettings()

  static let endpointEnvironmentKeys = [
    "LLM_ASSISTIVE_ENDPOINT", "LLM_FORMATTING_ENDPOINT", "LLM_ENDPOINT",
  ]
  static let modelEnvironmentKeys = [
    "LLM_ASSISTIVE_MODEL", "LLM_FORMATTING_MODEL", "LLM_MODEL",
  ]
  static let apiKeyEnvironmentKeys = [
    "LLM_ASSISTIVE_API_KEY", "LLM_FORMATTING_API_KEY", "LLM_API_KEY",
  ]

  private static let endpointDefaultsKey = "Pensieve.completionProvider.endpoint"
  private static let modelDefaultsKey = "Pensieve.completionProvider.model"
  private static let providerShapeDefaultsKey = "Pensieve.completionProvider.shape"
  private static let assistiveEndpointKey = "LLM_ASSISTIVE_ENDPOINT"
  private static let assistiveModelKey = "LLM_ASSISTIVE_MODEL"
  private static let assistiveAPIKey = "LLM_ASSISTIVE_API_KEY"

  @Published var providerShape: CompletionProviderShape
  @Published var endpoint: String
  @Published var model: String
  @Published var apiKey: String
  @Published private(set) var saveStatus: String?
  @Published private(set) var lastError: String?

  private let defaults: UserDefaults
  private let keychain: ProviderAPIKeyStoring
  private let environment: ProviderEnvironmentManaging
  private var managedEnvironmentKeys: Set<String> = []
  private let launchHadEndpointEnvironment: Bool
  private let launchHadModelEnvironment: Bool

  init(
    defaults: UserDefaults = .standard,
    keychain: ProviderAPIKeyStoring = KeychainProviderAPIKeyStore(),
    environment: ProviderEnvironmentManaging = ProcessProviderEnvironment()
  ) {
    self.defaults = defaults
    self.keychain = keychain
    self.environment = environment
    self.providerShape =
      CompletionProviderShape(
        rawValue: defaults.string(forKey: Self.providerShapeDefaultsKey) ?? ""
      ) ?? .openAIResponses
    self.endpoint = Self.normalizeOpenAIResponsesEndpoint(
      defaults.string(forKey: Self.endpointDefaultsKey) ?? "")
    self.model = defaults.string(forKey: Self.modelDefaultsKey) ?? ""
    self.apiKey = ""
    self.saveStatus = nil
    self.lastError = nil
    self.launchHadEndpointEnvironment = Self.hasNonEmptyValue(
      in: Self.endpointEnvironmentKeys, environment: environment)
    self.launchHadModelEnvironment = Self.hasNonEmptyValue(
      in: Self.modelEnvironmentKeys, environment: environment)

    do {
      self.apiKey = try keychain.loadAPIKey() ?? ""
    } catch {
      self.lastError = error.localizedDescription
    }

    do {
      try applyPersistedConfigurationAtLaunch()
    } catch {
      self.lastError = error.localizedDescription
    }
  }

  /// The kernel requires endpoint + model, but intentionally permits an empty
  /// API key for local/keyless OpenAI-compatible endpoints.
  var isConfigured: Bool {
    providerShape.isSupportedByCompletionEngine
      && Self.hasNonEmptyValue(in: Self.endpointEnvironmentKeys, environment: environment)
      && Self.hasNonEmptyValue(in: Self.modelEnvironmentKeys, environment: environment)
  }

  var isDraftValid: Bool {
    providerShape.isSupportedByCompletionEngine
      && !trimmed(endpoint).isEmpty && !trimmed(model).isEmpty
  }

  var usesInheritedEnvironmentAtLaunch: Bool {
    launchHadEndpointEnvironment && launchHadModelEnvironment
  }

  /// Explicit Save is the user override: it writes the highest-priority
  /// assistive variables. At launch, however, any non-empty inherited provider
  /// variable wins and persisted UI values only fill missing fields. This keeps
  /// terminal/developer workflows intact while making Finder launches work.
  func save() throws {
    do {
      guard providerShape.isSupportedByCompletionEngine else {
        throw ProviderSettingsError.unsupportedProviderShape(providerShape)
      }
      let rawEndpoint = trimmed(endpoint)
      let model = trimmed(model)
      let apiKey = trimmed(apiKey)
      guard !rawEndpoint.isEmpty else { throw ProviderSettingsError.endpointRequired }
      guard !model.isEmpty else { throw ProviderSettingsError.modelRequired }
      let endpoint = Self.normalizeOpenAIResponsesEndpoint(rawEndpoint)

      if apiKey.isEmpty {
        try keychain.deleteAPIKey()
      } else {
        try keychain.storeAPIKey(apiKey)
      }

      defaults.set(endpoint, forKey: Self.endpointDefaultsKey)
      defaults.set(model, forKey: Self.modelDefaultsKey)
      defaults.set(providerShape.rawValue, forKey: Self.providerShapeDefaultsKey)
      self.endpoint = endpoint
      self.model = model
      self.apiKey = apiKey

      try setManagedValue(endpoint, forKey: Self.assistiveEndpointKey)
      try setManagedValue(model, forKey: Self.assistiveModelKey)
      if apiKey.isEmpty {
        try removeManagedValueIfOwned(forKey: Self.assistiveAPIKey)
      } else {
        try setManagedValue(apiKey, forKey: Self.assistiveAPIKey)
      }

      lastError = nil
      saveStatus = "Saved and applied to AI Autocomplete."
      NotificationCenter.default.post(name: .completionProviderSettingsDidChange, object: self)
    } catch {
      saveStatus = nil
      lastError = error.localizedDescription
      throw error
    }
  }

  private func applyPersistedConfigurationAtLaunch() throws {
    guard providerShape.isSupportedByCompletionEngine else {
      throw ProviderSettingsError.unsupportedProviderShape(providerShape)
    }
    try fillMissingEnvironmentValue(
      Self.normalizeOpenAIResponsesEndpoint(endpoint),
      aliases: Self.endpointEnvironmentKeys,
      key: Self.assistiveEndpointKey)
    try fillMissingEnvironmentValue(
      trimmed(model), aliases: Self.modelEnvironmentKeys, key: Self.assistiveModelKey)
    // Never pair a saved secret with a developer-inherited endpoint/model: a
    // stale cloud key must not be sent to an unrelated local or test server.
    // Developers can provide an env key explicitly; a deliberate UI Save also
    // binds the visible triple and applies it as one user-owned override.
    if !launchHadEndpointEnvironment && !launchHadModelEnvironment {
      try fillMissingEnvironmentValue(
        trimmed(apiKey), aliases: Self.apiKeyEnvironmentKeys, key: Self.assistiveAPIKey)
    }
  }

  private func fillMissingEnvironmentValue(
    _ value: String,
    aliases: [String],
    key: String
  ) throws {
    guard !value.isEmpty else { return }
    guard !Self.hasNonEmptyValue(in: aliases, environment: environment) else { return }
    try setManagedValue(value, forKey: key)
  }

  private func setManagedValue(_ value: String, forKey key: String) throws {
    guard !trimmed(value).isEmpty else { return }
    try environment.setValue(value, forKey: key)
    managedEnvironmentKeys.insert(key)
  }

  private func removeManagedValueIfOwned(forKey key: String) throws {
    guard managedEnvironmentKeys.contains(key) else { return }
    try environment.removeValue(forKey: key)
    managedEnvironmentKeys.remove(key)
  }

  private func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Canonicalizes every UI-managed OpenAI-compatible endpoint onto the only
  /// request shape vista-kernel can safely emit today: OpenAI Responses.
  static func normalizeOpenAIResponsesEndpoint(_ endpoint: String) -> String {
    var base = endpoint.trimmingCharacters(
      in: .whitespacesAndNewlines.union(.init(charactersIn: "/")))
    guard !base.isEmpty else { return "" }

    for suffix in ["/v1/responses", "/v1/chat/completions", "/v1/completions"]
    where base.hasSuffix(suffix) {
      base.removeLast(suffix.count)
      return base + "/v1/responses"
    }
    if base.hasSuffix("/v1") {
      base.removeLast(3)
    }
    return base + "/v1/responses"
  }

  private static func hasNonEmptyValue(
    in keys: [String],
    environment: ProviderEnvironmentManaging
  ) -> Bool {
    keys.contains { key in
      guard let value = environment.value(forKey: key) else { return false }
      return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }
}
