import AppKit

class LineNumberGutter: NSRulerView {
  weak var textLayoutManager: NSTextLayoutManager?

  var fontSize: CGFloat = 14 {
    didSet { needsDisplay = true }
  }

  init(scrollView: NSScrollView, textLayoutManager: NSTextLayoutManager) {
    self.textLayoutManager = textLayoutManager
    super.init(scrollView: scrollView, orientation: .verticalRuler)
    self.clientView = scrollView.documentView
    self.ruleThickness = 40
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func drawHashMarksAndLabels(in rect: NSRect) {
    guard let textView = clientView as? NSTextView,
      let layoutManager = textLayoutManager,
      let textContentManager = layoutManager.textContentManager
    else { return }

    let bounds = self.bounds
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()

    // Draw right border
    NSColor.separatorColor.setStroke()
    let path = NSBezierPath()
    path.move(to: NSPoint(x: bounds.maxX - 1, y: bounds.minY))
    path.line(to: NSPoint(x: bounds.maxX - 1, y: bounds.maxY))
    path.lineWidth = 1
    path.stroke()

    let textContainerInset = textView.textContainerInset
    let scrollOffset = scrollView?.documentVisibleRect.origin.y ?? 0

    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize - 2, weight: .regular),
      .foregroundColor: NSColor.tertiaryLabelColor,
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
        let numberString = NSString(string: "\(lineNumber)")
        let size = numberString.size(withAttributes: attributes)
        let drawPoint = NSPoint(
          x: bounds.maxX - size.width - 6,
          y: fragmentRect.minY + (frame.height - size.height) / 2
        )
        numberString.draw(at: drawPoint, withAttributes: attributes)
      }

      lineNumber += 1
      return true  // continue enumeration
    }
  }
}
