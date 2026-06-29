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
  // AppState is @Observable: a plain `var` is observed when its properties are
  // read in this toolbar body. controller/themeManager stay ObservableObject.
  var appState: AppState
  @ObservedObject var controller: AppController
  @ObservedObject var themeManager: ThemeManager

  private var hasDocument: Bool {
    appState.documentSession.document != nil
  }

  /// The format strip and editor-facing controls light up for ANY editable buffer —
  /// untitled scratch notes included — not only file-backed documents. Gating them on
  /// `document != nil` made the whole edit toolbar vanish while editing an untitled note.
  /// Reads the discrete `documentHasEditableBuffer` mirror, not `documentSession`,
  /// so typing (a text-only change) never re-evaluates the toolbar.
  private var hasEditableBuffer: Bool {
    appState.documentHasEditableBuffer
  }

  private var transcriptionTaflaSystemImage: String {
    controller.isTranscriptionTaflaVisible ? "waveform.circle.fill" : "waveform.circle"
  }

  private var transcriptionTaflaHelp: String {
    controller.isTranscriptionTaflaVisible
      ? "Hide Transcription Tafla"
      : "Show Transcription Tafla"
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
      Button(action: { controller.toggleTranscriptionTafla() }) {
        Image(systemName: transcriptionTaflaSystemImage)
      }
      .help(transcriptionTaflaHelp)
      .accessibilityIdentifier("pensieve.toolbar.taflaToggle")

      Button(action: { DocumentSharing.share(session: appState.documentSession) }) {
        Image(systemName: "square.and.arrow.up")
      }
      .help("Share")
      .disabled(!hasEditableBuffer)
      .accessibilityIdentifier("pensieve.toolbar.share")

      previewThemePicker
      previewSkinPicker
      Button(action: { appState.requestPreviewRefresh() }) {
        Image(systemName: "arrow.clockwise")
      }
      .help("Reload Preview")
      .disabled(!hasEditableBuffer)
      .accessibilityIdentifier("pensieve.toolbar.reload")

      Toggle(
        isOn: Binding(
          get: { appState.previewAutoReload },
          set: { appState.previewAutoReload = $0 }
        )
      ) {
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
    Picker("Flavor", selection: $themeManager.current) {
      ForEach(ThemeManager.Theme.allCases) { theme in
        Text(theme.displayName).tag(theme)
      }
    }
    .pickerStyle(.menu)
    .help("Markdown flavor — plain Markdown or GitHub Flavored")
    .frame(minWidth: 140)
    .accessibilityIdentifier("pensieve.toolbar.themePicker")
  }

  /// Reading-surface skin picker. Orthogonal to the flavor: it re-skins the
  /// rendered surface — paper-like, code-like, stripped, or a document theme —
  /// without changing the markdown dialect. Authorial skins (Default, Document,
  /// Code, Raw, Vista, MLA, Jamstatic) plus open-licensed ports (Notion, Vercel,
  /// Themeable, Glass — see THIRD_PARTY_THEMES.md).
  private var previewSkinPicker: some View {
    Picker("Theme", selection: $themeManager.skin) {
      ForEach(ThemeManager.PreviewTheme.allCases) { skin in
        Label(skin.displayName, systemImage: skin.systemImage).tag(skin)
      }
    }
    .pickerStyle(.menu)
    .help("Preview theme — the reading surface for the rendered markdown")
    .frame(minWidth: 120)
    .accessibilityIdentifier("pensieve.toolbar.skinPicker")
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
