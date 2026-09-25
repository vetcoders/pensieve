import CodescribeBridge
import Foundation
import Synchronization
import XCTest

@testable import Pensieve

@MainActor
final class GrokAccountTests: XCTestCase {
  // MARK: - Readiness

  func testGrokIsReadyOnlyWithAnAuthorizedAccount() {
    XCTAssertFalse(AskReadiness.isReady(.grok(accountAuthorized: false)))
    XCTAssertTrue(AskReadiness.isReady(.grok(accountAuthorized: true)))
    XCTAssertEqual(
      AskReadiness.notReadyMessage(for: .grok(accountAuthorized: false)),
      AskReadiness.grokNotReadyMessage)
    XCTAssertEqual(AskReadiness.chipLabel(for: .grok(accountAuthorized: true)), "Grok ready")
    XCTAssertEqual(AskReadiness.chipLabel(for: .grok(accountAuthorized: false)), "Grok: sign in")
  }

  func testAskProviderFollowsTheAssistiveLaneAndTheFFIAccount() {
    let authorizedOnGrok = GrokAccountSnapshot(
      providers: [Self.grokRow(signedIn: true)], assistiveLane: Self.lane("xai-responses"))
    XCTAssertEqual(
      authorizedOnGrok.askProvider(apiKey: ""), .grok(accountAuthorized: true),
      "an empty API key field must not matter once Ask is routed to Grok")
    XCTAssertTrue(AskReadiness.isReady(authorizedOnGrok.askProvider(apiKey: "")))

    let signedOutOnGrok = GrokAccountSnapshot(
      providers: [Self.grokRow(signedIn: false)], assistiveLane: Self.lane("xai-responses"))
    XCTAssertEqual(
      signedOutOnGrok.askProvider(apiKey: "sk-test"), .grok(accountAuthorized: false),
      "an API key must not make Grok ready")
    XCTAssertFalse(AskReadiness.isReady(signedOutOnGrok.askProvider(apiKey: "sk-test")))

    let authorizedButOnOpenAI = GrokAccountSnapshot(
      providers: [Self.grokRow(signedIn: true)], assistiveLane: Self.lane("openai-responses"))
    XCTAssertEqual(authorizedButOnOpenAI.askProvider(apiKey: ""), .apiKey(""))
    XCTAssertFalse(AskReadiness.isReady(authorizedButOnOpenAI.askProvider(apiKey: "")))
    XCTAssertTrue(AskReadiness.isReady(authorizedButOnOpenAI.askProvider(apiKey: "sk-test")))
  }

  func testSnapshotReadsAccountTruthFromTheProviderRow() {
    let snapshot = GrokAccountSnapshot(
      providers: [
        Self.openAIRow(),
        Self.grokRow(signedIn: true, message: "signed in as vet@example.com"),
      ],
      assistiveLane: Self.lane("xai-responses"))

    XCTAssertTrue(snapshot.isSignedIn)
    XCTAssertTrue(snapshot.isLoginConfigured)
    XCTAssertEqual(snapshot.statusMessage, "signed in as vet@example.com")
    XCTAssertTrue(snapshot.askUsesGrok)

    let missing = GrokAccountSnapshot(providers: [Self.openAIRow()], assistiveLane: Self.lane(""))
    XCTAssertEqual(missing, .unknown, "no xAI row means no account, not a guess")
  }

  // MARK: - Device code

  func testDeviceCodeIsReadFromCodescribesInstructionLine() throws {
    let code = try XCTUnwrap(GrokDeviceCode(result: Self.started(code: "WXYZ-1234")))
    XCTAssertEqual(code.userCode, "WXYZ-1234")
    XCTAssertEqual(code.verificationURL.absoluteString, "https://auth.x.ai/device")
    XCTAssertEqual(
      code.instructions, "open the browser and approve access (code WXYZ-1234 if asked)")
  }

