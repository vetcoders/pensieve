import AppKit

class MarkdownTextView: NSTextView {

  weak var gutter: LineNumberGutter?
  var tableTidyOnPaste = true
  var asciiSafeTables = false
  private let fallbackUndoManager = UndoManager()

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
    usesFindBar = true
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
}
