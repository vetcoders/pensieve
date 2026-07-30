import AppKit
import Combine
import SwiftUI

/// Window toolbar contents for the main editor scene.
///
/// Titlebar contract: keep SwiftUI's native sidebar toggle first, leave
/// `.navigation` empty so the document title leads, then document/dispatch →
/// history → editing → view → preview runtime → assistants. Declaration order
/// is the only ordering authority. Each semantic family is a labeled native
/// toolbar group with a system `ControlGroup`; macOS owns width compression and
/// overflow. There is no app-authored ellipsis taxonomy and no spacer pretending
/// to prove visual separation. Raw format buttons stay inline whenever the
/// buffer is editable, matching the floating selection bar and the Format app
/// menu without adding formatter logic.
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
  static let autoReloadIdentifier = "pensieve.toolbar.autoReload"
  static let scrollSyncIdentifier = "pensieve.toolbar.scrollSync"
  static let dictationIdentifier = "pensieve.toolbar.dictationToggle"
  static let autocompleteIdentifier = "pensieve.toolbar.autocompleteToggle"
  static let rewriteIdentifier = "pensieve.toolbar.aiRewrite"
  static let undoIdentifier = "pensieve.toolbar.undo"
  static let redoIdentifier = "pensieve.toolbar.redo"
  static let richMarkdownToggleIdentifier = "pensieve.toolbar.richMarkdownToggle"

  enum ToolbarFamilyIdentifier: String, Equatable {
    case documentDispatch
    case history
    case editing
    case view
    case previewRuntime
    case assistants
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
    ToolbarItemGroup {
      ControlGroup {
        shareButton
        dispatchButton
      }
    } label: {
      Label("Document and Dispatch", systemImage: "doc")
    }

    if showsEditToolbelt {
      ToolbarItemGroup {
        ToolbarHistoryControls()
      } label: {
        Label("History", systemImage: "arrow.uturn.backward")
      }

      ToolbarItemGroup {
        ControlGroup {
          richMarkdownToggle
          formatButtons
        }
      } label: {
        Label("Editing", systemImage: "textformat")
      }
    }

    ToolbarItemGroup {
      ControlGroup {
        modePicker

        if Self.showsAppearanceControls(for: appState.mode) {
          AppearanceToolbarMenu(themeManager: themeManager)
        }
      }
    } label: {
      Label("View", systemImage: "rectangle.split.2x1")
    }

    ToolbarItemGroup {
      ControlGroup {
        reloadButton
        autoReloadToggle
        scrollSyncToggle
      }
    } label: {
      Label("Preview Runtime", systemImage: "arrow.clockwise")
    }

    ToolbarItemGroup {
      ControlGroup {
        dictationToggle
        autocompleteToggle
        rewriteMenu
      }
    } label: {
      Label("Assistants", systemImage: "sparkles")
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
      identifiers.append(undoIdentifier)
      identifiers.append(redoIdentifier)
      identifiers.append(richMarkdownToggleIdentifier)
      identifiers.append(contentsOf: MarkdownFormat.allCases.map(\.toolbarAccessibilityIdentifier))
    }

    identifiers.append(modePickerIdentifier)

    if showsAppearanceControls(for: mode) {
      identifiers.append(appearanceIdentifier)
    }

    identifiers.append(reloadIdentifier)
    identifiers.append(autoReloadIdentifier)
    identifiers.append(scrollSyncIdentifier)
    identifiers.append(dictationIdentifier)
    identifiers.append(autocompleteIdentifier)
    identifiers.append(rewriteIdentifier)
    return identifiers
  }

  static func visibleToolbarFamilyOrder(
    for mode: EditorMode,
    hasEditableBuffer: Bool
  ) -> [ToolbarFamilyIdentifier] {
    var families: [ToolbarFamilyIdentifier] = [.documentDispatch]

    if showsEditToolbelt(for: mode, hasEditableBuffer: hasEditableBuffer) {
      families.append(.history)
      families.append(.editing)
    }

    families.append(contentsOf: [.view, .previewRuntime, .assistants])
    return families
  }

  // MARK: - Subgroups

  private var shareButton: some View {
    Button(action: { DocumentSharing.share(session: appState.documentSession) }) {
      Label("Share", systemImage: "square.and.arrow.up")
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
        Label(format.label, systemImage: format.systemImageName)
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
      Label("Rich Markdown", systemImage: "textformat.alt")
    }
    .help("Rich Markdown (⌘/)")
    .accessibilityLabel("Rich Markdown")
    .accessibilityValue(appState.richMarkdownEnabled ? "On" : "Off")
    .accessibilityIdentifier(Self.richMarkdownToggleIdentifier)
  }

  private var reloadButton: some View {
    Button(action: { appState.requestPreviewRefresh() }) {
      Label("Reload Preview", systemImage: "arrow.clockwise")
    }
    .help("Reload Preview")
    .disabled(!hasEditableBuffer)
    .accessibilityIdentifier(Self.reloadIdentifier)
  }

  private var autoReloadToggle: some View {
    Toggle(
      isOn: Binding(
        get: { appState.previewAutoReload },
        set: { appState.previewAutoReload = $0 }
      )
    ) {
      Label("Auto Reload Preview", systemImage: "arrow.triangle.2.circlepath")
    }
    .help("Automatically reload the preview after edits")
    .accessibilityIdentifier(Self.autoReloadIdentifier)
  }

  private var scrollSyncToggle: some View {
    Toggle(
      isOn: Binding(
        get: { appState.scrollSyncEnabled },
        set: { appState.scrollSyncEnabled = $0 }
      )
    ) {
      Label("Scroll Sync", systemImage: "arrow.up.and.down")
    }
    .help("Keep editor and preview positions synchronized")
    .disabled(!hasEditableBuffer)
    .accessibilityIdentifier(Self.scrollSyncIdentifier)
  }

  private var dictationToggle: some View {
    Toggle(
      isOn: Binding(
        get: { controller.isTranscriptionTaflaVisible },
        set: { _ in controller.toggleTranscriptionTafla() }
      )
    ) {
      Label("Dictation", systemImage: "waveform.circle")
    }
    .help("Open Dictation")
    .accessibilityIdentifier(Self.dictationIdentifier)
  }

  private var autocompleteToggle: some View {
    Toggle(
      isOn: Binding(
        get: { appState.aiAutocompleteEnabled },
        set: { appState.aiAutocompleteEnabled = $0 }
      )
    ) {
      Label("AI Autocomplete", systemImage: "sparkles")
    }
    .help("Suggest the next phrase as you type; press Tab to accept")
    .accessibilityIdentifier(Self.autocompleteIdentifier)
  }

  private var rewriteMenu: some View {
    Menu {
      ForEach(RewriteIntent.allCases, id: \.self) { intent in
        Button(intent.label) {
          appState.pendingAIRewriteCommand = AIRewriteCommand(action: .request(intent))
        }
      }
    } label: {
      Label("Rewrite with AI", systemImage: "wand.and.stars")
    }
    .help("Rewrite the selection or current paragraph with AI")
    .disabled(!hasEditableBuffer || appState.mode == .preview)
    .accessibilityIdentifier(Self.rewriteIdentifier)
  }
}

