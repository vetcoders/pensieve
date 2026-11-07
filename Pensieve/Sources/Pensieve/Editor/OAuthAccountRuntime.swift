import Foundation
import Security
import Synchronization

enum OAuthAccountProvider: String, CaseIterable, Sendable, Equatable {
  case openAIResponses = "openai-responses"
  case xAIResponses = "xai-responses"
  case googleGemini = "google-gemini"

  static let googleAntigravityClientID =
    "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com"
  static let googleGeminiCLIClientID =
    "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
  static let defaultCCAProjectID = "rising-fact-p41fc"

  static func normalize(_ raw: String?) -> OAuthAccountProvider? {
    guard
      let cleaned = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !cleaned.isEmpty
    else {
      return nil
    }
    switch cleaned {
    case "openai", "openai-responses", "codex":
      return .openAIResponses
    case "xai", "xai-responses", "grok":
      return .xAIResponses
    case "google", "google-gemini", "gemini", "cca":
      return .googleGemini
    default:
      return nil
    }
  }

  var tokenEnvironmentKey: String {
    switch self {
    case .openAIResponses: return "LLM_OPENAI_ACCOUNT_TOKENS"
    case .xAIResponses: return "LLM_XAI_ACCOUNT_TOKENS"
    case .googleGemini: return "LLM_GOOGLE_ACCOUNT_TOKENS"
    }
  }

  var displayName: String {
    switch self {
    case .openAIResponses: return "Codex (OpenAI account)"
    case .xAIResponses: return "Grok (xAI account)"
    case .googleGemini: return "Gemini (Google account)"
    }
  }

  var defaultModel: String {
    switch self {
    case .openAIResponses: return "gpt-5.4"
    case .xAIResponses: return "grok-4.6"
    case .googleGemini: return "gemini-2.5-flash"
    }
  }

  var modelEnvironmentKeys: [String] {
    switch self {
    case .openAIResponses:
      return [
        "PENSIEVE_OAUTH_OPENAI_MODEL", "AI_OAUTH_OPENAI_MODEL", "VC_OAUTH_OPENAI_MODEL",
      ]
    case .xAIResponses:
      return [
        "PENSIEVE_OAUTH_XAI_MODEL", "AI_OAUTH_XAI_MODEL", "VC_OAUTH_XAI_MODEL",
      ]
    case .googleGemini:
      return [
        "PENSIEVE_OAUTH_GOOGLE_MODEL", "AI_OAUTH_GOOGLE_MODEL", "VC_OAUTH_GOOGLE_MODEL",
      ]
    }
  }

  var endpointEnvironmentKeys: [String] {
    switch self {
    case .openAIResponses:
      return [
        "PENSIEVE_CODEX_BACKEND_ENDPOINT",
        "CODESCRIBE_CODEX_BACKEND_ENDPOINT",
        "VISTA_CODEX_BACKEND_ENDPOINT",
      ]
    case .xAIResponses:
      return [
        "PENSIEVE_XAI_RESPONSES_ENDPOINT",
        "CODESCRIBE_XAI_RESPONSES_ENDPOINT",
        "VISTA_XAI_RESPONSES_ENDPOINT",
      ]
    case .googleGemini:
      return [
        "PENSIEVE_GOOGLE_CCA_ENDPOINT",
        "CODESCRIBE_GOOGLE_CCA_ENDPOINT",
        "VISTA_GOOGLE_CCA_ENDPOINT",
      ]
    }
  }

  func resolveEndpoint(
    tokens: OAuthAccountTokens,
    environment: any ProviderEnvironmentManaging
  ) -> String {
    if let override = ProviderSettings.firstNonEmptyValue(
      for: endpointEnvironmentKeys, in: environment)
    {
      return override
    }
    switch self {
    case .openAIResponses:
      return "https://chatgpt.com/backend-api/codex/responses"
    case .xAIResponses:
      return "https://api.x.ai/v1/responses"
    case .googleGemini:
      let isGeminiCLI = tokens.clientID == Self.googleGeminiCLIClientID
      return isGeminiCLI
        ? "https://cloudcode-pa.googleapis.com/v1internal"
        : "https://daily-cloudcode-pa.googleapis.com/v1internal"
    }
  }

  func resolveModel(environment: any ProviderEnvironmentManaging) -> String {
    if let override = ProviderSettings.firstNonEmptyValue(
      for: modelEnvironmentKeys, in: environment)
    {
      return override
    }
    return defaultModel
  }

