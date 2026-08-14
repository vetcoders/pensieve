import SwiftUI

/// The Settings window. It used to be the AI provider form alone; auto-save is a
/// document-lifecycle preference rather than a provider one, so the window gained
/// tabs instead of growing a second, unrelated section under an "AI Autocomplete"
/// heading. Appearance joined them when the titlebar's appearance menu was
/// removed and its axes needed a home reachable from a window with no document
/// in it. Every tab keeps the provider form's fixed metrics so switching between
/// them does not resize the window.
struct PensieveSettingsView: View {
  let providerSettings: ProviderSettings
  let savingSettings: DocumentSavingSettings
  let launchSettings: LaunchSettings
  @ObservedObject var themeManager: ThemeManager
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
        AppearanceSettingsView(themeManager: themeManager)
          .tabItem {
            Label("Appearance", systemImage: "paintpalette")
          }
          .tag(PensieveSettingsSection.appearance)
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

/// The two appearance axes, in the one place that is reachable with ⌘, from
/// every window — including a launcher, which has no status bar and therefore
/// no chip.
///
/// A deliberate MIRROR of the status-bar chip and nothing else (operator
/// decision, 14.08.2026): the same two pickers bound to the same
/// `ThemeManager`, so neither surface can drift from the other or need
/// reconciling. The chip remains the primary home. Previews, swatches and
/// per-axis explanation are explicitly deferred, so anything richer than these
/// two rows belongs to a later cut, not to this pane.
struct AppearanceSettingsView: View {
  /// The AX contract this pane publishes, named once — `pensieve.settings.*`
  /// rather than the chip's `pensieve.statusbar.*`, because the two surfaces are
  /// looked up independently even though they write the same state.
  static let paneIdentifier = "pensieve.settings.appearance"
  static let skinPickerIdentifier = "pensieve.settings.appearance.skinPicker"
  static let flavorPickerIdentifier = "pensieve.settings.appearance.flavorPicker"

  @ObservedObject var themeManager: ThemeManager

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Appearance")
          .font(.title2.weight(.semibold))
        Text("How Pensieve reads — the same two axes as the status bar's chip.")
          .foregroundStyle(.secondary)
      }

      Form {
        // Skin first, matching the order the chip's own label states them in
        // ("Theme / Flavor"), so the two surfaces read the same way round.
        Picker("Theme", selection: $themeManager.skin) {
          ForEach(PensieveTheme.allCases) { skin in
            Label(skin.displayName, systemImage: skin.systemImage).tag(skin)
          }
        }
        .pickerStyle(.menu)
        .help("Preview theme — the reading surface for the rendered markdown")
        .accessibilityIdentifier(Self.skinPickerIdentifier)

        Picker("Flavor", selection: $themeManager.current) {
          ForEach(ThemeManager.Theme.allCases) { theme in
            Text(theme.displayName).tag(theme)
          }
        }
        .pickerStyle(.menu)
        .help("Markdown flavor — plain Markdown or GitHub Flavored")
        .accessibilityIdentifier(Self.flavorPickerIdentifier)
      }
      .formStyle(.grouped)

      Text("Changes apply immediately, to every open window.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Spacer(minLength: 0)
    }
    .padding(24)
    .frame(width: 560, height: 540, alignment: .topLeading)
    .accessibilityIdentifier(Self.paneIdentifier)
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
