import Foundation
import XCTest

@testable import Pensieve

@MainActor
final class ProviderSettingsTests: XCTestCase {
  func testOpenAIResponsesEndpointNormalizationMatchesCanonicalInputs() {
    for testCase in responsesEndpointCases() {
      XCTAssertEqual(
        ProviderSettings.normalizeOpenAIResponsesEndpoint(testCase.input),
        testCase.expected,
        "input: \(testCase.input)")
    }
  }

  func testEveryCompatibleAndLegacyEndpointIsStoredAndAppliedAsResponses() throws {
    for testCase in responsesEndpointCases() {
      let (defaults, suiteName) = makeDefaults()
      defer { defaults.removePersistentDomain(forName: suiteName) }
      let environment = InMemoryProviderEnvironment()
      let settings = ProviderSettings(
        defaults: defaults,
        keychain: InMemoryProviderAPIKeyStore(),
        environment: environment)
      settings.endpoint = testCase.input
      settings.model = "completion-model"

      try settings.save()

      XCTAssertEqual(settings.endpoint, testCase.expected, "input: \(testCase.input)")
      XCTAssertEqual(
        environment.values["LLM_ASSISTIVE_ENDPOINT"], testCase.expected,
        "input: \(testCase.input)")
      XCTAssertFalse(
        environment.setCalls.contains { $0.value.contains("/chat/completions") },
        "legacy request shape reached the environment for input: \(testCase.input)")

      let restoredEnvironment = InMemoryProviderEnvironment()
      let restored = ProviderSettings(
        defaults: defaults,
        keychain: InMemoryProviderAPIKeyStore(),
        environment: restoredEnvironment)
      XCTAssertEqual(restored.endpoint, testCase.expected, "input: \(testCase.input)")
      XCTAssertEqual(
        restoredEnvironment.values["LLM_ASSISTIVE_ENDPOINT"], testCase.expected,
        "persisted input: \(testCase.input)")
    }
  }

  func testAnthropicMessagesFailsClosedWithoutPersistingOrApplying() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keychain = InMemoryProviderAPIKeyStore()
    let environment = InMemoryProviderEnvironment()
    let settings = ProviderSettings(
      defaults: defaults, keychain: keychain, environment: environment)
    settings.providerShape = .anthropicMessages
    settings.endpoint = "https://api.libraxis.cloud/v1/messages"
    settings.model = "claude-model"
    settings.apiKey = "anthropic-secret"

    XCTAssertFalse(settings.isDraftValid)
    XCTAssertNotNil(settings.providerShape.unsupportedMessage)
    XCTAssertThrowsError(try settings.save()) { error in
      guard case ProviderSettingsError.unsupportedProviderShape(.anthropicMessages) = error
      else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    XCTAssertTrue(environment.setCalls.isEmpty)
    XCTAssertTrue(environment.values.isEmpty)
    XCTAssertNil(keychain.apiKey)
    XCTAssertNil(defaults.string(forKey: "Pensieve.completionProvider.endpoint"))
  }

  func testSecondStoreRestoresPreferencesAndKeychainWithoutPersistingSecretInDefaults() throws {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keychain = InMemoryProviderAPIKeyStore()
    let environment = InMemoryProviderEnvironment()
    let secret = "sk-provider-settings-secret"
    let settings = ProviderSettings(
      defaults: defaults, keychain: keychain, environment: environment)

    settings.endpoint = " https://provider.example/v1 "
    settings.model = " completion-model "
    settings.apiKey = secret
    try settings.save()

    XCTAssertEqual(
      environment.values["LLM_ASSISTIVE_ENDPOINT"],
      "https://provider.example/v1/responses")
    XCTAssertEqual(environment.values["LLM_ASSISTIVE_MODEL"], "completion-model")
    XCTAssertEqual(environment.values["LLM_ASSISTIVE_API_KEY"], secret)
    XCTAssertEqual(keychain.apiKey, secret)

    let persistedValues = Array(defaults.persistentDomain(forName: suiteName)?.values ?? [:].values)
    XCTAssertFalse(persistedValues.contains { ($0 as? String) == secret })

    let restored = ProviderSettings(
      defaults: defaults,
      keychain: keychain,
      environment: InMemoryProviderEnvironment())
    XCTAssertEqual(restored.providerShape, .openAIResponses)
    XCTAssertEqual(restored.endpoint, "https://provider.example/v1/responses")
    XCTAssertEqual(restored.model, "completion-model")
    XCTAssertEqual(restored.apiKey, secret)
  }

