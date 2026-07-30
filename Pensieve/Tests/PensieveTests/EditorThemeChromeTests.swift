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
}
