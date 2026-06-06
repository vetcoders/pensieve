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

  /// The format strip and editor-facing controls light up for ANY editable buffer —
  /// untitled scratch notes included — not only file-backed documents. Gating them on
  /// `document != nil` made the whole edit toolbar vanish while editing an untitled note.
  private var hasEditableBuffer: Bool {
    appState.documentSession.hasEditableBuffer
  }

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      modePicker
      richMarkdownToggle
    }

    ToolbarItemGroup(placement: .principal) {
      if hasEditableBuffer {
        formatStrip
      }
    }

    ToolbarItemGroup(placement: .primaryAction) {
      Button(action: { DocumentSharing.share(session: appState.documentSession) }) {
        Image(systemName: "square.and.arrow.up")
      }
      .help("Share")
      .disabled(!hasEditableBuffer)
      .accessibilityIdentifier("pensieve.toolbar.share")

      previewThemePicker
      Button(action: { appState.requestPreviewRefresh() }) {
        Image(systemName: "arrow.clockwise")
      }
      .help("Reload Preview")
      .disabled(!hasEditableBuffer)
      .accessibilityIdentifier("pensieve.toolbar.reload")

      Toggle(isOn: $appState.previewAutoReload) {
        Image(systemName: "arrow.triangle.2.circlepath")
      }
      .toggleStyle(.button)
      .help(
        appState.previewAutoReload
          ? "Auto reload on — preview re-renders as you type"
          : "Auto reload off — use the reload button to refresh"
      )
      .accessibilityIdentifier("pensieve.toolbar.autoReload")
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
    .accessibilityIdentifier("pensieve.toolbar.modePicker")
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
        : "Plain syntax (⌘/)"
    )
    .accessibilityIdentifier("pensieve.toolbar.richMarkdownToggle")
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
    .accessibilityIdentifier("pensieve.toolbar.themePicker")
  }

  @ViewBuilder
  private var formatStrip: some View {
    ForEach(MarkdownFormat.allCases) { format in
      Button(action: { controller.applyMarkdownFormat(format) }) {
        Image(systemName: format.systemImageName)
      }
      .help(format.label)
      .accessibilityIdentifier(format.toolbarAccessibilityIdentifier)

      if format == .strike || format == .quote || format == .numberedList {
        Divider()
      }
    }
  }
}

extension MarkdownFormat {
  fileprivate var toolbarAccessibilityIdentifier: String {
    switch self {
    case .bold: return "pensieve.toolbar.format.bold"
    case .italic: return "pensieve.toolbar.format.italic"
    case .strike: return "pensieve.toolbar.format.strike"
    case .quote: return "pensieve.toolbar.format.quote"
    case .code: return "pensieve.toolbar.format.code"
    case .link: return "pensieve.toolbar.format.link"
    case .bulletedList: return "pensieve.toolbar.format.bulletedList"
    case .numberedList: return "pensieve.toolbar.format.numberedList"
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
