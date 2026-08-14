import SwiftUI

/// The Settings window. It used to be the AI provider form alone; auto-save is a
/// document-lifecycle preference rather than a provider one, so the window gained
/// tabs instead of growing a second, unrelated section under an "AI Autocomplete"
/// heading. Both tabs keep the provider form's fixed metrics so switching between
/// them does not resize the window.
struct PensieveSettingsView: View {
  let providerSettings: ProviderSettings
  let savingSettings: DocumentSavingSettings
  let launchSettings: LaunchSettings
  @ObservedObject var selection: PensieveSettingsSelection

  var body: some View {
    ZStack(alignment: .bottom) {
      TabView(selection: $selection.selectedSection) {
        GeneralSettingsView(settings: savingSettings, launchSettings: launchSettings)
          .tabItem {
            Label("General", systemImage: "gearshape")
          }
          .tag(PensieveSettingsSection.general)
        ProviderSettingsView(settings: providerSettings)
          .tabItem {
            Label("AI", systemImage: "sparkles")
          }
          .tag(PensieveSettingsSection.ai)
      }

      if let message = selection.presentationError {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
          Text(message)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          Button {
            selection.dismissPresentationError()
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(14)
        .accessibilityIdentifier("pensieve.settings.presentationError")
      }
    }
    .accessibilityIdentifier("pensieve.settings")
  }
}

/// Document-lifecycle and startup preferences: who owns writing an edit to a
/// file that already exists — Pensieve, or the user's explicit Save — and
/// whether a cold launch brings the previous session back.
struct GeneralSettingsView: View {
  @Bindable var settings: DocumentSavingSettings
  @Bindable var launchSettings: LaunchSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Saving")
          .font(.title2.weight(.semibold))
        Text("Who writes your edits to disk — Pensieve, or you.")
          .foregroundStyle(.secondary)
      }

      Form {
        Toggle(
          "Automatically save changes to files that already have a location",
          isOn: $settings.autoSavesPathedDocuments
        )
        .accessibilityIdentifier("pensieve.saving.autoSave")
      }
      .formStyle(.grouped)

      VStack(alignment: .leading, spacing: 5) {
        Text(
          "On, closing such a file saves it and closes. Off, Pensieve asks "
            + "Save / Don't Save / Cancel before anything is lost."
        )
        Text(
          "An untouched empty draft closes silently. Once edited, a new draft always asks "
            + "where to save it."
        )
        Text(
          "Crash recovery protects edited drafts and unsaved changes to existing files in "
            + "either mode. It never overwrites an original automatically."
        )
        Text("Changes take effect immediately — no restart needed.")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 6) {
        Text("Startup")
          .font(.title2.weight(.semibold))
        Text("What a cold launch brings back.")
          .foregroundStyle(.secondary)
      }

      Form {
        Toggle(
          "Restore session on launch",
          isOn: $launchSettings.restoreSessionOnLaunch
        )
        .accessibilityIdentifier("pensieve.startup.restoreSessionOnLaunch")
      }
      .formStyle(.grouped)

      VStack(alignment: .leading, spacing: 5) {
        Text(
          "When off, Pensieve opens one empty launcher and no documents. "
            + "When on, Pensieve alone restores the saved working set."
        )
        Text(
          "Your workspace comes back either way: the folders you work in are "
            + "always-alive configuration, not session."
        )
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(width: 560, height: 540, alignment: .topLeading)
    .accessibilityIdentifier("pensieve.saving.settings")
  }
}
