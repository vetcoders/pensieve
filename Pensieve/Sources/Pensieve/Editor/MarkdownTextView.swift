import AppKit
import SwiftUI

class MarkdownTextView: NSTextView {

  weak var gutter: LineNumberGutter?
  var tableTidyOnPaste = true
  var asciiSafeTables = false
  var onFormatRequest: ((MarkdownFormat) -> Void)?
  var onEscape: (() -> Bool)?
  var onAcceptAutocomplete: (() -> Bool)?
  private let fallbackUndoManager = UndoManager()
  private var autocompleteGhostField: NSTextField?
  private(set) var autocompleteGhostText: String?
  private(set) var autocompleteGhostAnchor: Int?
  // In-window floating accessory (a subview of this text view) — NOT an NSPopover. A popover is a
  // separate key window: showing it makes the text view resign first-responder, so the user had to
  // press Esc before typing/copying again. A non-responder subview in the SAME window never becomes
  // key, so the text view keeps first-responder → no focus theft, no Esc. The bar is also draggable.
  private var formattingAccessory: FloatingFormatBarView?

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

    // Seed the editor's font + typing attributes with the same monospaced base the
    // highlighter applies. Without this, freshly typed text inherits NSTextView's default
    // (proportional system) font and visibly "pops" to monospace only once the debounced
    // highlight pass re-applies attributes — the font-jump the operator saw per keystroke.
    // `EditorRepresentable.update` keeps these in sync when the font size changes.
    let baseFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    font = baseFont
    typingAttributes = [.font: baseFont, .foregroundColor: NSColor.textColor]
  }

  func setupGutter(layoutManager: NSTextLayoutManager) {
    guard let scrollView = enclosingScrollView else { return }
    let newGutter = LineNumberGutter(scrollView: scrollView, textLayoutManager: layoutManager)
    scrollView.verticalRulerView = newGutter
    scrollView.hasVerticalRuler = true
    scrollView.rulersVisible = true
    self.gutter = newGutter

    // Force a FULL gutter redraw on every scroll. Without explicit bounds-change posting the
    // ruler can repaint only a partial dirty rect, leaving stale line numbers behind at the old
    // scroll offset — the doubled/ghosted gutter the operator saw while the viewport jumped.
    scrollView.contentView.postsBoundsChangedNotifications = true
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
    if event.keyCode == 48, onAcceptAutocomplete?() == true {
      return
    }
    if event.keyCode == 53 {
      // Esc dismisses the floating bar too (parity with the old transient popover), without
      // consuming the key event meant for `onEscape` (find-bar / selection clearing).
      hideFormattingPopover()
      if onEscape?() == true {
        return
      }
    }
    super.keyDown(with: event)
  }

  var hasAutocompleteGhost: Bool {
    autocompleteGhostText != nil
  }

  func setAutocompleteGhost(_ suggestion: String, at caretLocation: Int) {
    guard !suggestion.isEmpty else {
      dismissAutocompleteGhost()
      return
    }
    autocompleteGhostText = suggestion
    autocompleteGhostAnchor = caretLocation

    let ghostField = autocompleteGhostField ?? makeAutocompleteGhostField()
    if ghostField.superview !== self {
      addSubview(ghostField)
    }
    ghostField.stringValue = suggestion
    ghostField.font = font ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    ghostField.sizeToFit()
    ghostField.setFrameOrigin(
      autocompleteGhostOrigin(caretLocation: caretLocation, size: ghostField.frame.size))
    autocompleteGhostField = ghostField
  }

  func dismissAutocompleteGhost() {
    autocompleteGhostText = nil
    autocompleteGhostAnchor = nil
    autocompleteGhostField?.removeFromSuperview()
  }

  private func makeAutocompleteGhostField() -> NSTextField {
    let field = NSTextField(labelWithString: "")
    field.isEditable = false
    field.isSelectable = false
    field.drawsBackground = false
    field.isBordered = false
    field.textColor = NSColor.placeholderTextColor
    field.alphaValue = 0.9
    field.lineBreakMode = .byClipping
    field.setAccessibilityIdentifier("pensieve.autocomplete.ghostText")
    return field
  }

  private func autocompleteGhostOrigin(caretLocation: Int, size: NSSize) -> NSPoint {
    let textLength = (textStorage?.string as NSString?)?.length ?? 0
    let location = min(max(caretLocation, 0), textLength)
    let range = NSRange(location: location, length: 0)
    var actualRange = NSRange(location: NSNotFound, length: 0)
    let screenRect = firstRect(forCharacterRange: range, actualRange: &actualRange)
    guard screenRect != .zero else {
      return NSPoint(x: textContainerInset.width, y: textContainerInset.height)
    }

    let localRect: NSRect
    if let window {
      localRect = convert(window.convertFromScreen(screenRect), from: nil)
    } else {
      localRect = screenRect
    }
    let baselineY = localRect.minY + max(0, (localRect.height - size.height) / 2)
    return NSPoint(x: localRect.maxX + 1, y: baselineY)
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
    guard selectedRange().length > 0, window?.firstResponder === self else {
      hideFormattingPopover()
      return
    }

    let selection = selectedRange()
    var actualRange = NSRange(location: 0, length: 0)
    let screenRect = firstRect(forCharacterRange: selection, actualRange: &actualRange)
    // The selection rect lives in this (flipped) text view's own coordinate space; anchoring the
    // accessory there makes it scroll in lockstep with the text, so it never sits over a stale spot.
    let localRect: NSRect
    if let window {
      localRect = convert(window.convertFromScreen(screenRect), from: nil)
    } else {
      localRect = visibleRect
    }

    let accessory =
      formattingAccessory
      ?? FloatingFormatBarView { [weak self] format in
        self?.applyFloatingFormat(format)
      }
    if accessory.superview !== self {
      accessory.removeFromSuperview()
      addSubview(accessory)
    }
    formattingAccessory = accessory

    let size = accessory.fittingBarSize
    accessory.setFrameSize(size)
    accessory.setFrameOrigin(accessoryOrigin(for: localRect, size: size))
  }

  /// Default position near the current selection, clamped into the visible rect. The bar prefers to
  /// sit just above the selection's first line; if there is no room above, it drops below. The user
  /// can drag it from here via the grip.
  private func accessoryOrigin(for selectionRect: NSRect, size: NSSize) -> NSPoint {
    let gap: CGFloat = 6
    let visible = visibleRect
    var y: CGFloat
    if isFlipped {
      y = selectionRect.minY - size.height - gap
      if y < visible.minY { y = selectionRect.maxY + gap }
    } else {
      y = selectionRect.maxY + gap
      if y + size.height > visible.maxY { y = selectionRect.minY - size.height - gap }
    }
    var x = selectionRect.minX
    x = min(max(x, visible.minX + 4), max(visible.minX + 4, visible.maxX - size.width - 4))
    return NSPoint(x: x, y: y)
  }

  func hideFormattingPopover() {
    formattingAccessory?.removeFromSuperview()
    formattingAccessory = nil
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
        .buttonStyle(.plain)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .help(format.label)
        .accessibilityIdentifier(format.floatingAccessibilityIdentifier)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color(NSColor.windowBackgroundColor).opacity(0.96))
    )
  }
}

