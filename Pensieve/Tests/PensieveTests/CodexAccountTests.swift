import CodescribeBridge
import Foundation
import Synchronization
import XCTest

@testable import Pensieve

@MainActor
final class CodexAccountTests: XCTestCase {
  func testUnsignedCodexIsNotReady() {
    XCTAssertFalse(AskReadiness.isReady(.codex(accountAuthorized: false)))
    XCTAssertTrue(AskReadiness.isReady(.codex(accountAuthorized: true)))
    XCTAssertEqual(
      AskReadiness.chipLabel(for: .codex(accountAuthorized: false)), "Codex: sign in")
    XCTAssertEqual(AskReadiness.chipLabel(for: .codex(accountAuthorized: true)), "Codex ready")
    XCTAssertEqual(
      AskReadiness.notReadyMessage(for: .codex(accountAuthorized: false)),
      AskReadiness.codexNotReadyMessage)

    let unsignedOnOpenAI = CodexAccountSnapshot(
      providers: [Self.codexRow(signedIn: false)], assistiveLane: Self.lane("openai-responses"))
    XCTAssertEqual(unsignedOnOpenAI.askProvider(apiKey: ""), .apiKey(""))
    XCTAssertFalse(AskReadiness.isReady(unsignedOnOpenAI.askProvider(apiKey: "")))
    XCTAssertEqual(
      AskReadiness.chipLabel(for: unsignedOnOpenAI.askProvider(apiKey: "")), "Needs API key")
  }

  func testSignInShowsTheCodeWhilePendingThenRoutesAsk() async {
    let bridge = FakeCodexAccountBridge(gateAwait: true)
    let account = CodexAccount(bridge: bridge, signInAllowed: true)
    await account.refresh()
    XCTAssertFalse(account.snapshot.isSignedIn)

    let signIn = Task { await account.signIn() }
    let pending = await waitUntil { account.phase.isInFlight && Self.pendingCode(account) != nil }
    XCTAssertTrue(pending, "the device code must be visible while approval is pending")
    XCTAssertEqual(Self.pendingCode(account)?.userCode, "CODE-4242")
    XCTAssertEqual(bridge.startProviderIDs, ["openai-responses"])
    XCTAssertEqual(bridge.awaitTimeouts, [CodexAccount.loginTimeoutSeconds])

    bridge.releaseAwait()
    await signIn.value

    XCTAssertEqual(account.phase, .authorized)
    XCTAssertTrue(account.snapshot.isSignedIn)
    XCTAssertEqual(bridge.laneWrites, ["openai-responses"])
    XCTAssertEqual(
      account.snapshot.askProvider(apiKey: ""), .codex(accountAuthorized: true))
    XCTAssertEqual(
      AskReadiness.chipLabel(for: account.snapshot.askProvider(apiKey: "")), "Codex ready")
  }

  func testSignOutClearsTheAccount() async {
    let bridge = FakeCodexAccountBridge(signedIn: true, laneProviderID: "openai-responses")
    let account = CodexAccount(bridge: bridge, signInAllowed: true)
    await account.refresh()
    XCTAssertTrue(AskReadiness.isReady(account.snapshot.askProvider(apiKey: nil)))

    await account.signOut()

    XCTAssertEqual(bridge.signOutProviderIDs, ["openai-responses"])
    XCTAssertFalse(account.snapshot.isSignedIn)
    XCTAssertEqual(account.phase, .idle)
    XCTAssertNil(account.lastError)
    XCTAssertEqual(account.snapshot.askProvider(apiKey: "sk-test"), .apiKey("sk-test"))
    XCTAssertEqual(
      AskReadiness.chipLabel(for: account.snapshot.askProvider(apiKey: "sk-test")), "Ready")
  }

