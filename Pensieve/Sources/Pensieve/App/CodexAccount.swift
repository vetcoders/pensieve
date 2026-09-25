import CodescribeBridge
import Combine
import Foundation

/// Everything the FFI says about the OpenAI account Ask can use as Codex.
/// Nothing here is persisted by Pensieve. The provider id is codescribe's
/// `openai-responses` — the same catalog row as the OpenAI API key, with the
/// account distinguished by `accountSignedIn` on that row.
struct CodexAccountSnapshot: Equatable, Sendable {
  var isSignedIn = false
  var isLoginConfigured = false
  var statusMessage = ""
  /// The assistive lane resolves to `openai-responses` and the account is
  /// signed in, so codescribe seals account auth and streams to the Codex
  /// backend instead of the API key.
  var askUsesCodex = false
  /// True when the xAI row is signed in. An unpinned lane is left for Grok
  /// to adopt; Codex adopts only when Grok is not signed in, or when the
  /// user pinned Codex.
  var grokSignedIn = false
  var assistiveProviderID = ""

  static let unknown = CodexAccountSnapshot()

  init(
    isSignedIn: Bool = false,
    isLoginConfigured: Bool = false,
    statusMessage: String = "",
    askUsesCodex: Bool = false,
    grokSignedIn: Bool = false,
    assistiveProviderID: String = ""
  ) {
    self.isSignedIn = isSignedIn
    self.isLoginConfigured = isLoginConfigured
    self.statusMessage = statusMessage
    self.askUsesCodex = askUsesCodex
    self.grokSignedIn = grokSignedIn
    self.assistiveProviderID = assistiveProviderID
  }

  init(providers: [CsProviderOption], assistiveLane: CsRuntimeLlmLane) {
    let codex = providers.first { $0.id == CodexAccount.providerID }
    let signedIn = codex?.accountSignedIn ?? false
    self.init(
      isSignedIn: signedIn,
      isLoginConfigured: codex?.accountLoginEnabled ?? false,
      statusMessage: codex?.accountStatusMessage ?? "",
      askUsesCodex: assistiveLane.providerId == CodexAccount.providerID && signedIn,
      grokSignedIn: providers.first { $0.id == GrokAccount.providerID }?.accountSignedIn ?? false,
      assistiveProviderID: assistiveLane.providerId)
  }

  /// Ask's provider when the lane is not Grok. Codex when this account owns
  /// the assistive lane; otherwise the API-key provider.
  func askProvider(apiKey: String?) -> AskProvider {
    askUsesCodex ? .codex(accountAuthorized: isSignedIn) : .apiKey(apiKey)
  }
}

/// The verification page and the code the user confirms on it. codescribe's
/// device-code start puts the code in the same instruction line Grok uses;
/// the OpenAI loopback start has a page and no code, and the panel shows
/// that instruction line instead.
typealias CodexDeviceCode = GrokDeviceCode

/// Codex wording for the same codescribe failure prose Grok classifies.
enum CodexLoginFailure: Equatable, Sendable {
  case underlying(GrokLoginFailure)

  var message: String {
    guard case .underlying(let failure) = self else { return "" }
    switch failure {
    case .expired:
      return "The sign-in code expired before it was approved. Start again to get a new code."
    case .denied:
      return "Access was denied on the OpenAI page. Start again if that was not intended."
    case .timedOut:
      let minutes = CodexAccount.loginTimeoutSeconds / 60
      return "Sign-in was not approved within \(minutes) minutes. Start again when you are ready."
    case .offline:
      return "Could not reach OpenAI. Check your internet connection and try again."
    case .notConfigured:
      return "Codex sign-in is not configured in this build (no OpenAI OAuth client id)."
    case .unavailableInSandbox:
      return SandboxCapabilities.accountSignInUnavailableExplanation
    case .other(let detail):
      return "Codex sign-in failed: \(detail)"
    }
  }

  static func classify(status: String, message: String) -> CodexLoginFailure {
    .underlying(GrokLoginFailure.classify(status: status, message: message))
  }

  static func classify(_ error: any Error) -> CodexLoginFailure {
    .underlying(GrokLoginFailure.classify(error))
  }
}

enum CodexLoginPhase: Equatable, Sendable {
  case idle
  case requestingCode
  case awaitingApproval(CodexDeviceCode)
  case authorized
  case failed(CodexLoginFailure)
  case cancelled

  var isInFlight: Bool {
    switch self {
    case .requestingCode, .awaitingApproval: return true
    case .idle, .authorized, .failed, .cancelled: return false
    }
  }
}

