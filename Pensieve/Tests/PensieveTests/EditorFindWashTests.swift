import AppKit
import XCTest

@testable import Pensieve

/// What a find session is allowed to look like while the rest of the app
/// repaints under it.
///
/// Two separate contracts live here. The washes must SURVIVE a deferred retheme
/// sweep — which repaints the document one chunk per frame and strips
/// `.backgroundColor` over every chunk it touches — instead of disappearing
/// until the last chunk lands. And whatever the wash is, the text under it has
/// to stay readable on every skin, which the fixed dark palettes did not.
final class EditorFindWashTests: XCTestCase {
  /// Comfortably past `MarkdownTextStorage.synchronousRethemeCharacterBudget`
  /// so a skin switch takes the DEFERRED path, and seeded with a word the find
  /// bar can match near the very top — the region the sweep strips first and,
  /// before the per-chunk repaint, restored last.
  private func makeDocument() -> String {
    "needle at the very top\n\n"
      + String(repeating: "body text paragraph\n\n", count: 4_000)
  }

  @MainActor
  private func makeHostedSurface(text: String) -> (MarkdownEditorSurface, NSWindow) {
    let surface = MarkdownEditorSurface(text: text, fontSize: 14, skin: .parchment)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = surface.scrollView
    surface.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    surface.scrollView.layoutSubtreeIfNeeded()
    surface.textLayoutManager.ensureLayout(for: surface.textLayoutManager.documentRange)
    return (surface, window)
  }

  /// Runs `body` at the first run-loop turn where `condition` holds, polling in
  /// between so the sweep's own timers keep firing. Fails the test if the moment
  /// never arrives — a pin that silently missed its window asserts nothing.
  @MainActor
  private func whenOnMain(
    _ description: String,
    _ condition: @escaping () -> Bool,
    _ body: @escaping () -> Void
  ) -> XCTestExpectation {
    let met = expectation(description: description)
    let deadline = Date().addingTimeInterval(10.0)
    var poll: (() -> Void)?
    poll = {
      if condition() {
        body()
        met.fulfill()
        poll = nil
        return
      }
      guard Date() < deadline else {
        poll = nil
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { poll?() }
    }
    DispatchQueue.main.async { poll?() }
    return met
  }

  private func background(_ storage: NSTextStorage, at location: Int) -> NSColor? {
    storage.attribute(.backgroundColor, at: location, effectiveRange: nil) as? NSColor
  }

  // MARK: - T14: washes survive the sweep

  /// THE pin. The sweep starts at offset 0, so the FIRST chunk strips the wash
  /// off a match at the top of the document. With `onRethemeCompleted` as the
  /// only signal it came back after the LAST chunk — on a large document, the
  /// entire length of the sweep with the matches invisible.
  ///
  /// Sampled MID-sweep, at a moment that is provably mid-sweep rather than a
  /// guessed delay: the sweep is still in flight and has already passed the
  /// match.
  @MainActor
  func testFindWashesSurviveEachChunkOfADeferredRethemeSweep() {
    let (surface, window) = makeHostedSurface(text: makeDocument())
    defer { window.contentView = nil }

    surface.updateFind(query: "needle", visible: true)
    let match = (surface.textStorage.string as NSString).range(of: "needle")
    XCTAssertNotEqual(match.location, NSNotFound)
    XCTAssertNotNil(
      background(surface.textStorage, at: match.location),
      "precondition: the match carries a wash before the sweep starts")

    // Tight budget so the sweep is many chunks wide and the sample lands while
    // it is genuinely still running.
    surface.textContentStorage.rethemeChunkTimeBudget = 0.0005

    var washMidSweep: NSColor?
    let sampled = whenOnMain(
      "sweep is past the match and still running",
      {
        surface.textContentStorage.isRethemeSweepInFlight
          && surface.textContentStorage.rethemeChunkCount >= 2
      },
      { washMidSweep = self.background(surface.textStorage, at: match.location) })

    surface.applyTheme(.ink)
    wait(for: [sampled], timeout: 10.0)

    XCTAssertEqual(
      washMidSweep, MarkdownEditorSurface.passiveFindWash,
      "the match lost its wash to a chunk that swept past it and had to wait for"
        + " the end of the sweep to get it back")
  }

  /// Control leg: the per-chunk repaint must not INVENT washes. A document with
  /// no find session must come out of the same sweep with no `.backgroundColor`
  /// anywhere the highlighter did not put one.
  @MainActor
  func testASweepWithoutAFindSessionPaintsNoWashes() {
    let (surface, window) = makeHostedSurface(text: makeDocument())
    defer { window.contentView = nil }

    surface.textContentStorage.rethemeChunkTimeBudget = 0.0005
    var sampled: NSColor?
    let met = whenOnMain(
      "sweep running",
      {
        surface.textContentStorage.isRethemeSweepInFlight
          && surface.textContentStorage.rethemeChunkCount >= 2
      },
      { sampled = self.background(surface.textStorage, at: 0) })

    surface.applyTheme(.ink)
    wait(for: [met], timeout: 10.0)

    XCTAssertNil(sampled, "a chunk repaint washed text that is not a find match")
  }
}
