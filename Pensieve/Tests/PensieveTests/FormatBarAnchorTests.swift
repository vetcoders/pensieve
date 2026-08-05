import AppKit
import XCTest

@testable import Pensieve

/// The floating formatting bar must sit at the current selection, or not at all.
///
/// TextKit 2 answers `firstRect(forCharacterRange:)` with exactly `.zero` for a
/// range it cannot currently address. `.zero` is a legal point in SCREEN space,
/// so converting it produces a position that looks plausible and has nothing to
/// do with the selection: the bar gets parked over a paragraph thousands of
/// characters away, where it also swallows clicks meant for the text.
///
/// These pins drive `showFormattingPopover()` — the real entry point, reached
/// from `textViewDidChangeSelection` — and the real `boundsDidChange`/`layout`
/// hooks. The five existing bar pins in `EditorToolbeltTests` exercise the pure
/// `accessoryOrigin` arithmetic with a hand-supplied, valid rect; all of them
/// stayed green for the whole life of this bug, because none of them could ever
/// feed it `.zero`.
///
/// The harness deliberately never calls `ensureLayout(for: documentRange)`:
/// pre-laying the whole document makes every range addressable and hides the
/// defect outright.
final class FormatBarAnchorTests: XCTestCase {

  // MARK: - Harness

  private func longDocument(paragraphs: Int = 600) -> String {
    (1...paragraphs)
      .map { "Akapit \($0): zdanie o umiarkowanej dlugosci uzyte jako tresc testowa." }
      .joined(separator: "\n")
  }

  @MainActor
  private func makeHostedSurface(text: String) -> (MarkdownEditorSurface, NSWindow) {
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = surface.scrollView
    surface.scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(surface.textView)
    surface.scrollView.layoutSubtreeIfNeeded()
    return (surface, window)
  }

  @MainActor
  private func formatBar(_ surface: MarkdownEditorSurface) -> NSView? {
    surface.textView.subviews.first {
      String(describing: type(of: $0)).contains("FloatingFormatBar")
    }
  }

  @MainActor
  private func screenRect(_ surface: MarkdownEditorSurface, _ range: NSRange) -> NSRect {
    var actual = NSRange(location: 0, length: 0)
    return surface.textView.firstRect(forCharacterRange: range, actualRange: &actual)
  }

  /// The selection rect in the text view's own (flipped) coordinate space, or
  /// `nil` when TextKit cannot currently address the range.
  @MainActor
  private func answerableSelectionRect(_ surface: MarkdownEditorSurface) -> NSRect? {
    let rect = screenRect(surface, surface.textView.selectedRange())
    guard rect != .zero, let window = surface.textView.window else { return nil }
    return surface.textView.convert(window.convertFromScreen(rect), from: nil)
  }

  @MainActor
  private func select(_ surface: MarkdownEditorSurface, _ range: NSRange) {
    surface.textView.setSelectedRange(range)
    surface.textView.showFormattingPopover()
  }

  @MainActor
  private func settle(_ surface: MarkdownEditorSurface) {
    surface.scrollView.layoutSubtreeIfNeeded()
    surface.textView.layoutSubtreeIfNeeded()
  }

  @MainActor
  private func range(_ surface: MarkdownEditorSurface, of needle: String, length: Int) -> NSRange {
    let location = (surface.textStorage.string as NSString).range(of: needle).location
    XCTAssertNotEqual(location, NSNotFound, "precondition: \"\(needle)\" must occur in the fixture")
    return NSRange(location: location, length: length)
  }

  /// The invariant the whole fix exists to hold: a bar the user can see is a bar
  /// anchored to a selection TextKit can actually place. Anything else is the bar
  /// hovering over unrelated text.
  @MainActor
  private func assertVisibleBarIsAnchoredToTheSelection(
    _ surface: MarkdownEditorSurface, _ context: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard let bar = formatBar(surface) else { return }  // hidden is always a valid answer
    guard let selectionRect = answerableSelectionRect(surface) else {
      return XCTFail(
        "\(context): the bar is visible at \(NSStringFromRect(bar.frame)) while TextKit "
          + "cannot address the selection \(NSStringFromRange(surface.textView.selectedRange())) "
          + "at all — its position was invented from a `.zero` rect and points at "
          + "unrelated text",
        file: file, line: line)
    }
    XCTAssertLessThan(
      abs(bar.frame.midY - selectionRect.midY), surface.scrollView.contentView.bounds.height,
      "\(context): the bar sits \(abs(bar.frame.midY - selectionRect.midY))pt away from the "
        + "selection it belongs to — further than a whole viewport",
      file: file, line: line)
  }

  // MARK: - Pin 1 — an unanswerable rect hides the bar instead of guessing

