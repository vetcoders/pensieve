import AppKit
import SwiftUI

struct ProviderSettingsView: View {
  @ObservedObject var settings: ProviderSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 6) {
        Text("AI Autocomplete")
          .font(.title2.weight(.semibold))
        Text("Connect the provider that powers inline suggestions as you type.")
          .foregroundStyle(.secondary)
      }

      Form {
        Picker("Provider API", selection: $settings.providerShape) {
          ForEach(CompletionProviderShape.allCases) { shape in
            Text(shape.displayName).tag(shape)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("pensieve.provider.shape")
        .onChange(of: settings.providerShape) {
          settings.providerShapeDidChange()
        }
        TextField(
          "Endpoint", text: $settings.endpoint, prompt: Text(settings.providerShape.endpointPrompt)
        )
        .textContentType(.URL)
        .accessibilityIdentifier("pensieve.provider.endpoint")
        .onChange(of: settings.endpoint) {
          settings.providerDiscoveryInputDidChange()
        }
        HStack {
          TextField("Model", text: $settings.model, prompt: Text("model-name"))
            .accessibilityIdentifier("pensieve.provider.model")
          Button {
            Task { await settings.discoverModels() }
          } label: {
            if settings.isDiscoveringModels {
              ProgressView()
                .controlSize(.small)
            } else {
              Label("Discover", systemImage: "arrow.clockwise")
            }
          }
          .disabled(settings.isDiscoveringModels || settings.endpoint.isEmpty)
          .accessibilityIdentifier("pensieve.provider.discoverModels")
        }
        if !settings.discoveredModels.isEmpty {
          Picker("Available models", selection: $settings.model) {
            Text("Choose a model…").tag("")
            ForEach(settings.discoveredModels) { model in
              Text(model.displayName).tag(model.id)
            }
          }
          .accessibilityIdentifier("pensieve.provider.discoveredModel")
        }
        SecureField("API Key", text: $settings.apiKey, prompt: Text("Optional for local providers"))
          .accessibilityIdentifier("pensieve.provider.apiKey")
          .onChange(of: settings.apiKey) {
            settings.providerDiscoveryInputDidChange()
          }
        Button("Forget Saved API Key", role: .destructive) {
          try? settings.forgetSavedAPIKey()
        }
        .accessibilityIdentifier("pensieve.provider.forgetAPIKey")
      }
      .formStyle(.grouped)

      VStack(alignment: .leading, spacing: 5) {
        Label("Your API key is stored only in the macOS Keychain.", systemImage: "key.fill")
        Text("Changes take effect immediately — no restart needed.")
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      if let discoveryStatus = settings.modelDiscoveryStatus {
        Label(discoveryStatus, systemImage: "network")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("pensieve.provider.discoveryStatus")
      }

      if let error = settings.lastError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityIdentifier("pensieve.provider.error")
      } else if let status = settings.saveStatus {
        Label(status, systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
          .accessibilityIdentifier("pensieve.provider.saved")
      } else if settings.usesInheritedEnvironmentAtLaunch {
        Label("A provider is already set up by your environment.", systemImage: "terminal")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Spacer()
        Button("Save") {
          try? settings.save()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!settings.isDraftValid)
        .accessibilityIdentifier("pensieve.provider.save")
      }
    }
    .padding(24)
    .frame(width: 560, height: 540, alignment: .topLeading)
    .accessibilityIdentifier("pensieve.provider.settings")
  }
}

@MainActor
struct ProviderOnboardingSettingsLane {
  var showSettings: (PensieveSettingsSection) -> PensieveSettingsPresentationResult = { section in
    PensieveSettingsWindowController.shared.show(section: section)
  }

  @discardableResult
  func configure() -> PensieveSettingsPresentationResult {
    showSettings(.ai)
  }
}

/// One-shot handoff from the document-owned onboarding sheet to the
/// application-owned Settings window.
///
/// SwiftUI's `onDisappear` and sheet `onDismiss` callbacks describe the view
/// hierarchy, not AppKit's native sheet relationship. Ordering Settings from
/// either callback can therefore overlap two independent `NSWindow`
/// lifecycles. Capture the actual host/sheet pair while Configure is pressed,
/// then wait until both native relationship edges are gone before ordering the
/// auxiliary window. `didEndSheet` is useful trace evidence, but AppKit can
/// update the relationship graph before that notification is delivered; the
/// detached graph is the actual ownership boundary.
@MainActor
final class ProviderOnboardingSettingsTransition: ObservableObject {
  enum Failure: Equatable {
    case sheetDidNotDetach

