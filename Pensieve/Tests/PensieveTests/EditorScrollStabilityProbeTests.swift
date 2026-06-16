import AppKit
import XCTest

@testable import Pensieve

/// Deterministic probe for the "document jumps on every keystroke" bug.
///
/// Replaces ad-hoc human smoke-testing with a programmed stimulus + an explicit
/// oracle: load a known document, pin a known viewport, type ONE character in
/// the middle (well away from the viewport edge), and assert the scroll origin
/// does not move. A pure-render/no-op keystroke must never re-scroll — that is
/// the invariant the bug violates.
///
/// The probe drives the real `MarkdownEditorSurface` (the AppKit layer where the
/// scroll mutation lives), not the SwiftUI wrapper, so a failure localizes the
/// jump to the surface and a pass exonerates it (pushing the search up to the
/// SwiftUI/window-integration layer). Either way the result is measured, not
/// guessed.
final class EditorScrollStabilityProbeTests: XCTestCase {

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

    /// Spin the main runloop briefly so the async `postEditorViewportIfNeeded`
    /// hop (DispatchQueue.main.async) actually runs before we read the origin.
    private func drainMainQueue() {
        let exp = expectation(description: "main-queue drain")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
    }

    @MainActor
    func test_typing_in_middle_does_not_move_viewport_in_source_mode() throws {
        // A document tall enough to scroll inside a 400pt viewport.
        let longDoc = (1...200).map { "Line \($0): the quick brown fox jumps over the lazy dog." }
            .joined(separator: "\n")
        let (surface, window) = makeHostedSurface(text: longDoc)
        defer { window.contentView = nil }

        // Source/split semantics: typewriter centering is OFF (it is gated to
        // Focus mode). This is the mode the operator reports jumping too.
        surface.typewriterScrollEnabled = false

        // Pin a known viewport NOT at the top: scroll to the vertical middle.
        let docHeight = surface.textView.bounds.height
        let pinnedY = (docHeight - 400) / 2
        surface.scrollView.contentView.scroll(to: NSPoint(x: 0, y: pinnedY))
        surface.scrollView.reflectScrolledClipView(surface.scrollView.contentView)
        let originBefore = surface.scrollView.contentView.bounds.origin

        // Place the caret on a line inside the pinned viewport (well away from
        // either edge) and type a single character through the real text path.
        let caret = (surface.textStorage.string as NSString).length / 2
        surface.textView.setSelectedRange(NSRange(location: caret, length: 0))
        surface.textView.insertText("x", replacementRange: NSRange(location: caret, length: 0))

        drainMainQueue()

        let originAfter = surface.scrollView.contentView.bounds.origin
        XCTAssertEqual(
            originAfter.y,
            originBefore.y,
            accuracy: 0.5,
            """
            Typing one character in the middle of the document moved the scroll \
            origin (\(originBefore.y) -> \(originAfter.y)). A non-edge edit must \
            not re-scroll the editor — this is the per-keystroke "jump".
            """
        )
    }

    /// Third matrix cell: the SwiftUI per-keystroke round-trip. In the live app
    /// every keystroke is textDidChange -> binding set -> SwiftUI re-render ->
    /// updateNSView -> surface.update(text:). The first two cells exercise only
    /// the raw AppKit edit; this one adds the re-apply that the SwiftUI layer
    /// runs on each render, with the caret VISIBLE in the middle (the truest
    /// model of "typing while watching the text"). The viewport must not move.
    @MainActor
    func test_swiftui_reapply_after_visible_edit_keeps_viewport_in_source_mode() throws {
        let longDoc = (1...200).map { "Line \($0): the quick brown fox jumps over the lazy dog." }
            .joined(separator: "\n")
        let (surface, window) = makeHostedSurface(text: longDoc)
        defer { window.contentView = nil }

        surface.typewriterScrollEnabled = false

        let docHeight = surface.textView.bounds.height
        let pinnedY = (docHeight - 400) / 2
        surface.scrollView.contentView.scroll(to: NSPoint(x: 0, y: pinnedY))
        surface.scrollView.reflectScrolledClipView(surface.scrollView.contentView)
        let originBefore = surface.scrollView.contentView.bounds.origin

        // Caret in the visible middle; type one char, then run the SwiftUI
        // re-apply exactly like updateNSView does on the re-render.
        let caret = (surface.textStorage.string as NSString).length / 2
        surface.textView.setSelectedRange(NSRange(location: caret, length: 0))
        surface.textView.insertText("x", replacementRange: NSRange(location: caret, length: 0))
        surface.update(text: surface.textStorage.string, fontSize: 14, syntaxHighlightingEnabled: true)

        drainMainQueue()

        let originAfter = surface.scrollView.contentView.bounds.origin
        XCTAssertEqual(
            originAfter.y,
            originBefore.y,
            accuracy: 0.5,
            """
            The SwiftUI re-apply round-trip moved the viewport on an in-view edit \
            (\(originBefore.y) -> \(originAfter.y)). Re-rendering on a keystroke \
            must preserve the scroll position.
            """
        )
    }