  func testDeviceCodePrefersTheCompleteVerificationURIsCode() throws {
    let code = try XCTUnwrap(
      GrokDeviceCode(
        result: Self.started(
          code: "PROSE-0000", url: "https://auth.x.ai/device?user_code=QUERY-1111")))
    XCTAssertEqual(code.userCode, "QUERY-1111")
  }

  func testDeviceCodeRefusesAnythingButAnHTTPSPage() {
    XCTAssertNil(GrokDeviceCode(result: Self.started(url: "file:///etc/passwd")))
    XCTAssertNil(GrokDeviceCode(result: Self.started(url: "http://auth.x.ai/device")))
    var noURL = Self.started()
    noURL.authUrl = nil
    XCTAssertNil(GrokDeviceCode(result: noURL))
    XCTAssertNil(GrokDeviceCode(result: Self.finished("signed_in", "signed in")))
  }

  func testUnparseableInstructionsKeepTheRawLine() throws {
    var result = Self.started()
    result.message = "approve access in your browser"
    let code = try XCTUnwrap(GrokDeviceCode(result: result))
    XCTAssertNil(code.userCode)
    XCTAssertEqual(code.instructions, "approve access in your browser")
  }

  // MARK: - Failure wording

  func testCodescribeFailuresBecomeReadableCases() {
    XCTAssertEqual(
      GrokLoginFailure.classify(
        status: "failed",
        message: "account auth failed: xAI device code expired - please re-run login"),
      .expired)
    XCTAssertEqual(
      GrokLoginFailure.classify(
        status: "failed", message: "account auth failed: xAI device authorization was denied"),
      .denied)
    XCTAssertEqual(
      GrokLoginFailure.classify(
        status: "timeout",
        message: "sign-in was not completed within 300s; device authorization abandoned"),
      .timedOut)
    XCTAssertEqual(
      GrokLoginFailure.classify(
        status: "failed", message: "account auth failed: xAI device authorization timed out"),
      .timedOut)
    XCTAssertEqual(
      GrokLoginFailure.classify(
        status: "failed",
        message:
          "account auth HTTP failed: error sending request for url (https://auth.x.ai): "
          + "operation timed out"),
      .offline,
      "a transport timeout is a network failure, not an unapproved code")
    XCTAssertEqual(
      GrokLoginFailure.classify(
        status: "failed",
        message: "awaiting app registration; paste the registered client id in Settings"),
      .notConfigured)
    XCTAssertEqual(
      GrokLoginFailure.classify(status: "failed", message: "account auth failed: nope"),
      .other("account auth failed: nope"))
    XCTAssertEqual(
      GrokLoginFailure.classify(status: "idle", message: " "),
      .other("codescribe returned status idle."))

    for failure: GrokLoginFailure in [
      .expired, .denied, .timedOut, .offline, .notConfigured, .unavailableInSandbox, .other("x"),
    ] {
      XCTAssertFalse(failure.message.isEmpty)
      XCTAssertFalse(failure.message.contains("CsError"), "no enum dumps in user copy")
    }
  }

  func testBridgeErrorDetailIsTheMessageNotTheEnumDump() {
    XCTAssertEqual(
      GrokLoginFailure.detail(of: CsError.Config(msg: "account auth HTTP failed: offline")),
      "account auth HTTP failed: offline")
    XCTAssertEqual(
      GrokLoginFailure.classify(CsError.Config(msg: "account auth HTTP failed: dns error")),
      .offline)
  }

  // MARK: - Login state machine

  func testSignInShowsTheCodeWhilePendingThenBecomesAuthorized() async throws {
    let bridge = FakeCodescribeAccountBridge(gateAwait: true)
    let account = GrokAccount(bridge: bridge, signInAllowed: true)
    await account.refresh()
    XCTAssertFalse(account.snapshot.isSignedIn)

    let signIn = Task { await account.signIn() }
    let pending = await waitUntil { account.phase.isInFlight && Self.pendingCode(account) != nil }
    XCTAssertTrue(pending, "the device code must be visible while approval is pending")
    XCTAssertEqual(Self.pendingCode(account)?.userCode, "WXYZ-1234")
    XCTAssertEqual(bridge.awaitTimeouts, [GrokAccount.loginTimeoutSeconds])

    bridge.releaseAwait()
    await signIn.value

    XCTAssertEqual(account.phase, .authorized)
    XCTAssertTrue(account.snapshot.isSignedIn, "authorized is re-read from the FFI")
    XCTAssertEqual(account.snapshot.statusMessage, "signed in as vet@example.com")
  }