  func resolveTokenURL(
    tokens: OAuthAccountTokens,
    environment: any ProviderEnvironmentManaging
  ) -> String {
    switch self {
    case .openAIResponses:
      return ProviderSettings.firstNonEmptyValue(
        for: [
          "PENSIEVE_OPENAI_OAUTH_TOKEN_URL",
          "CODESCRIBE_OPENAI_OAUTH_TOKEN_URL",
          "VISTA_OPENAI_OAUTH_TOKEN_URL",
        ],
        in: environment) ?? tokens.tokenURI ?? "https://auth.openai.com/oauth/token"
    case .xAIResponses:
      return ProviderSettings.firstNonEmptyValue(
        for: [
          "PENSIEVE_XAI_OAUTH_TOKEN_URL",
          "CODESCRIBE_XAI_OAUTH_TOKEN_URL",
          "VISTA_XAI_OAUTH_TOKEN_URL",
        ],
        in: environment) ?? tokens.tokenURI ?? "https://oes.x.ai/oauth2/token"
    case .googleGemini:
      return ProviderSettings.firstNonEmptyValue(
        for: [
          "PENSIEVE_GOOGLE_OAUTH_TOKEN_URL",
          "CODESCRIBE_GOOGLE_OAUTH_TOKEN_URL",
          "VISTA_GOOGLE_OAUTH_TOKEN_URL",
        ],
        in: environment) ?? tokens.tokenURI ?? "https://oauth2.googleapis.com/token"
    }
  }

  func resolveClientID(
    tokens: OAuthAccountTokens,
    environment: any ProviderEnvironmentManaging
  ) -> String {
    if let tokenClient = tokens.clientID?.trimmingCharacters(in: .whitespacesAndNewlines),
      !tokenClient.isEmpty
    {
      return tokenClient
    }
    switch self {
    case .openAIResponses:
      return ProviderSettings.firstNonEmptyValue(
        for: ["LLM_OPENAI_OAUTH_CLIENT_ID", "OPENAI_OAUTH_CLIENT_ID"], in: environment)
        ?? "app_EMoamEEZ73f0CkXaXp7hrann"
    case .xAIResponses:
      return ProviderSettings.firstNonEmptyValue(
        for: ["LLM_XAI_OAUTH_CLIENT_ID", "XAI_OAUTH_CLIENT_ID"], in: environment)
        ?? "de867527-a160-4f90-a91b-7fe29f0fb3f3"
    case .googleGemini:
      return ProviderSettings.firstNonEmptyValue(
        for: ["LLM_GOOGLE_OAUTH_CLIENT_ID", "GOOGLE_OAUTH_CLIENT_ID"], in: environment)
        ?? Self.googleAntigravityClientID
    }
  }
}

struct OAuthAccountTokens: Codable, Equatable, Sendable {
  static let refreshSkewSeconds: Int64 = 60

  var provider: String
  var accessToken: String
  var refreshToken: String?
  var idToken: String?
  var tokenType: String
  var expiresAtUnix: Int64?
  var email: String?
  var projectID: String?
  var clientID: String?
  var clientSecret: String?
  var tokenURI: String?

  init(
    provider: String = "",
    accessToken: String,
    refreshToken: String? = nil,
    idToken: String? = nil,
    tokenType: String = "Bearer",
    expiresAtUnix: Int64? = nil,
    email: String? = nil,
    projectID: String? = nil,
    clientID: String? = nil,
    clientSecret: String? = nil,
    tokenURI: String? = nil
  ) {
    self.provider = provider
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.idToken = idToken
    self.tokenType = tokenType
    self.expiresAtUnix = expiresAtUnix
    self.email = email
    self.projectID = projectID
    self.clientID = clientID
    self.clientSecret = clientSecret
    self.tokenURI = tokenURI
  }

  var hasUsableCredentials: Bool {
    !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !(refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
  }

  func isExpired(
    nowUnix: Int64 = Int64(Date().timeIntervalSince1970),
    skewSeconds: Int64 = Self.refreshSkewSeconds
  ) -> Bool {
    if accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return true
    }
    guard let expiresAtUnix else { return false }
    return nowUnix + skewSeconds >= expiresAtUnix
  }

