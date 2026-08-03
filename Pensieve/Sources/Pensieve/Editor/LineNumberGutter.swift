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

  /// 1-based row number for the row that STARTS at a UTF-16 offset, answered
  /// without laying anything out.
  ///
  /// The gutter used to get its numbering for free from the enumeration itself —
  /// start at 1 at the document start, +1 per fragment — which is precisely what
  /// forced every repaint to walk the whole document. Starting at the first
  /// VISIBLE fragment means the number for that fragment has to come from
  /// somewhere else, and the one thing it must not come from is layout.
  ///
  /// `MarkdownEditorSurface` wires this to its anchored caret→line resolver, so a
  /// scroll pays for the span it moved across rather than a fresh scan of
  /// everything above the viewport. Left unset (a gutter built standalone) the
  /// fallback below scans the text before the offset, which is layout-free but
  /// linear.
  var lineNumberForUTF16Offset: ((Int) -> Int)?

  /// Test seam: fires once per layout fragment a draw pass touches, with the row
  /// number resolved for it and whether that number was painted.
  ///
  /// The COUNT is the pin on the viewport contract — it has to track the height
  /// of the ruler, not the length of the document. The numbers are the pin on the
  /// contract that this stayed a pure performance change.
  var onFragmentVisited: ((_ lineNumber: Int, _ painted: Bool) -> Void)?

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

    // The band this pass may paint, mapped back into text-container coordinates
    // — the inverse of the `fragmentRect` construction below.
    let containerMinY = rect.minY - textContainerInset.height + scrollOffset
    let containerMaxY = rect.maxY - textContainerInset.height + scrollOffset

    // TextKit 2: iterate over the layout fragments the band actually covers.
    let documentStart = textContentManager.documentRange.location
    let firstVisible = firstFragmentLocation(
      atContainerY: containerMinY, layoutManager: layoutManager, documentStart: documentStart)
    let firstVisibleOffset = textContentManager.offset(from: documentStart, to: firstVisible)
    var lineNumber = lineNumber(
      forUTF16Offset: firstVisibleOffset == NSNotFound ? 0 : firstVisibleOffset, in: textView)

    layoutManager.enumerateTextLayoutFragments(
      from: firstVisible, options: [.ensuresLayout]
    ) { fragment in
      let frame = fragment.layoutFragmentFrame

      // Below the band: every later fragment sits lower still, so nothing beyond
      // this one can be painted. Stopping HERE is the fix. Running on to the end
      // of the document — which is what an unconditional `return true` did —
      // TYPESETS every paragraph below the viewport, because `.ensuresLayout`
      // lays out whatever it walks over. AppKit posts a full ruler repaint on
      // every scroll and on every text-view layout pass, and TextKit 2 discards
      // the layout it is not showing, so that whole-document typesetting ran
      // again and again: measured at 1.7-2.7 s per repaint on a 200 kB document
      // with a bundled theme face, and minutes on the operator's own file.
      guard frame.minY <= containerMaxY else {
        self.onFragmentVisited?(lineNumber, false)
        return false
      }

      // fragment rect in text view coordinates
      let fragmentRect = NSRect(
        x: frame.minX,
        y: frame.minY + textContainerInset.height - scrollOffset,
        width: frame.width,
        height: frame.height
      )

      // Only draw if visible
      let painted = fragmentRect.maxY >= rect.minY
      if painted {
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

      self.onFragmentVisited?(lineNumber, painted)
      lineNumber += 1
      return true  // continue enumeration
    }
  }

  /// Where a draw has to start enumerating so it can paint its band without
  /// touching anything above it.
  ///
  /// `textLayoutFragment(for:)` is the canonical "which fragment is at this
  /// point": it reads the layout the text view's own viewport controller has
  /// already produced rather than building more. It answers `nil` only where no
  /// layout exists at that height at all, and the fallbacks then give up as
  /// little ground as possible — the viewport controller's own range first, the
  /// document start (the old behaviour) only when there is no viewport at all,
  /// which is the top of the document and therefore cheap.
  private func firstFragmentLocation(
    atContainerY y: CGFloat,
    layoutManager: NSTextLayoutManager,
    documentStart: NSTextLocation
  ) -> NSTextLocation {
    guard y > 0 else { return documentStart }
    if let fragment = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: y)) {
      return fragment.rangeInElement.location
    }
    return layoutManager.textViewportLayoutController.viewportRange?.location ?? documentStart
  }

  /// 1-based number of the row starting at `offset`, counted WITHOUT layout.
  ///
  /// Rows and paragraph separators are the same thing here: TextKit 2 makes one
  /// `NSTextLayoutFragment` per paragraph, wrapping included, so a wrapped line
  /// still carries exactly one gutter number. That equality is pinned against a
  /// real layout manager in `EditorLineResolverTests`, which is what lets the
  /// number be read off the string instead of counted off the enumeration.
  private func lineNumber(forUTF16Offset offset: Int, in textView: NSTextView) -> Int {
    if let resolve = lineNumberForUTF16Offset { return resolve(offset) }
    let string = textView.string as NSString
    return MarkdownEditorSurface.paragraphSeparators(in: string, from: 0, to: offset).count + 1
  }
}
