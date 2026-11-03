import CodescribeBridge
import Combine
import Foundation

/// One account/routing snapshot for Settings and every Ask composer. Reads and
/// writes are ordered so a late refresh cannot resurrect an earlier selection.
@MainActor
final class AskAccountState {
  struct Snapshot {
    var grok: GrokAccountSnapshot
    var codex: CodexAccountSnapshot
  }

  enum Choice {
    case account, apiKey, automatic
  }

  static let shared = AskAccountState(
    defaults: .standard,
    environment: AppSupportLocation.isRunningTests() ? nil : ProcessProviderEnvironment())
  @Published private(set) var snapshot: Snapshot?
  let bridge: any CodescribeAccountBridging
  private let defaults: UserDefaults?
  private let environment: (any ProviderEnvironmentManaging)?
  private var apiKeySelected: Bool
  private var pending: Task<Void, Never>?

  init(
    bridge: (any CodescribeAccountBridging)? = nil, defaults: UserDefaults? = nil,
    environment: (any ProviderEnvironmentManaging)? = nil
  ) {
    self.bridge =
      bridge
      ?? (AppSupportLocation.isRunningTests()
        ? InertCodescribeAccountBridge() : LiveCodescribeAccountBridge())
    self.defaults = defaults
    self.environment = environment
    apiKeySelected = GrokAccount.apiKeyLaneIsPinned(defaults)
  }

  func refresh() async {
    let previous = pending
    let task = Task {
      await previous?.value
      await readSnapshot()
    }
    pending = task
    await task.value
  }

  func select(_ providerID: String, choice: Choice) async throws {
    let previous = pending
    let task = Task {
      await previous?.value
      // A view task may have decided to adopt before an explicit click was
      // queued. Recheck the committed preference at execution time.
      if case .automatic = choice {
        if apiKeySelected { return }
        if let pinned = GrokAccount.pinnedAccountProvider(defaults), pinned != providerID { return }
      }
      let bridge = self.bridge
      let environment = self.environment
      try await Self.offMain {
        let key = "LLM_ASSISTIVE_PROVIDER"
        let previous = environment?.value(forKey: key)
        // The engine resolves process env BEFORE persisted settings. Preserve
        // autocomplete's wire before changing the legacy shared selector.
        if let environment {
          if environment.value(forKey: "PENSIEVE_COMPLETION_PROVIDER") == nil {
            let shape =
              ProviderSettings.providerShapeEnvironmentKeys
              .compactMap { environment.value(forKey: $0) }
              .compactMap(CompletionProviderShape.init(rawValue:)).first ?? .openAIResponses
            try environment.setValue(shape.rawValue, forKey: "PENSIEVE_COMPLETION_PROVIDER")
          }
          try environment.setValue(providerID, forKey: key)
        }
        do {
          // Writing after env changes also invalidates the FFI's mtime cache.
          try bridge.setLaneProvider(lane: .assistive, providerId: providerID)
          guard bridge.assistiveLane().providerId == providerID else {
            throw CsError.Config(msg: "The engine did not apply the selected Ask provider.")
          }
        } catch {
          if let environment {
            if let previous {
              try environment.setValue(previous, forKey: key)
            } else {
              try environment.removeValue(forKey: key)
            }
          }
          throw error
        }
      }
      switch choice {
      case .account:
        apiKeySelected = false
        GrokAccount.pinAccount(providerID, defaults: defaults)
      case .apiKey:
        apiKeySelected = true
        GrokAccount.pinAPIKey(defaults)
      case .automatic:
        break
      }
      await readSnapshot()
    }
    pending = Task { _ = try? await task.value }
    try await task.value
  }

  private func readSnapshot() async {
    let bridge = self.bridge
    guard
      let read = try? await Self.offMain({
        (bridge.availableProviders(), bridge.assistiveLane())
      })
    else { return }
    var grok = GrokAccountSnapshot(providers: read.0, assistiveLane: read.1)
    var codex = CodexAccountSnapshot(providers: read.0, assistiveLane: read.1)
    // OAuth and API-key requests can share a provider id. Account presence
    // alone must not turn an explicit API-key selection back into OAuth.
    if apiKeySelected {
      grok.askUsesGrok = false
      codex.askUsesCodex = false
    }
    grok.askUsesCodex = codex.askUsesCodex
    snapshot = Snapshot(grok: grok, codex: codex)
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
