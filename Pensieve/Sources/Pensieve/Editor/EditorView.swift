import AppKit
import Combine
import SwiftUI

struct EditorView: View {
  @Environment(AppState.self) private var appState
  @EnvironmentObject private var controller: AppController
  @EnvironmentObject private var themeManager: ThemeManager
  @State private var autocompleteError: String?
  private let scrollSyncCoordinator: ScrollSyncCoordinator?

  init(scrollSyncCoordinator: ScrollSyncCoordinator? = nil) {
    self.scrollSyncCoordinator = scrollSyncCoordinator
    _autocompleteError = State(initialValue: nil)
  }

  var body: some View {
    @Bindable var appState = appState
    return VStack(spacing: 0) {
      if appState.findBarVisible {
        FindBar()
      }

      EditorRepresentable(
        text: documentText,
        editorMode: appState.mode,
        fontSize: appState.fontSize,
        skin: themeManager.skin,
        syntaxHighlightingEnabled: appState.richMarkdownEnabled,
        formattingCommand: appState.pendingMarkdownFormatCommand,
        rewriteCommand: appState.pendingAIRewriteCommand,
        findQuery: $appState.findQuery,
        findReplacement: $appState.findReplaceQuery,
        findBarVisible: appState.findBarVisible,
        findCommand: appState.pendingFindCommand,
        tableTidyOnPaste: appState.tableTidyOnPaste,
        asciiSafeTables: appState.asciiSafeTables,
        aiAutocompleteEnabled: appState.aiAutocompleteEnabled,
        documentID: appState.aiDocumentID,
        scrollSyncCoordinator: scrollSyncCoordinator,
        scrollSyncEnabled: appState.scrollSyncEnabled && appState.mode == .split,
        isDirty: documentDirty,
        onDocumentChanged: controller.documentDidChange,
        onCloseFindBar: closeFindBar,
        onFindStateChanged: { total, active in
          appState.findMatchCount = total
          appState.findActiveMatchIndex = active
        },
        onSelectionChanged: { caret, selectionLength in
          appState.caretUTF16Offset = caret
          appState.selectionUTF16Length = selectionLength
        },
        onAutocompleteErrorChanged: { error in
          autocompleteError = error
        },
        onRewritePreviewChanged: { preview in
          appState.aiRewritePreview = preview
        }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // Let the editor scroll view extend UNDER the unified toolbar so the text
      // (not just the line-number ruler) slides under it, blurred — the native
      // Finder look. The scroll view already reaches under the titlebar (the ruler
      // proves it); SwiftUI's top safe-area inset was the only thing holding the
      // text below. automaticallyAdjustsContentInsets (default) keeps the caret
      // line starting below the toolbar while letting scrolled content pass under.
      .ignoresSafeArea(.container, edges: .top)
      .overlay(alignment: .top) {
        if appState.aiAutocompleteEnabled, let autocompleteError {
          HStack(spacing: 8) {
            Label(autocompleteError, systemImage: "sparkles")
              .font(.caption)
              .lineLimit(2)

            Spacer(minLength: 12)

            Button {
              self.autocompleteError = nil
            } label: {
              Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss AI Autocomplete status")
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 9)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
          .overlay {
            RoundedRectangle(cornerRadius: 9)
              .stroke(Color.orange.opacity(0.45), lineWidth: 1)
          }
          .padding(12)
          .accessibilityIdentifier("pensieve.autocomplete.error")
        }
      }
      .overlay(alignment: .bottom) {
        if let preview = appState.aiRewritePreview {
          VStack(alignment: .leading, spacing: 10) {
            Text(preview.intent.label)
              .font(.headline)
            ScrollView {
              Text(preview.proposed)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .frame(maxHeight: 160)
            HStack {
              Button("Cancel") {
                appState.pendingAIRewriteCommand = AIRewriteCommand(action: .cancel)
              }
              .keyboardShortcut(.cancelAction)
              .accessibilityIdentifier("pensieve.rewrite.cancel")
              Spacer()
              Button("Accept Rewrite") {
                appState.pendingAIRewriteCommand = AIRewriteCommand(action: .accept)
              }
              .keyboardShortcut(.defaultAction)
              .accessibilityIdentifier("pensieve.rewrite.accept")
            }
          }
          .padding(16)
          .frame(maxWidth: 520)
          .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
          .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(.separator, lineWidth: 1)
          }
          .padding(16)
          .accessibilityIdentifier("pensieve.rewrite.preview")
        }
      }
    }
    .background(Color(themeManager.skin.tokens.source.nsColor))
  }

  private var documentText: Binding<String> {
    Binding(
      get: { appState.documentSession.text },
      set: { appState.documentSession.text = $0 }
    )
  }

  private var documentDirty: Binding<Bool> {
    Binding(
      get: { appState.documentSession.isDirty },
      set: { appState.documentSession.isDirty = $0 }
    )
  }

  private func closeFindBar() {
    appState.findBarVisible = false
    appState.pendingFindCommand = FindBarCommand(action: .clear)
  }
}

// MARK: - TextKit bridge

struct EditorRepresentable: NSViewRepresentable {
  @Binding var text: String
  let editorMode: EditorMode
  let fontSize: CGFloat
  /// Reading-surface skin driving the source panel tokens. Defaulted so test
  /// call sites that build the representable directly keep the GitHub surface.
  let skin: PensieveTheme
  let syntaxHighlightingEnabled: Bool
  let formattingCommand: MarkdownFormatCommand?
  let rewriteCommand: AIRewriteCommand?
  @Binding var findQuery: String
  @Binding var findReplacement: String
  let findBarVisible: Bool
  let findCommand: FindBarCommand?
  let tableTidyOnPaste: Bool
  let asciiSafeTables: Bool
  let aiAutocompleteEnabled: Bool
  let documentID: String
  let scrollSyncCoordinator: ScrollSyncCoordinator?
  let scrollSyncEnabled: Bool
  @Binding var isDirty: Bool
  let onDocumentChanged: @MainActor () -> Void
  let onCloseFindBar: @MainActor () -> Void
  // Defaults to a no-op so find-navigation tests that build the representable
  // directly need not wire the count callback they do not exercise.
  var onFindStateChanged: @MainActor (Int, Int?) -> Void = { _, _ in }
  // Caret/selection sink for the status bar; no-op default for the same reason.
  var onSelectionChanged: @MainActor (Int, Int) -> Void = { _, _ in }
  var onAutocompleteErrorChanged: @MainActor (String?) -> Void = { _ in }
  var onRewritePreviewChanged: @MainActor (AIRewritePreview?) -> Void = { _ in }

  init(
    text: Binding<String>,
    editorMode: EditorMode,
    fontSize: CGFloat,
    skin: PensieveTheme = .default,
    syntaxHighlightingEnabled: Bool,
    formattingCommand: MarkdownFormatCommand?,
    rewriteCommand: AIRewriteCommand? = nil,
    findQuery: Binding<String>,
    findReplacement: Binding<String>,
    findBarVisible: Bool,
    findCommand: FindBarCommand?,
    tableTidyOnPaste: Bool,
    asciiSafeTables: Bool,
    aiAutocompleteEnabled: Bool,
    documentID: String = "transient",
    scrollSyncCoordinator: ScrollSyncCoordinator? = nil,
    scrollSyncEnabled: Bool = false,
    isDirty: Binding<Bool>,
    onDocumentChanged: @escaping @MainActor () -> Void,
    onCloseFindBar: @escaping @MainActor () -> Void,
    onFindStateChanged: @escaping @MainActor (Int, Int?) -> Void = { _, _ in },
    onSelectionChanged: @escaping @MainActor (Int, Int) -> Void = { _, _ in },
    onAutocompleteErrorChanged: @escaping @MainActor (String?) -> Void = { _ in },
    onRewritePreviewChanged: @escaping @MainActor (AIRewritePreview?) -> Void = { _ in }
  ) {
    self._text = text
    self.editorMode = editorMode
    self.fontSize = fontSize
    self.skin = skin
    self.syntaxHighlightingEnabled = syntaxHighlightingEnabled
    self.formattingCommand = formattingCommand
    self.rewriteCommand = rewriteCommand
    self._findQuery = findQuery
    self._findReplacement = findReplacement
    self.findBarVisible = findBarVisible
    self.findCommand = findCommand
    self.tableTidyOnPaste = tableTidyOnPaste
    self.asciiSafeTables = asciiSafeTables
    self.aiAutocompleteEnabled = aiAutocompleteEnabled
    self.documentID = documentID
    self.scrollSyncCoordinator = scrollSyncCoordinator
    self.scrollSyncEnabled = scrollSyncEnabled
    self._isDirty = isDirty
    self.onDocumentChanged = onDocumentChanged
    self.onCloseFindBar = onCloseFindBar
    self.onFindStateChanged = onFindStateChanged
    self.onSelectionChanged = onSelectionChanged
    self.onAutocompleteErrorChanged = onAutocompleteErrorChanged
    self.onRewritePreviewChanged = onRewritePreviewChanged
  }

  func makeNSView(context: Context) -> NSScrollView {
    let surface = MarkdownEditorSurface(
      text: text,
      fontSize: fontSize,
      skin: skin,
      syntaxHighlightingEnabled: syntaxHighlightingEnabled,
      tableTidyOnPaste: tableTidyOnPaste,
      asciiSafeTables: asciiSafeTables,
      aiAutocompleteEnabled: aiAutocompleteEnabled,
      documentID: documentID
    )
    context.coordinator.rethemeMemo.record(skin.paintedIdentity)
    surface.onTextChanged = { newText in
      self.text = newText
      self.isDirty = true
      self.onDocumentChanged()
    }
    surface.onCloseFindBar = {
      self.onCloseFindBar()
    }
    surface.onFindStateChanged = { total, active in
      DispatchQueue.main.async {
        self.onFindStateChanged(total, active)
      }
    }
    surface.onSelectionChanged = { caret, selectionLength in
      DispatchQueue.main.async {
        self.onSelectionChanged(caret, selectionLength)
      }
    }
    surface.onAutocompleteErrorChanged = { error in
      DispatchQueue.main.async {
        self.onAutocompleteErrorChanged(error)
      }
    }
    surface.onRewritePreviewChanged = { preview in
      DispatchQueue.main.async {
        self.onRewritePreviewChanged(preview)
      }
    }
    surface.configureScrollSync(
      coordinator: scrollSyncCoordinator,
      enabled: scrollSyncEnabled
    )
    surface.typewriterScrollEnabled = editorMode == .focus
    context.coordinator.surface = surface
    return surface.scrollView
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let surface = context.coordinator.surface else { return }
    surface.onAutocompleteErrorChanged = onAutocompleteErrorChanged
    surface.onRewritePreviewChanged = onRewritePreviewChanged
    surface.configureDocument(id: documentID)
    // Re-theme only when the palette actually changed. Pushing tokens re-runs a
    // full highlight refresh, so doing it on every keystroke re-render would be
    // the per-keystroke hang the perf pins guard against.
    //
    // The key is the PAINTED identity, not the skin the operator picked. Those
    // were the same thing until a skin gained two palettes: on a paired skin the
    // enum stays `.typewriter` while the Mac moves between the halves, so a memo
    // keyed on the enum answers "nothing changed" to the one change that matters
    // and leaves the source panel painted in the other half — a black pane in a
    // fully light window, which is exactly what the operator saw.
    if context.coordinator.rethemeMemo.needsReapply(skin.paintedIdentity) {
      surface.applyTheme(skin)
    }
    // Keep the host window's appearance + titlebar backing in lockstep with the
    // source panel. Unlike `applyTheme` above this runs UNCONDITIONALLY, on every
    // pass: it is a compare-and-set invariant, not a one-shot pin. The window can
    // lose the chrome we set it without any skin change to tell us — AppKit
    // re-bridges the hosting view's toolbar when toolbar content changes (the
    // theme picker's label carries the skin name, so every switch re-bridges) and
    // tab-group reshuffles re-parent windows — and a pin that only fired on a
    // skin change would never come back to heal that. Running every pass also
    // covers the initial attach, where `applyTheme` ran before the window
    // existed. Equal values are skipped inside, so a keystroke re-render writes
    // nothing.
    surface.applyWindowChrome(for: skin)
    // Pin the scroll position across SwiftUI re-renders. The per-window state bridge fires
    // objectWillChange on every keystroke, re-laying out this representable; without this the
    // clip view re-scrolls to the caret each time ("the screen goes wild on every letter").
    // A genuine text change (document load) is allowed to scroll; a pure re-render keeps the
    // viewport where the user left it — caret only moves scroll when typing pushes it past
    // the edge, which AppKit already did before this re-render ran.
    let textUnchanged = surface.textStorage.string == text
    let savedOrigin = scroll.contentView.bounds.origin
    surface.typewriterScrollEnabled = editorMode == .focus
    surface.configureScrollSync(
      coordinator: scrollSyncCoordinator,
      enabled: scrollSyncEnabled
    )
    surface.update(
      text: text,
      fontSize: fontSize,
      syntaxHighlightingEnabled: syntaxHighlightingEnabled,
      tableTidyOnPaste: tableTidyOnPaste,
      asciiSafeTables: asciiSafeTables,
      aiAutocompleteEnabled: aiAutocompleteEnabled,
      findQuery: findQuery,
      findBarVisible: findBarVisible
    )
    if textUnchanged {
      if surface.typewriterScrollEnabled {
        surface.centerCaretLineIfNeeded()
      } else if scroll.contentView.bounds.origin != savedOrigin {
        // Only re-pin when surface.update() actually drifted the viewport. Firing
        // scroll(to:)+reflectScrolledClipView on EVERY keystroke posts a redundant
        // bounds-change → gutter redraw → the per-letter flicker the operator saw in
        // normal/split mode. No drift ⇒ nothing to restore.
        scroll.contentView.scroll(to: savedOrigin)
        scroll.reflectScrolledClipView(scroll.contentView)
      }
    }
    context.coordinator.apply(formattingCommand, to: surface)
    context.coordinator.apply(rewriteCommand, to: surface)
    if let selectedText = context.coordinator.applyFind(
      findCommand,
      to: surface,
      query: findQuery,
      replacement: findReplacement
    ) {
      findQuery = selectedText
    }
  }

  /// Remembers what the source panel is currently painted in, so the expensive
  /// re-theme runs on a palette change and on nothing else.
  ///
  /// A value type on purpose: the whole failure this replaces was a memo whose
  /// key was subtly weaker than the thing it guarded, and a key that can be
  /// exercised on its own is a key that can be pinned across a full
  /// dark → light → dark cycle without a SwiftUI host.
  struct RethemeMemo {
    private var painted: PaintedSkin?

    /// True when `candidate` differs from what was last painted — and records it
    /// in the same step, so a caller cannot ask and then forget to commit.
    mutating func needsReapply(_ candidate: PaintedSkin) -> Bool {
      guard painted != candidate else { return false }
      painted = candidate
      return true
    }

    /// Records a palette applied by someone else (the surface themes itself in
    /// its initialiser, before `updateNSView` ever runs).
    mutating func record(_ applied: PaintedSkin) {
      painted = applied
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  final class Coordinator {
    var surface: MarkdownEditorSurface?
    /// Guards the surface re-theme, so `updateNSView` re-themes only on a real
    /// palette change and never re-runs the highlight pass per keystroke.
    var rethemeMemo = RethemeMemo()
    private var lastAppliedFormattingCommandID: UUID?
    private var lastAppliedRewriteCommandID: UUID?
    private var lastAppliedFindCommandID: UUID?

    func apply(_ command: MarkdownFormatCommand?, to surface: MarkdownEditorSurface) {
      guard let command else { return }
      guard command.id != lastAppliedFormattingCommandID else { return }
      lastAppliedFormattingCommandID = command.id
      surface.applyMarkdownCommand(command)
    }

    func apply(_ command: AIRewriteCommand?, to surface: MarkdownEditorSurface) {
      guard let command, command.id != lastAppliedRewriteCommandID else { return }
      lastAppliedRewriteCommandID = command.id
      surface.applyRewriteCommand(command)
    }

    func applyFind(
      _ command: FindBarCommand?,
      to surface: MarkdownEditorSurface,
      query: String,
      replacement: String
    ) -> String? {
      guard let command else { return nil }
      guard command.id != lastAppliedFindCommandID else { return nil }
      lastAppliedFindCommandID = command.id

      switch command.action {
      case .next:
        surface.selectFindMatch(direction: .forward)
      case .previous:
        surface.selectFindMatch(direction: .backward)
      case .replace:
        surface.replaceCurrentFindMatch(query: query, replacement: replacement)
      case .replaceAll:
        surface.replaceAllFindMatches(query: query, replacement: replacement)
      case .useSelection:
        let selectedText = surface.selectedTextForFind()
        if !selectedText.isEmpty {
          surface.updateFind(query: selectedText, visible: true)
          surface.selectFindMatch(direction: .forward)
          return selectedText
        }
      case .clear:
        surface.clearFindHighlights()
      }
      return nil
    }
  }
}

final class MarkdownEditorSurface: NSObject, NSTextViewDelegate {
  let scrollView: NSScrollView
  let textView: MarkdownTextView
  let textStorage: NSTextStorage
  let textContentStorage: MarkdownTextStorage
  let textLayoutManager: NSTextLayoutManager
  let textContainer: NSTextContainer
  let autocompleteController: AutocompleteController

  var onTextChanged: ((String) -> Void)?
  var onCloseFindBar: (() -> Void)?
  var onFindStateChanged: ((Int, Int?) -> Void)?
  /// Reports (caret UTF-16 offset, selection UTF-16 length) for the status bar.
  var onSelectionChanged: ((Int, Int) -> Void)?
  var onAutocompleteErrorChanged: ((String?) -> Void)?
  var onRewritePreviewChanged: ((AIRewritePreview?) -> Void)?
  private var lastNotifiedCaretOffset = -1
  private var lastNotifiedSelectionLength = -1
  /// Active theme tokens for the source panel. Held so `update` can keep typing
  /// attributes on the theme text colour when the font size changes.
  private var activeTokens: ThemeTokens = PensieveTheme.default.tokens
  var typewriterScrollEnabled = false
  var isApplyingExternalText = false
  private var aiAutocompleteEnabled: Bool
  private var autocompleteCancellable: AnyCancellable?
  private var autocompleteErrorCancellable: AnyCancellable?
  private var rewritePreviewCancellable: AnyCancellable?
  private var documentRevision: UInt64 = 0
  private var autocompleteRenderGeneration: UInt64 = 0
  private var lastTextChangeSelection: NSRange?
  private weak var scrollSyncCoordinator: ScrollSyncCoordinator?
  private var scrollSyncEnabled = false
  private var pendingScrollSyncSample: DispatchWorkItem?
  private let scrollSyncDebounce: TimeInterval
  /// Logical line index (newline count before the caret) at the last typewriter
  /// re-center. Same-line edits keep this stable → no per-keystroke re-center.
  private var lastCenteredLine: Int?
  /// Anchor for `lineIndex(forUTF16Offset:)`: a (offset, line) pair that holds
  /// while the text in `[0, offset)` is unchanged. Parked on a LINE START
  /// whenever a resolve crosses a separator, so typing — which edits at or after
  /// the line start, backspace included — never invalidates it.
  private var lineAnchorOffset = 0
  private var lineAnchorLine = 0
  private var findQuery = ""
  /// `.foregroundColor` runs the find washes painted over, captured at paint
  /// time so a teardown can restore them without a highlight pass per match.
  private var inkUnderFindWashes: [(range: NSRange, color: NSColor?)] = []
  private var findMatches: [NSRange] = []
  private var activeFindMatchIndex: Int?
  private var isFindBarVisible = false
  private var hasNotifiedFindState = false
  private var lastNotifiedFindCount = -1
  private var lastNotifiedFindActiveIndex: Int?

  init(
    text: String,
    fontSize: CGFloat,
    skin: PensieveTheme = .default,
    syntaxHighlightingEnabled: Bool = true,
    tableTidyOnPaste: Bool = true,
    asciiSafeTables: Bool = false,
    aiAutocompleteEnabled: Bool = false,
    documentID: String = "transient",
    scrollSyncDebounce: TimeInterval = 0.04,
    // Production autocomplete backend. The factory is lazy and resolved only
    // after the debounce. STT/formatting stay in qube-ffi; editor completion uses
    // the current provider-safe Responses request contract directly.
    autocompleteController: AutocompleteController = AutocompleteController(
      completionFactory: { OpenAIResponsesAutocompleteBackend() })
  ) {
    textLayoutManager = NSTextLayoutManager()
    textContentStorage = MarkdownTextStorage()
    textStorage = NSTextStorage()
    self.autocompleteController = autocompleteController
    self.aiAutocompleteEnabled = aiAutocompleteEnabled
    self.scrollSyncDebounce = scrollSyncDebounce
    textContentStorage.syntaxHighlightingEnabled = syntaxHighlightingEnabled

    textContentStorage.textStorage = textStorage
    textContentStorage.addTextLayoutManager(textLayoutManager)

    textContainer = NSTextContainer(
      size: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
    textContainer.widthTracksTextView = true
    textLayoutManager.textContainer = textContainer

    scrollView = NSScrollView(frame: .zero)
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = .textBackgroundColor

    textView = MarkdownTextView(
      frame: NSRect(x: 0, y: 0, width: 640, height: scrollView.contentSize.height),
      textContainer: textContainer
    )

    textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.backgroundColor = .textBackgroundColor
    textView.setAccessibilityIdentifier("pensieve.editor")
    textView.textContainerInset = NSSize(
      width: 12,
      height: WindowChromeRecipe.documentContentTopInset)

    scrollView.documentView = textView
    textView.setupGutter(layoutManager: textLayoutManager)
    textView.tableTidyOnPaste = tableTidyOnPaste
    textView.asciiSafeTables = asciiSafeTables

    super.init()

    autocompleteController.configureDocument(id: documentID)

    textView.delegate = self
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(editorBoundsDidChange(_:)),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(editorWillUndo(_:)),
      name: .NSUndoManagerWillUndoChange,
      object: textView.undoManager
    )
    textView.onFormatRequest = { [weak self] format in
      _ = self?.applyMarkdownFormat(format)
    }
    textView.onEscape = { [weak self] in
      if self?.dismissAutocompleteSuggestion() == true {
        return true
      }
      guard self?.isFindBarVisible == true else { return false }
      self?.clearFindHighlights()
      self?.onCloseFindBar?()
      return true
    }
    textView.onAcceptAutocomplete = { [weak self] in
      self?.acceptAutocompleteSuggestion() ?? false
    }
    bindAutocomplete()
    bindRewritePreview()
    // Viewport seam for a live skin switch: the storage re-colours what is on
    // screen synchronously and defers the rest of the document, so it has to be
    // able to ask what "on screen" currently is. Wired BEFORE the first
    // `applyTheme` so no retheme can ever run without it.
    textContentStorage.visibleRangeProvider = { [weak self] in
      self?.textView.visibleCharacterRange
    }
    // The deferred half of that switch runs a full refresh, which strips
    // `.backgroundColor` document-wide — the attribute the find washes live in —
    // and lands after `applyTheme` already repainted them once.
    textContentStorage.onRethemeCompleted = { [weak self] in
      self?.reapplyFindHighlights()
    }
    // …and every SCOPED pass strips it over the range it repaints. The sweep
    // starts at offset 0 and rides one chunk per frame, so waiting for the
    // completion above left matches near the top of the document unwashed for
    // the whole length of the sweep. Repaint per chunk instead.
    textContentStorage.onHighlightingRepainted = { [weak self] range in
      self?.reapplyFindHighlights(in: range)
    }
    // The caret→line resolver caches an anchor keyed on the text before it. Only
    // the storage sees every character edit — direct mutations included — so the
    // invalidation is driven from there rather than from the delegate callbacks.
    textContentStorage.onCharactersEdited = { [weak self] location, _ in
      self?.invalidateLineAnchor(editedAt: location)
    }
    // Theme the surface BEFORE the initial content load so the first highlight
    // pass in `update` already uses the theme's source-panel colours.
    applyTheme(skin)
    update(
      text: text,
      fontSize: fontSize,
      syntaxHighlightingEnabled: syntaxHighlightingEnabled,
      tableTidyOnPaste: tableTidyOnPaste,
      asciiSafeTables: asciiSafeTables,
      aiAutocompleteEnabled: aiAutocompleteEnabled,
      findQuery: "",
      findBarVisible: false
    )
  }

  // No default parameter values on purpose: a defaulted behavior flag already
  // shipped one silent kill (init passed aiAutocompleteEnabled, the trailing
  // update() omitted it, and the =false default disabled autocomplete on every
  // surface). Every call site states every flag; the compiler enforces it.
  func update(
    text: String,
    fontSize: CGFloat,
    syntaxHighlightingEnabled: Bool,
    tableTidyOnPaste: Bool,
    asciiSafeTables: Bool,
    aiAutocompleteEnabled: Bool,
    findQuery: String,
    findBarVisible: Bool
  ) {
    textView.tableTidyOnPaste = tableTidyOnPaste
    textView.asciiSafeTables = asciiSafeTables
    setAIAutocompleteEnabled(aiAutocompleteEnabled)

    if textContentStorage.syntaxHighlightingEnabled != syntaxHighlightingEnabled {
      textContentStorage.syntaxHighlightingEnabled = syntaxHighlightingEnabled
      // A full highlight refresh strips `.backgroundColor` document-wide, and the
      // find washes live in that attribute — see `reapplyFindHighlights`.
      reapplyFindHighlights()
    }

    if textContentStorage.fontSize != fontSize {
      textContentStorage.fontSize = fontSize
      // One source of truth for the face: the highlighter's own base font, in the
      // active theme's monospace family at the new size.
      let baseFont = textContentStorage.baseFont
      textView.font = baseFont
      // Keep typing attributes in lockstep with the base font so newly typed text renders in
      // the monospaced face immediately (no system-font flash before the highlight pass).
      // Foreground stays on the active theme text colour, not a fixed system one.
      textView.typingAttributes = [
        .font: baseFont, .foregroundColor: activeTokens.text.nsColor,
      ]
      textView.gutter?.fontSize = fontSize
      textView.gutter?.needsDisplay = true
      reapplyFindHighlights()
    }

    if textStorage.string != text {
      isApplyingExternalText = true
      documentRevision &+= 1
      autocompleteController.cancelRewrite()
      lastCenteredLine = nil  // document changed under us; allow the next center
      invalidateAutocomplete()
      // A model→view text re-sync must NOT yank the viewport to the caret. Preserve the
      // caret + scroll across the full re-apply so a re-render never resets selection to 0
      // and scrolls there (the "screen goes wild on every letter" regression).
      let savedSelection = textView.selectedRange()
      let savedOrigin = scrollView.contentView.bounds.origin
      textStorage.replaceCharacters(
        in: NSRange(location: 0, length: textStorage.length), with: text)
      // Viewport-first past `LargeDocument.sizeBudget`, one synchronous full pass
      // below it — which is every ordinary document, unchanged. This call site is
      // the one the open path lands on, and a full-document pass here is seconds
      // of frozen main thread on a large file.
      textContentStorage.refreshHighlightingAfterFullTextReplacement()
      let newLength = (textStorage.string as NSString).length
      let caret = min(savedSelection.location, newLength)
      textView.setSelectedRange(
        NSRange(location: caret, length: min(savedSelection.length, newLength - caret)))
      if typewriterScrollEnabled {
        centerCaretLineIfNeeded()
      } else {
        scrollView.contentView.scroll(to: savedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
      }
      isApplyingExternalText = false
    }

    updateFind(query: findQuery, visible: findBarVisible)
    updateGutterCurrentLine()
  }

  /// Applies a reading-surface theme to the source panel: the scroll view and
  /// text view backgrounds become the theme `source`, the caret + typing colour
  /// follow `text`, the gutter takes its own tokens, and the markdown
  /// highlighter re-runs with the theme's syntax palette.
  func applyTheme(_ theme: PensieveTheme) {
    let tokens = theme.tokens
    activeTokens = tokens
    scrollView.backgroundColor = tokens.source.nsColor
    textView.applyTheme(tokens, baseSize: textContentStorage.fontSize)
    textContentStorage.tokens = tokens
    // Pushing tokens re-highlights, which strips `.backgroundColor` — the
    // attribute the find-match washes live in. `updateFind` will not repaint
    // them (unchanged query + non-empty matches short-circuits), so the matches
    // would stay invisible until the operator retyped the query. Repaint from
    // the cached matches instead of clearing them: clearing would also drop the
    // active-match index and the scroll position the operator is reading.
    //
    // This covers the pass that just ran inline. On a large document only the
    // viewport is repainted here and the rest of the refresh is deferred, so the
    // storage calls us back through `onRethemeCompleted` to do it again once the
    // full pass has landed.
    reapplyFindHighlights()
    applyWindowChrome(for: theme)
  }

  /// Holds the host window's appearance and titlebar backing on the skin, so the
  /// chrome reads the same reading surface as the source panel. The appearance
  /// is the theme's fixed light/dark (or `nil` for the adaptive skins, which
  /// follow the system), and the backing colour is the recipe's titlebar glass
  /// backing — the same `tokens.source` the pane paints, so the glass strip and
  /// the pane can never split. Assigning the window appearance also forces the
  /// full window re-composite the live layer-backed pane needs to actually show
  /// a new opaque source colour on a live skin switch (the NSColor properties
  /// alone update without a visible repaint until an appearance change lands).
  ///
  /// Re-asserted (compare-and-set), NOT pinned once: `updateNSView` calls this
  /// on every pass and `WindowChromeRecipe.assertWindowChrome` corrects only
  /// what disagrees. A one-shot pin guarded on "the skin changed" loses
  /// permanently to an external reset — AppKit re-bridges the toolbar when its
  /// content changes (the theme picker's label carries the skin name, so every
  /// switch re-bridges) and tab-group reshuffles re-parent windows; either can
  /// hand back a default appearance after we pinned, with no further skin
  /// change coming to re-trigger the pin. Equal values are skipped, so a
  /// steady state issues no sets and there is no recomposite storm.
  ///
  /// No window means nothing to assert AND no bookkeeping — recording a
  /// "pinned" state for a window that does not exist would claim a pin that
  /// never happened, which is what used to let a windowless call suppress the
  /// real one.
  func applyWindowChrome(for theme: PensieveTheme) {
    guard let window = scrollView.window else { return }
    WindowChromeRecipe.assertWindowChrome(on: window, for: theme)
  }

  deinit {
    pendingScrollSyncSample?.cancel()
    NotificationCenter.default.removeObserver(self)
  }

  func configureScrollSync(coordinator: ScrollSyncCoordinator?, enabled: Bool) {
    let wasEnabled = scrollSyncEnabled
    scrollSyncCoordinator = coordinator
    scrollSyncEnabled = enabled
    coordinator?.isEnabled = enabled
    if wasEnabled, !enabled {
      pendingScrollSyncSample?.cancel()
      pendingScrollSyncSample = nil
    }
  }

  @objc private func editorBoundsDidChange(_ notification: Notification) {
    guard notification.object as? NSClipView === scrollView.contentView else { return }
    scheduleScrollSyncSample()
  }

  @objc private func editorWillUndo(_ notification: Notification) {
    guard notification.object as? UndoManager === textView.undoManager else { return }
    autocompleteController.invalidateContinuation()
  }

  func scheduleScrollSyncSample() {
    guard scrollSyncEnabled, scrollSyncCoordinator?.isEnabled == true else { return }

    pendingScrollSyncSample?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.emitScrollSyncFromCurrentViewport()
    }
    pendingScrollSyncSample = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + scrollSyncDebounce, execute: workItem)
  }

  private func emitScrollSyncFromCurrentViewport() {
    pendingScrollSyncSample = nil
    guard scrollSyncEnabled, let scrollSyncCoordinator else { return }
    let visible = scrollView.contentView.bounds
    let documentHeight = scrollView.documentView?.bounds.height ?? textView.bounds.height
    let position = Self.scrollSyncPosition(visibleRect: visible, documentHeight: documentHeight)
    scrollSyncCoordinator.editorDidScroll(to: position)
  }

  static func scrollSyncPosition(visibleRect: NSRect, documentHeight: CGFloat) -> ScrollSyncPosition
  {
    let scrollableHeight = max(0, documentHeight - visibleRect.height)
    guard scrollableHeight > 0 else {
      return ScrollSyncPosition(progress: 0)
    }
    return ScrollSyncPosition(progress: Double(visibleRect.origin.y / scrollableHeight))
  }

  func textDidChange(_ notification: Notification) {
    guard !isApplyingExternalText else { return }
    guard let changedTextView = notification.object as? NSTextView, changedTextView === textView
    else { return }
    let latestText = textStorage.string
    documentRevision &+= 1
    if textView.undoManager?.isUndoing == true {
      autocompleteController.invalidateContinuation()
    }
    invalidateAutocomplete()
    onTextChanged?(latestText)
    if aiAutocompleteEnabled {
      lastTextChangeSelection = textView.selectedRange()
      // IME composition (marked text) fires textDidChange per candidate
      // update; requesting a completion against half-composed characters
      // wastes the LLM round-trip and risks rendering a ghost inside the
      // composition. The render path re-checks hasMarkedText for requests
      // already in flight.
      autocompleteController.textDidChange(
        context: autocompleteContext(from: latestText),
        isComposing: textView.hasMarkedText(),
        replacementRange: NSRange(location: textView.selectedRange().location, length: 0)
      )
    }
    refreshFindMatches()
    centerCaretLineIfNeeded()
    notifySelectionChanged()
  }

  /// Push the caret offset + selection length up to the status bar, deduped so
  /// a re-render or no-op selection event never loops the SwiftUI binding.
  private func notifySelectionChanged() {
    let range = textView.selectedRange()
    guard
      range.location != lastNotifiedCaretOffset
        || range.length != lastNotifiedSelectionLength
    else { return }
    lastNotifiedCaretOffset = range.location
    lastNotifiedSelectionLength = range.length
    onSelectionChanged?(range.location, range.length)
    updateGutterCurrentLine()
  }

  /// Pushes the caret's 1-based source line to the gutter so it can pick out the
  /// active line's number + accent marker. Layout-free (newline count before the
  /// caret, matching the gutter's per-paragraph counter), and the gutter no-ops
  /// when the line is unchanged, so same-line typing never repaints the ruler.
  private func updateGutterCurrentLine() {
    let caret = textView.selectedRange().location
    textView.gutter?.currentLineNumber = lineIndex(forUTF16Offset: caret) + 1
  }

  /// UTF-16 cap on the completion prompt tail. Without it every debounce
  /// ships the ENTIRE document up to the caret through UniFFI + HTTP — a
  /// multi-hundred-KB payload per typing pause in a large note. ~4k units
  /// (≈1–2k tokens) keeps the nearest context, which is all the completion
  /// endpoint conditions on anyway.
  static let autocompletePrefixMaxUTF16 = 4096
  static let autocompleteSuffixMaxUTF16 = 2048

  private func autocompleteContext(from text: String) -> AutocompleteContext {
    let caret = textView.selectedRange().location
    return Self.boundedAutocompleteContext(text as NSString, caret: caret)
  }

  static func boundedAutocompletePrefix(
    _ text: NSString,
    caret: Int,
    maxUTF16: Int = MarkdownEditorSurface.autocompletePrefixMaxUTF16
  ) -> String {
    let caret = min(max(caret, 0), text.length)
    guard caret > maxUTF16 else { return text.substring(to: caret) }
    // Snap the window start down to a composed-character boundary so a
    // surrogate pair (emoji, rare CJK) is never split; the window may grow
    // by at most one composed sequence.
    let start = text.rangeOfComposedCharacterSequence(at: caret - maxUTF16).location
    return text.substring(with: NSRange(location: start, length: caret - start))
  }

  static func boundedAutocompleteContext(
    _ text: NSString,
    caret: Int,
    beforeMaxUTF16: Int = MarkdownEditorSurface.autocompletePrefixMaxUTF16,
    afterMaxUTF16: Int = MarkdownEditorSurface.autocompleteSuffixMaxUTF16
  ) -> AutocompleteContext {
    let caret = min(max(caret, 0), text.length)
    let before = boundedAutocompletePrefix(text, caret: caret, maxUTF16: beforeMaxUTF16)
    let rawAfterLength = min(max(afterMaxUTF16, 0), text.length - caret)
    guard rawAfterLength > 0 else {
      return AutocompleteContext(beforeCursor: before, afterCursor: "")
    }
    let afterRange = text.rangeOfComposedCharacterSequences(
      for: NSRange(location: caret, length: rawAfterLength))
    return AutocompleteContext(
      beforeCursor: before,
      afterCursor: text.substring(with: afterRange))
  }

  private func bindAutocomplete() {
    autocompleteCancellable = autocompleteController.$suggestion
      .receive(on: DispatchQueue.main)
      .sink { [weak self] suggestion in
        self?.scheduleAutocompleteRender(suggestion)
      }
    autocompleteErrorCancellable = autocompleteController.$lastError
      .receive(on: DispatchQueue.main)
      .sink { [weak self] error in
        self?.onAutocompleteErrorChanged?(error)
      }
  }

  private func bindRewritePreview() {
    rewritePreviewCancellable = autocompleteController.$rewritePreview
      .receive(on: DispatchQueue.main)
      .sink { [weak self] preview in
        self?.onRewritePreviewChanged?(preview)
      }
  }

  private func setAIAutocompleteEnabled(_ enabled: Bool) {
    guard aiAutocompleteEnabled != enabled else { return }
    aiAutocompleteEnabled = enabled
    if !enabled {
      invalidateAutocomplete()
      autocompleteController.cancel()
    }
  }

  private func scheduleAutocompleteRender(_ suggestion: String?) {
    let selection = textView.selectedRange()
    let renderGeneration = autocompleteRenderGeneration
    guard aiAutocompleteEnabled, selection.length == 0, !textView.hasMarkedText(),
      let suggestion, !suggestion.isEmpty
    else {
      textView.dismissAutocompleteGhost()
      return
    }
    let caret = selection.location
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard self.aiAutocompleteEnabled,
        self.autocompleteRenderGeneration == renderGeneration,
        self.textView.selectedRange() == selection,
        !self.textView.hasMarkedText()
      else { return }
      self.textView.setAutocompleteGhost(suggestion, at: caret)
    }
  }

  @discardableResult
  func acceptAutocompleteSuggestion() -> Bool {
    guard let suggestion = textView.autocompleteGhostText, !suggestion.isEmpty else { return false }
    // Accepting during IME composition would splice the suggestion through
    // the marked range and corrupt the composition; refuse so Tab reaches
    // the input method instead.
    guard !textView.hasMarkedText() else {
      invalidateAutocomplete()
      return false
    }
    let range = textView.selectedRange()
    guard range.length == 0 else {
      invalidateAutocomplete()
      return false
    }
    guard textView.autocompleteGhostAnchor == range.location else {
      invalidateAutocomplete()
      return false
    }
    guard textView.shouldChangeText(in: range, replacementString: suggestion) else { return false }

    let acceptedCandidate = autocompleteController.candidateForAcceptance(suggestion, at: range)
    textView.dismissAutocompleteGhost()
    textView.insertText(suggestion, replacementRange: range)
    let insertedRange = NSRange(location: range.location, length: (suggestion as NSString).length)
    guard NSMaxRange(insertedRange) <= textStorage.length,
      (textStorage.string as NSString).substring(with: insertedRange) == suggestion
    else { return false }
    if let acceptedCandidate {
      autocompleteController.commitAppliedCandidate(acceptedCandidate)
    }
    textContentStorage.refreshHighlighting()
    return true
  }

  @discardableResult
  func dismissAutocompleteSuggestion() -> Bool {
    let hadGhost = textView.hasAutocompleteGhost
    invalidateAutocomplete()
    autocompleteController.cancel()
    return hadGhost
  }

  func invalidateAutocomplete() {
    autocompleteRenderGeneration &+= 1
    textView.dismissAutocompleteGhost()
  }

  func configureDocument(id: String) {
    autocompleteController.configureDocument(id: id)
  }

  func applyRewriteCommand(_ command: AIRewriteCommand) {
    switch command.action {
    case .request(let intent):
      requestRewrite(intent: intent)
    case .accept:
      acceptRewritePreview()
    case .cancel:
      autocompleteController.cancelRewrite()
    }
  }

  private func requestRewrite(intent: RewriteIntent) {
    let selection = textView.selectedRange()
    let range = selection.length > 0 ? selection : currentParagraphRange(at: selection.location)
    guard range.length > 0, NSMaxRange(range) <= textStorage.length else { return }
    let original = (textStorage.string as NSString).substring(with: range)
    autocompleteController.requestRewrite(
      context: RewriteContext(
        text: original,
        rangeLocation: range.location,
        rangeLength: range.length,
        documentRevision: documentRevision),
      intent: intent)
  }

  @discardableResult
  private func acceptRewritePreview() -> Bool {
    guard let preview = autocompleteController.rewritePreview,
      preview.documentRevision == documentRevision,
      NSMaxRange(preview.replacementRange) <= textStorage.length,
      (textStorage.string as NSString).substring(with: preview.replacementRange)
        == preview.original,
      let candidate = autocompleteController.candidateForRewriteAcceptance(preview)
    else {
      autocompleteController.cancelRewrite()
      return false
    }
    textView.insertText(preview.proposed, replacementRange: preview.replacementRange)
    let appliedRange = NSRange(
      location: preview.replacementRange.location,
      length: (preview.proposed as NSString).length)
    guard NSMaxRange(appliedRange) <= textStorage.length,
      (textStorage.string as NSString).substring(with: appliedRange) == preview.proposed
    else {
      autocompleteController.cancelRewrite()
      return false
    }
    autocompleteController.commitAppliedRewrite(candidate)
    textContentStorage.refreshHighlighting()
    return true
  }

  private func currentParagraphRange(at caret: Int) -> NSRange {
    let text = textStorage.string as NSString
    guard text.length > 0 else { return NSRange(location: 0, length: 0) }
    let safeCaret = min(max(caret, 0), max(text.length - 1, 0))
    var start = 0
    var end = 0
    var contentsEnd = 0
    text.getParagraphStart(
      &start,
      end: &end,
      contentsEnd: &contentsEnd,
      for: NSRange(location: safeCaret, length: 0))
    return NSRange(location: start, length: contentsEnd - start)
  }

  func textView(
    _ changedTextView: NSTextView,
    shouldChangeTextIn affectedCharRange: NSRange,
    replacementString: String?
  ) -> Bool {
    guard changedTextView === textView else { return true }
    guard !isApplyingExternalText else { return true }
    invalidateAutocomplete()
    guard textContentStorage.syntaxHighlightingEnabled else { return true }
    guard let replacementString else { return true }
    guard
      let conversion = MarkdownFormatter.autoconversion(
        in: textStorage.string,
        range: affectedCharRange,
        replacement: replacementString
      )
    else {
      return true
    }

    guard NSMaxRange(conversion.range) <= (textStorage.string as NSString).length else {
      return true
    }
    textStorage.replaceCharacters(in: conversion.range, with: conversion.replacement)
    textContentStorage.refreshHighlighting()
    textView.setSelectedRange(conversion.selectedRange)
    centerCaretLineIfNeeded()
    textView.didChangeText()
    return false
  }

  func textViewDidChangeSelection(_ notification: Notification) {
    guard let changedTextView = notification.object as? NSTextView, changedTextView === textView
    else { return }
    if textView.selectedRange().length > 0 {
      textView.showFormattingPopover()
    } else {
      textView.hideFormattingPopover()
    }
    let currentSelection = textView.selectedRange()
    if currentSelection != lastTextChangeSelection {
      dismissAutocompleteSuggestion()
    }
    lastTextChangeSelection = nil
    centerCaretLineIfNeeded()
    notifySelectionChanged()
  }

  func centerCaretLineIfNeeded() {
    guard typewriterScrollEnabled else { return }

    let textLength = (textStorage.string as NSString).length
    let selection = textView.selectedRange()
    let location = min(max(selection.location, 0), textLength)

    // Typewriter holds steady WHILE typing on a line and re-centers only when
    // the caret's logical line changes. The old guard assumed the caret-glyph
    // midY is stable for same-line typing — it is NOT (firstRect wobbles a
    // fraction of a line on each character), so the document jumped on every
    // keystroke in Focus mode. Anchoring on the newline-count line makes a
    // same-line edit physically unable to re-center.
    let caretLine = lineIndex(forUTF16Offset: location)
    if caretLine == lastCenteredLine { return }
    lastCenteredLine = caretLine

    let range = NSRange(location: location, length: 0)
    var actualRange = NSRange(location: NSNotFound, length: 0)
    let screenRect = textView.firstRect(forCharacterRange: range, actualRange: &actualRange)
    guard screenRect != .zero else {
      textView.scrollRangeToVisible(range)
      return
    }

    let caretRect: NSRect
    if let window = textView.window {
      caretRect = textView.convert(window.convertFromScreen(screenRect), from: nil)
    } else {
      caretRect = screenRect
    }

    let visible = scrollView.contentView.bounds
    let documentHeight = max(textView.bounds.height, visible.height)
    let targetY = Self.centeredScrollY(
      caretMidY: caretRect.midY,
      visibleHeight: visible.height,
      documentHeight: documentHeight
    )
    // Secondary no-op: on a genuine line change, still skip a sub-pixel scroll.
    // The PRIMARY same-line guard is the logical-line check at the top —
    // caretMidY from firstRect is NOT stable across same-line edits, so this
    // tolerance alone let the document JUMP on every keystroke in Focus mode.
    guard abs(targetY - visible.origin.y) > 0.5 else { return }
    scrollView.contentView.scroll(to: NSPoint(x: visible.origin.x, y: targetY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
  }

  /// Logical line index = number of PARAGRAPH SEPARATORS before `offset`.
  /// Layout-free and stable across same-line horizontal edits — the property the
  /// typewriter re-center guard needs and the caret-glyph rect does not have.
  ///
  /// Two things were wrong with the walk this replaces.
  ///
  /// It rescanned from offset 0 on EVERY call. `updateGutterCurrentLine` runs it
  /// from `notifySelectionChanged` and again, unconditionally, from `update(…)`
  /// on every SwiftUI pass — twice per keystroke — and Focus mode's
  /// `centerCaretLineIfNeeded` makes three. Measured in a debug test build,
  /// 200 caret moves on a 1.08 MB document cost 1436 ms through this method
  /// (~7 ms a call), i.e. 14–21 ms of main thread per keystroke purely to move a
  /// gutter marker; the bare counting loop alone is 4.1 ms. It is now anchored: a caret
  /// move counts separators only over the span between the last resolved
  /// position and this one, which for typing on one line is nothing at all.
  ///
  /// And it counted 0x0A alone, while the gutter numbers one row per
  /// `NSTextLayoutFragment`. Measured on a real `NSTextLayoutManager` in this
  /// package, `"alpha\rbeta\rgamma"` is THREE fragments and U+2029 likewise,
  /// both of which the old count read as line 0. Nothing normalises line endings
  /// on load — `DocumentStore.loadClean` reads the bytes as they are — so a
  /// CR-only file put the whole document on line 1.
  ///
  /// The separator set is the measured one, not the intuitive one: U+2028,
  /// U+0085, U+000B and U+000C each yield ONE fragment in the same harness, so
  /// none of them starts a row here. See `EditorLineResolverTests`, which
  /// asserts this against the layout manager rather than against a list.
  func lineIndex(forUTF16Offset offset: Int) -> Int {
    let ns = textStorage.string as NSString
    let clamped = min(max(offset, 0), ns.length)
    if lineAnchorOffset > ns.length {
      resetLineAnchor()
    }

    if clamped >= lineAnchorOffset {
      let scan = Self.paragraphSeparators(in: ns, from: lineAnchorOffset, to: clamped)
      lineAnchorLine += scan.count
      // Park the anchor on the START of the line the caret landed on. A caret
      // position would be lost by the very next backspace (which edits at
      // caret-1, i.e. BELOW the anchor); a line start survives every edit on
      // that line, which is what typing is.
      if let lineStart = scan.lastSeparatorEnd {
        lineAnchorOffset = lineStart
      }
    } else {
      let scan = Self.paragraphSeparators(in: ns, from: clamped, to: lineAnchorOffset)
      lineAnchorLine = max(0, lineAnchorLine - scan.count)
      // Moving BACKWARDS gives no line start for free — finding one would mean
      // scanning back from `clamped`, which is the walk being removed. The
      // caret offset is a perfectly valid anchor, just a more fragile one.
      lineAnchorOffset = clamped
    }
    return lineAnchorLine
  }

  private func resetLineAnchor() {
    lineAnchorOffset = 0
    lineAnchorLine = 0
  }

  /// Drops the anchor when an edit landed BELOW it. At or above it, the text in
  /// `[0, lineAnchorOffset)` is untouched and the anchor still answers correctly.
  private func invalidateLineAnchor(editedAt location: Int) {
    guard lineAnchorOffset > location else { return }
    resetLineAnchor()
  }

  struct ParagraphSeparatorScan {
    let count: Int
    /// Offset just past the LAST separator in the window, i.e. the start of the
    /// line the window ends on. `nil` when the window crossed none.
    let lastSeparatorEnd: Int?
  }

  /// Counts the paragraph separators in `[start, end)`.
  ///
  /// CR, LF and CRLF, plus U+2029. CRLF is ONE separator, not two — see the
  /// fragment counts in `EditorLineResolverTests`.
  static func paragraphSeparators(in string: NSString, from start: Int, to end: Int)
    -> ParagraphSeparatorScan
  {
    guard end > start, start >= 0, end <= string.length else {
      return ParagraphSeparatorScan(count: 0, lastSeparatorEnd: nil)
    }
    var count = 0
    var lastSeparatorEnd: Int?
    var index = start
    // A window opening ON the LF of a CRLF would count the pair a second time:
    // the CR that owns it sits just outside, and already counted it.
    if index > 0, string.character(at: index) == 0x0A,
      string.character(at: index - 1) == 0x0D
    {
      index += 1
    }
    while index < end {
      let unit = string.character(at: index)
      if unit == 0x0D {
        count += 1
        if index + 1 < string.length, string.character(at: index + 1) == 0x0A {
          index += 1
        }
        lastSeparatorEnd = index + 1
      } else if unit == 0x0A || unit == 0x2029 {
        count += 1
        lastSeparatorEnd = index + 1
      }
      index += 1
    }
    return ParagraphSeparatorScan(count: count, lastSeparatorEnd: lastSeparatorEnd)
  }

  static func centeredScrollY(
    caretMidY: CGFloat,
    visibleHeight: CGFloat,
    documentHeight: CGFloat
  ) -> CGFloat {
    guard visibleHeight > 0, documentHeight > visibleHeight else { return 0 }
    let maxY = documentHeight - visibleHeight
    let centeredY = caretMidY - (visibleHeight / 2)
    return min(max(centeredY, 0), maxY)
  }

  @discardableResult
  func applyMarkdownFormat(_ format: MarkdownFormat) -> Bool {
    let range = textView.selectedRange()
    guard range.length > 0 else { return false }
    guard NSMaxRange(range) <= (textStorage.string as NSString).length else { return false }

    guard
      let edit = MarkdownFormatter.formatSelection(
        in: textStorage.string,
        range: range,
        as: format)
    else { return false }
    guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else {
      return false
    }

    textStorage.replaceCharacters(in: edit.range, with: edit.replacement)
    textContentStorage.refreshHighlighting()
    textView.setSelectedRange(edit.selectedRange)
    textView.didChangeText()
    textView.hideFormattingPopover()
    return true
  }

  @discardableResult
  func applyMarkdownCommand(_ command: MarkdownFormatCommand) -> Bool {
    switch command.action {
    case .format(let format):
      return applyMarkdownFormat(format)
    case .tidyTable(let asciiSafe):
      return tidyTable(asciiSafe: asciiSafe)
    }
  }

  @discardableResult
  func tidyTable(asciiSafe: Bool) -> Bool {
    let storageString = textStorage.string as NSString
    let selectedRange = textView.selectedRange()
    let range =
      selectedRange.length > 0
      ? selectedRange
      : NSRange(location: 0, length: storageString.length)
    guard NSMaxRange(range) <= storageString.length else { return false }

    let target = storageString.substring(with: range)
    guard TableNormalizer.containsTableSmell(target) else { return false }

    let replacement = TableNormalizer.normalize(target, asciiSafe: asciiSafe)
    guard replacement != target else { return false }
    guard textView.shouldChangeText(in: range, replacementString: replacement) else { return false }

    textStorage.replaceCharacters(in: range, with: replacement)
    textContentStorage.refreshHighlighting()
    textView.setSelectedRange(
      NSRange(location: range.location, length: (replacement as NSString).length))
    textView.didChangeText()
    return true
  }

  enum FindDirection {
    case forward
    case backward
  }

  func updateFind(query: String, visible: Bool) {
    isFindBarVisible = visible
    guard visible, !query.isEmpty else {
      findQuery = ""
      clearFindHighlights()
      return
    }

    // Unchanged query with matches already computed: the highlights are on
    // screen. SwiftUI routes every render pass through here, and re-applying
    // thousands of attributes per pass is a main-thread hang on big documents.
    guard query != findQuery || findMatches.isEmpty else { return }

    findQuery = query
    refreshFindMatches()
  }

  /// Repaints the CACHED find matches after something else wiped the document's
  /// `.backgroundColor` (a theme switch, a font-size change, a syntax-highlight
  /// toggle — all of which run a full highlight refresh). Idempotent, and a
  /// no-op when no find session is live, so it never costs a keystroke.
  ///
  /// Match ranges are validated against the current text first: the caller may
  /// sit in the same update pass that is about to replace the document, and
  /// painting a stale range past the end of the storage would raise. Skipping is
  /// safe — the text change reaches `refreshFindMatches` on its own.
  func reapplyFindHighlights() {
    guard !findMatches.isEmpty else { return }
    let length = textStorage.length
    guard findMatches.allSatisfy({ NSMaxRange($0) <= length }) else { return }
    applyFindHighlights()
  }

  /// The same repaint, restricted to the matches a PARTIAL highlight pass
  /// touched.
  ///
  /// The deferred retheme sweep repaints the document one chunk per frame, and
  /// every chunk resets `.backgroundColor` over its own range. Repainting the
  /// whole cached match set on each of those chunks would be quadratic on a
  /// document with many matches, so only the matches intersecting the painted
  /// range are put back — which is exactly the set that just lost its wash.
  func reapplyFindHighlights(in range: NSRange) {
    guard !findMatches.isEmpty else { return }
    let length = textStorage.length
    guard findMatches.allSatisfy({ NSMaxRange($0) <= length }) else { return }
    let touched = findMatches.enumerated().filter {
      NSIntersectionRange($0.element, range).length > 0
    }
    guard !touched.isEmpty else { return }

    // The highlighter just repainted `range`, so the ink snapshot for it is
    // stale AND the colour sitting there now is the correct one — drop the old
    // entries before capturing fresh ones underneath the wash.
    inkUnderFindWashes.removeAll { NSIntersectionRange($0.range, range).length > 0 }

    textStorage.beginEditing()
    let palette = Self.findWashes(for: activeTokens)
    for (index, match) in touched {
      paintFindWash(over: match, isActive: index == activeFindMatchIndex, palette: palette)
    }
    textStorage.endEditing()
  }

  func clearFindHighlights() {
    removeFindHighlights()
    findMatches = []
    activeFindMatchIndex = nil
    notifyFindStateChanged()
  }

  func selectFindMatch(direction: FindDirection) {
    guard !findQuery.isEmpty else { return }
    if findMatches.isEmpty {
      refreshFindMatches()
    }
    guard !findMatches.isEmpty else { return }

    let selectedLocation = textView.selectedRange().location
    let nextIndex: Int
    switch direction {
    case .forward:
      if let activeFindMatchIndex {
        nextIndex = (activeFindMatchIndex + 1) % findMatches.count
      } else {
        nextIndex =
          findMatches.firstIndex { $0.location >= selectedLocation }
          ?? 0
      }
    case .backward:
      if let activeFindMatchIndex {
        nextIndex = (activeFindMatchIndex - 1 + findMatches.count) % findMatches.count
      } else {
        nextIndex =
          findMatches.lastIndex { $0.location < selectedLocation }
          ?? (findMatches.count - 1)
      }
    }

    activeFindMatchIndex = nextIndex
    let range = findMatches[nextIndex]
    textView.setSelectedRange(range)
    textView.scrollRangeToVisible(range)
    applyFindHighlights()
    notifyFindStateChanged()
  }

  func replaceCurrentFindMatch(query: String, replacement: String) {
    updateFind(query: query, visible: true)
    if activeFindMatchIndex == nil {
      selectFindMatch(direction: .forward)
    }
    guard let activeFindMatchIndex, findMatches.indices.contains(activeFindMatchIndex) else {
      return
    }

    let range = findMatches[activeFindMatchIndex]
    guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
    removeFindHighlights()
    textStorage.replaceCharacters(in: range, with: replacement)
    textContentStorage.refreshHighlighting()
    textView.setSelectedRange(
      NSRange(location: range.location, length: (replacement as NSString).length))
    textView.didChangeText()
    refreshFindMatches()
    selectFindMatch(direction: .forward)
  }

  func replaceAllFindMatches(query: String, replacement: String) {
    updateFind(query: query, visible: true)
    guard !findMatches.isEmpty else { return }

    let fullRange = NSRange(location: 0, length: (textStorage.string as NSString).length)
    let mutable = NSMutableString(string: textStorage.string)
    var replaced = false
    for range in findMatches.reversed() {
      mutable.replaceCharacters(in: range, with: replacement)
      replaced = true
    }
    guard replaced else { return }
    let newText = mutable as String
    guard textView.shouldChangeText(in: fullRange, replacementString: newText) else { return }
    removeFindHighlights()
    textStorage.replaceCharacters(in: fullRange, with: newText)
    textContentStorage.refreshHighlighting()
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    textView.didChangeText()
    refreshFindMatches()
  }

  func selectedTextForFind() -> String {
    let range = textView.selectedRange()
    guard range.length > 0, NSMaxRange(range) <= (textStorage.string as NSString).length else {
      return ""
    }
    return (textStorage.string as NSString).substring(with: range)
  }

  private func refreshFindMatches() {
    removeFindHighlights()
    guard !findQuery.isEmpty else {
      findMatches = []
      activeFindMatchIndex = nil
      return
    }

    let haystack = textStorage.string as NSString
    var ranges: [NSRange] = []
    var searchRange = NSRange(location: 0, length: haystack.length)
    while searchRange.length > 0 {
      let found = haystack.range(
        of: findQuery,
        options: [.caseInsensitive, .diacriticInsensitive],
        range: searchRange
      )
      guard found.location != NSNotFound, found.length > 0 else { break }
      ranges.append(found)
      let nextLocation = found.location + found.length
      searchRange = NSRange(location: nextLocation, length: haystack.length - nextLocation)
    }
    findMatches = ranges
    if let activeFindMatchIndex, !findMatches.indices.contains(activeFindMatchIndex) {
      self.activeFindMatchIndex = nil
    }
    applyFindHighlights()
    notifyFindStateChanged()
  }

  private func applyFindHighlights() {
    // One edit transaction for the whole pass: each unbatched addAttribute is
    // its own TextKit transaction with a layout invalidation, so a common
    // query on a large document (thousands of matches) beachballed the main
    // thread once per match.
    textStorage.beginEditing()
    removeFindHighlights()
    let palette = Self.findWashes(for: activeTokens)
    for (index, range) in findMatches.enumerated() {
      paintFindWash(over: range, isActive: index == activeFindMatchIndex, palette: palette)
    }
    textStorage.endEditing()
  }

  /// Clear, high-contrast find shading: every match gets a yellow wash so it is
  /// obvious in the document, and the active match an orange one so it stands
  /// out from the rest of the hits.
  ///
  /// The one place a wash is written, so the full repaint and the per-chunk one
  /// can never disagree about what a match looks like. Caller owns the edit
  /// transaction and supplies the resolved palette, so the contrast arithmetic
  /// runs once per pass rather than once per match.
  private func paintFindWash(over range: NSRange, isActive: Bool, palette: FindWashPalette) {
    let wash = isActive ? palette.active : palette.passive
    // Capture what the highlighter had put here BEFORE the wash ink covers it,
    // so a teardown can give it back without re-running a highlight pass.
    textStorage.enumerateAttribute(.foregroundColor, in: range, options: []) {
      value, subrange, _ in
      inkUnderFindWashes.append((subrange, value as? NSColor))
    }
    textStorage.addAttribute(.backgroundColor, value: wash.background, range: range)
    textStorage.addAttribute(.foregroundColor, value: wash.foreground, range: range)
  }

  /// Puts the highlighter's own `.foregroundColor` back under every wash this
  /// surface painted, then forgets them.
  ///
  /// Ranges are validated against the CURRENT length: a teardown can follow a
  /// text change that shortened the document, and painting past the end raises.
  private func restoreInkUnderFindWashes() {
    guard !inkUnderFindWashes.isEmpty else { return }
    let length = textStorage.length
    for entry in inkUnderFindWashes where NSMaxRange(entry.range) <= length {
      if let color = entry.color {
        textStorage.addAttribute(.foregroundColor, value: color, range: entry.range)
      } else {
        textStorage.removeAttribute(.foregroundColor, range: entry.range)
      }
    }
    inkUnderFindWashes.removeAll(keepingCapacity: true)
  }

  /// A find wash and the ink that has to stay readable on it.
  struct FindWash: Equatable {
    let background: NSColor
    let foreground: NSColor
  }

  struct FindWashPalette: Equatable {
    let passive: FindWash
    let active: FindWash
  }

  /// The washes stay on the system accents rather than theme tokens: a find hit
  /// should read as a find hit in every skin, and stay distinguishable from the
  /// theme's own `==mark==` wash, which is a different statement about the text.
  /// The SKIN then decides the ink that goes on top.
  static let passiveFindWash = NSColor.systemYellow.withAlphaComponent(0.50)
  static let activeFindWash = NSColor.systemOrange.withAlphaComponent(0.80)

  /// Resolves both washes for a skin.
  ///
  /// The washes used to be written as `.backgroundColor` alone, leaving the
  /// foreground on whatever the highlighter had painted. Measured on this
  /// machine, that put Graphite's body ink at 2.15:1 on the active match's
  /// composited orange and 2.96:1 on the passive yellow, and Ink's at 2.40:1
  /// active — all under the repo's own `ThemeContrast.minimumTextContrast` of 3.
  /// A dark skin's find results were the hardest text in the document to read.
  ///
  /// Resolved per pass rather than cached because the adaptive skins carry LIVE
  /// semantic colours: a cached answer would freeze whichever appearance was
  /// current when it was built. That is also why there is no `tokens.mode`
  /// guard here — unlike the highlighter's colour caches, nothing outlives the
  /// pass.
  static func findWashes(for tokens: ThemeTokens) -> FindWashPalette {
    FindWashPalette(
      passive: FindWash(
        background: passiveFindWash,
        foreground: findWashInk(on: passiveFindWash, tokens: tokens)),
      active: FindWash(
        background: activeFindWash,
        foreground: findWashInk(on: activeFindWash, tokens: tokens)))
  }

  /// Ink for `wash` over the skin's source surface: the theme's body text when
  /// it carries the composited wash, otherwise the theme's `source` — the far
  /// pole of the SAME palette, so the match reads as an inverted stamp. Two
  /// tokens from one theme, never an invented per-theme hex: the shape
  /// `SyntaxHighlighter.legibleHighlightText` and `CodeBlockHighlighter`'s
  /// accent guard already use.
  static func findWashInk(on wash: NSColor, tokens: ThemeTokens) -> NSColor {
    let surface = compositedFindWash(wash, over: tokens.source.nsColor)
    let text = tokens.text.nsColor
    if ThemeContrast.isLegible(text, on: surface) { return text }

    let source = tokens.source.nsColor
    // Neither pole proven legible (an unmeasurable pattern colour, say): take
    // whichever measures better, and keep the body ink when nothing measures.
    guard let textRatio = ThemeContrast.ratio(text, surface),
      let sourceRatio = ThemeContrast.ratio(source, surface)
    else { return text }
    return sourceRatio > textRatio ? source : text
  }

  /// `wash` composited over an opaque `surface`. The wash is translucent, so
  /// measuring ink against the wash alone would answer a question nobody asked —
  /// what the operator looks at is the blend.
  static func compositedFindWash(_ wash: NSColor, over surface: NSColor) -> NSColor {
    guard let top = wash.usingColorSpace(.sRGB),
      let bottom = surface.usingColorSpace(.sRGB)
    else { return wash }
    let alpha = top.alphaComponent
    func blend(_ over: CGFloat, _ under: CGFloat) -> CGFloat {
      over * alpha + under * (1 - alpha)
    }
    return NSColor(
      srgbRed: blend(top.redComponent, bottom.redComponent),
      green: blend(top.greenComponent, bottom.greenComponent),
      blue: blend(top.blueComponent, bottom.blueComponent),
      alpha: 1)
  }

  private func removeFindHighlights() {
    // Find highlights only exist when there are matches. Skip the whole-document
    // attribute mutation when there is nothing to remove: this ran on EVERY
    // keystroke (textDidChange -> refreshFindMatches) AND every SwiftUI re-render
    // (updateNSView -> updateFind -> clearFindHighlights), and a full-range
    // removeAttribute forces a TextKit2 relayout of the visible viewport — the
    // per-keystroke "text reflows/jumps at a fixed scroll origin" bug, which is
    // independent of syntax highlighting (hence disabling rich markdown never
    // helped).
    // The washes co-write `.foregroundColor` — a wash the body ink cannot carry
    // would otherwise hide exactly what it marks — so taking them down has to
    // give the highlighter's own colour back. Unconditional: the ink outlives a
    // match set that has already been emptied.
    restoreInkUnderFindWashes()
    guard !findMatches.isEmpty else { return }
    let fullRange = NSRange(location: 0, length: textStorage.length)
    textStorage.removeAttribute(.backgroundColor, range: fullRange)
  }

  /// Push the current match total + active index up to the UI (FindBar count),
  /// deduped so a re-render with unchanged find state never loops the binding.
  private func notifyFindStateChanged() {
    if hasNotifiedFindState,
      lastNotifiedFindCount == findMatches.count,
      lastNotifiedFindActiveIndex == activeFindMatchIndex
    {
      return
    }
    hasNotifiedFindState = true
    lastNotifiedFindCount = findMatches.count
    lastNotifiedFindActiveIndex = activeFindMatchIndex
    onFindStateChanged?(findMatches.count, activeFindMatchIndex)
  }
}