/// Responder-chain history actions for the toolbar. The state mirrors only the
/// active responder's existing undo manager; it never owns or duplicates a
/// history stack. Standard AppKit selectors keep the toolbar on the same path
/// as Edit > Undo/Redo and the focused `NSTextView`.
@MainActor
final class ToolbarResponderHistoryState: ObservableObject {
  @MainActor
  enum Action: String, CaseIterable {
    case undo
    case redo

    var selector: Selector { NSSelectorFromString("\(rawValue):") }
    var label: String { rawValue.capitalized }
    var systemImage: String {
      switch self {
      case .undo: return "arrow.uturn.backward"
      case .redo: return "arrow.uturn.forward"
      }
    }
    var accessibilityIdentifier: String {
      switch self {
      case .undo: return EditorToolbelt.undoIdentifier
      case .redo: return EditorToolbelt.redoIdentifier
      }
    }
  }

  struct Availability: Equatable {
    let canUndo: Bool
    let canRedo: Bool
  }

  @Published private(set) var availability = Availability(canUndo: false, canRedo: false)
  private var cancellables = Set<AnyCancellable>()

  static let refreshNotificationNames: [Notification.Name] = [
    .NSUndoManagerDidCloseUndoGroup,
    .NSUndoManagerDidUndoChange,
    .NSUndoManagerDidRedoChange,
    NSWindow.didBecomeKeyNotification,
    NSWindow.didBecomeMainNotification,
    NSText.didBeginEditingNotification,
    NSText.didChangeNotification,
    NSText.didEndEditingNotification,
  ]