    /// Fourth cell: FOCUS mode (typewriter centering ON). The operator reports
    /// the jump here too. Steady-state typewriter typing on the SAME line must
    /// not re-scroll: caretMidY is stable, so centerCaretLineIfNeeded's
    /// "skip redundant re-centering" guard should no-op. If it still moves the
    /// viewport, the guard is the per-keystroke jump in Focus mode.
    @MainActor
    func test_typing_same_line_in_focus_mode_does_not_re_center_per_keystroke() throws {
        let longDoc = (1...200).map { "Line \($0): the quick brown fox jumps over the lazy dog." }
            .joined(separator: "\n")
        let (surface, window) = makeHostedSurface(text: longDoc)
        defer { window.contentView = nil }

        surface.typewriterScrollEnabled = true  // Focus mode

        // Park the caret mid-document and let typewriter SETTLE (call until the
        // target stops moving) so we measure a steady state, not setup lag —
        // a jump after this is real, not a measurement artifact.
        let caret = (surface.textStorage.string as NSString).length / 2
        surface.textView.setSelectedRange(NSRange(location: caret, length: 0))
        for _ in 0..<5 {
            surface.centerCaretLineIfNeeded()
            surface.scrollView.layoutSubtreeIfNeeded()
        }
        let originBefore = surface.scrollView.contentView.bounds.origin

        // Type one character on the same line (no vertical caret movement).
        surface.textView.insertText("x", replacementRange: surface.textView.selectedRange())
        drainMainQueue()

        let originAfter = surface.scrollView.contentView.bounds.origin
        XCTAssertEqual(
            originAfter.y,
            originBefore.y,
            accuracy: 0.5,
            """
            Focus-mode same-line typing re-centered the viewport \
            (\(originBefore.y) -> \(originAfter.y)). Steady typewriter typing \
            must no-op, not jump on every character.
            """
        )
    }

    /// Boundary cell: caret OFF-SCREEN (at the end, viewport parked in the
    /// middle). Scrolling to bring an off-screen caret into view on edit is
    /// EXPECTED editor behavior, not the bug — this cell pins that boundary so
    /// it is never confused with the in-view per-keystroke jump (which the two
    /// cells above prove the surface does NOT have).
    @MainActor
    func test_typing_at_offscreen_caret_scrolls_it_into_view_expected() throws {
        let longDoc = (1...200).map { "Line \($0): the quick brown fox jumps over the lazy dog." }
            .joined(separator: "\n")
        let (surface, window) = makeHostedSurface(text: longDoc)
        defer { window.contentView = nil }

        surface.typewriterScrollEnabled = false

        // User has scrolled to the vertical middle and parked there.
        let docHeight = surface.textView.bounds.height
        let pinnedY = (docHeight - 400) / 2
        surface.scrollView.contentView.scroll(to: NSPoint(x: 0, y: pinnedY))
        surface.scrollView.reflectScrolledClipView(surface.scrollView.contentView)
        let originBefore = surface.scrollView.contentView.bounds.origin

        // Caret jumps to the very end (e.g. ⌘↓ / programmatic) and a char is typed.
        let end = (surface.textStorage.string as NSString).length
        surface.textView.setSelectedRange(NSRange(location: end, length: 0))
        surface.textView.insertText("x", replacementRange: NSRange(location: end, length: 0))

        drainMainQueue()

        let originAfter = surface.scrollView.contentView.bounds.origin
        XCTAssertGreaterThan(
            originAfter.y,
            originBefore.y + 0.5,
            """
            Editing at an off-screen caret should scroll the caret into view \
            (origin \(originBefore.y) -> \(originAfter.y)). This is expected \
            editor behavior and the boundary against the in-view jump.
            """
        )
    }
}
