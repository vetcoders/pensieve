import AppKit
import XCTest

@testable import Pensieve

/// Deterministic probe for the "document jumps on every keystroke" bug.
///
/// Replaces ad-hoc human smoke-testing with a programmed stimulus + an explicit
/// oracle: load a known document, pin a known viewport, type ONE character, and
/// assert the scroll origin behaves. A pure in-view edit must never re-scroll.
///
/// The probe drives the real `MarkdownEditorSurface` (the AppKit layer where the
/// scroll mutation lives), so a failure localizes the jump and a pass exonerates
/// the surface. Either way the result is measured, not guessed.
final class EditorScrollStabilityProbeTests: XCTestCase {

  /// A document tall enough to scroll inside a 400pt viewport.
  private func longDocument() -> String {
    (1...200)
      .map { "Line \($0): the quick brown fox jumps over the lazy dog." }
      .joined(separator: "\n")
  }

  @MainActor
  private func makeHostedSurface(text: String) -> (MarkdownEditorSurface, NSWindow) {
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = surface.scrollView
    surface.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    // Force TextKit 2 layout so the document has real height (scroll room).
    surface.scrollView.layoutSubtreeIfNeeded()
    surface.textLayoutManager.ensureLayout(for: surface.textLayoutManager.documentRange)
    return (surface, window)
  }

  /// Spin the main runloop so any deferred main-queue work settles before we
  /// read the scroll origin.
  private func drainMainQueue() {
    let exp = expectation(description: "main-queue drain")
    DispatchQueue.main.async { exp.fulfill() }
    wait(for: [exp], timeout: 1.0)
  }

  @MainActor
  func test_typing_in_middle_does_not_move_viewport_in_source_mode() throws {
    let (surface, window) = makeHostedSurface(text: longDocument())
    defer { window.contentView = nil }

    // Source/split semantics: typewriter centering is OFF (gated to Focus).
    surface.typewriterScrollEnabled = false

    // Pin a known viewport NOT at the top: scroll to the vertical middle.
    let docHeight = surface.textView.bounds.height
    let pinnedY = (docHeight - 400) / 2
    surface.scrollView.contentView.scroll(to: NSPoint(x: 0, y: pinnedY))
    surface.scrollView.reflectScrolledClipView(surface.scrollView.contentView)
    let originBefore = surface.scrollView.contentView.bounds.origin

    // Type a single character on a line inside the pinned viewport.
    let caret = (surface.textStorage.string as NSString).length / 2
    surface.textView.setSelectedRange(NSRange(location: caret, length: 0))
    surface.textView.insertText("x", replacementRange: NSRange(location: caret, length: 0))
    drainMainQueue()

    let originAfter = surface.scrollView.contentView.bounds.origin
    XCTAssertEqual(
      originAfter.y, originBefore.y, accuracy: 0.5,
      "In-view typing moved the scroll origin (\(originBefore.y) -> \(originAfter.y))."
    )
  }

  @MainActor
  func test_swiftui_reapply_after_visible_edit_keeps_viewport_in_source_mode() throws {
    // The live per-keystroke path is textDidChange -> binding -> SwiftUI
    // re-render -> updateNSView -> surface.update(text:). This adds the
    // re-apply the SwiftUI layer runs on each render, caret VISIBLE in the
    // middle. The viewport must not move.
    let (surface, window) = makeHostedSurface(text: longDocument())
    defer { window.contentView = nil }

    surface.typewriterScrollEnabled = false

    let docHeight = surface.textView.bounds.height
    let pinnedY = (docHeight - 400) / 2
    surface.scrollView.contentView.scroll(to: NSPoint(x: 0, y: pinnedY))
    surface.scrollView.reflectScrolledClipView(surface.scrollView.contentView)
    let originBefore = surface.scrollView.contentView.bounds.origin

    let caret = (surface.textStorage.string as NSString).length / 2
    surface.textView.setSelectedRange(NSRange(location: caret, length: 0))
    surface.textView.insertText("x", replacementRange: NSRange(location: caret, length: 0))
    surface.update(
      text: surface.textStorage.string,
      fontSize: 14,
      syntaxHighlightingEnabled: true,
      tableTidyOnPaste: true,
      asciiSafeTables: false,
      aiAutocompleteEnabled: false,
      findQuery: "",
      findBarVisible: false
    )
    drainMainQueue()

    let originAfter = surface.scrollView.contentView.bounds.origin
    XCTAssertEqual(
      originAfter.y, originBefore.y, accuracy: 0.5,
      "SwiftUI re-apply moved the viewport (\(originBefore.y) -> \(originAfter.y))."
    )
  }