  func testExpiredCodeFailsReadablyInsteadOfStayingPending() async {
    let bridge = FakeCodescribeAccountBridge(
      awaitResult: .success(
        Self.finished(
          "failed", "account auth failed: xAI device code expired - please re-run login")))
    let account = GrokAccount(bridge: bridge, signInAllowed: true)

    await account.signIn()

    XCTAssertEqual(account.phase, .failed(.expired))
    XCTAssertFalse(account.phase.isInFlight)
    XCTAssertFalse(account.snapshot.isSignedIn)
  }

  func testDeniedAndTimedOutAttemptsEndInReadableFailures() async {
    let denied = GrokAccount(
      bridge: FakeCodescribeAccountBridge(
        awaitResult: .success(
          Self.finished("failed", "account auth failed: xAI device authorization was denied"))),
      signInAllowed: true)
    await denied.signIn()
    XCTAssertEqual(denied.phase, .failed(.denied))

    let timedOut = GrokAccount(
      bridge: FakeCodescribeAccountBridge(
        awaitResult: .success(
          Self.finished(
            "timeout", "sign-in was not completed within 300s; device authorization abandoned"))),
      signInAllowed: true)
    await timedOut.signIn()
    XCTAssertEqual(timedOut.phase, .failed(.timedOut))
  }

  func testOfflineStartFailsBeforeAnyCodeIsShown() async {
    let bridge = FakeCodescribeAccountBridge(
      startResult: .failure(
        CsError.Config(msg: "account auth HTTP failed: error sending request for url")))
    let account = GrokAccount(bridge: bridge, signInAllowed: true)

    await account.signIn()

    XCTAssertEqual(account.phase, .failed(.offline))
    XCTAssertEqual(bridge.awaitTimeouts, [], "nothing to await without a device code")
  }

  func testMissingClientIDIsReportedAsNotConfigured() async {
    var result = Self.started()
    result.authUrl = nil
    result.clientIdConfigured = false
    let bridge = FakeCodescribeAccountBridge(startResult: .success(result))
    let account = GrokAccount(bridge: bridge, signInAllowed: true)

    await account.signIn()

    XCTAssertEqual(account.phase, .failed(.notConfigured))
    XCTAssertEqual(bridge.cancelCount, 1, "a start without a usable page must not stay parked")
  }

  func testReportedSuccessWithoutStoredTokensIsNotAuthorized() async {
    let bridge = FakeCodescribeAccountBridge(storesTokensOnApproval: false)
    let account = GrokAccount(bridge: bridge, signInAllowed: true)

    await account.signIn()

    guard case .failed(.other) = account.phase else {
      return XCTFail("expected a failure, got \(account.phase)")
    }
    XCTAssertFalse(account.snapshot.isSignedIn)
  }

  func testCancelWhilePendingReturnsAtOnceAndIgnoresTheLateAnswer() async {
    let bridge = FakeCodescribeAccountBridge(gateAwait: true)
    let account = GrokAccount(bridge: bridge, signInAllowed: true)

    let signIn = Task { await account.signIn() }
    let pending = await waitUntil { Self.pendingCode(account) != nil }
    XCTAssertTrue(pending)

    account.cancelSignIn()
    XCTAssertEqual(account.phase, .cancelled, "cancel must not wait on the blocked poll")
    XCTAssertEqual(bridge.cancelCount, 1)

    bridge.releaseAwait()
    await signIn.value
    XCTAssertEqual(account.phase, .cancelled, "the abandoned attempt's answer must not win")
    XCTAssertTrue(
      account.snapshot.isSignedIn,
      "a code approved after Cancel still produced an account; the FFI truth must show it")
  }