  func testSignedInAccountOnTheAPIKeyLaneAdoptsCodexUntilPinned() async {
    let defaults = UserDefaults(suiteName: "pensieve.tests.codex-ask-lane")!
    defaults.removePersistentDomain(forName: "pensieve.tests.codex-ask-lane")
    let bridge = FakeCodexAccountBridge(signedIn: true, laneProviderID: "anthropic-messages")
    let account = CodexAccount(bridge: bridge, signInAllowed: true, laneChoiceDefaults: defaults)
    await account.refresh()
    XCTAssertEqual(account.snapshot.askProvider(apiKey: ""), .apiKey(""))
    XCTAssertEqual(
      AskReadiness.chipLabel(for: account.snapshot.askProvider(apiKey: "")), "Needs API key")

    await account.adoptCodexForAskIfSignedIn()

    XCTAssertEqual(bridge.laneWrites, ["openai-responses"])
    XCTAssertEqual(
      AskReadiness.chipLabel(for: account.snapshot.askProvider(apiKey: "")), "Codex ready")

    await account.useAPIKeyProviderForAsk(.anthropicMessages)
    XCTAssertEqual(bridge.laneWrites, ["openai-responses", "anthropic-messages"])
    XCTAssertEqual(account.snapshot.askProvider(apiKey: "sk-ant"), .apiKey("sk-ant"))
    XCTAssertEqual(
      AskReadiness.chipLabel(for: account.snapshot.askProvider(apiKey: "sk-ant")), "Ready")

    await account.adoptCodexForAskIfSignedIn()
    XCTAssertEqual(
      bridge.laneWrites, ["openai-responses", "anthropic-messages"],
      "an explicit API-key choice stays put across the next refresh")
  }

  func testAskReturnsToTheAPIKeyProviderByItsSharedID() async {
    let bridge = FakeCodexAccountBridge(signedIn: true, laneProviderID: "openai-responses")
    let account = CodexAccount(bridge: bridge, signInAllowed: true)
    await account.refresh()

    await account.useAPIKeyProviderForAsk(.anthropicMessages)

    XCTAssertEqual(bridge.laneWrites, ["anthropic-messages"])
    XCTAssertFalse(account.snapshot.askUsesCodex)
    XCTAssertEqual(account.snapshot.askProvider(apiKey: "sk-ant"), .apiKey("sk-ant"))
  }

  func testAPinnedGrokLaneIsNotStolenByCodex() async {
    let defaults = UserDefaults(suiteName: "pensieve.tests.codex-respects-grok-pin")!
    defaults.removePersistentDomain(forName: "pensieve.tests.codex-respects-grok-pin")
    GrokAccount.pinAccount(GrokAccount.providerID, defaults: defaults)
    let bridge = FakeCodexAccountBridge(
      signedIn: true, grokSignedIn: true, laneProviderID: "anthropic-messages")
    let account = CodexAccount(bridge: bridge, signInAllowed: true, laneChoiceDefaults: defaults)
    await account.refresh()

    await account.adoptCodexForAskIfSignedIn()

    XCTAssertEqual(bridge.laneWrites, [], "an explicit Grok pin stays put")
  }

  func testBothAccountSurfacesFollowEveryExplicitSelectionIncludingOpenAIAPIKey() async {
    let suite = "pensieve.tests.ask-routing.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let bridge = FakeCodexAccountBridge(
      signedIn: true, grokSignedIn: true, laneProviderID: "xai-responses")
    let state = AskAccountState(bridge: bridge, defaults: defaults)
    let grok = GrokAccount(laneChoiceDefaults: defaults, accountState: state)
    let codex = CodexAccount(laneChoiceDefaults: defaults, accountState: state)
    await grok.refresh()
    XCTAssertTrue(grok.snapshot.askUsesGrok)
    XCTAssertFalse(codex.snapshot.askUsesCodex)

    await codex.useCodexForAsk()
    XCTAssertFalse(grok.snapshot.askUsesGrok)
    XCTAssertTrue(grok.snapshot.askUsesCodex)
    XCTAssertTrue(codex.snapshot.askUsesCodex)

