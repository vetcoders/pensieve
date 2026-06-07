import AppKit
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
        fontSize: appState.fontSize,
        syntaxHighlightingEnabled: appState.richMarkdownEnabled,
        formattingCommand: appState.pendingMarkdownFormatCommand,
        findQuery: $appState.findQuery,
        findReplacement: $appState.findReplaceQuery,
        findBarVisible: appState.findBarVisible,
        findCommand: appState.pendingFindCommand,
        tableTidyOnPaste: appState.tableTidyOnPaste,
        asciiSafeTables: appState.asciiSafeTables,
        isDirty: documentDirty,
        onDocumentChanged: controller.documentDidChange,
        onCloseFindBar: closeFindBar
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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
  let fontSize: CGFloat
  let syntaxHighlightingEnabled: Bool
  let formattingCommand: MarkdownFormatCommand?
  @Binding var findQuery: String
  @Binding var findReplacement: String
  let findBarVisible: Bool
  let findCommand: FindBarCommand?
  let tableTidyOnPaste: Bool
  let asciiSafeTables: Bool
  @Binding var isDirty: Bool
  let onDocumentChanged: @MainActor () -> Void
  let onCloseFindBar: @MainActor () -> Void

  func makeNSView(context: Context) -> NSScrollView {
    let surface = MarkdownEditorSurface(
      text: text,
      fontSize: fontSize,
      syntaxHighlightingEnabled: syntaxHighlightingEnabled,
      tableTidyOnPaste: tableTidyOnPaste,
      asciiSafeTables: asciiSafeTables
    )
    surface.onTextChanged = { newText in
      self.text = newText
      self.isDirty = true
      self.onDocumentChanged()
    }
    surface.onCloseFindBar = {
      self.onCloseFindBar()
    }
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
    surface.update(
      text: text,
      fontSize: fontSize,
      syntaxHighlightingEnabled: syntaxHighlightingEnabled,
      tableTidyOnPaste: tableTidyOnPaste,
      asciiSafeTables: asciiSafeTables,
      findQuery: findQuery,
      findBarVisible: findBarVisible
    )
    if textUnchanged {
      scroll.contentView.scroll(to: savedOrigin)
      scroll.reflectScrolledClipView(scroll.contentView)
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

  var onTextChanged: ((String) -> Void)?
  var onCloseFindBar: (() -> Void)?
  var isApplyingExternalText = false
  private var findQuery = ""
  private var findMatches: [NSRange] = []
  private var activeFindMatchIndex: Int?
  private var isFindBarVisible = false

  init(
    text: String,
    fontSize: CGFloat,
    syntaxHighlightingEnabled: Bool = true,
    tableTidyOnPaste: Bool = true,
    asciiSafeTables: Bool = false
  ) {
    textLayoutManager = NSTextLayoutManager()
    textContentStorage = MarkdownTextStorage()
    textStorage = NSTextStorage()
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
      guard self?.isFindBarVisible == true else { return false }
      self?.clearFindHighlights()
      self?.onCloseFindBar?()
      return true
    }
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
    findQuery: String = "",
    findBarVisible: Bool = false
  ) {
    textView.tableTidyOnPaste = tableTidyOnPaste
    textView.asciiSafeTables = asciiSafeTables

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
      scrollView.contentView.scroll(to: savedOrigin)
      scrollView.reflectScrolledClipView(scrollView.contentView)
      isApplyingExternalText = false
    }

    updateFind(query: findQuery, visible: findBarVisible)
  }

  func textDidChange(_ notification: Notification) {
    guard !isApplyingExternalText else { return }
    guard let changedTextView = notification.object as? NSTextView, changedTextView === textView
    else { return }
    onTextChanged?(textStorage.string)
    refreshFindMatches()
  }

  func textView(
    _ changedTextView: NSTextView,
    shouldChangeTextIn affectedCharRange: NSRange,
    replacementString: String?
  ) -> Bool {
    guard changedTextView === textView else { return true }
    guard !isApplyingExternalText else { return true }
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
  }

  private func applyFindHighlights() {
    removeFindHighlights()
    let passiveColor = NSColor.controlAccentColor.withAlphaComponent(0.18)
    let activeColor = NSColor.controlAccentColor.withAlphaComponent(0.34)
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
}