  var chatGPTAccountID: String? {
    for candidate in [idToken, accessToken] {
      guard let token = candidate, let claims = Self.decodeJWTClaims(token) else { continue }
      if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
        let accountID = Self.nonEmpty(auth["chatgpt_account_id"] as? String)
      {
        return accountID
      }
      if let accountID = Self.nonEmpty(claims["chatgpt_account_id"] as? String) {
        return accountID
      }
      if let orgs = claims["organizations"] as? [[String: Any]],
        let firstOrgID = Self.nonEmpty(orgs.first?["id"] as? String)
      {
        return firstOrgID
      }
    }
    return nil
  }

  static func decodeSecretPayload(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("b64:") else { return trimmed }
    let encoded = String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let data = decodeBase64Flexible(encoded),
      let decoded = String(data: data, encoding: .utf8)
    else {
      return trimmed
    }
    return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func decode(from raw: String, defaultProvider: String = "") -> OAuthAccountTokens? {
    let payload = decodeSecretPayload(raw)
    guard
      !payload.isEmpty,
      let data = payload.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    let accessToken =
      nonEmpty(object["access_token"] as? String)
      ?? nonEmpty(object["accessToken"] as? String)
      ?? ""
    let refreshToken =
      nonEmpty(object["refresh_token"] as? String)
      ?? nonEmpty(object["refreshToken"] as? String)
    guard !accessToken.isEmpty || refreshToken != nil else {
      return nil
    }
    let provider =
      nonEmpty(object["provider"] as? String)
      ?? nonEmpty(defaultProvider)
      ?? ""
    let idToken =
      nonEmpty(object["id_token"] as? String)
      ?? nonEmpty(object["idToken"] as? String)
    let tokenType =
      nonEmpty(object["token_type"] as? String)
      ?? nonEmpty(object["tokenType"] as? String)
      ?? "Bearer"
    let expiresAtUnix =
      int64Value(object["expires_at_unix"])
      ?? int64Value(object["expiresAtUnix"])
    let email = nonEmpty(object["email"] as? String)
    let projectID =
      nonEmpty(object["project_id"] as? String)
      ?? nonEmpty(object["projectId"] as? String)
      ?? nonEmpty(object["projectID"] as? String)
    let clientID =
      nonEmpty(object["client_id"] as? String)
      ?? nonEmpty(object["clientId"] as? String)
      ?? nonEmpty(object["clientID"] as? String)
    let clientSecret =
      nonEmpty(object["client_secret"] as? String)
      ?? nonEmpty(object["clientSecret"] as? String)
    let tokenURI =
      nonEmpty(object["token_uri"] as? String)
      ?? nonEmpty(object["tokenUri"] as? String)
      ?? nonEmpty(object["tokenURI"] as? String)

    return OAuthAccountTokens(
      provider: provider,
      accessToken: accessToken,
      refreshToken: refreshToken,
      idToken: idToken,
      tokenType: tokenType,
      expiresAtUnix: expiresAtUnix,
      email: email,
      projectID: projectID,
      clientID: clientID,
      clientSecret: clientSecret,
      tokenURI: tokenURI)
  }

  static func decodeBundle(from raw: String) -> [OAuthAccountProvider: OAuthAccountTokens] {
    let payload = decodeSecretPayload(raw)
    guard
      !payload.isEmpty,
      let data = payload.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return [:]
    }
    let keysObject = (root["keys"] as? [String: Any]) ?? root
    var result: [OAuthAccountProvider: OAuthAccountTokens] = [:]
    for provider in OAuthAccountProvider.allCases {
      guard let entry = keysObject[provider.tokenEnvironmentKey] else { continue }
      if let entryString = entry as? String,
        let tokens = decode(from: entryString, defaultProvider: provider.rawValue)
      {
        result[provider] = tokens
      } else if JSONSerialization.isValidJSONObject(entry),
        let nestedData = try? JSONSerialization.data(withJSONObject: entry),
        let nestedString = String(data: nestedData, encoding: .utf8),
        let tokens = decode(from: nestedString, defaultProvider: provider.rawValue)
      {
        result[provider] = tokens
      }
    }
    return result
  }