/// In-window host for the floating format bar. It is a plain `NSView` subview of the text view, so it
/// never becomes the window's key/first-responder — the text view keeps focus while the bar is shown.
/// A leading grip lets the user drag the whole bar to reposition it without intercepting button taps.
private final class FloatingFormatBarView: NSView {
  private let grip = FormatBarGrip()
  private let hostingView: NSHostingView<MarkdownFloatingFormatBar>
  private let gripWidth: CGFloat = 14

  init(apply: @escaping (MarkdownFormat) -> Void) {
    hostingView = NSHostingView(rootView: MarkdownFloatingFormatBar(apply: apply))
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.masksToBounds = false
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.18
    layer?.shadowRadius = 6
    layer?.shadowOffset = .zero
    hostingView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(grip)
    addSubview(hostingView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // Never participate in the responder chain — that is the whole point of not using NSPopover.
  override var acceptsFirstResponder: Bool { false }

  /// Intrinsic size of the SwiftUI bar plus the drag grip.
  var fittingBarSize: NSSize {
    let inner = hostingView.fittingSize
    return NSSize(width: inner.width + gripWidth, height: max(inner.height, 28))
  }

  override func layout() {
    super.layout()
    grip.frame = NSRect(x: 0, y: 0, width: gripWidth, height: bounds.height)
    hostingView.frame = NSRect(
      x: gripWidth, y: 0, width: max(0, bounds.width - gripWidth), height: bounds.height)
  }
}

/// Drag handle drawn as a column of dots. Dragging it moves the parent `FloatingFormatBarView` within
/// its superview (the text view), clamped to the visible rect so the bar cannot be lost off-screen.
private final class FormatBarGrip: NSView {
  private var lastWindowPoint: NSPoint = .zero

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .openHand)
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
    let dot: CGFloat = 2
    let columnX = (bounds.width - dot) / 2
    var y = bounds.midY - (dot * 3 + 4)
    for _ in 0..<3 {
      NSBezierPath(ovalIn: NSRect(x: columnX, y: y, width: dot, height: dot)).fill()
      y += dot + 4
    }
  }

  override func mouseDown(with event: NSEvent) {
    lastWindowPoint = event.locationInWindow
  }

  override func mouseDragged(with event: NSEvent) {
    guard let bar = superview, let canvas = bar.superview else { return }
    let now = event.locationInWindow
    let dx = now.x - lastWindowPoint.x
    let dy = now.y - lastWindowPoint.y
    lastWindowPoint = now

    var origin = bar.frame.origin
    origin.x += dx
    // Window y grows upward; a flipped canvas (NSTextView) grows downward, so invert there.
    origin.y += canvas.isFlipped ? -dy : dy

    let visible = canvas.visibleRect
    origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - bar.frame.width))
    origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - bar.frame.height))
    bar.setFrameOrigin(origin)
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