  @MainActor
  func test_typing_same_line_in_focus_mode_does_not_re_center_per_keystroke() throws {
    // Focus mode (typewriter ON). Steady-state same-line typing must not
    // re-scroll: the fix gates re-centering on the caret's logical line, so a
    // same-line edit cannot move the viewport. Regression for the per-keystroke
    // jump (reproduced pre-fix as 1518.5 -> 1531.0 on one same-line char).
    let (surface, window) = makeHostedSurface(text: longDocument())
    defer { window.contentView = nil }

    surface.typewriterScrollEnabled = true

    // Park the caret mid-document and let typewriter SETTLE so we measure a
    // steady state, not setup lag.
    let caret = (surface.textStorage.string as NSString).length / 2
    surface.textView.setSelectedRange(NSRange(location: caret, length: 0))
    for _ in 0..<5 {
      surface.centerCaretLineIfNeeded()
      surface.scrollView.layoutSubtreeIfNeeded()
    }
    let originBefore = surface.scrollView.contentView.bounds.origin

    // One character on the same line (no vertical caret movement).
    surface.textView.insertText("x", replacementRange: surface.textView.selectedRange())
    drainMainQueue()

    let originAfter = surface.scrollView.contentView.bounds.origin
    XCTAssertEqual(
      originAfter.y, originBefore.y, accuracy: 0.5,
      "Focus-mode same-line typing re-centered (\(originBefore.y) -> \(originAfter.y))."
    )
  }

  @MainActor
  func test_typing_at_offscreen_caret_scrolls_it_into_view_expected() throws {
    // Boundary: caret OFF-SCREEN (at the end, viewport parked in the middle).
    // Scrolling an off-screen caret into view on edit is EXPECTED behavior, not
    // the bug — this pins the boundary against the in-view jump.
    let (surface, window) = makeHostedSurface(text: longDocument())
    defer { window.contentView = nil }

    surface.typewriterScrollEnabled = false

    let docHeight = surface.textView.bounds.height
    let pinnedY = (docHeight - 400) / 2
    surface.scrollView.contentView.scroll(to: NSPoint(x: 0, y: pinnedY))
    surface.scrollView.reflectScrolledClipView(surface.scrollView.contentView)
    let originBefore = surface.scrollView.contentView.bounds.origin

    let end = (surface.textStorage.string as NSString).length
    surface.textView.setSelectedRange(NSRange(location: end, length: 0))
    surface.textView.insertText("x", replacementRange: NSRange(location: end, length: 0))
    drainMainQueue()

    let originAfter = surface.scrollView.contentView.bounds.origin
    XCTAssertGreaterThan(
      originAfter.y, originBefore.y + 0.5,
      "Editing at an off-screen caret should scroll it into view "
        + "(\(originBefore.y) -> \(originAfter.y))."
    )
  }

  /// Regression for the live per-keystroke jump (operator-confirmed). With no
  /// active find, the find-highlight cleanup must NOT mutate document attributes:
  /// `removeFindHighlights()` used to run a whole-document
  /// `removeAttribute(.backgroundColor)` on EVERY keystroke (textDidChange ->
  /// refreshFindMatches) and EVERY re-render (updateNSView -> updateFind ->
  /// clearFindHighlights), which forced a TextKit2 relayout of the viewport — the
  /// content "jump" at a fixed scroll origin, independent of syntax highlighting.
  /// A planted background attribute must survive cleanup when there are no matches.
  @MainActor
  func test_find_cleanup_is_noop_without_active_matches() throws {
    let (surface, window) = makeHostedSurface(text: "alpha beta gamma")
    defer { window.contentView = nil }

    let sentinel = NSColor.systemBlue
    surface.textStorage.addAttribute(
      .backgroundColor, value: sentinel, range: NSRange(location: 0, length: 5))

    // The cleanup path that fires on every keystroke / re-render with no find.
    surface.updateFind(query: "", visible: false)

    var effective = NSRange()
    let attr = surface.textStorage.attribute(
      .backgroundColor, at: 0, effectiveRange: &effective)
    XCTAssertEqual(
      attr as? NSColor, sentinel,
      "find cleanup wiped document attributes with no active find — the "
        + "whole-document removeAttribute that forced a per-keystroke relayout"
    )
  }
}
