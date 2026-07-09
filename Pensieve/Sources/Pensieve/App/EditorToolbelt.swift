import AppKit
import SwiftUI

/// Window toolbar contents for the main editor scene.
///
/// Titlebar contract (Cut 7-8): keep SwiftUI's native sidebar toggle first,
/// leave `.navigation` empty so the document title leads, then mount share and
/// dispatch as their own native island before the principal edit row.
/// Modes, preview appearance, reload, and overflow live on the
/// trailing side.
/// Everything else (transcription tafla, scroll sync, auto reload) lives in a
/// single overflow menu. Raw format buttons stay inline whenever the buffer is
/// editable, matching the floating selection bar and the Format app menu without
/// adding formatter logic.
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
  let onDispatchToAgent: () -> Void
  let isDispatchDisabled: Bool
  let dispatchHelp: String

  static let shareIdentifier = "pensieve.toolbar.share"
  static let dispatchIdentifier = "pensieve.toolbar.dispatchToAgent"
  static let modePickerIdentifier = "pensieve.toolbar.modePicker"
  static let appearanceIdentifier = "pensieve.toolbar.appearance"
  static let reloadIdentifier = "pensieve.toolbar.reload"
  static let overflowIdentifier = "pensieve.toolbar.overflow"
  static let richMarkdownToggleIdentifier = "pensieve.toolbar.richMarkdownToggle"

  enum ToolbarIslandIdentifier: String, Equatable {
    case shareDispatch
    case edit
    case trailing
  }

  /// The edit menu and editor-facing controls light up for ANY editable buffer —
  /// untitled scratch notes included — not only file-backed documents. Gating them on
  /// `document != nil` made the whole edit toolbar vanish while editing an untitled note.
  /// Reads the discrete `documentHasEditableBuffer` mirror, not `documentSession`,
  /// so typing (a text-only change) never re-evaluates the toolbar.
  private var hasEditableBuffer: Bool {
    appState.documentHasEditableBuffer
  }

  private var showsEditToolbelt: Bool {
    Self.showsEditToolbelt(for: appState.mode, hasEditableBuffer: hasEditableBuffer)
  }

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .automatic) {
      shareButton
      dispatchButton
    }

    if showsEditToolbelt {
      ToolbarItemGroup(placement: .principal) {
        richMarkdownToggle
        formatButtons
      }
    }

    ToolbarItemGroup {
      modePicker

      if Self.showsAppearanceControls(for: appState.mode) {
        AppearanceToolbarButton(themeManager: themeManager)
      }

      Button(action: { appState.requestPreviewRefresh() }) {
        Image(systemName: "arrow.clockwise")
      }
      .help("Reload Preview")
      .disabled(!hasEditableBuffer)
      .accessibilityLabel("Reload Preview")
      .accessibilityIdentifier(Self.reloadIdentifier)

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

  static func showsEditToolbelt(for mode: EditorMode, hasEditableBuffer: Bool) -> Bool {
    hasEditableBuffer && mode != .preview
  }

  static func visibleToolbarIdentifierOrder(
    for mode: EditorMode,
    hasEditableBuffer: Bool
  ) -> [String] {
    var identifiers = [
      shareIdentifier,
      dispatchIdentifier,
    ]

    if showsEditToolbelt(for: mode, hasEditableBuffer: hasEditableBuffer) {
      identifiers.append(richMarkdownToggleIdentifier)
      identifiers.append(contentsOf: MarkdownFormat.allCases.map(\.toolbarAccessibilityIdentifier))
    }

    identifiers.append(modePickerIdentifier)

    if showsAppearanceControls(for: mode) {
      identifiers.append(appearanceIdentifier)
    }

    identifiers.append(reloadIdentifier)
    identifiers.append(overflowIdentifier)
    return identifiers
  }

  static func visibleToolbarIslandOrder(
    for mode: EditorMode,
    hasEditableBuffer: Bool
  ) -> [ToolbarIslandIdentifier] {
    var islands: [ToolbarIslandIdentifier] = [.shareDispatch]

    if showsEditToolbelt(for: mode, hasEditableBuffer: hasEditableBuffer) {
      islands.append(.edit)
    }

    islands.append(.trailing)
    return islands
  }

  // MARK: - Subgroups

  private var shareButton: some View {
    Button(action: { DocumentSharing.share(session: appState.documentSession) }) {
      Image(systemName: "square.and.arrow.up")
    }
    .help("Share")
    .disabled(!hasEditableBuffer)
    .accessibilityLabel("Share Document")
    .accessibilityIdentifier(Self.shareIdentifier)
  }

  private var dispatchButton: some View {
    Button(action: onDispatchToAgent) {
      Label("Dispatch to Agent", systemImage: "paperplane")
    }
    .disabled(isDispatchDisabled)
    .help(dispatchHelp)
    .accessibilityIdentifier(Self.dispatchIdentifier)
  }

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
    .accessibilityIdentifier(Self.modePickerIdentifier)
  }

  /// The format action row is not a second source of truth: it iterates
  /// `MarkdownFormat.allCases` in declaration order, exactly like the floating
  /// selection bar and editor context menu. Each action is a bare toolbar
  /// button — no custom backgrounds, borders, or chip shapes — so the row is
  /// styled by the system exactly like the neighboring navigation and trailing
  /// clusters (template glyphs, hover/press highlight, chevron overflow).
  private var formatButtons: some View {
    ForEach(MarkdownFormat.allCases) { format in
      Button {
        controller.applyMarkdownFormat(format)
      } label: {
        Image(systemName: format.systemImageName)
      }
      .help(format.label)
      .accessibilityLabel(format.label)
      .accessibilityIdentifier(format.toolbarAccessibilityIdentifier)
    }
  }

  /// Rich Markdown is the row's only non-format action: a native toolbar
  /// toggle whose on state the system renders like the sidebar button's.
  private var richMarkdownToggle: some View {
    Toggle(
      isOn: Binding(
        get: { appState.richMarkdownEnabled },
        set: { _ in controller.toggleRichMarkdown() }
      )
    ) {
      Image(systemName: "textformat.alt")
    }
    .help("Rich Markdown (⌘/)")
    .accessibilityLabel("Rich Markdown")
    .accessibilityValue(appState.richMarkdownEnabled ? "On" : "Off")
    .accessibilityIdentifier(Self.richMarkdownToggleIdentifier)
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
    .accessibilityIdentifier(Self.overflowIdentifier)
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
    .accessibilityIdentifier(EditorToolbelt.appearanceIdentifier)
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
  var toolbarAccessibilityIdentifier: String {
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