    var userMessage: String {
      switch self {
      case .sheetDidNotDetach:
        return
          "Settings could not open because the setup sheet did not finish closing. "
          + "Close the setup sheet, then choose Pensieve > Settings."
      }
    }
  }

  private let notificationCenter: NotificationCenter
  private let attachedSheetProvider: @MainActor (NSWindow) -> NSWindow?
  private let isDetachedProvider: @MainActor (NSWindow, NSWindow) -> Bool
  private let nowProvider: @MainActor () -> TimeInterval
  private let scheduleAfter:
    @MainActor (
      _ delay: TimeInterval,
      _ operation: @escaping @MainActor () -> Void
    ) -> Void
  private let retryInterval: TimeInterval
  private let timeout: TimeInterval
  // The captured native pair is deliberately retained until success, failure,
  // replacement, or explicit cancellation. AppKit may release either side
  // while completing sheet teardown; weak references would turn that normal
  // delay into a silent loss of the already-dismissed Configure action.
  private var hostWindow: NSWindow?
  private var sheetWindow: NSWindow?
  private var observer: NSObjectProtocol?
  private var completion: (@MainActor () -> Void)?
  private var failure: (@MainActor (Failure) -> Void)?
  private var didObserveEndForCapturedPair = false
  private var deadline: TimeInterval?
  private var hasScheduledCheck = false
  private var generation: UInt = 0

  init(
    notificationCenter: NotificationCenter = .default,
    attachedSheetProvider: @escaping @MainActor (NSWindow) -> NSWindow? = {
      $0.attachedSheet
    },
    isDetachedProvider: @escaping @MainActor (NSWindow, NSWindow) -> Bool = {
      hostWindow, sheetWindow in
      hostWindow.attachedSheet == nil && sheetWindow.sheetParent == nil
    },
    nowProvider: @escaping @MainActor () -> TimeInterval = {
      ProcessInfo.processInfo.systemUptime
    },
    scheduleAfter:
      @escaping @MainActor (
        _ delay: TimeInterval,
        _ operation: @escaping @MainActor () -> Void
      ) -> Void = { delay, operation in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
          MainActor.assumeIsolated {
            operation()
          }
        }
      },
    retryInterval: TimeInterval = 0.05,
    timeout: TimeInterval = 1
  ) {
    precondition(retryInterval > 0)
    precondition(timeout > 0)
    self.notificationCenter = notificationCenter
    self.attachedSheetProvider = attachedSheetProvider
    self.isDetachedProvider = isDetachedProvider
    self.nowProvider = nowProvider
    self.scheduleAfter = scheduleAfter
    self.retryInterval = retryInterval
    self.timeout = timeout
  }

  deinit {
    if let observer {
      notificationCenter.removeObserver(observer)
    }
  }

  @discardableResult
  func arm(
    hostWindow: NSWindow?,
    onFailure: @escaping @MainActor (Failure) -> Void,
    completion: @escaping @MainActor () -> Void
  ) -> Bool {
    guard let hostWindow, let sheetWindow = attachedSheetProvider(hostWindow) else {
      DebugTrace.log("provider-onboarding.settings-transition.refused-no-sheet")
      return false
    }

    cancel()
    let armedGeneration = generation
    self.hostWindow = hostWindow
    self.sheetWindow = sheetWindow
    self.completion = completion
    failure = onFailure
    deadline = nowProvider() + timeout
    DebugTrace.logWindowMutation(
      "provider-onboarding.settings-transition.armed",
      owner: hostWindow,
      member: sheetWindow)

    observer = notificationCenter.addObserver(
      forName: NSWindow.didEndSheetNotification,
      object: hostWindow,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.generation == armedGeneration else {
          return
        }
        self.didObserveEndForCapturedPair = true
        // Notification delivery can precede AppKit's final relationship
        // bookkeeping. The already-scheduled bounded poll will inspect it
        // after a real delay instead of spinning through immediate queue hops.
      }
    }
    scheduleNextCheck(generation: armedGeneration)
    return true
  }

  func cancel() {
    generation &+= 1
    if let observer {
      notificationCenter.removeObserver(observer)
    }
    observer = nil
    hostWindow = nil
    sheetWindow = nil
    completion = nil
    failure = nil
    didObserveEndForCapturedPair = false
    deadline = nil
    hasScheduledCheck = false
  }

  private func scheduleNextCheck(generation: UInt) {
    guard generation == self.generation, !hasScheduledCheck else { return }
    hasScheduledCheck = true
    scheduleAfter(retryInterval) { [weak self] in
      guard let self, generation == self.generation else { return }
      self.hasScheduledCheck = false
      self.finishIfDetached(generation: generation)
    }
  }

  private func finishIfDetached(generation: UInt) {
    guard generation == self.generation else { return }
    guard let hostWindow, let sheetWindow, let deadline else {
      fail(.sheetDidNotDetach)
      return
    }

    if isDetachedProvider(hostWindow, sheetWindow) {
      if didObserveEndForCapturedPair {
        DebugTrace.logWindowEvent(
          "provider-onboarding.settings-transition.sheet-ended",
          window: hostWindow)
      } else {
        // Native ownership is the safety boundary. AppKit's relationship graph
        // can be fully detached before SwiftUI/AppKit delivers the matching
        // didEndSheet notification; do not lose an accepted Configure action
        // merely because the advisory notification arrived late or not at all.
        DebugTrace.logWindowEvent(
          "provider-onboarding.settings-transition.detached-without-notification",
          window: hostWindow)
      }
      let completion = self.completion
      cancel()
      completion?()
      return
    }

    guard nowProvider() < deadline else {
      DebugTrace.logWindowMutation(
        "provider-onboarding.settings-transition.detach-timeout",
        owner: hostWindow,
        member: sheetWindow)
      fail(.sheetDidNotDetach)
      return
    }

    scheduleNextCheck(generation: generation)
  }

  private func fail(_ reason: Failure) {
    let failure = self.failure
    cancel()
    failure?(reason)
  }
}

