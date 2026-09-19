import CodescribeBridge
import Combine
import Foundation
import Synchronization

/// The slice of the codescribe config engine the Grok account needs: provider
/// rows (account truth), the assistive lane Ask streams through (routing
/// truth), and the RFC 8628 device-code verbs. A seam so tests drive the whole
/// state machine without ever reaching a real xAI account, the Keychain, or
/// `~/.codescribe`.
protocol CodescribeAccountBridging: Sendable {
  func availableProviders() -> [CsProviderOption]
  func assistiveLane() -> CsRuntimeLlmLane
  func startAccountLogin(providerId: String) throws -> CsAccountLoginResult
  func awaitAccountLogin(providerId: String, timeoutSeconds: UInt64) throws
    -> CsAccountLoginResult
  func cancelAccountLogin()
  func signOutAccount(providerId: String) throws
  func setLaneProvider(lane: CsLlmLane, providerId: String) throws
}

/// The vendored codescribe FFI. `CodescribeConfig()` is not a pure allocation —
/// it seeds the recorder's audio-input selector and resumes persisted run
/// monitors — so the handle is built on first use, never at launch and never
/// by merely rendering a view that holds this bridge.
final class LiveCodescribeAccountBridge: CodescribeAccountBridging {
  private let handle = Mutex<CodescribeConfig?>(nil)

  private var config: CodescribeConfig {
    handle.withLock { slot in
      if let existing = slot { return existing }
      let created = CodescribeConfig()
      slot = created
      return created
    }
  }

  func availableProviders() -> [CsProviderOption] {
    config.availableProviders()
  }

  func assistiveLane() -> CsRuntimeLlmLane {
    runtimeLlmLane(lane: .assistive)
  }

  func startAccountLogin(providerId: String) throws -> CsAccountLoginResult {
    try config.startAccountLogin(providerId: providerId)
  }

  func awaitAccountLogin(providerId: String, timeoutSeconds: UInt64) throws
    -> CsAccountLoginResult
  {
    try config.awaitAccountLogin(providerId: providerId, timeoutSeconds: timeoutSeconds)
  }

  func cancelAccountLogin() {
    config.cancelAccountLogin()
  }

  func signOutAccount(providerId: String) throws {
    try config.signOutAccount(providerId: providerId)
  }

  func setLaneProvider(lane: CsLlmLane, providerId: String) throws {
    try config.setLaneProvider(lane: lane, providerId: providerId)
  }
}

/// What an XCTest host gets from `GrokAccount.shared`: no providers, no lane,
/// every verb refused. Tests that exercise Grok inject their own fake; a test
/// that merely renders the composer or Settings must never touch the
/// operator's real codescribe account, Keychain, or settings.json.
struct InertCodescribeAccountBridge: CodescribeAccountBridging {
  private static let refusal = CsError.Config(
    msg: "the codescribe account bridge is inert under XCTest")

  func availableProviders() -> [CsProviderOption] { [] }

  func assistiveLane() -> CsRuntimeLlmLane {
    CsRuntimeLlmLane(
      lane: .assistive, providerId: "", providerDisplayName: "", wire: "", endpoint: "",
      model: "", keyAccount: "", keyPresent: false, accountAuth: false, available: false,
      unavailableReason: nil)
  }

  func startAccountLogin(providerId: String) throws -> CsAccountLoginResult {
    throw Self.refusal
  }

  func awaitAccountLogin(providerId: String, timeoutSeconds: UInt64) throws
    -> CsAccountLoginResult
  {
    throw Self.refusal
  }

  func cancelAccountLogin() {}

  func signOutAccount(providerId: String) throws {
    throw Self.refusal
  }

  func setLaneProvider(lane: CsLlmLane, providerId: String) throws {
    throw Self.refusal
  }
}

/// Everything the FFI says about Grok, read in one refresh. Nothing here is
/// persisted by Pensieve.
struct GrokAccountSnapshot: Equatable, Sendable {
  /// xAI account tokens are stored (`CsProviderOption.accountSignedIn`).
  var isSignedIn = false
  /// This build carries an xAI OAuth client id (`accountLoginEnabled`).
  var isLoginConfigured = false
  /// codescribe's own copy: "signed in as …", "not signed in",
  /// "awaiting app registration".
  var statusMessage = ""
  /// The assistive lane — the one `CodescribeAgent.streamReply` sends Ask
  /// through — resolves to xAI.
  var askUsesGrok = false