  @MainActor
  func testASelectionTextKitCannotAddressHidesTheBarInsteadOfPlacingIt() throws {
    let (surface, window) = makeHostedSurface(text: longDocument())
    defer { window.contentView = nil }

    // Deep in the document and never scrolled to, so TextKit 2 has never laid it out.
    let deep = range(surface, of: "Akapit 560:", length: 30)
    XCTAssertEqual(
      screenRect(surface, deep), .zero,
      "precondition: TextKit must be unable to answer for this range")

    select(surface, deep)

    XCTAssertNil(
      formatBar(surface).map { NSStringFromRect($0.frame) },
      "the bar was placed from an unanswerable rect: a `.zero` SCREEN point converts "
        + "to a plausible-looking position that has nothing to do with the selection")
  }

  // MARK: - Pin 2 — never stranded after a mutation above the selection

  /// Text inserted above the selection is the shape an undone deletion has: the
  /// text and the selection come back correct, but TextKit stops being able to
  /// answer for the selection — and the bar used to land hundreds of paragraphs
  /// away, where it intercepts clicks.
  @MainActor
  func testAMutationAboveTheSelectionNeverStrandsTheBarOverForeignContent() throws {
    let (surface, window) = makeHostedSurface(text: longDocument())
    defer { window.contentView = nil }

    let anchor = range(surface, of: "Akapit 300:", length: 40)
    surface.textView.scrollRangeToVisible(anchor)
    settle(surface)
    select(surface, anchor)
    XCTAssertNotNil(formatBar(surface), "precondition: the bar is up at a laid-out selection")

    let insertion = "DOKLEJONE\nDOKLEJONE\nDOKLEJONE\nDOKLEJONE\nDOKLEJONE\n"
    surface.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: insertion)
    surface.textContentStorage.refreshHighlighting()
    // Same TEXT, shifted range — exactly what the user still has selected.
    select(
      surface,
      NSRange(location: anchor.location + (insertion as NSString).length, length: anchor.length))
    settle(surface)