struct ProviderOnboardingView: View {
  @Binding var isPresented: Bool
  let hostWindow: NSWindow?
  let settingsTransition: ProviderOnboardingSettingsTransition
  var settingsLane = ProviderOnboardingSettingsLane()
  var onSettingsTransitionFailure:
    @MainActor (ProviderOnboardingSettingsTransition.Failure) -> Void = { _ in }
  var onSettingsPresentationFailure:
    @MainActor (PensieveSettingsPresentationResult) -> Void = { _ in }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 12) {
        Image(systemName: "sparkles")
          .font(.system(size: 28, weight: .medium))
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 3) {
          Text("Set Up AI Autocomplete")
            .font(.headline)
          Text("Add a completion provider once, then keep writing.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }

      Text(
        "Connect an AI provider and Pensieve will suggest the next phrase as you type. "
          + "All you need is your provider's address and a model name — "
          + "your API key stays in the macOS Keychain."
      )
      .font(.callout)
      .fixedSize(horizontal: false, vertical: true)

      Divider()

      HStack {
        Spacer()
        Button("Not Now") {
          isPresented = false
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("pensieve.provider.onboarding.notNow")
        Button("Configure…") {
          beginConfiguration()
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("pensieve.provider.onboarding.configure")
      }
    }
    .padding(20)
    .frame(width: 390)
    .accessibilityIdentifier("pensieve.provider.onboarding")
  }

  /// Begins native sheet teardown only after the Settings handoff owns the
  /// exact host/sheet pair. Failure to arm leaves onboarding visible. A later
  /// native teardown timeout reports through the document's non-modal error
  /// surface and never asks SwiftUI to attach another sheet over the unresolved
  /// pair.
  @discardableResult
  func beginConfiguration() -> Bool {
    let didArm = settingsTransition.arm(
      hostWindow: hostWindow,
      onFailure: { failure in
        // A timeout means native sheet ownership did not settle. Never ask
        // SwiftUI to attach another onboarding sheet on top of that unresolved
        // pair. The document host reports the failure through its ordinary,
        // non-modal error surface instead.
        onSettingsTransitionFailure(failure)
      },
      completion: {
        let result = settingsLane.configure()
        if result != .presented {
          // The onboarding sheet has already detached, so its originating
          // document is now the only reliable visible surface for a block by
          // another modal. Do not let the Settings controller's app-global
          // routing become the sole report for this explicit handoff.
          onSettingsPresentationFailure(result)
        }
      })
    if didArm {
      isPresented = false
    }
    return didArm
  }
}
