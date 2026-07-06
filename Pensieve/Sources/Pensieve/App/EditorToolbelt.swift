import SwiftUI

/// Window toolbar contents for the main editor scene.
///
/// Declutter contract (Cut 5-1R): the titlebar carries the navigation cluster
/// (mode picker), one summary `Aa` Edit menu in the principal slot, and a
/// reduced trailing side of daily drivers — share, preview appearance, reload
/// (plus the dispatch item mounted by `ContentView`). Everything else
/// (transcription tafla, scroll sync, auto reload) lives in a single overflow
/// menu. No raw format buttons sit in the bar; the edit actions surface via
/// the `Aa` menu, the floating selection bar, and the Format app menu.
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

  /// The edit menu and editor-facing controls light up for ANY editable buffer —
  /// untitled scratch notes included — not only file-backed documents. Gating them on
  /// `document != nil` made the whole edit toolbar vanish while editing an untitled note.
  /// Reads the discrete `documentHasEditableBuffer` mirror, not `documentSession`,
  /// so typing (a text-only change) never re-evaluates the toolbar.
  private var hasEditableBuffer: Bool {
    appState.documentHasEditableBuffer
  }

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      modePicker
    }

    ToolbarItemGroup(placement: .principal) {
      if hasEditableBuffer {
        editMenu
      }
    }

    ToolbarItemGroup(placement: .primaryAction) {
      Button(action: { DocumentSharing.share(session: appState.documentSession) }) {
        Image(systemName: "square.and.arrow.up")
      }
      .help("Share")
      .disabled(!hasEditableBuffer)
      .accessibilityLabel("Share Document")
      .accessibilityIdentifier("pensieve.toolbar.share")

      if Self.showsAppearanceControls(for: appState.mode) {
        AppearanceToolbarButton(themeManager: themeManager)
      }

      Button(action: { appState.requestPreviewRefresh() }) {
        Image(systemName: "arrow.clockwise")
      }
      .help("Reload Preview")
      .disabled(!hasEditableBuffer)
      .accessibilityLabel("Reload Preview")
      .accessibilityIdentifier("pensieve.toolbar.reload")

      overflowMenu
    }
  }

  /// Appearance controls describe only the rendered preview surface, so they
  /// earn toolbar space only while a preview pane is actually on screen.
  /// `.split` counts even when a narrow window collapses it to one pane —
  /// the mode, not the momentary geometry, is the source of truth.
  static func showsAppearanceControls(for mode: EditorMode) -> Bool {
    mode == .preview || mode == .split
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

  /// The ONE summary Edit menu behind the `Aa` glyph. Its action list is not a
  /// second source of truth: it iterates `MarkdownFormat.allCases` in
  /// declaration order — exactly the list the floating selection bar and the
  /// editor context menu render — so the surfaces can never drift apart.
  /// The rich-markdown toggle rides along at the bottom: it is an
  /// editor-buffer property, formerly the misleading bare `Aa` button.
  private var editMenu: some View {
    Menu {
      ForEach(MarkdownFormat.allCases) { format in
        Button(action: { controller.applyMarkdownFormat(format) }) {
          Label(format.label, systemImage: format.systemImageName)
        }
        .accessibilityIdentifier(format.toolbarAccessibilityIdentifier)
      }

      Divider()

      Toggle(
        isOn: Binding(
          get: { appState.richMarkdownEnabled },
          set: { _ in controller.toggleRichMarkdown() }
        )
      ) {
        Label("Rich Markdown (⌘/)", systemImage: "textformat.alt")
      }
      .accessibilityIdentifier("pensieve.toolbar.richMarkdownToggle")
    } label: {
      Image(systemName: "textformat")
    }
    .help("Edit — Markdown formatting for the selection, plus Rich Markdown")
    .accessibilityLabel("Markdown Formatting")
    .accessibilityIdentifier("pensieve.toolbar.editMenu")
  }

  /// Single overflow for the non-daily controls the trailing side used to
  /// carry raw: transcription tafla, scroll sync, auto reload. They are
  /// set-and-forget toggles, so one `ellipsis.circle` menu holds them all;
  /// share/appearance/reload/dispatch stay visible as the daily drivers.
  private var overflowMenu: some View {
    Menu {
      Toggle(
        isOn: Binding(
          get: { controller.isTranscriptionTaflaVisible },
          set: { _ in controller.toggleTranscriptionTafla() }
        )
      ) {
        Label("Transcription Tafla", systemImage: "waveform.circle")
      }
      .accessibilityIdentifier("pensieve.toolbar.taflaToggle")

      Divider()

      Toggle(
        isOn: Binding(
          get: { appState.scrollSyncEnabled },
          set: { appState.scrollSyncEnabled = $0 }
        )
      ) {
        Label("Scroll Sync", systemImage: "arrow.up.and.down")
      }
      .disabled(!hasEditableBuffer)
      .accessibilityIdentifier("pensieve.toolbar.scrollSync")

      Toggle(
        isOn: Binding(
          get: { appState.previewAutoReload },
          set: { appState.previewAutoReload = $0 }
        )
      ) {
        Label("Auto Reload Preview", systemImage: "arrow.triangle.2.circlepath")
      }
      .accessibilityIdentifier("pensieve.toolbar.autoReload")
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .help("More — transcription tafla, scroll sync, auto reload")
    .accessibilityLabel("More Controls")
    .accessibilityIdentifier("pensieve.toolbar.overflow")
  }
}

/// Compact replacement for the two wide preview pickers that used to dominate
/// the titlebar: one monochrome toolbar button opening a popover that hosts
/// both appearance axes. A plain `View` (not `ToolbarContent`) so it can own
/// the `@State` driving the popover presentation.
private struct AppearanceToolbarButton: View {
  @ObservedObject var themeManager: ThemeManager
  @State private var isPopoverPresented = false

  var body: some View {
    Button(action: { isPopoverPresented.toggle() }) {
      Image(systemName: "paintpalette")
    }
    .help("Preview appearance — markdown flavor and reading theme")
    .accessibilityLabel("Preview Appearance")
    .accessibilityIdentifier("pensieve.toolbar.appearance")
    .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
      AppearancePopoverContent(themeManager: themeManager)
    }
  }
}