  private static func decodeJWTClaims(_ jwt: String) -> [String: Any]? {
    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count >= 2 else { return nil }
    guard
      let data = decodeBase64Flexible(String(parts[1])),
      let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return nil
    }
    return claims
  }

  private static func decodeBase64Flexible(_ raw: String) -> Data? {
    var normalized =
      raw
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let remainder = normalized.count % 4
    if remainder > 0 {
      normalized += String(repeating: "=", count: 4 - remainder)
    }
    return Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters])
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }

  static func int64Value(_ raw: Any?) -> Int64? {
    if let int64 = raw as? Int64 { return int64 }
    if let int = raw as? Int { return Int64(int) }
    if let double = raw as? Double {
      guard
        double.isFinite,
        double >= Double(Int64.min),
        double < 9_223_372_036_854_775_808.0
      else {
        return nil
      }
      return Int64(exactly: double.rounded(.towardZero))
    }
    if let number = raw as? NSNumber { return number.int64Value }
    if let string = raw as? String,
      let parsed = Int64(string.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      return parsed
    }
    return nil
  }
}

protocol OAuthAccountTokenStoring: Sendable {
  func loadTokens(
    for provider: OAuthAccountProvider,
    environment: any ProviderEnvironmentManaging
  ) -> OAuthAccountTokens?

  func saveTokens(
    _ tokens: OAuthAccountTokens,
    for provider: OAuthAccountProvider,
    environment: any ProviderEnvironmentManaging
  )
}

final class KeychainOAuthAccountTokenStore: OAuthAccountTokenStoring {
  static let codescribeService = "com.vetcoders.codescribe"
  static let bundleAccount = "codescribe_keychain_bundle_v1"

  private struct CacheState: Sendable {
    var cachedTokens: [OAuthAccountProvider: OAuthAccountTokens] = [:]
    var refreshedTokens: [OAuthAccountProvider: OAuthAccountTokens] = [:]
    var missingProviders: Set<OAuthAccountProvider> = []
    var lastKeychainLoad: Date?
  }

  private let state = Mutex(CacheState())
  private let allowSystemKeychain: Bool
  private let keychainReader: @Sendable (String, String) -> String?
  private let cacheTTL: TimeInterval
  private nonisolated(unsafe) var settingsObserver: NSObjectProtocol?

  init(
    allowSystemKeychain: Bool = !AppSupportLocation.isRunningTests(),
    cacheTTL: TimeInterval = 5.0,
    keychainReader: @escaping @Sendable (String, String) -> String? = { service, account in
      KeychainOAuthAccountTokenStore.readKeychainItem(service: service, account: account)
    }
  ) {
    self.allowSystemKeychain = allowSystemKeychain
    self.cacheTTL = cacheTTL
    self.keychainReader = keychainReader
    self.settingsObserver = NotificationCenter.default.addObserver(
      forName: .completionProviderSettingsDidChange,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.invalidateCache()
    }
  }

  deinit {
    if let settingsObserver {
      NotificationCenter.default.removeObserver(settingsObserver)
    }
  }

  func invalidateCache() {
    state.withLock { state in
      state.cachedTokens.removeAll()
      state.refreshedTokens.removeAll()
      state.missingProviders.removeAll()
      state.lastKeychainLoad = nil
    }
  }

  func loadTokens(
    for provider: OAuthAccountProvider,
    environment: any ProviderEnvironmentManaging
  ) -> OAuthAccountTokens? {
    if let rawEnv = environment.value(forKey: provider.tokenEnvironmentKey),
      let decoded = OAuthAccountTokens.decode(from: rawEnv, defaultProvider: provider.rawValue),
      decoded.hasUsableCredentials
    {
      return decoded
    }

    if let refreshed = state.withLock({ state -> OAuthAccountTokens? in
      guard let tokens = state.refreshedTokens[provider], tokens.hasUsableCredentials else {
        return nil
      }
      return tokens
    }) {
      return refreshed
    }

    if let rawBundleEnv = environment.value(forKey: Self.bundleAccount)
      ?? environment.value(forKey: "CODESCRIBE_KEYCHAIN_BUNDLE_V1")
    {
      let bundle = OAuthAccountTokens.decodeBundle(from: rawBundleEnv)
      if let tokens = bundle[provider], tokens.hasUsableCredentials {
        return tokens
      }
    }

    let now = Date()
    let cacheLookup = state.withLock { state -> (hit: Bool, tokens: OAuthAccountTokens?) in
      if !allowSystemKeychain {
        if let tokens = state.cachedTokens[provider], tokens.hasUsableCredentials {
          return (true, tokens)
        }
        return (true, nil)
      }
      if let lastLoad = state.lastKeychainLoad, now.timeIntervalSince(lastLoad) < cacheTTL {
        if let tokens = state.cachedTokens[provider], tokens.hasUsableCredentials {
          return (true, tokens)
        }
        if state.missingProviders.contains(provider) {
          return (true, nil)
        }
      }
      return (false, nil)
    }
    if cacheLookup.hit {
      return cacheLookup.tokens
    }

    let loaded = loadFromSystemKeychain(environment: environment)
    return state.withLock { state in
      for candidate in OAuthAccountProvider.allCases {
        if let refreshed = state.refreshedTokens[candidate], refreshed.hasUsableCredentials {
          state.cachedTokens[candidate] = refreshed
          state.missingProviders.remove(candidate)
        } else if let value = loaded[candidate], value.hasUsableCredentials {
          state.cachedTokens[candidate] = value
          state.missingProviders.remove(candidate)
        } else {
          state.cachedTokens.removeValue(forKey: candidate)
          state.missingProviders.insert(candidate)
        }
      }
      state.lastKeychainLoad = now
      return state.cachedTokens[provider]
    }
  }