  static let unknown = GrokAccountSnapshot()

  init(
    isSignedIn: Bool = false,
    isLoginConfigured: Bool = false,
    statusMessage: String = "",
    askUsesGrok: Bool = false
  ) {
    self.isSignedIn = isSignedIn
    self.isLoginConfigured = isLoginConfigured
    self.statusMessage = statusMessage
    self.askUsesGrok = askUsesGrok
  }

  init(providers: [CsProviderOption], assistiveLane: CsRuntimeLlmLane) {
    let grok = providers.first { $0.id == GrokAccount.providerID }
    self.init(
      isSignedIn: grok?.accountSignedIn ?? false,
      isLoginConfigured: grok?.accountLoginEnabled ?? false,
      statusMessage: grok?.accountStatusMessage ?? "",
      askUsesGrok: assistiveLane.providerId == GrokAccount.providerID)
  }

  /// Ask's provider as the lane states it: Grok when the assistive lane is
  /// xAI, otherwise the API-key provider under the unchanged W5 rule.
  func askProvider(apiKey: String?) -> AskProvider {
    askUsesGrok ? .grok(accountAuthorized: isSignedIn) : .apiKey(apiKey)
  }
}

/// The verification page and the code the user confirms on it.
struct GrokDeviceCode: Equatable, Sendable {
  let verificationURL: URL
  let userCode: String?
  /// codescribe's raw instruction line, shown when no code can be isolated.
  let instructions: String

  /// Nil unless codescribe started a device login with an https page to open:
  /// the address comes from xAI's response, and only a web page may be handed
  /// to NSWorkspace.
  init?(result: CsAccountLoginResult) {
    guard result.status == "started",
      let rawURL = result.authUrl,
      let url = URL(string: rawURL),
      url.scheme?.lowercased() == "https",
      url.host != nil
    else { return nil }
    verificationURL = url
    instructions = result.message
    userCode = Self.userCode(message: result.message, verificationURL: url)
  }

  /// `CsAccountLoginResult` has no field for the code. When xAI sends
  /// `verification_uri_complete`, the code rides in its `user_code` query
  /// item; otherwise it exists only inside codescribe's prose — "open the
  /// browser and approve access (code ABCD-1234 if asked)", from the
  /// device-code branch of `start_account_login` in bridge/src/config.rs.
  static func userCode(message: String, verificationURL: URL) -> String? {
    if let item = URLComponents(url: verificationURL, resolvingAgainstBaseURL: false)?
      .queryItems?.first(where: { $0.name == "user_code" })?.value,
      !item.isEmpty
    {
      return item
    }
    guard let marker = message.range(of: "(code ") else { return nil }
    let code = message[marker.upperBound...].prefix { !$0.isWhitespace && $0 != ")" }
    return code.isEmpty ? nil : String(code)
  }
}

/// Every way a Grok sign-in ends short of an account, in words a user can act
/// on. codescribe reports these as prose (`AccountAuthError`'s Display) inside
/// a `failed` / `timeout` status or a thrown `CsError`; `classify` maps that
/// prose onto the cases below.
enum GrokLoginFailure: Equatable, Sendable {
  case expired
  case denied
  case timedOut
  case offline
  case notConfigured
  case unavailableInSandbox
  case other(String)

  var message: String {
    switch self {
    case .expired:
      return "The sign-in code expired before it was approved. Start again to get a new code."
    case .denied:
      return "Access was denied on the xAI page. Start again if that was not intended."
    case .timedOut:
      let minutes = GrokAccount.loginTimeoutSeconds / 60
      return "Sign-in was not approved within \(minutes) minutes. Start again when you are ready."
    case .offline:
      return "Could not reach xAI. Check your internet connection and try again."
    case .notConfigured:
      return "Grok sign-in is not configured in this build (no xAI OAuth client id)."
    case .unavailableInSandbox:
      return SandboxCapabilities.accountSignInUnavailableExplanation
    case .other(let detail):
      return "Grok sign-in failed: \(detail)"
    }
  }

  static func classify(status: String, message: String) -> GrokLoginFailure {
    let text = message.lowercased()
    if status == "timeout" { return .timedOut }
    // `AccountAuthError::Http` — the request never completed. Checked before
    // "timed out" because a transport timeout is a network failure, not an
    // unapproved code.
    if text.contains("http failed") { return .offline }
    if text.contains("expired") { return .expired }
    if text.contains("denied") { return .denied }
    if text.contains("timed out") { return .timedOut }
    if text.contains("awaiting app registration") { return .notConfigured }
    let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
    return .other(detail.isEmpty ? "codescribe returned status \(status)." : detail)
  }