    await codex.useAPIKeyProviderForAsk(.openAIResponses)
    XCTAssertFalse(grok.snapshot.askUsesGrok)
    XCTAssertFalse(grok.snapshot.askUsesCodex)
    XCTAssertFalse(codex.snapshot.askUsesCodex)
    XCTAssertEqual(codex.snapshot.askProvider(apiKey: "test-key"), .apiKey("test-key"))
    // The choice survives reconstruction and distinguishes an API key from
    // stored OAuth tokens for the same provider id.
    let reopened = AskAccountState(bridge: bridge, defaults: defaults)
    await reopened.refresh()
    XCTAssertFalse(reopened.snapshot?.codex.askUsesCodex ?? true)
    try? await state.select("xai-responses", choice: .automatic)
    XCTAssertFalse(grok.snapshot.askUsesGrok)
    // Opening Settings or another document must not undo the user's choice.
    await grok.refresh()
    await codex.refresh()
    await grok.adoptGrokForAskIfSignedIn()
    await codex.adoptCodexForAskIfSignedIn()
    XCTAssertFalse(codex.snapshot.askUsesCodex)
    XCTAssertFalse(grok.snapshot.askUsesGrok)

    await grok.useGrokForAsk()
    XCTAssertTrue(grok.snapshot.askUsesGrok)
    XCTAssertFalse(codex.snapshot.askUsesCodex)
    XCTAssertEqual(codex.snapshot.assistiveProviderID, "xai-responses")
    await codex.useCodexForAsk()
    XCTAssertFalse(grok.snapshot.askUsesGrok)
    XCTAssertTrue(codex.snapshot.askUsesCodex)
    XCTAssertEqual(
      bridge.laneWrites,
      [
        "openai-responses", "openai-responses", "xai-responses", "openai-responses",
      ])
  }

  func testExplicitChoiceOutranksOldProcessEnvironmentWithoutChangingAutocomplete() async {
    let environment = AskTestEnvironment(values: ["LLM_ASSISTIVE_PROVIDER": "openai-responses"])
    let bridge = FakeCodexAccountBridge(
      signedIn: true, grokSignedIn: true, environment: environment)
    let state = AskAccountState(bridge: bridge, environment: environment)
    let grok = GrokAccount(accountState: state)
    let codex = CodexAccount(accountState: state)
    await grok.refresh()
    XCTAssertTrue(codex.snapshot.askUsesCodex)
    await grok.useGrokForAsk()
    XCTAssertTrue(grok.snapshot.askUsesGrok)
    XCTAssertFalse(codex.snapshot.askUsesCodex)
    XCTAssertEqual(environment.value(forKey: "LLM_ASSISTIVE_PROVIDER"), "xai-responses")
    XCTAssertEqual(environment.value(forKey: "PENSIEVE_COMPLETION_PROVIDER"), "openai-responses")
  }

  private func waitUntil(
    timeout: TimeInterval = 2.0, _ predicate: @escaping () -> Bool
  ) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if predicate() { return true }
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return predicate()
  }

  private static func pendingCode(_ account: CodexAccount) -> CodexDeviceCode? {
    if case .awaitingApproval(let code) = account.phase { return code }
    return nil
  }

  nonisolated static func codexRow(signedIn: Bool, message: String? = nil) -> CsProviderOption {
    let status = message ?? (signedIn ? "signed in as vet@example.com" : "not signed in")
    return CsProviderOption(
      id: "openai-responses", kind: "vendor", displayName: "OpenAI (Responses)",
      wire: "responses", endpoint: "https://api.openai.com/v1/responses",
      apiKeyAccount: "LLM_OPENAI_API_KEY", apiKeySet: false, keyRequired: true,
      accountSignedIn: signedIn, accountLoginEnabled: true, accountStatusMessage: status,
      oauthClientId: "shipped-client-id")
  }

  nonisolated static func grokRow(signedIn: Bool) -> CsProviderOption {
    CsProviderOption(
      id: "xai-responses", kind: "vendor", displayName: "xAI (Grok)", wire: "responses",
      endpoint: "https://api.x.ai/v1/responses", apiKeyAccount: "LLM_XAI_API_KEY",
      apiKeySet: false, keyRequired: true, accountSignedIn: signedIn, accountLoginEnabled: true,
      accountStatusMessage: signedIn ? "signed in" : "not signed in", oauthClientId: nil)
  }

  nonisolated static func lane(_ providerID: String) -> CsRuntimeLlmLane {
    CsRuntimeLlmLane(
      lane: .assistive, providerId: providerID, providerDisplayName: providerID, wire: "responses",
      endpoint: "", model: "", keyAccount: "", keyPresent: false,
      accountAuth: providerID == "openai-responses", available: true, unavailableReason: nil)
  }

  nonisolated static func started(
    code: String = "CODE-4242", url: String = "https://auth.openai.com/codex/device"
  ) -> CsAccountLoginResult {
    CsAccountLoginResult(
      providerId: "openai-responses", status: "started",
      message: "open the browser and approve access (code \(code) if asked)", authUrl: url,
      signedIn: false, clientIdConfigured: true)
  }

  nonisolated static func finished(_ status: String, _ message: String) -> CsAccountLoginResult {
    CsAccountLoginResult(
      providerId: "openai-responses", status: status, message: message, authUrl: nil,
      signedIn: status == "signed_in", clientIdConfigured: true)
  }
}

