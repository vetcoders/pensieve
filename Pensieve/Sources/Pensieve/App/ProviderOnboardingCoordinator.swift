import Combine

/// App-run authority for provider onboarding presentation.
///
/// Every native tab owns a live `ContentView`, but only the key tab may claim
/// the onboarding sheet. Once one tab claims it, all other window contexts see
/// the same presentation owner and cannot enqueue another sheet.
@MainActor
final class ProviderOnboardingCoordinator: ObservableObject {
  static let shared = ProviderOnboardingCoordinator()

  @Published private(set) var presentingWindowID: ObjectIdentifier?
  /// Startup restore mutates one native tab group over several run-loop turns.
  /// A sheet becoming key between those turns used to replace the document
  /// host as the registry's merge target and split the restored working set
  /// into standalone windows. Keep onboarding eligible but unpresented until
  /// the restore has finished building its tab group.
  @Published private(set) var startupRestoreInProgress = false

  private var autocompleteEnabled: Bool?
  private var providerConfigured: Bool
  private var dismissedForEnableCycle = false

  init(
    autocompleteEnabled: Bool? = nil,
    providerConfigured: Bool = false
  ) {
    self.autocompleteEnabled = autocompleteEnabled
    self.providerConfigured = providerConfigured
  }

  /// Seeds app-wide eligibility from the first mounted window without letting
  /// later, stale per-window models overwrite a user toggle made elsewhere.
  func initializeIfNeeded(
    autocompleteEnabled: Bool,
    providerConfigured: Bool
  ) {
    if self.autocompleteEnabled == nil {
      self.autocompleteEnabled = autocompleteEnabled
    }
    self.providerConfigured = providerConfigured
    reconcileEligibility()
  }

  /// Records the app-wide toggle. Turning autocomplete off also starts a fresh
  /// enable cycle, so turning it back on may offer setup once again.
  func setAutocompleteEnabled(_ enabled: Bool) {
    guard autocompleteEnabled != enabled else { return }
    autocompleteEnabled = enabled
    presentingWindowID = nil
    if !enabled {
      dismissedForEnableCycle = false
    }
  }

  func setProviderConfigured(_ configured: Bool) {
    providerConfigured = configured
    reconcileEligibility()
  }

  func setStartupRestoreInProgress(_ inProgress: Bool) {
    guard startupRestoreInProgress != inProgress else { return }
    startupRestoreInProgress = inProgress
    if inProgress {
      // A view may have claimed presentation during its first onAppear while
      // the controller was still preparing the working set. Withdraw that
      // pending claim before SwiftUI materializes the sheet.
      presentingWindowID = nil
    }
  }

  /// Lets one window context claim presentation only when it is currently key.
  /// Calls from background tabs are harmless and cannot create queued sheets.
  func evaluate(windowID: ObjectIdentifier?, isKeyWindow: Bool) {
    guard autocompleteEnabled == true, !providerConfigured,
      !dismissedForEnableCycle, presentingWindowID == nil,
      !startupRestoreInProgress,
      isKeyWindow, let windowID
    else {
      return
    }
    presentingWindowID = windowID
  }

  func isPresented(in windowID: ObjectIdentifier?) -> Bool {
    presentingWindowID != nil && presentingWindowID == windowID
  }

  /// Both "Not Now" and "Configure…" dismiss app-wide for this enable cycle.
  func dismiss() {
    presentingWindowID = nil
    dismissedForEnableCycle = true
  }

  private func reconcileEligibility() {
    guard autocompleteEnabled == true, !providerConfigured else {
      presentingWindowID = nil
      return
    }
  }
}