  func testCancelWhileRequestingTheCodeClearsTheParkedLogin() async {
    let bridge = FakeCodescribeAccountBridge(gateStart: true)
    let account = GrokAccount(bridge: bridge, signInAllowed: true)

    let signIn = Task { await account.signIn() }
    let requesting = await waitUntil { account.phase == .requestingCode && bridge.startCount == 1 }
    XCTAssertTrue(requesting)

    account.cancelSignIn()
    XCTAssertEqual(account.phase, .cancelled)
    bridge.releaseStart()
    await signIn.value

    XCTAssertEqual(account.phase, .cancelled)
    XCTAssertEqual(bridge.awaitTimeouts, [], "a cancelled attempt must not start polling")
    XCTAssertEqual(bridge.cancelCount, 2, "the late start's parked login is taken back out")
  }

  func testASecondSignInCannotRaceAnUnfinishedStart() async {
    let bridge = FakeCodescribeAccountBridge(gateStart: true)
    let account = GrokAccount(bridge: bridge, signInAllowed: true)

    let first = Task { await account.signIn() }
    _ = await waitUntil { bridge.startCount == 1 }
    account.cancelSignIn()
    await account.signIn()
    XCTAssertEqual(bridge.startCount, 1, "codescribe keeps one pending-login slot")

    bridge.releaseStart()
    await first.value
  }

  func testSignInIsRefusedWhereTheSandboxDeniesTheNetwork() async {
    let bridge = FakeCodescribeAccountBridge()
    let account = GrokAccount(bridge: bridge, signInAllowed: false)

    await account.signIn()

    XCTAssertEqual(account.phase, .failed(.unavailableInSandbox))
    XCTAssertEqual(bridge.startCount, 0, "a sandboxed build must not start the flow at all")
    XCTAssertFalse(SandboxCapabilities.allowsAccountSignIn(isSandboxed: true))
    XCTAssertTrue(SandboxCapabilities.allowsAccountSignIn(isSandboxed: false))
    XCTAssertEqual(
      GrokLoginFailure.unavailableInSandbox.message,
      SandboxCapabilities.accountSignInUnavailableExplanation)
  }

  // MARK: - Sign out

  func testSignOutRemovesTheAccountAndRereadsTheFFI() async {
    let bridge = FakeCodescribeAccountBridge(signedIn: true, laneProviderID: "xai-responses")
    let account = GrokAccount(bridge: bridge, signInAllowed: true)
    await account.refresh()
    XCTAssertTrue(AskReadiness.isReady(account.snapshot.askProvider(apiKey: nil)))

    await account.signOut()

    XCTAssertEqual(bridge.signOutProviderIDs, ["xai-responses"])
    XCTAssertFalse(account.snapshot.isSignedIn)
    XCTAssertEqual(account.phase, .idle)
    XCTAssertNil(account.lastError)
    XCTAssertEqual(
      account.snapshot.askProvider(apiKey: "sk-test"), .grok(accountAuthorized: false),
      "signing out leaves Ask on Grok, visibly not ready — never silently on another key")
    XCTAssertFalse(AskReadiness.isReady(account.snapshot.askProvider(apiKey: "sk-test")))
  }

  func testSignOutFailureIsReportedAndKeepsTheAccount() async {
    let bridge = FakeCodescribeAccountBridge(
      signedIn: true, signOutError: CsError.Config(msg: "account token storage failed: locked"))
    let account = GrokAccount(bridge: bridge, signInAllowed: true)

    await account.signOut()

    XCTAssertEqual(
      account.lastError, "Could not sign out of Grok: account token storage failed: locked")
    XCTAssertTrue(account.snapshot.isSignedIn)
  }

  // MARK: - Ask routing

