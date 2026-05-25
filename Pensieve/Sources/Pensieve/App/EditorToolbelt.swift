import SwiftUI

/// Window toolbar contents for the main editor scene.
///
/// Re-creates the chrome density of the legacy MarkdownEditor: a mode/syntax
/// picker on the leading side, a Markdown format strip in the middle, and the
/// preview style/refresh/auto-reload controls trailing. Built as
/// `ToolbarContent` so `ContentView` can mount it via `.toolbar { … }` and
/// SwiftUI lays the items into the native unified window toolbar.
///
/// All controls bind into `AppState` / `AppController` / `ThemeManager`, which
/// is owned by `PensieveApp` and shared as an `EnvironmentObject` so the
/// toolbar's theme picker and `PreviewView` see the same selection.
struct EditorToolbelt: ToolbarContent {
  @ObservedObject var appState: AppState
  @ObservedObject var controller: AppController
  @ObservedObject var themeManager: ThemeManager

  private var hasDocument: Bool {
    appState.documentSession.document != nil
  }

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      modePicker
      richMarkdownToggle
    }

    ToolbarItemGroup(placement: .principal) {
      if hasDocument {
        formatStrip
      }
    }

    ToolbarItemGroup(placement: .primaryAction) {
      previewThemePicker
      Button(action: { appState.requestPreviewRefresh() }) {
        Image(systemName: "arrow.clockwise")
      }
      .help("Reload Preview")
      .disabled(!hasDocument)

      Toggle(isOn: $appState.previewAutoReload) {
        Image(systemName: "arrow.triangle.2.circlepath")
      }
      .toggleStyle(.button)
      .help(
        appState.previewAutoReload
          ? "Auto reload on — preview re-renders as you type"
          : "Auto reload off — use the reload button to refresh")
    }
  }

  // MARK: - Subgroups

  private var modePicker: some View {
    Picker(
      "Mode",
      selection: Binding(
        get: { appState.mode },
        set: { controller.setMode($0) }
      )
    ) {
      ForEach(EditorMode.allCases) { mode in
        Label(mode.label, systemImage: mode.systemImage)
          .labelStyle(.iconOnly)
          .tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .help("Editor layout")
    .frame(minWidth: 140)
  }

  private var richMarkdownToggle: some View {
    Button(action: { controller.toggleRichMarkdown() }) {
      Image(
        systemName: appState.richMarkdownEnabled
          ? "textformat.alt"
          : "textformat")
    }
    .help(
      appState.richMarkdownEnabled
        ? "Rich Markdown on (⌘/)"
        : "Plain syntax (⌘/)")
  }

  private var previewThemePicker: some View {
    Picker("Preview Style", selection: $themeManager.current) {
      ForEach(ThemeManager.Theme.allCases) { theme in
        Text(theme.displayName).tag(theme)
      }
    }
    .pickerStyle(.menu)
    .help("Preview stylesheet")
    .frame(minWidth: 140)
  }

  @ViewBuilder
  private var formatStrip: some View {
    ForEach(MarkdownFormat.allCases) { format in
      Button(action: { controller.applyMarkdownFormat(format) }) {
        Image(systemName: format.systemImageName)
      }
      .help(format.label)

      if format == .strike || format == .quote || format == .numberedList {
        Divider()
      }
    }
  }
}

extension EditorMode {
  fileprivate var systemImage: String {
    switch self {
    case .source: return "doc.plaintext"
    case .split: return "rectangle.split.2x1"
    case .preview: return "eye"
    case .focus: return "scope"
    }
  }
}
