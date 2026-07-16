import SwiftUI

struct ProviderOnboardingState: Equatable {
  private(set) var isPresented = false

  mutating func evaluate(autocompleteEnabled: Bool, providerConfigured: Bool) {
    isPresented = autocompleteEnabled && !providerConfigured
  }

  mutating func dismiss() {
    isPresented = false
  }
}

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
        TextField(
          "Endpoint", text: $settings.endpoint, prompt: Text(settings.providerShape.endpointPrompt)
        )
        .textContentType(.URL)
        .accessibilityIdentifier("pensieve.provider.endpoint")
        TextField("Model", text: $settings.model, prompt: Text("model-name"))
          .accessibilityIdentifier("pensieve.provider.model")
        SecureField("API Key", text: $settings.apiKey, prompt: Text("Optional for local providers"))
          .accessibilityIdentifier("pensieve.provider.apiKey")
      }
      .formStyle(.grouped)

      VStack(alignment: .leading, spacing: 5) {
        Label("Your API key is stored only in the macOS Keychain.", systemImage: "key.fill")
        Text("Changes take effect immediately — no restart needed.")
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      if let unsupportedMessage = settings.providerShape.unsupportedMessage {
        Label(unsupportedMessage, systemImage: "hand.raised.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("pensieve.provider.unsupportedShape")
      } else if let error = settings.lastError {
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
        Label("A provider is already set up by your development environment.", systemImage: "terminal")
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
    .frame(width: 560, height: 470, alignment: .topLeading)
    .accessibilityIdentifier("pensieve.provider.settings")
  }
}

struct ProviderOnboardingView: View {
  @Environment(\.openSettings) private var openSettings
  @Binding var isPresented: Bool

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
          isPresented = false
          openSettings()
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("pensieve.provider.onboarding.configure")
      }
    }
    .padding(20)
    .frame(width: 390)
    .accessibilityIdentifier("pensieve.provider.onboarding")
  }
}