  func testGrokIsSelectableForAskOnlyOnceAuthorized() async {
    let bridge = FakeCodescribeAccountBridge(laneProviderID: "openai-responses")
    let account = GrokAccount(bridge: bridge, signInAllowed: true)
    await account.refresh()

    await account.useGrokForAsk()
    XCTAssertEqual(bridge.laneWrites, [], "an unauthorized account must not take over Ask")
    XCTAssertEqual(account.lastError, AskReadiness.grokNotReadyMessage)
    XCTAssertFalse(account.snapshot.askUsesGrok)

    await account.signIn()
    XCTAssertEqual(account.phase, .authorized)
    XCTAssertEqual(bridge.laneWrites, ["xai-responses"], "signing in selects Grok for Ask")
    XCTAssertEqual(
      account.snapshot.askProvider(apiKey: ""), .grok(accountAuthorized: true))
    XCTAssertEqual(
      AskReadiness.chipLabel(for: account.snapshot.askProvider(apiKey: "")), "Grok ready")

    await account.useGrokForAsk()
    XCTAssertEqual(bridge.laneWrites, ["xai-responses"], "already on Grok writes the lane once")
    XCTAssertTrue(account.snapshot.askUsesGrok)
    XCTAssertNil(account.lastError)
  }

  func testSignedInAccountOnTheAPIKeyLaneAdoptsGrokUntilPinned() async {
    let defaults = UserDefaults(suiteName: "pensieve.tests.grok-ask-lane")!
    defaults.removePersistentDomain(forName: "pensieve.tests.grok-ask-lane")
    let bridge = FakeCodescribeAccountBridge(signedIn: true, laneProviderID: "openai-responses")
    let account = GrokAccount(bridge: bridge, signInAllowed: true, laneChoiceDefaults: defaults)
    await account.refresh()
    XCTAssertEqual(account.snapshot.askProvider(apiKey: ""), .apiKey(""))

    await account.adoptGrokForAskIfSignedIn()

    XCTAssertEqual(bridge.laneWrites, ["xai-responses"])
    XCTAssertEqual(
      AskReadiness.chipLabel(for: account.snapshot.askProvider(apiKey: "")), "Grok ready")

    await account.useAPIKeyProviderForAsk(.openAIResponses)
    XCTAssertEqual(bridge.laneWrites, ["xai-responses", "openai-responses"])
    XCTAssertEqual(account.snapshot.askProvider(apiKey: ""), .apiKey(""))

    await account.adoptGrokForAskIfSignedIn()
    XCTAssertEqual(
      bridge.laneWrites, ["xai-responses", "openai-responses"],
      "an explicit API-key choice stays put across the next refresh")
    XCTAssertEqual(
      AskReadiness.chipLabel(for: account.snapshot.askProvider(apiKey: "sk-test")), "Ready")
  }

  func testAskReturnsToTheAPIKeyProviderByItsSharedID() async {
    let bridge = FakeCodescribeAccountBridge(signedIn: true, laneProviderID: "xai-responses")
    let account = GrokAccount(bridge: bridge, signInAllowed: true)
    await account.refresh()

    await account.useAPIKeyProviderForAsk(.anthropicMessages)

    XCTAssertEqual(bridge.laneWrites, ["anthropic-messages"])
    XCTAssertFalse(account.snapshot.askUsesGrok)
    XCTAssertEqual(account.snapshot.askProvider(apiKey: "sk-ant"), .apiKey("sk-ant"))
  }

  func testChoosingTheAPIKeyProviderOffGrokWritesNothing() async {
    let bridge = FakeCodescribeAccountBridge(signedIn: true, laneProviderID: "openai-responses")
    let account = GrokAccount(bridge: bridge, signInAllowed: true)
    await account.refresh()

    await account.useAPIKeyProviderForAsk(.anthropicMessages)

    XCTAssertEqual(
      bridge.laneWrites, [],
      "codescribe's settings.json is shared; Pensieve writes the lane only to leave Grok")
    XCTAssertFalse(account.snapshot.askUsesGrok)
  }