  func testInheritedEnvironmentWinsAtLaunchAndPersistedSettingsDoNotClobberIt() throws {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keychain = InMemoryProviderAPIKeyStore()
    let seedEnvironment = InMemoryProviderEnvironment()
    let seed = ProviderSettings(
      defaults: defaults, keychain: keychain, environment: seedEnvironment)
    seed.endpoint = "https://saved.example/v1"
    seed.model = "saved-model"
    seed.apiKey = "saved-secret"
    try seed.save()

    let inheritedEnvironment = InMemoryProviderEnvironment(values: [
      "LLM_ENDPOINT": "https://developer.example/v1",
      "LLM_MODEL": "developer-model",
    ])
    let restored = ProviderSettings(
      defaults: defaults, keychain: keychain, environment: inheritedEnvironment)

    XCTAssertTrue(restored.usesInheritedEnvironmentAtLaunch)
    XCTAssertTrue(restored.isConfigured)
    XCTAssertTrue(inheritedEnvironment.setCalls.isEmpty)
    XCTAssertEqual(inheritedEnvironment.values["LLM_ENDPOINT"], "https://developer.example/v1")
    XCTAssertEqual(inheritedEnvironment.values["LLM_MODEL"], "developer-model")
    XCTAssertNil(
      inheritedEnvironment.values["LLM_ASSISTIVE_API_KEY"],
      "a saved key must never be paired automatically with an inherited provider")
  }

  func testWhitespaceEndpointOrModelNeverTouchesEnvironment() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let environment = InMemoryProviderEnvironment()
    let settings = ProviderSettings(
      defaults: defaults,
      keychain: InMemoryProviderAPIKeyStore(),
      environment: environment)
    settings.endpoint = "   \n"
    settings.model = "model"

    XCTAssertThrowsError(try settings.save())
    XCTAssertTrue(environment.setCalls.isEmpty)