  static func classify(_ error: any Error) -> GrokLoginFailure {
    classify(status: "failed", message: detail(of: error))
  }

  /// The message a `CsError` carries, without the enum dump that its
  /// generated `errorDescription` produces.
  static func detail(of error: any Error) -> String {
    guard let bridgeError = error as? CsError else { return error.localizedDescription }
    switch bridgeError {
    case .Agent(let msg), .Config(let msg), .Recording(let msg), .License(let msg),
      .Quality(let msg), .Runtime(let msg):
      return msg
    }
  }
}

/// One device-code sign-in attempt: idle → requestingCode → awaitingApproval →
/// authorized / failed / cancelled. Whether an account exists is never this
/// enum's claim — that is `GrokAccountSnapshot.isSignedIn`, read from the FFI.
enum GrokLoginPhase: Equatable, Sendable {
  case idle
  case requestingCode
  case awaitingApproval(GrokDeviceCode)
  case authorized
  case failed(GrokLoginFailure)
  case cancelled

  var isInFlight: Bool {
    switch self {
    case .requestingCode, .awaitingApproval: return true
    case .idle, .authorized, .failed, .cancelled: return false
    }
  }
}

/// Grok as Ask's third provider: the account (codescribe's xAI OAuth tokens)
/// and the routing (codescribe's assistive lane). Settings ▸ AI and the Ask
/// composer observe one shared instance, so the two surfaces cannot disagree.
@MainActor
final class GrokAccount: ObservableObject {
  nonisolated static let providerID = "xai-responses"
  /// codescribe P2-09: the OAuth human step (a second screen, 2FA) routinely
  /// outlasts a short timeout. Five minutes matches the Codescribe app.
  nonisolated static let loginTimeoutSeconds: UInt64 = 300

  static let shared = GrokAccount()

  @Published private(set) var snapshot: GrokAccountSnapshot = .unknown
  @Published private(set) var phase: GrokLoginPhase = .idle
  @Published private(set) var hasLoaded = false
  @Published private(set) var lastError: String?

  let signInAllowed: Bool

  private let bridge: any CodescribeAccountBridging
  private let staleAfter: TimeInterval
  private let now: () -> Date
  private var lastRefresh: Date?
  /// Bumped by every start and cancel. A blocking FFI call that returns under
  /// an older value belongs to an abandoned attempt and must not move `phase`.
  private var attempt: UInt64 = 0
  /// codescribe keeps one pending-login slot; a second start racing an
  /// unfinished first could park the wrong device code in it.
  private var isStartInFlight = false

  init(
    bridge: (any CodescribeAccountBridging)? = nil,
    signInAllowed: Bool = SandboxCapabilities.allowsAccountSignIn(),
    staleAfter: TimeInterval = 30,
    now: @escaping () -> Date = Date.init
  ) {
    self.bridge = bridge ?? Self.defaultBridge()
    self.signInAllowed = signInAllowed
    self.staleAfter = staleAfter
    self.now = now
  }

  nonisolated private static func defaultBridge() -> any CodescribeAccountBridging {
    if AppSupportLocation.isRunningTests() { return InertCodescribeAccountBridge() }
    return LiveCodescribeAccountBridge()
  }

  /// Re-read the account row and the assistive lane from the FFI.
  func refresh() async {
    let bridge = self.bridge
    if let read = try? await Self.offMain({
      (providers: bridge.availableProviders(), lane: bridge.assistiveLane())
    }) {
      snapshot = GrokAccountSnapshot(providers: read.providers, assistiveLane: read.lane)
    }
    hasLoaded = true
    lastRefresh = now()
  }

  /// The composer's refresh: every window with an editable buffer shows one,
  /// so reads are coalesced instead of hitting the Keychain per render.
  func refreshIfStale() async {
    if let lastRefresh, now().timeIntervalSince(lastRefresh) < staleAfter { return }
    await refresh()
  }