  func saveTokens(
    _ tokens: OAuthAccountTokens,
    for provider: OAuthAccountProvider,
    environment: any ProviderEnvironmentManaging
  ) {
    state.withLock { state in
      state.cachedTokens[provider] = tokens
      state.refreshedTokens[provider] = tokens
      state.missingProviders.remove(provider)
      state.lastKeychainLoad = Date()
    }
    if let encoded = try? JSONEncoder().encode(tokens),
      let jsonString = String(data: encoded, encoding: .utf8)
    {
      if environment.value(forKey: provider.tokenEnvironmentKey) != nil {
        try? environment.setValue(jsonString, forKey: provider.tokenEnvironmentKey)
      }
      if let tokenObject = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] {
        for bundleKey in [Self.bundleAccount, "CODESCRIBE_KEYCHAIN_BUNDLE_V1"] {
          guard
            let rawBundle = environment.value(forKey: bundleKey),
            let bundleData = rawBundle.data(using: .utf8),
            var bundleObject = try? JSONSerialization.jsonObject(with: bundleData)
              as? [String: Any]
          else { continue }
          var entries = (bundleObject["entries"] as? [String: Any]) ?? bundleObject
          entries[provider.tokenEnvironmentKey] = tokenObject
          if bundleObject["entries"] != nil {
            bundleObject["entries"] = entries
          } else {
            bundleObject = entries
          }
          if let updatedData = try? JSONSerialization.data(withJSONObject: bundleObject),
            let updatedString = String(data: updatedData, encoding: .utf8)
          {
            try? environment.setValue(updatedString, forKey: bundleKey)
          }
        }
      }
    }
  }

  private func loadFromSystemKeychain(
    environment: any ProviderEnvironmentManaging
  ) -> [OAuthAccountProvider: OAuthAccountTokens] {
    var services: [String] = []
    if let customService = environment.value(
      forKey: KeychainProviderAPIKeyStore.serviceEnvironmentKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !customService.isEmpty
    {
      services.append(customService)
    } else {
      services.append(KeychainProviderAPIKeyStore.service)
    }
    if !services.contains(Self.codescribeService) {
      services.append(Self.codescribeService)
    }

    var discovered: [OAuthAccountProvider: OAuthAccountTokens] = [:]
    for service in services {
      if let rawBundle = keychainReader(service, Self.bundleAccount) {
        for (provider, tokens) in OAuthAccountTokens.decodeBundle(from: rawBundle)
        where discovered[provider] == nil && tokens.hasUsableCredentials {
          discovered[provider] = tokens
        }
      }
      for provider in OAuthAccountProvider.allCases where discovered[provider] == nil {
        if let rawItem = keychainReader(service, provider.tokenEnvironmentKey),
          let tokens = OAuthAccountTokens.decode(from: rawItem, defaultProvider: provider.rawValue),
          tokens.hasUsableCredentials
        {
          discovered[provider] = tokens
        }
      }
    }
    return discovered
  }

  nonisolated static func readKeychainItem(service: String, account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
      return nil
    }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum OAuthAccountRuntime {
  static let activeProviderEnvironmentKeys = [
    "LLM_ACTIVE_OAUTH_PROVIDER",
    "VC_OAUTH_PRIMARY_PROVIDER",
    "AI_OAUTH_PRIMARY_PROVIDER",
  ]

  static func orderedProviders(
    in environment: any ProviderEnvironmentManaging,
    defaults: UserDefaults = .standard
  ) -> [OAuthAccountProvider] {
    var preferred: OAuthAccountProvider?
    if let explicit = ProviderSettings.firstNonEmptyValue(
      for: activeProviderEnvironmentKeys, in: environment)
    {
      preferred = OAuthAccountProvider.normalize(explicit)
    }
    if preferred == nil,
      let pinned = GrokAccount.pinnedAccountProvider(defaults)
    {
      preferred = OAuthAccountProvider.normalize(pinned)
    }
    if preferred == nil,
      let assistive = environment.value(forKey: "LLM_ASSISTIVE_PROVIDER")
    {
      preferred = OAuthAccountProvider.normalize(assistive)
    }

    var ordered: [OAuthAccountProvider] = []
    if let preferred {
      ordered.append(preferred)
    }
    for candidate in OAuthAccountProvider.allCases where !ordered.contains(candidate) {
      ordered.append(candidate)
    }
    return ordered
  }

  static func hasSignedInAccount(
    in environment: any ProviderEnvironmentManaging,
    tokenStore: any OAuthAccountTokenStoring
  ) -> Bool {
    for provider in OAuthAccountProvider.allCases {
      if let tokens = tokenStore.loadTokens(for: provider, environment: environment),
        tokens.hasUsableCredentials
      {
        return true
      }
    }
    return false
  }

  static func buildCodexRequest(
    endpoint: String,
    model: String,
    tokens: OAuthAccountTokens,
    inputItems: [[String: Any]],
    instructions: String,
    timeoutInterval: TimeInterval
  ) throws -> URLRequest {
    guard let url = URL(string: endpoint) else {
      throw VistaError.ModelError(msg: "completion LLM unavailable: invalid Codex OAuth endpoint")
    }
    var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("pensieve", forHTTPHeaderField: "originator")
    request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
    if let accountID = tokens.chatGPTAccountID {
      request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
    }

    let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    let body: [String: Any] = [
      "model": model,
      "instructions": trimmedInstructions.isEmpty
        ? "You are a helpful assistant." : trimmedInstructions,
      "input": inputItems,
      "stream": true,
      "store": false,
      "tools": [],
      "tool_choice": "auto",
      "parallel_tool_calls": false,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  static func buildXAIRequest(
    endpoint: String,
    model: String,
    tokens: OAuthAccountTokens,
    inputItems: [[String: Any]],
    instructions: String,
    timeoutInterval: TimeInterval
  ) throws -> URLRequest {
    guard let url = URL(string: endpoint) else {
      throw VistaError.ModelError(msg: "completion LLM unavailable: invalid xAI OAuth endpoint")
    }
    var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")

    let body: [String: Any] = [
      "model": model,
      "instructions": instructions,
      "input": inputItems,
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  static func buildGoogleCCARequest(
    endpoint: String,
    model: String,
    tokens: OAuthAccountTokens,
    acceptedTurns: [AcceptedAITurn],
    input: String,
    instructions: String,
    environment: any ProviderEnvironmentManaging,
    timeoutInterval: TimeInterval
  ) throws -> URLRequest {
    var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    let fullURLString: String
    if base.hasSuffix(":generateContent") || base.hasSuffix(":streamGenerateContent") {
      fullURLString = base
    } else {
      fullURLString = "\(base):generateContent"
    }
    guard let url = URL(string: fullURLString) else {
      throw VistaError.ModelError(msg: "completion LLM unavailable: invalid Google OAuth endpoint")
    }

    let clientID =
      tokens.clientID?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? OAuthAccountProvider.googleAntigravityClientID
    let antigravity = clientID != OAuthAccountProvider.googleGeminiCLIClientID
    let project =
      tokens.projectID?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
      ?? ProviderSettings.firstNonEmptyValue(
        for: ["GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_PROJECT_ID"], in: environment)
      ?? (antigravity ? OAuthAccountProvider.defaultCCAProjectID : nil)

    guard let project, !project.isEmpty else {
      throw VistaError.ModelError(
        msg: "completion request failed: Cloud Code Assist requires a project id")
    }

    var contents: [[String: Any]] = []
    for turn in acceptedTurns {
      contents.append([
        "role": "user",
        "parts": [["text": turn.input]],
      ])
      contents.append([
        "role": "model",
        "parts": [["text": turn.output]],
      ])
    }
    contents.append([
      "role": "user",
      "parts": [["text": input]],
    ])

    var geminiRequest: [String: Any] = ["contents": contents]
    let trimmedInstructions = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedInstructions.isEmpty {
      geminiRequest["systemInstruction"] = [
        "parts": [["text": trimmedInstructions]]
      ]
    }

    var envelope: [String: Any] = [
      "project": project,
      "model": model,
      "request": geminiRequest,
    ]
    if antigravity {
      envelope["userAgent"] = "antigravity"
      envelope["requestType"] = "agent"
      envelope["requestId"] = UUID().uuidString.lowercased()
    }

    var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue(
      antigravity ? "antigravity/1.15.8 darwin/arm64" : "google-api-nodejs-client/9.15.1",
      forHTTPHeaderField: "User-Agent")
    request.setValue(
      antigravity ? "google-cloud-sdk vscode_cloudshelleditor/0.1" : "gl-node/22.14.0",
      forHTTPHeaderField: "X-Goog-Api-Client")
    request.setValue(
      #"{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}"#,
      forHTTPHeaderField: "Client-Metadata")
    request.httpBody = try JSONSerialization.data(withJSONObject: envelope)
    return request
  }

  static func parseCodexOrResponsesOutput(from data: Data) throws -> (
    text: String, responseID: String?
  ) {
    if let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      return try parseResponsesJSONObject(jsonObject)
    }
    guard let raw = String(data: data, encoding: .utf8) else {
      throw VistaError.ModelError(msg: "completion response was not valid UTF-8")
    }
    var deltas = ""
    var doneText: String?
    var completedObject: [String: Any]?
    var responseID: String?
    var streamError: String?

    let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
    for block in normalized.components(separatedBy: "\n\n") {
      var eventName: String?
      var dataLines: [String] = []
      for line in block.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("event:") {
          eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
          let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
          dataLines.append(payload)
        }
      }
      let joinedData = dataLines.joined(separator: "\n").trimmingCharacters(
        in: .whitespacesAndNewlines)
      guard !joinedData.isEmpty, joinedData != "[DONE]",
        let eventData = joinedData.data(using: .utf8),
        let event = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any]
      else {
        continue
      }
      let type = (event["type"] as? String) ?? eventName ?? ""
      if type == "response.created",
        let resp = event["response"] as? [String: Any],
        let id = resp["id"] as? String
      {
        responseID = id
      } else if type == "response.output_text.delta",
        let delta = event["delta"] as? String
      {
        deltas += delta
      } else if type == "response.output_text.done",
        let text = event["text"] as? String
      {
        doneText = text
      } else if type == "response.completed",
        let resp = event["response"] as? [String: Any]
      {
        completedObject = resp
        if let id = resp["id"] as? String {
          responseID = id
        }
      } else if type == "response.failed" || type == "error" || type == "response.error" {
        if let resp = event["response"] as? [String: Any],
          let err = resp["error"] as? [String: Any],
          let msg = err["message"] as? String
        {
          streamError = msg
        } else if let err = event["error"] as? [String: Any],
          let msg = err["message"] as? String
        {
          streamError = msg
        } else if let msg = event["message"] as? String {
          streamError = msg
        } else {
          streamError = "upstream stream failed"
        }
      }
    }

    if let streamError, deltas.isEmpty, doneText == nil, completedObject == nil {
      throw VistaError.ModelError(msg: "completion request failed: \(streamError)")
    }
    if let completedObject {
      let parsed = try parseResponsesJSONObject(completedObject)
      let finalText = parsed.text.isEmpty ? (doneText ?? deltas) : parsed.text
      return (finalText, parsed.responseID ?? responseID)
    }
    return (doneText ?? deltas, responseID)
  }

  static func parseGoogleCCAResponse(from data: Data) throws -> String {
    guard
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw VistaError.ModelError(msg: "completion response was not valid JSON")
    }
    let value = (root["response"] as? [String: Any]) ?? root
    if let error = value["error"] as? [String: Any],
      let message = error["message"] as? String
    {
      throw VistaError.ModelError(msg: "completion request failed: \(message)")
    }
    if let feedback = value["promptFeedback"] as? [String: Any],
      let blockReason = feedback["blockReason"] as? String,
      !blockReason.isEmpty
    {
      throw VistaError.ModelError(msg: "completion request failed: Google blocked (\(blockReason))")
    }
    guard let candidates = value["candidates"] as? [[String: Any]],
      let first = candidates.first(where: { ($0["index"] as? Int ?? 0) == 0 }) ?? candidates.first,
      let content = first["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]]
    else {
      return ""
    }
    var texts: [String] = []
    for part in parts {
      if (part["thought"] as? Bool) == true { continue }
      if let text = part["text"] as? String {
        texts.append(text)
      }
    }
    return texts.joined()
  }

  static func refreshTokens(
    _ current: OAuthAccountTokens,
    for provider: OAuthAccountProvider,
    environment: any ProviderEnvironmentManaging,
    timeoutInterval: TimeInterval,
    sendRequest: AIProviderRuntime.RequestSender
  ) async throws -> OAuthAccountTokens {
    guard
      let refreshToken = current.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
      !refreshToken.isEmpty
    else {
      throw VistaError.ModelError(
        msg: "completion request failed: \(provider.rawValue) OAuth token expired")
    }
    let tokenURLString = provider.resolveTokenURL(tokens: current, environment: environment)
    guard let url = URL(string: tokenURLString) else {
      throw VistaError.ModelError(
        msg: "completion request failed: invalid OAuth token refresh URL")
    }
    let clientID = provider.resolveClientID(tokens: current, environment: environment)
    var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    switch provider {
    case .openAIResponses:
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      let payload: [String: String] = [
        "grant_type": "refresh_token",
        "refresh_token": refreshToken,
        "client_id": clientID,
      ]
      request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    case .xAIResponses, .googleGemini:
      request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
      var params: [(String, String)] = [
        ("grant_type", "refresh_token"),
        ("refresh_token", refreshToken),
        ("client_id", clientID),
      ]
      if let secret = current.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
        !secret.isEmpty
      {
        params.append(("client_secret", secret))
      }
      let formBody =
        params
        .map { key, value in
          "\(Self.urlFormEncode(key))=\(Self.urlFormEncode(value))"
        }
        .joined(separator: "&")
      request.httpBody = Data(formBody.utf8)
    }

    let (data, response) = try await sendRequest(request)
    guard (200..<300).contains(response.statusCode) else {
      throw VistaError.ModelError(
        msg: "completion request failed: OAuth refresh HTTP \(response.statusCode)")
    }
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let newAccess = (json["access_token"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !newAccess.isEmpty
    else {
      throw VistaError.ModelError(
        msg: "completion request failed: OAuth refresh response missing access_token")
    }

    var updated = current
    updated.accessToken = newAccess
    if let newRefresh = (json["refresh_token"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !newRefresh.isEmpty
    {
      updated.refreshToken = newRefresh
    }
    if let newIDToken = (json["id_token"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !newIDToken.isEmpty
    {
      updated.idToken = newIDToken
    }
    if let newType = (json["token_type"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !newType.isEmpty
    {
      updated.tokenType = newType
    }
    let rawExpiresIn = OAuthAccountTokens.int64Value(json["expires_in"])
    let lifetimeSeconds = (rawExpiresIn ?? 0) > 0 ? rawExpiresIn! : 3600
    updated.expiresAtUnix = Int64(Date().timeIntervalSince1970) + lifetimeSeconds
    return updated
  }

  private static func parseResponsesJSONObject(
    _ json: [String: Any]
  ) throws -> (text: String, responseID: String?) {
    if let status = (json["status"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased(),
      !status.isEmpty,
      status != "completed"
    {
      throw VistaError.ModelError(msg: "completion response was \(status)")
    }
    let responseID = (json["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let output = json["output"] as? [[String: Any]] {
      var parts: [String] = []
      for item in output {
        guard let content = item["content"] as? [[String: Any]] else { continue }
        for part in content {
          let type = (part["type"] as? String) ?? "output_text"
          if type == "output_text" || type == "text",
            let text = part["text"] as? String
          {
            parts.append(text)
          }
        }
      }
      if !parts.isEmpty {
        return (parts.joined(), responseID?.isEmpty == true ? nil : responseID)
      }
    }
    if let outputText = json["output_text"] as? String {
      return (outputText, responseID?.isEmpty == true ? nil : responseID)
    }
    return ("", responseID?.isEmpty == true ? nil : responseID)
  }

  private static func urlFormEncode(_ string: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
  }
}

extension String {
  fileprivate var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
