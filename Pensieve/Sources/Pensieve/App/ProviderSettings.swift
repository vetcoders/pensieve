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

enum CompletionProviderShape: String, CaseIterable, Identifiable, Sendable {
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
      return "https://api.openai.com/v1/responses"
    case .anthropicMessages:
      return "https://api.anthropic.com/v1/messages"
    }
  }

  func normalizeEndpoint(_ endpoint: String) -> String {
    switch self {
    case .openAIResponses:
      return ProviderSettings.normalizeOpenAIResponsesEndpoint(endpoint)
    case .anthropicMessages:
      return ProviderSettings.normalizeAnthropicMessagesEndpoint(endpoint)
    }
  }

}

enum ProviderSettingsError: LocalizedError {
  case endpointRequired
  case modelRequired
  case invalidKeychainData
  case keychain(OSStatus)
  case environment(operation: String, key: String, code: Int32)

  var errorDescription: String? {
    switch self {
    case .endpointRequired:
      return "Enter a provider endpoint."
    case .modelRequired:
      return "Enter a provider model."
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
    let accessControl = try makeAccessControl()
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessControl as String: accessControl,
    ]
    let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess { return }
    guard updateStatus == errSecItemNotFound else {
      throw ProviderSettingsError.keychain(updateStatus)
    }

    let item: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      kSecAttrAccessControl as String: accessControl,
    ]
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
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  private func makeAccessControl() throws -> SecAccessControl {
    var error: Unmanaged<CFError>?
    guard
      let accessControl = SecAccessControlCreateWithFlags(
        nil,
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        .biometryCurrentSet,
        &error)
    else {
      throw ProviderSettingsError.keychain(errSecParam)
    }
    return accessControl
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
  static let anthropicAPIKeyEnvironmentKeys = ["LLM_ANTHROPIC_API_KEY"]
  static let providerShapeEnvironmentKeys = [
    "LLM_ASSISTIVE_PROVIDER", "LLM_FORMATTING_PROVIDER", "LLM_PROVIDER",
  ]

  private static let endpointDefaultsKey = "Pensieve.completionProvider.endpoint"
  private static let modelDefaultsKey = "Pensieve.completionProvider.model"
  private static let providerShapeDefaultsKey = "Pensieve.completionProvider.shape"
  private static let assistiveEndpointKey = "LLM_ASSISTIVE_ENDPOINT"
  private static let assistiveModelKey = "LLM_ASSISTIVE_MODEL"
  private static let assistiveAPIKey = "LLM_ASSISTIVE_API_KEY"
  private static let assistiveProviderKey = "LLM_ASSISTIVE_PROVIDER"

  @Published var providerShape: CompletionProviderShape
  @Published var endpoint: String
  @Published var model: String
  @Published var apiKey: String
  @Published private(set) var saveStatus: String?
  @Published private(set) var lastError: String?
  @Published private(set) var discoveredModels: [DiscoveredProviderModel] = []
  @Published private(set) var modelDiscoveryStatus: String?
  @Published private(set) var isDiscoveringModels = false

  private let defaults: UserDefaults
  private let keychain: ProviderAPIKeyStoring
  private let environment: ProviderEnvironmentManaging
  private let modelDiscovery: ProviderModelDiscovering
  private var managedEnvironmentKeys: Set<String> = []
  private var discoveryGeneration: UInt64 = 0
  private let launchHadEndpointEnvironment: Bool
  private let launchHadModelEnvironment: Bool

  init(
    defaults: UserDefaults = .standard,
    keychain: ProviderAPIKeyStoring = KeychainProviderAPIKeyStore(),
    environment: ProviderEnvironmentManaging = ProcessProviderEnvironment(),
    modelDiscovery: ProviderModelDiscovering? = nil
  ) {
    self.defaults = defaults
    self.keychain = keychain
    self.environment = environment
    self.modelDiscovery = modelDiscovery ?? ProviderModelDiscovery(defaults: defaults)
    let persistedShape =
      CompletionProviderShape(
        rawValue: defaults.string(forKey: Self.providerShapeDefaultsKey) ?? ""
      ) ?? .openAIResponses
    self.providerShape = persistedShape
    self.endpoint = persistedShape.normalizeEndpoint(
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
    Self.hasNonEmptyValue(in: Self.endpointEnvironmentKeys, environment: environment)
      && Self.hasNonEmptyValue(in: Self.modelEnvironmentKeys, environment: environment)
  }

  var isDraftValid: Bool {
    !trimmed(endpoint).isEmpty && !trimmed(model).isEmpty
  }

  var usesInheritedEnvironmentAtLaunch: Bool {
    launchHadEndpointEnvironment && launchHadModelEnvironment
  }

  @MainActor
  func providerShapeDidChange() {
    discoveryGeneration &+= 1
    discoveredModels = []
    modelDiscoveryStatus = nil
    let lowercasedEndpoint = endpoint.lowercased()
    if lowercasedEndpoint.contains("api.openai.com")
      || lowercasedEndpoint.contains("api.anthropic.com")
      || trimmed(endpoint).isEmpty
    {
      endpoint = providerShape.endpointPrompt
    } else {
      endpoint = providerShape.normalizeEndpoint(endpoint)
    }
    let normalizedModel = trimmed(model).lowercased()
    if providerShape == .anthropicMessages, normalizedModel.hasPrefix("gpt-") {
      model = ""
    } else if providerShape == .openAIResponses, normalizedModel.hasPrefix("claude-") {
      model = ""
    }
  }

  @MainActor
  func discoverModels() async {
    discoveryGeneration &+= 1
    let generation = discoveryGeneration
    let shape = providerShape
    let endpoint = shape.normalizeEndpoint(endpoint)
    let apiKey = trimmed(apiKey)
    isDiscoveringModels = true
    modelDiscoveryStatus = nil
    defer {
      if discoveryGeneration == generation {
        isDiscoveringModels = false
      }
    }

    do {
      let result = try await modelDiscovery.discover(
        shape: shape, endpoint: endpoint, apiKey: apiKey)
      guard discoveryGeneration == generation, providerShape == shape else { return }
      discoveredModels = result.models
      switch result.source {
      case .fresh:
        modelDiscoveryStatus = "Found \(result.models.count) models."
      case .cache:
        modelDiscoveryStatus = "Provider unavailable — showing the last known model list."
      }
    } catch is CancellationError {
      return
    } catch {
      guard discoveryGeneration == generation else { return }
      discoveredModels = []
      modelDiscoveryStatus = error.localizedDescription
    }
  }

  /// Explicit Save is the user override: it writes the highest-priority
  /// assistive variables. At launch, however, any non-empty inherited provider
  /// variable wins and persisted UI values only fill missing fields. This keeps
  /// terminal/developer workflows intact while making Finder launches work.
  func save() throws {
    do {
      let rawEndpoint = trimmed(endpoint)
      let model = trimmed(model)
      let apiKey = trimmed(apiKey)
      guard !rawEndpoint.isEmpty else { throw ProviderSettingsError.endpointRequired }
      guard !model.isEmpty else { throw ProviderSettingsError.modelRequired }
      let endpoint = providerShape.normalizeEndpoint(rawEndpoint)

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
      try setManagedValue(providerShape.rawValue, forKey: Self.assistiveProviderKey)
      if apiKey.isEmpty {
        try removeManagedValueIfOwned(forKey: Self.assistiveAPIKey)
      } else {
        try setManagedValue(apiKey, forKey: Self.assistiveAPIKey)
      }

      lastError = nil
      saveStatus = "Saved and applied to AI features."
      NotificationCenter.default.post(name: .completionProviderSettingsDidChange, object: self)
    } catch {
      saveStatus = nil
      lastError = error.localizedDescription
      throw error
    }
  }

  private func applyPersistedConfigurationAtLaunch() throws {
    let persistedEndpoint = providerShape.normalizeEndpoint(endpoint)
    let persistedModel = trimmed(model)
    try fillMissingEnvironmentValue(
      persistedEndpoint,
      aliases: Self.endpointEnvironmentKeys,
      key: Self.assistiveEndpointKey)
    try fillMissingEnvironmentValue(
      persistedModel, aliases: Self.modelEnvironmentKeys, key: Self.assistiveModelKey)
    if !launchHadEndpointEnvironment && !launchHadModelEnvironment
      && !persistedEndpoint.isEmpty && !persistedModel.isEmpty
    {
      try fillMissingEnvironmentValue(
        providerShape.rawValue,
        aliases: Self.providerShapeEnvironmentKeys,
        key: Self.assistiveProviderKey)
    }
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

  static func normalizeAnthropicMessagesEndpoint(_ endpoint: String) -> String {
    var base = endpoint.trimmingCharacters(
      in: .whitespacesAndNewlines.union(.init(charactersIn: "/")))
    guard !base.isEmpty else { return "" }

    for suffix in ["/v1/messages", "/v1/responses", "/v1/chat/completions"]
    where base.hasSuffix(suffix) {
      base.removeLast(suffix.count)
      return base + "/v1/messages"
    }
    if base.hasSuffix("/v1") {
      base.removeLast(3)
    }
    return base + "/v1/messages"
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