  /// Runs the whole device-code sign-in: request a code, show it, wait for
  /// approval, then re-read the account from the FFI.
  func signIn() async {
    guard signInAllowed else {
      phase = .failed(.unavailableInSandbox)
      return
    }
    guard !phase.isInFlight, !isStartInFlight else { return }
    attempt &+= 1
    let current = attempt
    lastError = nil
    phase = .requestingCode
    isStartInFlight = true
    let bridge = self.bridge
    let providerID = Self.providerID

    let started: CsAccountLoginResult
    do {
      started = try await Self.offMain { try bridge.startAccountLogin(providerId: providerID) }
    } catch {
      isStartInFlight = false
      if current == attempt { phase = .failed(.classify(error)) }
      return
    }
    isStartInFlight = false
    guard current == attempt else {
      // Cancelled while xAI was issuing the code: the start has since parked
      // a pending login in codescribe's slot. Take it back out.
      bridge.cancelAccountLogin()
      return
    }
    guard let code = GrokDeviceCode(result: started) else {
      bridge.cancelAccountLogin()
      phase = .failed(
        started.clientIdConfigured
          ? .classify(status: started.status, message: started.message) : .notConfigured)
      return
    }
    phase = .awaitingApproval(code)

    let timeout = Self.loginTimeoutSeconds
    let outcome: Result<CsAccountLoginResult, any Error>
    do {
      outcome = .success(
        try await Self.offMain {
          try bridge.awaitAccountLogin(providerId: providerID, timeoutSeconds: timeout)
        })
    } catch {
      outcome = .failure(error)
    }
    // Always re-read, even for an abandoned attempt: a code approved after
    // Cancel still produced an account, and the row must say so.
    await refresh()
    guard current == attempt else { return }
    switch outcome {
    case .success(let result) where result.status == "signed_in":
      phase =
        snapshot.isSignedIn
        ? .authorized
        : .failed(.other("xAI reported success, but no Grok account was stored."))
    case .success(let result):
      phase = .failed(.classify(status: result.status, message: result.message))
    case .failure(let error):
      phase = .failed(.classify(error))
    }
  }

  /// Stops waiting and returns the surface to a startable state at once.
  ///
  /// codescribe's `await_account_login` takes the device poll out of the
  /// cancel slot before polling, so `cancelAccountLogin()` reaches a login
  /// only until the await begins; a poll already running ends at its own
  /// timeout. The attempt counter makes that late answer inert here, and the
  /// refresh it triggers still shows an approval that landed anyway.
  func cancelSignIn() {
    guard phase.isInFlight else { return }
    attempt &+= 1
    bridge.cancelAccountLogin()
    phase = .cancelled
  }

  func signOut() async {
    guard !phase.isInFlight else { return }
    let bridge = self.bridge
    let providerID = Self.providerID
    do {
      try await Self.offMain { try bridge.signOutAccount(providerId: providerID) }
      lastError = nil
      phase = .idle
    } catch {
      lastError = "Could not sign out of Grok: \(GrokLoginFailure.detail(of: error))"
    }
    await refresh()
  }

  /// Routes Ask to Grok by pointing codescribe's assistive lane at xAI. A
  /// persisted lane provider outranks the `LLM_ASSISTIVE_PROVIDER` that
  /// ProviderSettings exports (codescribe docs/lane-truth.md), so the very
  /// next `streamReply` goes to Grok.
  func useGrokForAsk() async {
    guard snapshot.isSignedIn else {
      lastError = AskReadiness.grokNotReadyMessage
      return
    }
    await routeAsk(to: Self.providerID)
  }

  /// Hands Ask back to the API-key provider. codescribe refuses an empty lane
  /// provider — every value is resolved against its catalog — so the Grok
  /// routing cannot be cleared, only replaced: by the API-key provider's own
  /// id, which `CompletionProviderShape` shares with codescribe. Off Grok this
  /// writes nothing: codescribe's settings.json is shared with the Codescribe
  /// app, and Pensieve only owns the move into and out of Grok.
  func useAPIKeyProviderForAsk(_ shape: CompletionProviderShape) async {
    guard snapshot.askUsesGrok else { return }
    await routeAsk(to: shape.rawValue)
  }

  private func routeAsk(to providerID: String) async {
    let bridge = self.bridge
    do {
      try await Self.offMain {
        try bridge.setLaneProvider(lane: .assistive, providerId: providerID)
      }
      lastError = nil
    } catch {
      lastError = "Could not switch the Ask provider: \(GrokLoginFailure.detail(of: error))"
    }
    await refresh()
  }

  /// Runs one blocking codescribe call on a GCD worker. `start` performs a
  /// network request and `await` parks for up to five minutes; neither may
  /// hold the main actor or a cooperative-pool thread.
  nonisolated private static func offMain<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result { try work() })
      }
    }
  }
}
