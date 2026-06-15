import AppKit
import Combine
import SwiftUI

struct EditorView: View {
  @EnvironmentObject private var appState: AppState
  @EnvironmentObject private var controller: AppController

  var body: some View {
    VStack(spacing: 0) {
      if appState.findBarVisible {
        FindBar()
      }

      EditorRepresentable(
        text: documentText,
        editorMode: appState.mode,
        fontSize: appState.fontSize,
        syntaxHighlightingEnabled: appState.richMarkdownEnabled,
        formattingCommand: appState.pendingMarkdownFormatCommand,
        findQuery: $appState.findQuery,
        findReplacement: $appState.findReplaceQuery,
        findBarVisible: appState.findBarVisible,
        findCommand: appState.pendingFindCommand,
        tableTidyOnPaste: appState.tableTidyOnPaste,
        asciiSafeTables: appState.asciiSafeTables,
        aiAutocompleteEnabled: appState.aiAutocompleteEnabled,
        isDirty: documentDirty,
        onDocumentChanged: controller.documentDidChange,
        onCloseFindBar: closeFindBar,
        onFindStateChanged: { total, active in
          appState.findMatchCount = total
          appState.findActiveMatchIndex = active
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
    }
    .background(Color(NSColor.textBackgroundColor))
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
  let syntaxHighlightingEnabled: Bool
  let formattingCommand: MarkdownFormatCommand?
  @Binding var findQuery: String
  @Binding var findReplacement: String
  let findBarVisible: Bool
  let findCommand: FindBarCommand?
  let tableTidyOnPaste: Bool
  let asciiSafeTables: Bool
  let aiAutocompleteEnabled: Bool
  @Binding var isDirty: Bool
  let onDocumentChanged: @MainActor () -> Void
  let onCloseFindBar: @MainActor () -> Void
  // Defaults to a no-op so find-navigation tests that build the representable
  // directly need not wire the count callback they do not exercise.
  var onFindStateChanged: @MainActor (Int, Int?) -> Void = { _, _ in }

  func makeNSView(context: Context) -> NSScrollView {
    let surface = MarkdownEditorSurface(
      text: text,
      fontSize: fontSize,
      syntaxHighlightingEnabled: syntaxHighlightingEnabled,
      tableTidyOnPaste: tableTidyOnPaste,
      asciiSafeTables: asciiSafeTables,
      aiAutocompleteEnabled: aiAutocompleteEnabled
    )
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
    surface.typewriterScrollEnabled = editorMode == .focus
    context.coordinator.surface = surface
    return surface.scrollView
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let surface = context.coordinator.surface else { return }
    // Pin the scroll position across SwiftUI re-renders. The per-window state bridge fires
    // objectWillChange on every keystroke, re-laying out this representable; without this the
    // clip view re-scrolls to the caret each time ("the screen goes wild on every letter").
    // A genuine text change (document load) is allowed to scroll; a pure re-render keeps the
    // viewport where the user left it — caret only moves scroll when typing pushes it past
    // the edge, which AppKit already did before this re-render ran.
    let textUnchanged = surface.textStorage.string == text
    let savedOrigin = scroll.contentView.bounds.origin
    surface.typewriterScrollEnabled = editorMode == .focus
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
    if let selectedText = context.coordinator.applyFind(
      findCommand,
      to: surface,
      query: findQuery,
      replacement: findReplacement
    ) {
      findQuery = selectedText
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  final class Coordinator {
    var surface: MarkdownEditorSurface?
    private var lastAppliedFormattingCommandID: UUID?
    private var lastAppliedFindCommandID: UUID?

    func apply(_ command: MarkdownFormatCommand?, to surface: MarkdownEditorSurface) {
      guard let command else { return }
      guard command.id != lastAppliedFormattingCommandID else { return }
      lastAppliedFormattingCommandID = command.id
      surface.applyMarkdownCommand(command)
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
  var typewriterScrollEnabled = false
  var isApplyingExternalText = false
  private var aiAutocompleteEnabled: Bool
  private var autocompleteCancellable: AnyCancellable?
  private var autocompleteRenderGeneration: UInt64 = 0
  private var lastTextChangeSelection: NSRange?
  private var findQuery = ""
  private var findMatches: [NSRange] = []
  private var activeFindMatchIndex: Int?
  private var isFindBarVisible = false
  private var hasNotifiedFindState = false
  private var lastNotifiedFindCount = -1
  private var lastNotifiedFindActiveIndex: Int?
  private var lastPostedEditorBlock: Int?
  private var lastPreviewAppliedBlock: Int?

  init(
    text: String,
    fontSize: CGFloat,
    syntaxHighlightingEnabled: Bool = true,
    tableTidyOnPaste: Bool = true,
    asciiSafeTables: Bool = false,
    aiAutocompleteEnabled: Bool = false,
    autocompleteController: AutocompleteController = AutocompleteController()
  ) {
    textLayoutManager = NSTextLayoutManager()
    textContentStorage = MarkdownTextStorage()
    textStorage = NSTextStorage()
    self.autocompleteController = autocompleteController
    self.aiAutocompleteEnabled = aiAutocompleteEnabled
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
    textView.textContainerInset = NSSize(width: 12, height: 10)

    scrollView.documentView = textView
    textView.setupGutter(layoutManager: textLayoutManager)
    textView.tableTidyOnPaste = tableTidyOnPaste
    textView.asciiSafeTables = asciiSafeTables

    super.init()

    textView.delegate = self
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
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(editorBoundsDidChange),
      name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handlePreviewViewportChanged(_:)),
      name: .vcPreviewViewportChanged,
      object: nil
    )
    update(
      text: text,
      fontSize: fontSize,
      syntaxHighlightingEnabled: syntaxHighlightingEnabled,
      tableTidyOnPaste: tableTidyOnPaste,
      asciiSafeTables: asciiSafeTables
    )
  }

  func update(
    text: String,
    fontSize: CGFloat,
    syntaxHighlightingEnabled: Bool,
    tableTidyOnPaste: Bool = true,
    asciiSafeTables: Bool = false,
    aiAutocompleteEnabled: Bool = false,
    findQuery: String = "",
    findBarVisible: Bool = false
  ) {
    textView.tableTidyOnPaste = tableTidyOnPaste
    textView.asciiSafeTables = asciiSafeTables
    setAIAutocompleteEnabled(aiAutocompleteEnabled)

    if textContentStorage.syntaxHighlightingEnabled != syntaxHighlightingEnabled {
      textContentStorage.syntaxHighlightingEnabled = syntaxHighlightingEnabled
    }

    if textContentStorage.fontSize != fontSize {
      textContentStorage.fontSize = fontSize
      let baseFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
      textView.font = baseFont
      // Keep typing attributes in lockstep with the base font so newly typed text renders in
      // the monospaced face immediately (no system-font flash before the highlight pass).
      textView.typingAttributes = [.font: baseFont, .foregroundColor: NSColor.textColor]
      textView.gutter?.fontSize = fontSize
      textView.gutter?.needsDisplay = true
    }

    if textStorage.string != text {
      isApplyingExternalText = true
      invalidateAutocomplete()
      // A model→view text re-sync must NOT yank the viewport to the caret. Preserve the
      // caret + scroll across the full re-apply so a re-render never resets selection to 0
      // and scrolls there (the "screen goes wild on every letter" regression).
      let savedSelection = textView.selectedRange()
      let savedOrigin = scrollView.contentView.bounds.origin
      textStorage.replaceCharacters(
        in: NSRange(location: 0, length: textStorage.length), with: text)
      textContentStorage.refreshHighlighting()
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
    postEditorViewportIfNeeded()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func textDidChange(_ notification: Notification) {
    guard !isApplyingExternalText else { return }
    guard let changedTextView = notification.object as? NSTextView, changedTextView === textView
    else { return }
    let latestText = textStorage.string
    invalidateAutocomplete()
    onTextChanged?(latestText)
    if aiAutocompleteEnabled {
      lastTextChangeSelection = textView.selectedRange()
      autocompleteController.textDidChange(prefix: autocompletePrefix(from: latestText))
    }
    refreshFindMatches()
    centerCaretLineIfNeeded()
    postEditorViewportIfNeeded()
  }

  private func autocompletePrefix(from text: String) -> String {
    let nsText = text as NSString
    let caret = min(max(textView.selectedRange().location, 0), nsText.length)
    return nsText.substring(to: caret)
  }

  private func bindAutocomplete() {
    autocompleteCancellable = autocompleteController.$suggestion
      .receive(on: DispatchQueue.main)
      .sink { [weak self] suggestion in
        self?.scheduleAutocompleteRender(suggestion)
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
    guard aiAutocompleteEnabled, selection.length == 0, let suggestion, !suggestion.isEmpty else {
      textView.dismissAutocompleteGhost()
      return
    }
    let caret = selection.location
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      guard self.aiAutocompleteEnabled,
        self.autocompleteRenderGeneration == renderGeneration,
        self.textView.selectedRange() == selection
      else { return }
      self.textView.setAutocompleteGhost(suggestion, at: caret)
    }
  }

  @discardableResult
  func acceptAutocompleteSuggestion() -> Bool {
    guard let suggestion = textView.autocompleteGhostText, !suggestion.isEmpty else { return false }
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

    autocompleteController.cancel()
    textView.dismissAutocompleteGhost()
    textStorage.replaceCharacters(in: range, with: suggestion)
    textContentStorage.refreshHighlighting()
    textView.setSelectedRange(
      NSRange(location: range.location + (suggestion as NSString).length, length: 0))
    textView.didChangeText()
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
    postEditorViewportIfNeeded()
  }

  private var isApplyingPreviewScroll = false

  @objc private func editorBoundsDidChange() {
    // Re-entrancy guard (crash fix): handlePreviewViewportChanged scrolls the editor, whose clip-view
    // bounds change fires this SYNCHRONOUSLY; re-posting the editor viewport here recurses back into
    // NSTextView layout (postEditorViewportIfNeeded → currentTopVisibleBlockIndex →
    // characterIndexForInsertion) mid-scroll and crashed with EXC_BAD_ACCESS in objc_msgSend
    // (build 146). Suppress the echo while a preview-driven scroll is applying.
    guard !isApplyingPreviewScroll else { return }
    postEditorViewportIfNeeded()
  }

  @objc private func handlePreviewViewportChanged(_ note: Notification) {
    // DISABLED (P0 crash, builds 146/148): driving the editor's scroll from the preview re-enters
    // TextKit2 layout (scrollRangeToVisible → bounds-change → editorBoundsDidChange →
    // currentTopVisibleBlockIndex → characterIndexForInsertion) and crashes with EXC_BAD_ACCESS in
    // objc_msgSend. Two targeted guards (bbdb719 first-responder, d4aa124 re-entrancy flag) did NOT
    // hold — the crashing layout query also fires from textDidChange / selection paths. Until two-way
    // scroll-sync is re-implemented OFF the layout pass (async/coalesced, never querying layout inside
    // a notification), the preview must NOT move the editor. Panes scroll independently.
    _ = note
  }

  private func postEditorViewportIfNeeded() {
    // DISABLED (P0 crash, builds 146/148): currentTopVisibleBlockIndex() → characterIndexForInsertion
    // triggers TextKit2 viewport layout (a nested scroll) when invoked from a bounds-change / text /
    // selection notification → EXC_BAD_ACCESS. The editor no longer pushes its viewport to the
    // preview; both panes scroll independently. Re-enable only with an async/coalesced, layout-safe
    // top-block computation that never runs characterIndexForInsertion inside a notification.
  }

  private func currentTopVisibleBlockIndex() -> Int? {
    let point = NSPoint(
      x: textView.textContainerInset.width + 1,
      y: scrollView.contentView.bounds.minY + textView.textContainerInset.height + 1
    )
    let rawLocation = textView.characterIndexForInsertion(at: point)
    let maxLocation = (textStorage.string as NSString).length
    return MarkdownBlockMapper.blockIndex(
      atUTF16Location: min(max(rawLocation, 0), maxLocation),
      in: textStorage.string
    )
  }

  func centerCaretLineIfNeeded() {
    guard typewriterScrollEnabled else { return }

    let textLength = (textStorage.string as NSString).length
    let selection = textView.selectedRange()
    let location = min(max(selection.location, 0), textLength)
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
    // IfNeeded (the name was a lie): skip redundant re-centering when the caret line
    // is already at the typewriter target. Without this guard, every keystroke re-issues
    // a ~0px scroll + reflectScrolledClipView, and the document visibly JUMPS on each
    // typed character in Focus mode. Same-line typing keeps caretMidY (→ targetY) stable,
    // so this no-ops; a real vertical caret move (new line, wrap) still re-centers.
    guard abs(targetY - visible.origin.y) > 0.5 else { return }
    scrollView.contentView.scroll(to: NSPoint(x: visible.origin.x, y: targetY))
    scrollView.reflectScrolledClipView(scrollView.contentView)
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

    let selectedText = (textStorage.string as NSString).substring(with: range)
    let replacement = MarkdownFormatter.format(selectedText, as: format)
    guard textView.shouldChangeText(in: range, replacementString: replacement) else { return false }

    textStorage.replaceCharacters(in: range, with: replacement)
    textContentStorage.refreshHighlighting()
    textView.setSelectedRange(
      NSRange(location: range.location, length: (replacement as NSString).length))
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

    guard query != findQuery || findMatches.isEmpty else {
      applyFindHighlights()
      return
    }

    findQuery = query
    refreshFindMatches()
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
    removeFindHighlights()
    // Clear, high-contrast find shading: every match gets a yellow wash so it is
    // obvious in the document, and the active match an orange one so it stands
    // out from the rest of the hits.
    let passiveColor = NSColor.systemYellow.withAlphaComponent(0.50)
    let activeColor = NSColor.systemOrange.withAlphaComponent(0.80)
    for (index, range) in findMatches.enumerated() {
      textStorage.addAttribute(
        .backgroundColor,
        value: index == activeFindMatchIndex ? activeColor : passiveColor,
        range: range
      )
    }
  }

  private func removeFindHighlights() {
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