private final class FakeCodexAccountBridge: CodescribeAccountBridging {
  private struct State {
    var signedIn: Bool
    var grokSignedIn: Bool
    var laneProviderID: String
    var laneWrites: [String] = []
    var signOutProviderIDs: [String] = []
    var startProviderIDs: [String] = []
    var awaitTimeouts: [UInt64] = []
  }

  private let state: Mutex<State>
  private let awaitGate: DispatchSemaphore?
  private let environment: (any ProviderEnvironmentManaging)?

  init(
    signedIn: Bool = false,
    grokSignedIn: Bool = false,
    laneProviderID: String = "anthropic-messages",
    gateAwait: Bool = false,
    environment: (any ProviderEnvironmentManaging)? = nil
  ) {
    self.environment = environment
    state = Mutex(
      State(signedIn: signedIn, grokSignedIn: grokSignedIn, laneProviderID: laneProviderID))
    awaitGate = gateAwait ? DispatchSemaphore(value: 0) : nil
  }

  var laneWrites: [String] { state.withLock { $0.laneWrites } }
  var signOutProviderIDs: [String] { state.withLock { $0.signOutProviderIDs } }
  var startProviderIDs: [String] { state.withLock { $0.startProviderIDs } }
  var awaitTimeouts: [UInt64] { state.withLock { $0.awaitTimeouts } }

  func releaseAwait() { awaitGate?.signal() }

  func availableProviders() -> [CsProviderOption] {
    state.withLock { state in
      [
        CodexAccountTests.codexRow(signedIn: state.signedIn),
        CodexAccountTests.grokRow(signedIn: state.grokSignedIn),
      ]
    }
  }

  func assistiveLane() -> CsRuntimeLlmLane {
    CodexAccountTests.lane(
      environment?.value(forKey: "LLM_ASSISTIVE_PROVIDER") ?? state.withLock { $0.laneProviderID })
  }

  func startAccountLogin(providerId: String) throws -> CsAccountLoginResult {
    state.withLock { $0.startProviderIDs.append(providerId) }
    return CodexAccountTests.started()
  }

  func awaitAccountLogin(providerId: String, timeoutSeconds: UInt64) throws
    -> CsAccountLoginResult
  {
    state.withLock { $0.awaitTimeouts.append(timeoutSeconds) }
    awaitGate?.wait()
    return state.withLock { state in
      state.signedIn = true
      return CodexAccountTests.finished("signed_in", "signed in as vet@example.com")
    }
  }

  func cancelAccountLogin() {}

  func signOutAccount(providerId: String) throws {
    state.withLock { state in
      state.signOutProviderIDs.append(providerId)
      state.signedIn = false
    }
  }

  func setLaneProvider(lane: CsLlmLane, providerId: String) throws {
    state.withLock { state in
      XCTAssertEqual(lane, .assistive)
      state.laneWrites.append(providerId)
      state.laneProviderID = providerId
    }
  }
}

private final class AskTestEnvironment: ProviderEnvironmentManaging {
  private let values: Mutex<[String: String]>
  init(values: [String: String]) { self.values = Mutex(values) }
  func value(forKey key: String) -> String? { values.withLock { $0[key] } }
  func setValue(_ value: String, forKey key: String) throws { values.withLock { $0[key] = value } }
  func removeValue(forKey key: String) throws {
    _ = values.withLock { $0.removeValue(forKey: key) }
  }
}
