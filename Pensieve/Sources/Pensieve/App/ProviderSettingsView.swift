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
        Text("Connect one OpenAI-compatible completion provider.")
          .foregroundStyle(.secondary)
      }

      Form {
        TextField("Endpoint", text: $settings.endpoint, prompt: Text("https://api.example.com/v1"))
          .textContentType(.URL)
          .accessibilityIdentifier("pensieve.provider.endpoint")
        TextField("Model", text: $settings.model, prompt: Text("model-name"))
          .accessibilityIdentifier("pensieve.provider.model")
        SecureField("API Key", text: $settings.apiKey, prompt: Text("Optional for local providers"))
          .accessibilityIdentifier("pensieve.provider.apiKey")
      }
      .formStyle(.grouped)

      VStack(alignment: .leading, spacing: 5) {
        Label("The API key is stored only in your macOS Keychain.", systemImage: "key.fill")
        Text(
          "Endpoint and model are saved as app preferences. Existing provider environment "
            + "variables win at launch; Save applies these fields to the running app immediately."
        )
      }
      .font(.caption)
      .foregroundStyle(.secondary)

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
        Label("Using provider environment inherited at launch.", systemImage: "terminal")
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
    .frame(width: 520, height: 410, alignment: .topLeading)
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
        "Pensieve needs an endpoint and model before it can suggest the next phrase. "
          + "API keys are optional for local providers and otherwise stay in Keychain."
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