    assertVisibleBarIsAnchoredToTheSelection(surface, "after a mutation above the selection")
  }

  // MARK: - Pin 3 — the position must come from the selection

  /// Two different unaddressable selections used to produce the very same bar
  /// frame, because the position came from the viewport instead of from the text.
  /// That is why a second Undo looked like it left the bar "stuck".
  @MainActor
  func testTwoDifferentSelectionsCannotProduceTheSameBarPosition() throws {
    let (surface, window) = makeHostedSurface(text: longDocument())
    defer { window.contentView = nil }

    // Unaddressable pair: whatever the bar does here, it must not be the same
    // wrong place twice.
    let farApart = (
      range(surface, of: "Akapit 520:", length: 30), range(surface, of: "Akapit 580:", length: 30)
    )
    select(surface, farApart.0)
    let unlaidFirst = formatBar(surface)?.frame
    select(surface, farApart.1)
    let unlaidSecond = formatBar(surface)?.frame

    if let unlaidFirst, let unlaidSecond {
      XCTAssertNotEqual(
        unlaidFirst, unlaidSecond,
        "two selections \(farApart.1.location - farApart.0.location) characters apart put the "
          + "bar at the identical frame \(NSStringFromRect(unlaidFirst)) — its position is not "
          + "coming from the selection at all")
    }

    // Addressable pair on two different laid-out lines: the same assertion, but
    // one that stays meaningful once unaddressable selections hide the bar.
    let near = range(surface, of: "Akapit 3:", length: 20)
    let alsoNear = range(surface, of: "Akapit 9:", length: 20)
    surface.textView.scrollRangeToVisible(near)
    settle(surface)

    select(surface, near)
    let laidFirst = try XCTUnwrap(formatBar(surface)?.frame, "the bar must show on a laid-out line")
    select(surface, alsoNear)
    let laidSecond = try XCTUnwrap(
      formatBar(surface)?.frame, "the bar must show on a laid-out line")

    XCTAssertNotEqual(
      laidFirst, laidSecond,
      "two selections on different visible lines put the bar at the identical frame "
        + "\(NSStringFromRect(laidFirst))")
  }

  // MARK: - Pin 4 — a scroll re-anchors instead of leaving a stale bar behind

  /// The bar is a subview of the text view, so it scrolls with the text and the
  /// chrome clamp keeps it reachable. What it must never do is stay visible once
  /// the selection it annotates has dropped out of the laid-out region — at that
  /// point it is just an overlay parked on somebody else's paragraph.
  @MainActor
  func testScrollingFarFromTheSelectionDoesNotLeaveAStaleBarBehind() throws {
    let (surface, window) = makeHostedSurface(text: longDocument())
    defer { window.contentView = nil }

    let anchor = range(surface, of: "Akapit 300:", length: 40)
    surface.textView.scrollRangeToVisible(anchor)
    settle(surface)
    select(surface, anchor)
    XCTAssertNotNil(formatBar(surface), "precondition: the bar is up")

    // Scroll a long way off without touching the selection, through the real
    // notification path (`boundsDidChange`), not by poking the bar directly.
    surface.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    surface.scrollView.reflectScrolledClipView(surface.scrollView.contentView)
    settle(surface)

    assertVisibleBarIsAnchoredToTheSelection(surface, "after scrolling away from the selection")
  }

  // MARK: - Pin 5 — hiding is temporary: the bar comes back when the anchor does

  /// Stepping aside must not mean giving up. Taking the bar away when the anchor
  /// is unmeasurable is only acceptable because the intent survives: the next
  /// bounds/layout pass that CAN measure the selection puts the bar back, with no
  /// timer, no polling, and without making the user re-select.
  @MainActor
  func testTheBarComesBackOnceTheSelectionCanBeMeasuredAgain() throws {
    let (surface, window) = makeHostedSurface(text: longDocument())
    defer { window.contentView = nil }

    let anchor = range(surface, of: "Akapit 300:", length: 40)
    surface.textView.scrollRangeToVisible(anchor)
    settle(surface)
    select(surface, anchor)
    XCTAssertNotNil(formatBar(surface), "precondition: the bar is up")

    surface.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    surface.scrollView.reflectScrolledClipView(surface.scrollView.contentView)
    settle(surface)
    XCTAssertNil(formatBar(surface), "precondition: the unmeasurable anchor took the bar away")

    // Back to the selection — the selection itself was never touched.
    surface.textView.scrollRangeToVisible(surface.textView.selectedRange())
    surface.scrollView.reflectScrolledClipView(surface.scrollView.contentView)
    settle(surface)

    XCTAssertNotNil(
      formatBar(surface),
      "the bar never came back after its selection scrolled into view again — hiding on an "
        + "unmeasurable anchor is only safe if the next good measurement restores it")
    assertVisibleBarIsAnchoredToTheSelection(surface, "after the anchor became measurable again")
  }

  // MARK: - Pin 6 — an explicit dismissal is final

  /// The retry must not resurrect a bar the user dismissed. Esc routes through
  /// `hideFormattingPopover`, and that has to clear the intent, not just the view.
  @MainActor
  func testAnExplicitlyDismissedBarIsNotBroughtBackByALaterLayoutPass() throws {
    let (surface, window) = makeHostedSurface(text: longDocument())
    defer { window.contentView = nil }

    let anchor = range(surface, of: "Akapit 300:", length: 40)
    surface.textView.scrollRangeToVisible(anchor)
    settle(surface)
    select(surface, anchor)
    XCTAssertNotNil(formatBar(surface), "precondition: the bar is up")

    surface.textView.hideFormattingPopover()
    XCTAssertNil(formatBar(surface), "precondition: dismissing takes the bar away")

    // Any amount of scrolling and re-laying out must leave it dismissed.
    surface.textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    surface.scrollView.reflectScrolledClipView(surface.scrollView.contentView)
    settle(surface)
    surface.textView.scrollRangeToVisible(surface.textView.selectedRange())
    surface.scrollView.reflectScrolledClipView(surface.scrollView.contentView)
    settle(surface)

    XCTAssertNil(
      formatBar(surface),
      "a layout pass brought back a bar the user had dismissed — the retry is supposed to "
        + "restore an anchor that went missing, not to override an explicit dismissal")
  }

  // MARK: - Pin 7 — overshoot guard: a good rect still anchors exactly

  /// The fix must not answer "hide" to everything. Where TextKit can address the
  /// selection, the bar keeps its designed 6pt gap above it.
  @MainActor
  func testAnAddressableSelectionStillAnchorsSixPointsAboveIt() throws {
    let (surface, window) = makeHostedSurface(text: longDocument())
    defer { window.contentView = nil }

    let anchor = range(surface, of: "Akapit 300:", length: 40)
    surface.textView.scrollRangeToVisible(anchor)
    settle(surface)
    select(surface, anchor)

    guard let bar = formatBar(surface) else {
      return XCTFail("the bar must be shown for a selection TextKit can address")
    }
    guard let selectionRect = answerableSelectionRect(surface) else {
      return XCTFail("precondition: the selection rect must be answerable here")
    }

    XCTAssertEqual(
      selectionRect.minY - bar.frame.maxY, 6, accuracy: 0.5,
      "the bar sits \(selectionRect.minY - bar.frame.maxY)pt above the selection instead of "
        + "the designed 6 — the fix overshot and stopped anchoring where it still can")
  }
}
