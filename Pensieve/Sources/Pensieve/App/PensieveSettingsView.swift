import SwiftUI

/// The Settings window. It used to be the AI provider form alone; auto-save is a
/// document-lifecycle preference rather than a provider one, so the window gained
/// tabs instead of growing a second, unrelated section under an "AI Autocomplete"
/// heading. Both tabs keep the provider form's fixed metrics so switching between
/// them does not resize the window.
struct PensieveSettingsView: View {
  let providerSettings: ProviderSettings
  let savingSettings: DocumentSavingSettings

  var body: some View {
    TabView {
      GeneralSettingsView(settings: savingSettings)
        .tabItem {
          Label("General", systemImage: "gearshape")
        }
      ProviderSettingsView(settings: providerSettings)
        .tabItem {
          Label("AI", systemImage: "sparkles")
        }
    }
    .accessibilityIdentifier("pensieve.settings")
  }
}

/// Document-lifecycle preferences. One toggle today: who owns writing an edit to
/// a file that already exists — Pensieve, or the user's explicit Save.
struct GeneralSettingsView: View {
  @Bindable var settings: DocumentSavingSettings

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
        Text("A new draft has no location yet, so closing one always asks where to save it.")
        Text("Recovered drafts protect unsaved work after a crash either way.")
        Text("Changes take effect immediately — no restart needed.")
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
