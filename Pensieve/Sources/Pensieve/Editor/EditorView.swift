import AppKit
import SwiftUI

struct EditorView: View {
  @EnvironmentObject private var appState: AppState
  @EnvironmentObject private var controller: AppController

  var body: some View {
    VStack(spacing: 0) {
      MarkdownFormattingToolbelt { format in
        controller.applyMarkdownFormat(format)
      }

      EditorRepresentable(
        text: documentText,
        fontSize: appState.fontSize,
        syntaxHighlightingEnabled: appState.richMarkdownEnabled,
        formattingCommand: appState.pendingMarkdownFormatCommand,
        tableTidyOnPaste: appState.tableTidyOnPaste,
        asciiSafeTables: appState.asciiSafeTables,
        isDirty: documentDirty,
        onDocumentChanged: controller.documentDidChange
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
}

struct MarkdownFormattingToolbelt: View {
  let apply: (MarkdownFormat) -> Void

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 4) {
        ForEach(MarkdownFormat.allCases) { format in
          Button {
            apply(format)
          } label: {
            Image(systemName: format.systemImageName)
              .frame(width: 22, height: 22)
          }
          .buttonStyle(.borderless)
          .help(format.label)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
    }
    .frame(height: 32)
    .background(Color(NSColor.controlBackgroundColor))
    .overlay(alignment: .bottom) {
      Divider()
    }
  }
}

// MARK: - TextKit bridge

struct EditorRepresentable: NSViewRepresentable {
  @Binding var text: String
  let fontSize: CGFloat
  let syntaxHighlightingEnabled: Bool
  let formattingCommand: MarkdownFormatCommand?
  let tableTidyOnPaste: Bool
  let asciiSafeTables: Bool
  @Binding var isDirty: Bool
  let onDocumentChanged: @MainActor () -> Void

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
    context.coordinator.surface = surface
    return surface.scrollView
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let surface = context.coordinator.surface else { return }
    surface.update(
      text: text,
      fontSize: fontSize,
      syntaxHighlightingEnabled: syntaxHighlightingEnabled,
      tableTidyOnPaste: tableTidyOnPaste,
      asciiSafeTables: asciiSafeTables
    )
    context.coordinator.apply(formattingCommand, to: surface)
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  final class Coordinator {
    var surface: MarkdownEditorSurface?
    private var lastAppliedFormattingCommandID: UUID?

    func apply(_ command: MarkdownFormatCommand?, to surface: MarkdownEditorSurface) {
      guard let command else { return }
      guard command.id != lastAppliedFormattingCommandID else { return }
      lastAppliedFormattingCommandID = command.id
      surface.applyMarkdownCommand(command)
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
  var isApplyingExternalText = false

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
    asciiSafeTables: Bool = false
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
      textStorage.replaceCharacters(
        in: NSRange(location: 0, length: textStorage.length), with: text)
      textContentStorage.refreshHighlighting()
      isApplyingExternalText = false
    }
  }

  func textDidChange(_ notification: Notification) {
    guard !isApplyingExternalText else { return }
    guard let changedTextView = notification.object as? NSTextView, changedTextView === textView
    else { return }
    onTextChanged?(textStorage.string)
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
}