/// Codex as an Ask provider beside Grok: the OpenAI account (codescribe OAuth
/// tokens for `openai-responses`) and the assistive-lane routing. Settings ▸
/// AI and the Ask composer observe one shared instance.
@MainActor
final class CodexAccount: ObservableObject {
  /// codescribe `ProviderKind::OpenAiResponses`. Account sign-in and the
  /// OpenAI API key share this id; the account wins on the assistive lane
  /// once tokens are stored.
  nonisolated static let providerID = "openai-responses"
  nonisolated static let loginTimeoutSeconds: UInt64 = GrokAccount.loginTimeoutSeconds

  static let shared = CodexAccount(laneChoiceDefaults: .standard)

  @Published private(set) var snapshot: CodexAccountSnapshot = .unknown
  @Published private(set) var phase: CodexLoginPhase = .idle
  @Published private(set) var hasLoaded = false
  @Published private(set) var lastError: String?

  let signInAllowed: Bool

  private let bridge: any CodescribeAccountBridging
  private let laneChoiceDefaults: UserDefaults?
  private let staleAfter: TimeInterval
  private let now: () -> Date
  private var lastRefresh: Date?
  private var attempt: UInt64 = 0
  private var isStartInFlight = false

  init(
    bridge: (any CodescribeAccountBridging)? = nil,
    signInAllowed: Bool = SandboxCapabilities.allowsAccountSignIn(),
    laneChoiceDefaults: UserDefaults? = nil,
    staleAfter: TimeInterval = 30,
    now: @escaping () -> Date = Date.init
  ) {
    self.bridge = bridge ?? Self.defaultBridge()
    self.signInAllowed = signInAllowed
    self.laneChoiceDefaults = laneChoiceDefaults
    self.staleAfter = staleAfter
    self.now = now
  }

  nonisolated private static func defaultBridge() -> any CodescribeAccountBridging {
    if AppSupportLocation.isRunningTests() { return InertCodescribeAccountBridge() }
    return LiveCodescribeAccountBridge()
  }

  func refresh() async {
    let bridge = self.bridge
    if let read = try? await Self.offMain({
      (providers: bridge.availableProviders(), lane: bridge.assistiveLane())
    }) {
      snapshot = CodexAccountSnapshot(providers: read.providers, assistiveLane: read.lane)
    }
    hasLoaded = true
    lastRefresh = now()
  }

  func refreshIfStale() async {
    if let lastRefresh, now().timeIntervalSince(lastRefresh) < staleAfter { return }
    await refresh()
  }

  func signIn() async {
    guard signInAllowed else {
      phase = .failed(.underlying(.unavailableInSandbox))
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
      bridge.cancelAccountLogin()
      return
    }
    guard let code = CodexDeviceCode(result: started) else {
      bridge.cancelAccountLogin()
      phase = .failed(
        started.clientIdConfigured
          ? .classify(status: started.status, message: started.message) : .underlying(.notConfigured)
      )
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
    await refresh()
    guard current == attempt else { return }
    switch outcome {
    case .success(let result) where result.status == "signed_in":
      if snapshot.isSignedIn {
        phase = .authorized
        GrokAccount.pinAccount(providerID, defaults: laneChoiceDefaults)
        await routeAsk(to: providerID)
      } else {
        phase = .failed(
          .underlying(.other("OpenAI reported success, but no Codex account was stored.")))
      }
    case .success(let result):
      phase = .failed(.classify(status: result.status, message: result.message))
    case .failure(let error):
      phase = .failed(.classify(error))
    }
  }

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
      lastError = "Could not sign out of Codex: \(GrokLoginFailure.detail(of: error))"
    }
    await refresh()
  }

  func useCodexForAsk() async {
    guard snapshot.isSignedIn else {
      lastError = AskReadiness.codexNotReadyMessage
      return
    }
    GrokAccount.pinAccount(Self.providerID, defaults: laneChoiceDefaults)
    guard !snapshot.askUsesCodex else { return }
    await routeAsk(to: Self.providerID)
  }

  /// A signed-in Codex account drives Ask unless the user pinned another
  /// provider. When Grok is also signed in and nothing is pinned, Grok keeps
  /// the unpinned lane; choosing "Use Codex for Ask" pins Codex.
  func adoptCodexForAskIfSignedIn() async {
    if GrokAccount.apiKeyLaneIsPinned(laneChoiceDefaults) { return }
    if let pinned = GrokAccount.pinnedAccountProvider(laneChoiceDefaults), pinned != Self.providerID
    {
      return
    }
    if GrokAccount.pinnedAccountProvider(laneChoiceDefaults) == nil, snapshot.grokSignedIn {
      return
    }
    guard snapshot.isSignedIn, !snapshot.askUsesCodex else { return }
    await routeAsk(to: Self.providerID)
  }

  func useAPIKeyProviderForAsk(_ shape: CompletionProviderShape) async {
    guard snapshot.askUsesCodex else { return }
    GrokAccount.pinAPIKey(laneChoiceDefaults)
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
