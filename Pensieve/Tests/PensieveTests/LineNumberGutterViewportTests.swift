import AppKit
import XCTest

@testable import Pensieve

/// What ONE gutter repaint is allowed to touch.
///
/// `drawHashMarksAndLabels` enumerated from the document start with
/// `.ensuresLayout` and never stopped, so every repaint TYPESET the entire
/// document — AppKit posts a full ruler repaint on every scroll and on every
/// text-view layout pass, and TextKit 2 discards the layout it is not showing,
/// so the same whole-document shaping ran over and over. Sampled on the
/// operator's machine (build 528, 0.4.2) the main thread was 4019/4019 samples
/// deep inside that one call, in `NSTextLayoutFragment _layout` →
/// `CTTypesetterCreateWithAttributedStringAndOptions` → `OTL::GSUB::ApplyLookups`;
/// font cascade/fallback was 21 of those 4019 samples, so this was never a
/// missing-glyph problem, just the whole document being shaped again.
///
/// Two pins: the work has to scale with the RULER, and the numbers it paints
/// must not have changed.
final class LineNumberGutterViewportTests: XCTestCase {

  private static let viewportHeight: CGFloat = 400

  @MainActor
  private func makeHostedSurface(text: String) -> (MarkdownEditorSurface, NSWindow) {
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: Self.viewportHeight),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = surface.scrollView
    surface.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: Self.viewportHeight)
    surface.scrollView.layoutSubtreeIfNeeded()
    surface.textLayoutManager.ensureLayout(for: surface.textLayoutManager.documentRange)
    surface.scrollView.layoutSubtreeIfNeeded()
    return (surface, window)
  }

  /// Runs one real gutter repaint into an offscreen bitmap and reports every
  /// fragment it touched. `NSString.draw` needs a live graphics context, so the
  /// pass has to be driven inside one rather than called bare.
  @MainActor
  private func drawGutter(
    _ surface: MarkdownEditorSurface
  ) -> (visited: [(line: Int, painted: Bool)], rect: NSRect) {
    guard let gutter = surface.textView.gutter else {
      XCTFail("the surface built no gutter")
      return ([], .zero)
    }
    var visited: [(line: Int, painted: Bool)] = []
    gutter.onFragmentVisited = { line, painted in visited.append((line, painted)) }
    defer { gutter.onFragmentVisited = nil }

    let rect = gutter.bounds
    let image = NSImage(size: NSSize(width: max(rect.width, 1), height: max(rect.height, 1)))
    image.lockFocus()
    gutter.drawHashMarksAndLabels(in: rect)
    image.unlockFocus()
    return (visited, rect)
  }

  @MainActor
  private func scroll(_ surface: MarkdownEditorSurface, toY y: CGFloat) {
    surface.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
    surface.scrollView.reflectScrolledClipView(surface.scrollView.contentView)
    surface.scrollView.layoutSubtreeIfNeeded()
  }

  private func document(paragraphs: Int) -> String {
    (0..<paragraphs)
      .map { index -> String in
        // Mixed lengths, some long enough to WRAP in a 600pt window: a wrapped
        // paragraph is still one layout fragment and so still one gutter number,
        // which is the property the offset→number mapping relies on.
        switch index % 4 {
        case 0: return "## Sekcja \(index / 4 + 1)"
        case 1:
          return
            "Strony ustalają, że wynagrodzenie za wykonanie przedmiotu umowy płatne "
            + "będzie w terminie 14 dni od dnia doręczenia prawidłowo wystawionej "
            + "faktury, przelewem na rachunek wskazany w jej treści."
        case 2: return ""
        default: return "Zdanie numer \(index)."
        }
      }
      .joined(separator: "\n")
  }

  // MARK: - The cost pin

  /// The work one repaint does must scale with the RULER, not the document.
  ///
  /// Asserted as an invariant rather than as a number: the same viewport is
  /// pointed at the same offset in a small document and in one five times
  /// longer, and the count of fragments the repaint touched has to be the same.
  /// Before the fix it was the paragraph count both times — 2 000 and 10 000 —
  /// so this fails by the length of the document, on any hardware, with no
  /// wall-clock budget to go flaky.
  @MainActor
  func testOneRepaintTouchesTheViewportNotTheDocument() {
    var counts: [Int: Int] = [:]
    for paragraphs in [2_000, 10_000] {
      let (surface, window) = makeHostedSurface(text: document(paragraphs: paragraphs))
      defer { window.contentView = nil }
      // Somewhere in the middle, where "from the document start" is expensive
      // and "from the first visible fragment" is not.
      scroll(surface, toY: 4_000)
      counts[paragraphs] = drawGutter(surface).visited.count
    }

    XCTAssertEqual(
      counts[2_000], counts[10_000],
      "one gutter repaint touched \(counts[2_000] ?? -1) fragments in a 2 000-paragraph"
        + " document and \(counts[10_000] ?? -1) in a 10 000-paragraph one — it is walking"
        + " the document, not the viewport, and `.ensuresLayout` typesets everything it walks")

    // …and the absolute size is a viewport's worth of rows, not an arbitrary
    // constant that happens to be equal in both runs.
    let rowsThatFit = Int(Self.viewportHeight / 14) + 4
    XCTAssertLessThanOrEqual(
      counts[10_000] ?? .max, rowsThatFit,
      "a \(Int(Self.viewportHeight))pt ruler cannot show more than ~\(rowsThatFit) rows")
  }

  // MARK: - The correctness pin

  /// The numbers are the same ones. The oracle re-implements what the gutter did
  /// BEFORE the fix — ordinal 1… over every fragment from the document start,
  /// with the old visibility predicate — and the painted numbers must match it
  /// at every scroll position, including the top and the very bottom.
  @MainActor
  func testPaintedNumbersAreUnchangedByTheViewportScoping() {
    let (surface, window) = makeHostedSurface(text: document(paragraphs: 240))
    defer { window.contentView = nil }

    let maxScroll = max(0, surface.textView.frame.height - Self.viewportHeight)
    for fraction in [0.0, 0.17, 0.5, 0.83, 1.0] {
      let y = (maxScroll * fraction).rounded()
      scroll(surface, toY: y)
      let pass = drawGutter(surface)
      let painted = pass.visited.filter(\.painted).map(\.line)
      let expected = oracleLineNumbers(surface, rect: pass.rect)
      XCTAssertEqual(
        painted, expected,
        "at scroll y=\(y) the gutter painted \(painted.prefix(4))…\(painted.suffix(2))"
          + " where the pre-fix walk painted \(expected.prefix(4))…\(expected.suffix(2))")
      XCTAssertFalse(painted.isEmpty, "no numbers painted at scroll y=\(y)")
    }
  }

  /// A document whose rows are NOT all `\n`-separated: the offset→number mapping
  /// has to agree with the fragments CR, CRLF and U+2029 actually produce, not
  /// with a newline count. Same oracle, mixed separators.
  @MainActor
  func testMixedLineEndingsNumberTheSameRowsAsTheFragmentWalk() {
    let text =
      (0..<200)
      .map { index -> String in
        let separator = ["\n", "\r", "\r\n", "\u{2029}"][index % 4]
        return "wiersz \(index) dokumentu o mieszanych końcach linii\(separator)"
      }
      .joined()
    let (surface, window) = makeHostedSurface(text: text)
    defer { window.contentView = nil }

    let maxScroll = max(0, surface.textView.frame.height - Self.viewportHeight)
    for fraction in [0.0, 0.4, 0.9] {
      let y = (maxScroll * fraction).rounded()
      scroll(surface, toY: y)
      let pass = drawGutter(surface)
      XCTAssertEqual(
        pass.visited.filter(\.painted).map(\.line),
        oracleLineNumbers(surface, rect: pass.rect),
        "mixed line endings at scroll y=\(y)")
    }
  }

  /// The pre-fix walk, verbatim: number every fragment from the document start
  /// and keep the ones the old visibility test would have drawn.
  @MainActor
  private func oracleLineNumbers(_ surface: MarkdownEditorSurface, rect: NSRect) -> [Int] {
    let layoutManager = surface.textLayoutManager
    guard let content = layoutManager.textContentManager else { return [] }
    let inset = surface.textView.textContainerInset
    let scrollOffset = surface.scrollView.documentVisibleRect.origin.y

    var lineNumber = 1
    var drawn: [Int] = []
    layoutManager.enumerateTextLayoutFragments(
      from: content.documentRange.location, options: [.ensuresLayout]
    ) { fragment in
      let frame = fragment.layoutFragmentFrame
      let minY = frame.minY + inset.height - scrollOffset
      if minY + frame.height >= rect.minY && minY <= rect.maxY {
        drawn.append(lineNumber)
      }
      lineNumber += 1
      return true
    }
    return drawn
  }
}
