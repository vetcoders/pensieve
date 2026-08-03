import AppKit
import XCTest

@testable import Pensieve

/// A paired skin must survive the Mac being flipped BACK AND FORTH while the app
/// runs — not just be correct at launch.
///
/// The defect these pin was measured on the running app, not argued: with the
/// Mac on dark, Typewriter's dark half drew correctly; flipping the system to
/// light moved the titlebar, the sidebar, the gutter, the status bar and the
/// window appearance, and left the SOURCE PANEL black. A black pane inside an
/// otherwise fully light window.
///
/// The theme layer was never at fault, which is why nothing at `ThemeManager`
/// level could see it: an instrumented build showed the observation firing, the
/// generation counter advancing, `tokens.mode` flipping and the window's
/// appearance following on every flip. What did not move was the one surface
/// whose repaint is gated behind a memo — and the memo's key was the skin ENUM,
/// which a paired skin does not change when its half changes. The memo answered
/// "nothing to do" to the only event it existed to catch.
///
/// So these pins walk the FULL cycle (dark → light → dark) over the real memo
/// and the real editor surface, and assert the panel and the window agree at
/// every step. Windows are hosted but never ordered on screen and are torn down
/// by detaching the content view, matching `EditorThemeChromeTests`.
final class PairedSkinLiveFlipTests: XCTestCase {
  @MainActor
  private func makeHostedSurface(skin: PensieveTheme) -> (MarkdownEditorSurface, NSWindow) {
    let surface = MarkdownEditorSurface(
      text: "# Heading\n\n- item `code`\n",
      fontSize: 14,
      skin: skin,
      syntaxHighlightingEnabled: true)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false)
    window.contentView = surface.scrollView
    surface.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    surface.scrollView.layoutSubtreeIfNeeded()
    return (surface, window)
  }

  private func srgb(_ color: NSColor) -> NSColor {
    color.usingColorSpace(.sRGB) ?? color
  }

  /// THE REGRESSION PIN — one live window, three system settings, no restart.
  ///
  /// Drives exactly what `updateNSView` drives: ask the memo, re-theme when it
  /// says the palette moved, and re-assert the window chrome unconditionally.
  /// Under the old enum key the memo returns `false` on both flips and the
  /// assertions below fail on the very first one.
  @MainActor
  func testTypewriterRepaintsTheSourcePanelOnEveryLiveSystemFlip() throws {
    var memo = EditorRepresentable.RethemeMemo()
    let skin = PensieveTheme.typewriter

    let (surface, window) = try withSystemAppearance(dark: true) {
      let hosted = makeHostedSurface(skin: skin)
      // The surface themes itself in its initialiser, which is what the
      // representable records rather than re-running.
      memo.record(skin.paintedIdentity)
      return hosted
    }
    defer { window.contentView = nil }

    for (step, dark) in [(1, true), (2, false), (3, true)] {
      try withSystemAppearance(dark: dark) {
        if memo.needsReapply(skin.paintedIdentity) {
          surface.applyTheme(skin)
        }
        surface.applyWindowChrome(for: skin)

        let expected = skin.tokens(underDarkSystem: dark)
        XCTAssertEqual(
          srgb(surface.textView.backgroundColor), srgb(expected.source.nsColor),
          "step \(step) (system \(dark ? "dark" : "light")): the source panel is still painted in"
            + " the other half — the memo never noticed the palette moved")
        XCTAssertEqual(
          window.appearance?.name, dark ? .darkAqua : .aqua,
          "step \(step): the window and the panel must dress from ONE half, and the window"
            + " already moved")
      }
    }
  }

  /// The panel is not alone: whatever the flip does, the PAGE stays white. The
  /// pair's whole premise is that the sheet is paper on both sides, so a fix for
  /// the panel must not "fix" the preview into following the system too.
  @MainActor
  func testThePageStaysWhiteAcrossTheSameCycle() throws {
    for dark in [true, false, true] {
      try withSystemAppearance(dark: dark) {
        XCTAssertEqual(
          PensieveTheme.typewriter.readingSurfaceAppearanceName, .aqua,
          "the reading surface followed the system flip")
        XCTAssertEqual(
          srgb(PensieveTheme.typewriter.exportTokens.source.nsColor),
          srgb(PensieveTheme.typewriter.tokens(underDarkSystem: false).source.nsColor),
          "an export taken under a \(dark ? "dark" : "light") Mac stopped being the light sheet")
      }
    }
  }

  /// The perf guard the memo exists for is still a guard: within one half,
  /// repeated passes (every keystroke re-render is one) re-theme nothing.
  @MainActor
  func testRepeatedPassesWithinOneHalfDoNotRetheme() throws {
    var memo = EditorRepresentable.RethemeMemo()
    try withSystemAppearance(dark: true) {
      XCTAssertTrue(memo.needsReapply(PensieveTheme.typewriter.paintedIdentity))
      for pass in 1...20 {
        XCTAssertFalse(
          memo.needsReapply(PensieveTheme.typewriter.paintedIdentity),
          "pass \(pass) re-ran the full highlight refresh with nothing changed — this is the"
            + " per-keystroke hang the perf pins guard against")
      }
    }
  }

  /// An unpaired skin's palette does not read the system setting, so the flip
  /// must cost it nothing. Widening the key to "skin + system setting" for
  /// everyone would repaint every single-mode skin for a change it cannot see.
  @MainActor
  func testAnUnpairedSkinIsNotRethemedByASystemFlip() throws {
    var memo = EditorRepresentable.RethemeMemo()
    try withSystemAppearance(dark: true) {
      XCTAssertTrue(memo.needsReapply(PensieveTheme.ink.paintedIdentity))
    }
    try withSystemAppearance(dark: false) {
      XCTAssertFalse(
        memo.needsReapply(PensieveTheme.ink.paintedIdentity),
        "a single-mode skin was re-themed for a system change its palette cannot see")
    }
  }

  /// The identity itself, stated once: a pair moves with the system, everything
  /// else is the enum and nothing more.
  func testPaintedIdentitySeparatesTheHalvesOnlyForAPair() {
    XCTAssertNotEqual(
      PensieveTheme.typewriter.paintedIdentity(underDarkSystem: true),
      PensieveTheme.typewriter.paintedIdentity(underDarkSystem: false))
    XCTAssertEqual(
      PensieveTheme.ink.paintedIdentity(underDarkSystem: true),
      PensieveTheme.ink.paintedIdentity(underDarkSystem: false))
    XCTAssertNotEqual(
      PensieveTheme.ink.paintedIdentity(underDarkSystem: true),
      PensieveTheme.parchment.paintedIdentity(underDarkSystem: true))
  }
}
