import AppKit
import XCTest

@testable import Pensieve

/// The source panel and the host-window chrome (titlebar glass backing +
/// appearance) must dress from ONE skin at the same instant. A live skin switch
/// that updated the pane colours but left the window chrome on the previous skin
/// produced the half-applied surface the operator hit: teal/brown highlighter
/// tokens on a stale dark pane, dark body text on the old dark background, and a
/// dark titlebar strip — because without an appearance change the live
/// layer-backed window keeps compositing the prior skin's chrome.
///
/// Windows are hosted (contentView) but never ordered on screen, and torn down
/// by detaching the content view — not `close()` — to stay clear of the
/// window-undo-manager teardown SIGSEGV that `MarkdownEditorSurface`'s text view
/// guards on detach (same pattern as `EditorScrollStabilityProbeTests`).
final class EditorThemeChromeTests: XCTestCase {
  @MainActor
  private func makeHostedSurface(skin: PensieveTheme, windowAppearance: NSAppearance.Name)
    -> (MarkdownEditorSurface, NSWindow)
  {
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
    window.appearance = NSAppearance(named: windowAppearance)
    window.contentView = surface.scrollView
    surface.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    surface.scrollView.layoutSubtreeIfNeeded()
    return (surface, window)
  }

  private func srgb(_ color: NSColor) -> NSColor {
    color.usingColorSpace(.sRGB) ?? color
  }

  /// Live switch ink → porcelain: the pane background AND the titlebar backing +
  /// window appearance must all move to the new skin together.
  @MainActor
  func testLiveSkinSwitchMovesSourcePaneAndTitlebarChromeTogether() {
    // Start dark so a switch to a light skin has to actually move the chrome.
    let (surface, window) = makeHostedSurface(skin: .ink, windowAppearance: .darkAqua)
    defer { window.contentView = nil }

    surface.applyTheme(.porcelain)

    let porcelainSource = srgb(PensieveTheme.porcelain.tokens.source.nsColor)

    // Source pane: the property the pane paints from.
    XCTAssertEqual(srgb(surface.textView.backgroundColor), porcelainSource)
    XCTAssertEqual(srgb(surface.scrollView.backgroundColor), porcelainSource)

    // Titlebar backing: the window backing colour the glass strip composites,
    // pinned to the SAME source token (the invariant WindowChromeRecipeTests
    // pins for titlebarGlassBackingColor).
    XCTAssertEqual(
      srgb(window.backgroundColor),
      srgb(WindowChromeRecipe.titlebarGlassBackingColor(for: .porcelain)))

    // Appearance: porcelain is a fixed light skin, so the whole window (and its
    // titlebar glass tint) must be pinned to aqua — not left on the prior dark
    // appearance. This is what forces the live re-composite of the pane.
    XCTAssertEqual(window.appearance?.name, .aqua)
  }

  /// Reverse direction porcelain → ink pins the dark appearance + dark backing.
  @MainActor
  func testLiveSkinSwitchToDarkSkinPinsDarkChrome() {
    let (surface, window) = makeHostedSurface(skin: .porcelain, windowAppearance: .aqua)
    defer { window.contentView = nil }

    surface.applyTheme(.ink)

    XCTAssertEqual(
      srgb(surface.textView.backgroundColor), srgb(PensieveTheme.ink.tokens.source.nsColor))
    XCTAssertEqual(
      srgb(window.backgroundColor),
      srgb(WindowChromeRecipe.titlebarGlassBackingColor(for: .ink)))
    XCTAssertEqual(window.appearance?.name, .darkAqua)
  }

  /// Adaptive skins (default/raw) carry no fixed appearance, so the window is
  /// released back to the system setting rather than force-pinned.
  @MainActor
  func testAdaptiveSkinReleasesWindowAppearanceToSystem() {
    let (surface, window) = makeHostedSurface(skin: .ink, windowAppearance: .darkAqua)
    defer { window.contentView = nil }

    surface.applyTheme(.default)

    XCTAssertNil(window.appearance)
    XCTAssertEqual(
      srgb(window.backgroundColor),
      srgb(WindowChromeRecipe.titlebarGlassBackingColor(for: .default)))
  }

  /// The chrome pin must fire on the FIRST window attach for the persisted skin
  /// too — not only on a change — because at launch `applyTheme` runs before the
  /// surface has a window. `updateNSView` re-invokes `applyWindowChrome` every
  /// pass; here we drive that seam directly with an unchanged skin.
  @MainActor
  func testWindowChromePinsOnFirstAttachForPersistedSkin() {
    let (surface, window) = makeHostedSurface(skin: .parchment, windowAppearance: .darkAqua)
    defer { window.contentView = nil }

    // The skin did not change since construction, but the window only became
    // available after init — the same call updateNSView makes each pass must
    // pin the persisted skin's chrome on that first attach.
    surface.applyWindowChrome(for: .parchment)

    XCTAssertEqual(window.appearance?.name, .aqua)
    XCTAssertEqual(
      srgb(window.backgroundColor),
      srgb(WindowChromeRecipe.titlebarGlassBackingColor(for: .parchment)))
  }

