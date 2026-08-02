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

  // MARK: - T7: the ink on the wash

  /// THE contrast pin. Every skin, both halves of the pair, both washes.
  ///
  /// The washes used to be written as `.backgroundColor` alone, leaving the
  /// foreground on whatever the highlighter had painted. Measured here before
  /// the fix: Graphite's body ink lands at 2.15:1 on the active match's
  /// composited orange and 2.96:1 on the passive yellow, Ink's at 2.40:1
  /// active, Typewriter's dark half at 2.18:1 active — all under the repo's own
  /// `ThemeContrast.minimumTextContrast`. A dark skin's find results were the
  /// hardest text in the document to read.
  ///
  /// The appearance is pinned explicitly on both sides rather than read from
  /// the machine: the adaptive skins carry live semantic colours, so a test
  /// that just calls `tokens` is measuring the Mac it happens to run on.
  func testEveryFindWashCarriesLegibleInkOnEverySkin() {
    for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
      guard let appearance = NSAppearance(named: appearanceName) else {
        XCTFail("no appearance \(appearanceName.rawValue)")
        continue
      }
      appearance.performAsCurrentDrawingAppearance {
        for skin in PensieveTheme.allCases {
          for isDark in [false, true] {
            let tokens = skin.tokens(underDarkSystem: isDark)
            let palette = MarkdownEditorSurface.findWashes(for: tokens)
            let label = "\(skin.rawValue) half=\(isDark ? "dark" : "light")"
              + " appearance=\(appearanceName.rawValue)"

            for (name, wash) in [("passive", palette.passive), ("active", palette.active)] {
              let composited = MarkdownEditorSurface.compositedFindWash(
                wash.background, over: tokens.source.nsColor)
              let ratio = ThemeContrast.ratio(wash.foreground, composited)
              XCTAssertNotNil(ratio, "\(label) \(name): unmeasurable ink")
              XCTAssertGreaterThanOrEqual(
                ratio ?? 0, ThemeContrast.minimumTextContrast,
                "\(label) \(name): find match is not legible on its own wash")
            }
          }
        }
      }
    }
  }

  /// Control leg: the ink swap must not fire wholesale. On the LIGHT fixed
  /// palettes the body ink already carries both washes comfortably, so swapping
  /// to `source` there would throw away the theme's own text colour for nothing.
  func testLightPalettesKeepTheirBodyInkOnTheWash() {
    for skin in [PensieveTheme.parchment, .porcelain] {
      let tokens = skin.tokens
      let palette = MarkdownEditorSurface.findWashes(for: tokens)
      XCTAssertEqual(palette.passive.foreground, tokens.text.nsColor, skin.rawValue)
      XCTAssertEqual(palette.active.foreground, tokens.text.nsColor, skin.rawValue)
    }
  }

  /// Control leg: co-writing the ink must be REVERSIBLE. Ending a find session
  /// has to give the highlighter's own colours back — otherwise every former
  /// match keeps the wash ink on the bare surface, which on a dark skin is the
  /// pane colour, i.e. invisible text.
  @MainActor
  func testEndingAFindSessionGivesTheHighlighterInkBack() {
    let text = "# needle heading\n\nplain needle body\n"
    let (surface, window) = makeHostedSurface(text: text)
    defer { window.contentView = nil }
    surface.applyTheme(.graphite)

    let ns = surface.textStorage.string as NSString
    let headingMatch = ns.range(of: "needle")
    let bodyMatch = ns.range(of: "needle", options: [], range: NSRange(location: 20, length: ns.length - 20))
    XCTAssertNotEqual(bodyMatch.location, NSNotFound)

    func ink(_ at: Int) -> NSColor? {
      surface.textStorage.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor
    }
    let headingInkBefore = ink(headingMatch.location)
    let bodyInkBefore = ink(bodyMatch.location)
    XCTAssertNotNil(headingInkBefore)
    XCTAssertNotEqual(
      headingInkBefore, bodyInkBefore,
      "precondition: the two matches start on DIFFERENT highlighter colours")

    surface.updateFind(query: "needle", visible: true)
    XCTAssertNotEqual(
      ink(headingMatch.location), headingInkBefore,
      "precondition: the wash actually changed the ink")

    surface.clearFindHighlights()

    XCTAssertEqual(
      ink(headingMatch.location), headingInkBefore,
      "the heading kept the find ink after the session ended")
    XCTAssertEqual(
      ink(bodyMatch.location), bodyInkBefore,
      "the body text kept the find ink after the session ended")
  }
}
