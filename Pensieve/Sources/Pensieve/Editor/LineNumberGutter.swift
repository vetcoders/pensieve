import AppKit

class LineNumberGutter: NSRulerView {
  weak var textLayoutManager: NSTextLayoutManager?

  var fontSize: CGFloat = 14 {
    didSet { needsDisplay = true }
  }

  // Theme colours for the gutter. Defaulted to the previous system colours so a
  // gutter built without a theme keeps the established look. The gutter fill is
  // the editor `source` (not `windowBackgroundColor`) so it stops reading as a
  // separate band beside the text on dark themes. `currentLine` is carried for
  // the active-line marker that lands with the chrome-polish cut; it has no
  // painter yet.
  var gutterBackground: NSColor = .windowBackgroundColor {
    didSet { needsDisplay = true }
  }
  var gutterBorder: NSColor = .separatorColor {
    didSet { needsDisplay = true }
  }
  var gutterNumber: NSColor = .tertiaryLabelColor {
    didSet { needsDisplay = true }
  }
  var gutterCurrentLine: NSColor = .labelColor {
    didSet { needsDisplay = true }
  }

  /// 1-based source line the caret currently sits on, so the gutter can pick out
  /// that number in `gutterCurrentLine` and draw the right-edge accent marker.
  /// `0` means "no active line". `MarkdownEditorSurface` pushes this on selection
  /// changes; only a real line change repaints, so same-line typing stays quiet
  /// (the per-keystroke gutter redraw the scroll pins guard against).
  var currentLineNumber: Int = 0 {
    didSet {
      guard currentLineNumber != oldValue else { return }
      needsDisplay = true
    }
  }

  /// Monospace family the line numbers are drawn in — the theme's own
  /// (`ThemeTokens.monoFamily`), so the gutter cannot read as a different
  /// typeface than the text beside it. Empty (adaptive skins) keeps the system
  /// tabular figures.
  var monoFamily: String = "" {
    didSet {
      guard monoFamily != oldValue else { return }
      needsDisplay = true
    }
  }

  /// Applies the source-panel tokens the brief maps to the gutter: `source`
  /// (fill), `border` (right edge), `srcGutter` (numbers), `srcCurrentLine`,
  /// plus the theme's monospace family for the numbers themselves.
  func applyTokens(_ tokens: ThemeTokens) {
    gutterBackground = tokens.source.nsColor
    gutterBorder = tokens.border.nsColor
    gutterNumber = tokens.srcGutter.nsColor
    gutterCurrentLine = tokens.srcCurrentLine.nsColor
    monoFamily = tokens.monoFamily
  }

  init(scrollView: NSScrollView, textLayoutManager: NSTextLayoutManager) {
    self.textLayoutManager = textLayoutManager
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    self.clientView = scrollView.documentView
    self.ruleThickness = 46
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // Real anti-ghosting fix: by default AppKit clips a view's drawing to the
  // minimal dirty rect, so during a scroll only the newly exposed strip is
  // repainted and the stale line numbers at the old offset survive (the doubled
  // gutter). Opting out of default clipping means `drawHashMarksAndLabels`
  // always fills + repaints the FULL ruler bounds, so no stale numbers remain.
  // (NSClipView.copiesOnScroll is a no-op since macOS 11, so it cannot help here.)
  override var wantsDefaultClipping: Bool { false }

  /// Where the gutter is allowed to paint: its bounds minus any window chrome
  /// overlapping them. With a full-size content view the ruler's bounds run
  /// under the translucent titlebar/toolbelt, so an unclipped background fill
  /// and separator stroke show through the glass and cut across the window
  /// title. Same boundary truth as the editor's floating accessories.
  func chromeClippedDrawingRect() -> NSRect {
    WindowChromeRecipe.chromeClippedVisibleRect(for: self, fallback: bounds)
  }

  override func drawHashMarksAndLabels(in rect: NSRect) {
    guard let textView = clientView as? NSTextView,
      let layoutManager = textLayoutManager,
      let textContentManager = layoutManager.textContentManager
    else { return }

    let bounds = self.bounds

    // Clip ≠ skipped repaint: the anti-ghosting contract above (full-bounds
    // repaint on every pass) still holds inside this region; the chrome strip
    // itself simply never receives gutter pixels.
    let allowed = chromeClippedDrawingRect()
    guard !allowed.isEmpty else { return }
    NSGraphicsContext.current?.saveGraphicsState()
    defer { NSGraphicsContext.current?.restoreGraphicsState() }
    NSBezierPath(rect: allowed).setClip()

    gutterBackground.setFill()
    bounds.fill()

    // Draw right border
    gutterBorder.setStroke()
    let path = NSBezierPath()
    path.move(to: NSPoint(x: bounds.maxX - 1, y: bounds.minY))
    path.line(to: NSPoint(x: bounds.maxX - 1, y: bounds.maxY))
    path.lineWidth = 1
    path.stroke()

    let textContainerInset = textView.textContainerInset
    let scrollOffset = scrollView?.documentVisibleRect.origin.y ?? 0

    // Resolved (and cached) per family+size — this runs on every gutter repaint,
    // i.e. on every scroll, so it must never construct a font from scratch.
    let numberFont = MonoFontResolver.font(
      family: monoFamily, size: fontSize - 2, fallback: .monoDigits)
    let numberAttributes: [NSAttributedString.Key: Any] = [
      .font: numberFont,
      .foregroundColor: gutterNumber,
    ]
    let currentLineAttributes: [NSAttributedString.Key: Any] = [
      .font: numberFont,
      .foregroundColor: gutterCurrentLine,
    ]

    var lineNumber = 1

    // TextKit 2: iterate over layout fragments
    let documentRange = textContentManager.documentRange
    layoutManager.enumerateTextLayoutFragments(
      from: documentRange.location, options: [.ensuresLayout]
    ) { fragment in
      let frame = fragment.layoutFragmentFrame

      // fragment rect in text view coordinates
      let fragmentRect = NSRect(
        x: frame.minX,
        y: frame.minY + textContainerInset.height - scrollOffset,
        width: frame.width,
        height: frame.height
      )

      // Only draw if visible
      if fragmentRect.maxY >= rect.minY && fragmentRect.minY <= rect.maxY {
        let isCurrentLine = lineNumber == currentLineNumber
        let attributes = isCurrentLine ? currentLineAttributes : numberAttributes
        let numberString = NSString(string: "\(lineNumber)")
        let size = numberString.size(withAttributes: attributes)
        let drawPoint = NSPoint(
          x: bounds.maxX - size.width - 6,
          y: fragmentRect.minY + (frame.height - size.height) / 2
        )
        numberString.draw(at: drawPoint, withAttributes: attributes)

        // Active-line accent: a 2 px marker hard against the gutter's right
        // edge, in the same current-line token as the number.
        if isCurrentLine {
          gutterCurrentLine.setFill()
          NSRect(
            x: bounds.maxX - 2, y: fragmentRect.minY, width: 2, height: frame.height
          ).fill()
        }
      }

      lineNumber += 1
      return true  // continue enumeration
    }
  }
}