  /// THE regression pin for the live-switch bug: the chrome is an INVARIANT
  /// re-asserted on every update pass, not a one-shot pin.
  ///
  /// A pin guarded on "the skin changed" loses permanently to an external
  /// reset. AppKit re-bridges the hosting view's toolbar into the window
  /// whenever toolbar CONTENT changes — and the theme picker's label carries
  /// the skin name, so every switch re-bridges — and a tab-group reshuffle
  /// re-parents windows; either hands the window back a default appearance
  /// AFTER we pinned it, with no further skin change coming to re-trigger a
  /// pin. Here the external reset is simulated directly: pin, clobber, then
  /// drive the same call `updateNSView` makes each pass and require the chrome
  /// back. Fails on the pre-fix seam, which short-circuits on (skin, window).
  @MainActor
  func testExternalChromeResetIsHealedOnTheNextUpdatePass() {
    let (surface, window) = makeHostedSurface(skin: .ink, windowAppearance: .darkAqua)
    defer { window.contentView = nil }

    surface.applyTheme(.parchment)
    XCTAssertEqual(window.appearance?.name, .aqua)

    // External reset: what a toolbar re-bridge / tab reshuffle does to us.
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = .windowBackgroundColor

    // No skin change — just the next SwiftUI pass.
    surface.applyWindowChrome(for: .parchment)

    XCTAssertEqual(
      window.appearance?.name, .aqua,
      "an external appearance reset must be re-asserted on the next update pass")
    XCTAssertEqual(
      srgb(window.backgroundColor),
      srgb(WindowChromeRecipe.titlebarGlassBackingColor(for: .parchment)),
      "an external backing reset must be re-asserted on the next update pass")
  }

  /// Guard-ordering: a call made while the surface has no window must not
  /// record any "already pinned" bookkeeping, because nothing was pinned. The
  /// pin has to land once the window attaches, with the skin unchanged.
  @MainActor
  func testWindowlessCallDoesNotSuppressThePinAfterAttach() {
    let surface = MarkdownEditorSurface(
      text: "# Heading\n", fontSize: 14, skin: .parchment, syntaxHighlightingEnabled: true)

    // No window yet — this is the launch ordering (`applyTheme` runs before the
    // surface is in a window).
    surface.applyWindowChrome(for: .parchment)

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = surface.scrollView
    defer { window.contentView = nil }

    // Same skin as the windowless call: the pin must still land.
    surface.applyWindowChrome(for: .parchment)

    XCTAssertEqual(window.appearance?.name, .aqua)
    XCTAssertEqual(
      srgb(window.backgroundColor),
      srgb(WindowChromeRecipe.titlebarGlassBackingColor(for: .parchment)))
  }

  /// Repeated switches (dark → light → dark) each move the chrome, and a
  /// re-assert with the skin unchanged is idempotent (reports no correction).
  @MainActor
  func testRepeatedSwitchesMoveChromeAndSteadyStateIsIdempotent() {
    let (surface, window) = makeHostedSurface(skin: .ink, windowAppearance: .darkAqua)
    defer { window.contentView = nil }

    surface.applyTheme(.parchment)
    XCTAssertEqual(window.appearance?.name, .aqua)

    surface.applyTheme(.ink)
    XCTAssertEqual(window.appearance?.name, .darkAqua)
    XCTAssertEqual(
      srgb(window.backgroundColor),
      srgb(WindowChromeRecipe.titlebarGlassBackingColor(for: .ink)))

    surface.applyTheme(.parchment)
    XCTAssertEqual(window.appearance?.name, .aqua)

    // Already correct → nothing to correct, so no redundant set (this is what
    // keeps per-pass re-assertion from becoming a recomposite storm).
    XCTAssertFalse(
      WindowChromeRecipe.assertWindowChrome(on: window, for: .parchment),
      "re-asserting an already-correct chrome must not write anything")
  }

  /// Preview-only mode mounts no source editor, so the editor seam never runs;
  /// the preview must assert the host window's chrome itself or the titlebar
  /// and sidebar stay on the previous skin.
  @MainActor
  func testPreviewChromeAssertsHostWindowAppearance() {
    let preview = PreviewWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = preview
    defer { window.contentView = nil }

    preview.applyThemeChrome(for: .parchment)

    XCTAssertEqual(window.appearance?.name, .aqua)
    XCTAssertEqual(
      srgb(window.backgroundColor),
      srgb(WindowChromeRecipe.titlebarGlassBackingColor(for: .parchment)))
  }

  /// Moving the caret to another source line pushes that 1-based line to the
  /// gutter, which is what lets it pick out the active line's number + accent.
  @MainActor
  func testGutterCurrentLineFollowsCaret() {
    let surface = MarkdownEditorSurface(
      text: "one\ntwo\nthree\n", fontSize: 14, skin: .ink)

    // Caret at the start of "two" (offset 4) → one newline before it → line 2.
    surface.textView.setSelectedRange(NSRange(location: 4, length: 0))
    XCTAssertEqual(surface.textView.gutter?.currentLineNumber, 2)

    // Caret into "three" (offset 8) → two newlines before → line 3.
    surface.textView.setSelectedRange(NSRange(location: 9, length: 0))
    XCTAssertEqual(surface.textView.gutter?.currentLineNumber, 3)
  }

  /// Fenced code rides the SAME live-switch path as the rest of the source
  /// panel. `applyTheme` pushes tokens onto the markdown highlighter AND the
  /// code-block highlighter before the full refresh; pushing them afterwards (or
  /// not at all) leaves already-typed code blocks on the previous skin until the
  /// next keystroke — the stale-colour shape this pins against.
  @MainActor
  func testLiveSkinSwitchRetintsFencedCodeBlocks() {
    let surface = MarkdownEditorSurface(
      text: "intro\n\n```swift\nfunc greet() {}\n```\n", fontSize: 14, skin: .ink)
    let storage = surface.textView.textStorage ?? surface.textStorage
    let keywordAt = (storage.string as NSString).range(of: "func").location

    func keywordColor() -> NSColor? {
      storage.attribute(.foregroundColor, at: keywordAt, effectiveRange: nil) as? NSColor
    }

    XCTAssertEqual(keywordColor(), PensieveTheme.ink.tokens.accent.nsColor)

    surface.applyTheme(.parchment)

    XCTAssertEqual(keywordColor(), PensieveTheme.parchment.tokens.accent.nsColor)
  }
}