    settings.endpoint = "https://provider.example/v1"
    settings.model = "\t"
    XCTAssertThrowsError(try settings.save())
    XCTAssertTrue(environment.setCalls.isEmpty)
  }

  func testDeletingAPIKeyRemovesKeychainItemAndOnlyAppOwnedEnvironmentValue() throws {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let keychain = InMemoryProviderAPIKeyStore()
    let environment = InMemoryProviderEnvironment()
    let settings = ProviderSettings(
      defaults: defaults, keychain: keychain, environment: environment)
    settings.endpoint = "https://provider.example/v1"
    settings.model = "model"
    settings.apiKey = "secret"
    try settings.save()

    settings.apiKey = "  "
    try settings.save()

    XCTAssertNil(keychain.apiKey)
    XCTAssertNil(environment.values["LLM_ASSISTIVE_API_KEY"])
    XCTAssertTrue(environment.removeCalls.contains("LLM_ASSISTIVE_API_KEY"))
  }

  func testOnboardingStateOffersSetupWithoutDisablingAutocomplete() {
    var state = ProviderOnboardingState()

    state.evaluate(autocompleteEnabled: true, providerConfigured: false)
    XCTAssertTrue(state.isPresented)

    state.dismiss()
    XCTAssertFalse(state.isPresented)

    state.evaluate(autocompleteEnabled: true, providerConfigured: true)
    XCTAssertFalse(state.isPresented)
    state.evaluate(autocompleteEnabled: false, providerConfigured: false)
    XCTAssertFalse(state.isPresented)
  }

  func testSavingSettingsClearsTypedUnavailableLatchForNextRequest() async throws {
    let attempts = ProviderAttemptCounter()
    let engine = MockVistaAutocompleteEngine(completionHandler: { _, _ in
      if attempts.incrementAndGet() == 1 {
        throw VistaError.ModelError(msg: "completion LLM unavailable: set LLM_ENDPOINT")
      }
      return " next"
    })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 1)
    controller.textDidChange(prefix: "hello")
    await waitUntil {
      controller.lastError == AutocompleteController.completionProviderUnavailableMessage
    }
    XCTAssertEqual(attempts.value, 1)

    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = ProviderSettings(
      defaults: defaults,
      keychain: InMemoryProviderAPIKeyStore(),
      environment: InMemoryProviderEnvironment())
    settings.endpoint = "https://provider.example/v1"
    settings.model = "model"
    try settings.save()

    controller.textDidChange(prefix: "hello again")
    await waitUntil { controller.suggestion == " next" }

    XCTAssertEqual(attempts.value, 2)
    XCTAssertNil(controller.lastError)
  }

  private func responsesEndpointCases() -> [(input: String, expected: String)] {
    let expected = "https://api.libraxis.cloud/v1/responses"
    return [
      ("https://api.libraxis.cloud", expected),
      ("https://api.libraxis.cloud/", expected),
      ("  https://api.libraxis.cloud  ", expected),
      ("https://api.libraxis.cloud/v1", expected),
      ("https://api.libraxis.cloud/v1/", expected),
      (" https://api.libraxis.cloud/v1/\n", expected),
      ("https://api.libraxis.cloud/v1/responses", expected),
      ("https://api.libraxis.cloud/v1/responses/", expected),
      (" https://api.libraxis.cloud/v1/responses/ ", expected),
      ("https://api.libraxis.cloud/v1/chat/completions", expected),
      ("https://api.libraxis.cloud/v1/chat/completions/", expected),
      ("\thttps://api.libraxis.cloud/v1/chat/completions/\n", expected),
      ("https://api.libraxis.cloud/v1/completions", expected),
      ("https://api.libraxis.cloud/v1/completions/", expected),
      (" https://api.libraxis.cloud/v1/completions/ ", expected),
    ]
  }

  private func makeDefaults() -> (UserDefaults, String) {
    let suiteName = "ProviderSettingsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
  }

  private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    pollNanoseconds: UInt64 = 10_000_000,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
  ) async {
    let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
    while !condition() {
      if DispatchTime.now().uptimeNanoseconds >= deadline {
        XCTFail("condition timed out", file: file, line: line)
        return
      }
      try? await Task.sleep(nanoseconds: pollNanoseconds)
    }
  }
}

private final class InMemoryProviderAPIKeyStore: ProviderAPIKeyStoring {
  var apiKey: String?

  func loadAPIKey() throws -> String? { apiKey }
  func storeAPIKey(_ apiKey: String) throws { self.apiKey = apiKey }
  func deleteAPIKey() throws { apiKey = nil }
}

private final class InMemoryProviderEnvironment: ProviderEnvironmentManaging {
  var values: [String: String]
  private(set) var setCalls: [(key: String, value: String)] = []
  private(set) var removeCalls: [String] = []

  init(values: [String: String] = [:]) {
    self.values = values
  }

  func value(forKey key: String) -> String? {
    values[key]
  }

  func setValue(_ value: String, forKey key: String) throws {
    values[key] = value
    setCalls.append((key, value))
  }

  func removeValue(forKey key: String) throws {
    values.removeValue(forKey: key)
    removeCalls.append(key)
  }
}

private final class ProviderAttemptCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedValue
  }

  func incrementAndGet() -> Int {
    lock.lock()
    defer { lock.unlock() }
    storedValue += 1
    return storedValue
  }
}