  func testRefusedLaneSwitchIsReported() async {
    let bridge = FakeCodescribeAccountBridge(
      signedIn: true, laneError: CsError.Config(msg: "unknown provider: xai-responses"))
    let account = GrokAccount(bridge: bridge, signInAllowed: true)
    await account.refresh()

    await account.useGrokForAsk()

    XCTAssertEqual(
      account.lastError, "Could not switch the Ask provider: unknown provider: xai-responses")
    XCTAssertFalse(account.snapshot.askUsesGrok)
  }

  // MARK: - Refresh and isolation

  func testComposerRefreshIsCoalescedWithinTheStaleWindow() async {
    let bridge = FakeCodescribeAccountBridge()
    let clock = TestClock()
    let account = GrokAccount(
      bridge: bridge, signInAllowed: true, staleAfter: 30, now: { clock.now })

    await account.refreshIfStale()
    await account.refreshIfStale()
    XCTAssertEqual(bridge.providerReads, 1)
    XCTAssertTrue(account.hasLoaded)

    clock.now = clock.now.addingTimeInterval(31)
    await account.refreshIfStale()
    XCTAssertEqual(bridge.providerReads, 2)
  }

  func testTheDefaultBridgeIsInertUnderXCTest() async {
    let account = GrokAccount(signInAllowed: true)

    await account.refresh()
    XCTAssertEqual(account.snapshot, .unknown, "no real codescribe account under tests")
    XCTAssertTrue(account.hasLoaded)

    await account.signIn()
    XCTAssertEqual(
      account.phase, .failed(.other("the codescribe account bridge is inert under XCTest")))
  }

  // MARK: - Helpers

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

  private static func pendingCode(_ account: GrokAccount) -> GrokDeviceCode? {
    if case .awaitingApproval(let code) = account.phase { return code }
    return nil
  }

  nonisolated static func grokRow(signedIn: Bool, message: String? = nil) -> CsProviderOption {
    let status = message ?? (signedIn ? "signed in as vet@example.com" : "not signed in")
    return CsProviderOption(
      id: "xai-responses", kind: "vendor", displayName: "xAI (Grok)", wire: "responses",
      endpoint: "https://api.x.ai/v1/responses", apiKeyAccount: "LLM_XAI_API_KEY",
      apiKeySet: false, keyRequired: true, accountSignedIn: signedIn,
      accountLoginEnabled: true,
      accountStatusMessage: status, oauthClientId: "shipped-client-id")
  }

  nonisolated static func openAIRow() -> CsProviderOption {
    CsProviderOption(
      id: "openai-responses", kind: "vendor", displayName: "OpenAI", wire: "responses",
      endpoint: "https://api.openai.com/v1/responses", apiKeyAccount: "LLM_OPENAI_API_KEY",
      apiKeySet: true, keyRequired: true, accountSignedIn: false, accountLoginEnabled: true,
      accountStatusMessage: "not signed in", oauthClientId: nil)
  }

  nonisolated static func lane(_ providerID: String) -> CsRuntimeLlmLane {
    CsRuntimeLlmLane(
      lane: .assistive, providerId: providerID, providerDisplayName: providerID, wire: "responses",
      endpoint: "", model: "", keyAccount: "", keyPresent: false,
      accountAuth: providerID == "xai-responses", available: true, unavailableReason: nil)
  }

  /// Mirrors codescribe's device-code start verbatim (bridge/src/config.rs):
  /// the user code exists only inside this sentence.
  nonisolated static func started(
    code: String = "WXYZ-1234", url: String = "https://auth.x.ai/device"
  ) -> CsAccountLoginResult {
    CsAccountLoginResult(
      providerId: "xai-responses", status: "started",
      message: "open the browser and approve access (code \(code) if asked)", authUrl: url,
      signedIn: false, clientIdConfigured: true)
  }

  nonisolated static func finished(_ status: String, _ message: String) -> CsAccountLoginResult {
    CsAccountLoginResult(
      providerId: "xai-responses", status: status, message: message, authUrl: nil,
      signedIn: status == "signed_in", clientIdConfigured: true)
  }
}

private final class TestClock {
  var now = Date(timeIntervalSince1970: 1_000_000)
}

