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

  /// Spin the main runloop so the async `postEditorViewportIfNeeded` hop runs
  /// before we read the origin.
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
      syntaxHighlightingEnabled: true
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
  func test_typing_does_not_drive_editor_viewport_sync() throws {
    // The per-keystroke "blocks vanish + vertical reflow without viewport
    // mutation" symptom: textDidChange posted the editor viewport on every
    // edit, and publishing queries currentTopVisibleBlockIndex ->
    // characterIndexForInsertion, which forces a TextKit2 layout pass mid-edit
    // (fragments invalidate -> vanish/reflow). Typing does not scroll, so it
    // must NOT drive viewport sync — that belongs to editorBoundsDidChange.
    let (surface, window) = makeHostedSurface(text: longDocument())
    defer { window.contentView = nil }
    surface.typewriterScrollEnabled = false

    // Pin the viewport so the caret is IN VIEW — then typing causes no scroll.
    let docHeight = surface.textView.bounds.height
    surface.scrollView.contentView.scroll(to: NSPoint(x: 0, y: (docHeight - 400) / 2))
    surface.scrollView.reflectScrolledClipView(surface.scrollView.contentView)
    let caret = (surface.textStorage.string as NSString).length / 2
    surface.textView.setSelectedRange(NSRange(location: caret, length: 0))
    drainMainQueue()  // let any setup-scroll viewport query settle first

    // Count forced-layout viewport queries directly (dedup-proof: the query
    // runs BEFORE the notification dedup, so counting it — not the post — is
    // the sound guard).
    let queriesBefore = surface.editorViewportLayoutQueryCount
    surface.textView.insertText("x", replacementRange: NSRange(location: caret, length: 0))
    drainMainQueue()

    XCTAssertEqual(
      surface.editorViewportLayoutQueryCount, queriesBefore,
      "In-view typing forced a TextKit2 viewport layout query "
        + "(characterIndexForInsertion) — the per-keystroke block-vanish/reflow."
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
}
