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