/// Popover body hosting the flavor and skin pickers. Same `Picker` views as the
/// old toolbar items — both auto-populate from `CaseIterable` and keep their
/// accessibility identifiers, so switching either axis drives `ThemeManager`
/// (and the live preview) exactly as before.
private struct AppearancePopoverContent: View {
  @ObservedObject var themeManager: ThemeManager

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("Flavor", selection: $themeManager.current) {
        ForEach(ThemeManager.Theme.allCases) { theme in
          Text(theme.displayName).tag(theme)
        }
      }
      .pickerStyle(.menu)
      .help("Markdown flavor — plain Markdown or GitHub Flavored")
      .accessibilityIdentifier("pensieve.toolbar.themePicker")

      // Reading-surface skin, orthogonal to the flavor: it re-skins the
      // rendered surface — paper-like, code-like, stripped, or a document
      // theme — without changing the markdown dialect. Authorial skins
      // (Default, Document, Code, Raw, Vista, MLA, Jamstatic) plus
      // open-licensed ports (Notion, Vercel, Themeable, Glass — see
      // THIRD_PARTY_THEMES.md).
      Picker("Theme", selection: $themeManager.skin) {
        ForEach(ThemeManager.PreviewTheme.allCases) { skin in
          Label(skin.displayName, systemImage: skin.systemImage).tag(skin)
        }
      }
      .pickerStyle(.menu)
      .help("Preview theme — the reading surface for the rendered markdown")
      .accessibilityIdentifier("pensieve.toolbar.skinPicker")
    }
    .padding(14)
    .frame(width: 280)
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