  init(center: NotificationCenter = .default) {
    Publishers.MergeMany(Self.refreshNotificationNames.map { center.publisher(for: $0) })
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        Task { @MainActor in
          self?.refresh()
        }
      }
      .store(in: &cancellables)

    refresh()
  }

  static func availability(for responder: NSResponder?) -> Availability {
    guard let undoManager = responder?.undoManager else {
      return Availability(canUndo: false, canRedo: false)
    }
    return Availability(canUndo: undoManager.canUndo, canRedo: undoManager.canRedo)
  }

  func isEnabled(_ action: Action) -> Bool {
    switch action {
    case .undo: return availability.canUndo
    case .redo: return availability.canRedo
    }
  }

  @discardableResult
  func perform(_ action: Action) -> Bool {
    let sent = NSApp.sendAction(action.selector, to: nil, from: nil)
    refresh()
    return sent
  }

  func refresh() {
    let nextAvailability = Self.availability(for: NSApp.keyWindow?.firstResponder)
    guard nextAvailability != availability else { return }
    availability = nextAvailability
  }
}

private struct ToolbarHistoryControls: View {
  @StateObject private var history = ToolbarResponderHistoryState()

  var body: some View {
    ControlGroup {
      ForEach(ToolbarResponderHistoryState.Action.allCases, id: \.self) { action in
        Button {
          history.perform(action)
        } label: {
          Label(action.label, systemImage: action.systemImage)
        }
        .help(action == .undo ? "Undo (⌘Z)" : "Redo (⇧⌘Z)")
        .disabled(!history.isEnabled(action))
        .accessibilityIdentifier(action.accessibilityIdentifier)
      }
    }
  }
}

/// Native menu for the two preview appearance axes. Keeping presentation under
/// AppKit's menu-button contract avoids transient SwiftUI popover state being
/// recreated by the toolbar host between mouse-down and mouse-up.
private struct AppearanceToolbarMenu: View {
  @ObservedObject var themeManager: ThemeManager

  var body: some View {
    Menu {
      Picker("Flavor", selection: $themeManager.current) {
        ForEach(ThemeManager.Theme.allCases) { theme in
          Text(theme.displayName).tag(theme)
        }
      }
      .pickerStyle(.menu)
      .help("Markdown flavor — plain Markdown or GitHub Flavored")
      .accessibilityIdentifier("pensieve.toolbar.themePicker")

      // Reading-surface skin, orthogonal to the flavor: it re-dresses BOTH the
      // rendered preview and the source editor — surface, typography and syntax
      // tokens — without changing the markdown dialect. Seven first-party
      // themes: Default, Raw, Pergament, Graphite, Ink, Klinika, Maszynopis.
      Picker("Theme", selection: $themeManager.skin) {
        ForEach(PensieveTheme.allCases) { skin in
          Label(skin.displayName, systemImage: skin.systemImage).tag(skin)
        }
      }
      .pickerStyle(.menu)
      .help("Preview theme — the reading surface for the rendered markdown")
      .accessibilityIdentifier("pensieve.toolbar.skinPicker")
    } label: {
      Label("Preview Appearance", systemImage: "paintpalette")
    }
    .help("Preview appearance — markdown flavor and reading theme")
    .accessibilityLabel("Preview Appearance")
    .accessibilityIdentifier(EditorToolbelt.appearanceIdentifier)
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