/// In-memory stand-in for the codescribe account FFI. Semaphores let a test
/// hold `start` or `await` open — the way a real network request or device
/// poll would — and observe the phase in between.
private final class FakeCodescribeAccountBridge: CodescribeAccountBridging {
  private struct State {
    var signedIn: Bool
    var laneProviderID: String
    var startResult: Result<CsAccountLoginResult, CsError>
    var awaitResult: Result<CsAccountLoginResult, CsError>
    var storesTokensOnApproval: Bool
    var signOutError: CsError?
    var laneError: CsError?
    var laneWrites: [String] = []
    var signOutProviderIDs: [String] = []
    var awaitTimeouts: [UInt64] = []
    var cancelCount = 0
    var startCount = 0
    var providerReads = 0
  }

  private let state: Mutex<State>
  private let startGate: DispatchSemaphore?
  private let awaitGate: DispatchSemaphore?

  init(
    signedIn: Bool = false,
    laneProviderID: String = "openai-responses",
    startResult: Result<CsAccountLoginResult, CsError> = .success(GrokAccountTests.started()),
    awaitResult: Result<CsAccountLoginResult, CsError> = .success(
      GrokAccountTests.finished("signed_in", "signed in as vet@example.com")),
    storesTokensOnApproval: Bool = true,
    signOutError: CsError? = nil,
    laneError: CsError? = nil,
    gateStart: Bool = false,
    gateAwait: Bool = false
  ) {
    state = Mutex(
      State(
        signedIn: signedIn, laneProviderID: laneProviderID, startResult: startResult,
        awaitResult: awaitResult, storesTokensOnApproval: storesTokensOnApproval,
        signOutError: signOutError, laneError: laneError))
    startGate = gateStart ? DispatchSemaphore(value: 0) : nil
    awaitGate = gateAwait ? DispatchSemaphore(value: 0) : nil
  }

  var laneWrites: [String] { state.withLock { $0.laneWrites } }
  var signOutProviderIDs: [String] { state.withLock { $0.signOutProviderIDs } }
  var awaitTimeouts: [UInt64] { state.withLock { $0.awaitTimeouts } }
  var cancelCount: Int { state.withLock { $0.cancelCount } }
  var startCount: Int { state.withLock { $0.startCount } }
  var providerReads: Int { state.withLock { $0.providerReads } }

  func releaseStart() { startGate?.signal() }
  func releaseAwait() { awaitGate?.signal() }

  func availableProviders() -> [CsProviderOption] {
    state.withLock { state in
      state.providerReads += 1
      return [GrokAccountTests.openAIRow(), GrokAccountTests.grokRow(signedIn: state.signedIn)]
    }
  }

  func assistiveLane() -> CsRuntimeLlmLane {
    GrokAccountTests.lane(state.withLock { $0.laneProviderID })
  }

  func startAccountLogin(providerId: String) throws -> CsAccountLoginResult {
    state.withLock { $0.startCount += 1 }
    startGate?.wait()
    return try state.withLock { $0.startResult }.get()
  }

  func awaitAccountLogin(providerId: String, timeoutSeconds: UInt64) throws
    -> CsAccountLoginResult
  {
    state.withLock { $0.awaitTimeouts.append(timeoutSeconds) }
    awaitGate?.wait()
    return try state.withLock { state in
      let result = try state.awaitResult.get()
      if result.status == "signed_in", state.storesTokensOnApproval {
        state.signedIn = true
      }
      return result
    }
  }

  func cancelAccountLogin() {
    state.withLock { $0.cancelCount += 1 }
  }

  func signOutAccount(providerId: String) throws {
    try state.withLock { state in
      if let error = state.signOutError { throw error }
      state.signOutProviderIDs.append(providerId)
      state.signedIn = false
    }
  }

  func setLaneProvider(lane: CsLlmLane, providerId: String) throws {
    try state.withLock { state in
      if let error = state.laneError { throw error }
      XCTAssertEqual(lane, .assistive)
      state.laneWrites.append(providerId)
      state.laneProviderID = providerId
    }
  }
}
