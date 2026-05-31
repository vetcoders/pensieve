import AppKit
import SwiftUI

class MarkdownTextView: NSTextView {

  weak var gutter: LineNumberGutter?
  var tableTidyOnPaste = true
  var asciiSafeTables = false
  var onFormatRequest: ((MarkdownFormat) -> Void)?
  var onEscape: (() -> Bool)?
  private let fallbackUndoManager = UndoManager()
  private var formattingPopover: NSPopover?

  override var undoManager: UndoManager? {
    super.undoManager ?? fallbackUndoManager
  }

  override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
    super.init(frame: frameRect, textContainer: container)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    isAutomaticQuoteSubstitutionEnabled = false
    isAutomaticDashSubstitutionEnabled = false
    isAutomaticTextReplacementEnabled = false
    isAutomaticSpellingCorrectionEnabled = false
    allowsUndo = true
    usesFindBar = false
    isRichText = false
  }

  func setupGutter(layoutManager: NSTextLayoutManager) {
    guard let scrollView = enclosingScrollView else { return }
    let newGutter = LineNumberGutter(scrollView: scrollView, textLayoutManager: layoutManager)
    scrollView.verticalRulerView = newGutter
    scrollView.hasVerticalRuler = true
    scrollView.rulersVisible = true
    self.gutter = newGutter

    NotificationCenter.default.addObserver(
      self, selector: #selector(boundsDidChange), name: NSView.boundsDidChangeNotification,
      object: scrollView.contentView)
  }

  @objc private func boundsDidChange() {
    gutter?.needsDisplay = true
  }

  override func layout() {
    super.layout()
    gutter?.needsDisplay = true
  }

  override func paste(_ sender: Any?) {
    guard pasteTableIfNeeded(from: .general) else {
      super.paste(sender)
      return
    }
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53, onEscape?() == true {
      return
    }
    super.keyDown(with: event)
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let menu = super.menu(for: event) ?? NSMenu()
    guard selectedRange().length > 0 else { return menu }

    if menu.items.isEmpty == false {
      menu.addItem(.separator())
    }
    for format in MarkdownFormat.allCases {
      let item = NSMenuItem(
        title: format.label,
        action: #selector(applyMarkdownFormatFromMenu(_:)),
        keyEquivalent: "")
      item.image = NSImage(systemSymbolName: format.systemImageName, accessibilityDescription: nil)
      item.target = self
      item.representedObject = format
      menu.addItem(item)
    }
    return menu
  }

  func showFormattingPopover() {
    guard selectedRange().length > 0, window?.firstResponder === self else { return }
    guard formattingPopover?.isShown != true else { return }

    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = false
    popover.contentSize = NSSize(width: 244, height: 36)
    popover.contentViewController = NSHostingController(
      rootView: MarkdownFloatingFormatBar { [weak self] format in
        self?.applyFloatingFormat(format)
      })
    formattingPopover = popover

    let selection = selectedRange()
    var actualRange = NSRange(location: 0, length: 0)
    let screenRect = firstRect(forCharacterRange: selection, actualRange: &actualRange)
    let localRect: NSRect
    if let window {
      localRect = convert(window.convertFromScreen(screenRect), from: nil)
    } else {
      localRect = visibleRect
    }
    popover.show(relativeTo: localRect, of: self, preferredEdge: .maxY)
  }

  func hideFormattingPopover() {
    formattingPopover?.close()
    formattingPopover = nil
  }

  @discardableResult
  func pasteTableIfNeeded(from pasteboard: NSPasteboard) -> Bool {
    guard tableTidyOnPaste else { return false }
    guard let raw = pasteboard.string(forType: .string) else { return false }
    guard TableNormalizer.containsTableSmell(raw) else { return false }

    let normalized = TableNormalizer.normalize(raw, asciiSafe: asciiSafeTables)
    guard normalized != raw else { return false }

    let insertionRange = selectedRange()
    guard let textStorage, NSMaxRange(insertionRange) <= (textStorage.string as NSString).length
    else {
      return false
    }
    textStorage.replaceCharacters(in: insertionRange, with: normalized)
    setSelectedRange(
      NSRange(location: insertionRange.location + (normalized as NSString).length, length: 0))
    didChangeText()
    registerSmartPasteUndo(location: insertionRange.location, current: normalized, replacement: raw)
    return true
  }

  private func registerSmartPasteUndo(location: Int, current: String, replacement: String) {
    undoManager?.registerUndo(withTarget: self) { target in
      target.replaceSmartPasteText(location: location, current: current, replacement: replacement)
    }
    undoManager?.setActionName("Tidy Table Paste")
  }

  private func replaceSmartPasteText(location: Int, current: String, replacement: String) {
    let currentLength = (current as NSString).length
    let range = NSRange(location: location, length: currentLength)
    guard let textStorage, NSMaxRange(range) <= (textStorage.string as NSString).length else {
      return
    }
    guard (textStorage.string as NSString).substring(with: range) == current else {
      return
    }
    textStorage.replaceCharacters(in: range, with: replacement)
    setSelectedRange(NSRange(location: location + (replacement as NSString).length, length: 0))
    didChangeText()
    registerSmartPasteUndo(location: location, current: replacement, replacement: current)
  }

  @objc private func applyMarkdownFormatFromMenu(_ sender: NSMenuItem) {
    guard let format = sender.representedObject as? MarkdownFormat else { return }
    applyFloatingFormat(format)
  }

  private func applyFloatingFormat(_ format: MarkdownFormat) {
    hideFormattingPopover()
    onFormatRequest?(format)
  }
}

private struct MarkdownFloatingFormatBar: View {
  let apply: (MarkdownFormat) -> Void

  var body: some View {
    HStack(spacing: 2) {
      ForEach(MarkdownFormat.allCases) { format in
        Button {
          apply(format)
        } label: {
          Image(systemName: format.systemImageName)
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(format.label)
        .accessibilityIdentifier(format.floatingAccessibilityIdentifier)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
  }
}

extension MarkdownFormat {
  fileprivate var floatingAccessibilityIdentifier: String {
    switch self {
    case .bold: return "pensieve.editor.floatingFormat.bold"
    case .italic: return "pensieve.editor.floatingFormat.italic"
    case .strike: return "pensieve.editor.floatingFormat.strike"
    case .quote: return "pensieve.editor.floatingFormat.quote"
    case .code: return "pensieve.editor.floatingFormat.code"
    case .link: return "pensieve.editor.floatingFormat.link"
    case .bulletedList: return "pensieve.editor.floatingFormat.bulletedList"
    case .numberedList: return "pensieve.editor.floatingFormat.numberedList"
    }
  }
}
