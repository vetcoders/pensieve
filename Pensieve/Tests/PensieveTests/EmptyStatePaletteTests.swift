import AppKit
import XCTest

@testable import Pensieve

/// The detail-pane empty state is the document pane with nothing in it: it is
/// mounted by `EditorPreviewSplit` where the editor/preview would go, under a
/// titlebar whose glass is already backed by `tokens.source`. It therefore has
/// to dress from the active skin, not from the system window colours — the
/// reported break was parchment showing a cream titlebar strip above a system
/// grey body that never moved on a skin switch.
final class EmptyStatePaletteTests: XCTestCase {
  /// Every skin's empty state paints the SAME surface the document pane and the
  /// titlebar backing use. This is the pin the pre-fix
  /// `Color(NSColor.windowBackgroundColor)` fails for every fixed skin.
  func testEmptyStateSurfaceIsTheSkinsPaneSurface() {
    for theme in PensieveTheme.allCases {
      let palette = EmptyStatePalette(theme: theme)

      XCTAssertTrue(
        WindowChromeRecipe.colorsMatch(palette.background, theme.tokens.source.nsColor),
        "\(theme.rawValue): the empty state must paint the skin's pane surface")
      XCTAssertTrue(
        WindowChromeRecipe.colorsMatch(
          palette.background, WindowChromeRecipe.titlebarGlassBackingColor(for: theme)),
        "\(theme.rawValue): the pane and the titlebar glass must agree on one surface")
      XCTAssertFalse(
        WindowChromeRecipe.colorsMatch(palette.background, .windowBackgroundColor)
          && theme.tokens.mode != nil,
        "\(theme.rawValue): a fixed skin must not fall back to the system window colour")
    }
  }

  /// Text and chrome on that surface come from the same skin, and are measurably
  /// legible on it. Painting the pane from tokens while leaving the glyphs on the
  /// system label colours is the half-fix this rejects: typewriter pins a LIGHT
  /// appearance (its chrome was drawn for the light window face) over a dark
  /// `#1c1c1c` pane, so system labels would arrive near-black on near-black.
  func testFixedSkinsCarryLegibleEmptyStateChrome() {
    for theme in PensieveTheme.allCases where theme.tokens.mode != nil {
      let palette = EmptyStatePalette(theme: theme)

      XCTAssertTrue(
        ThemeContrast.isLegible(palette.primaryText, on: palette.background),
        "\(theme.rawValue): body text must carry on the empty-state surface")
      XCTAssertTrue(
        ThemeContrast.isLegible(palette.secondaryText, on: palette.background),
        "\(theme.rawValue): labels must carry on the empty-state surface")
      XCTAssertTrue(
        ThemeContrast.isLegible(palette.wordmark, on: palette.background),
        "\(theme.rawValue): the wordmark must carry on the empty-state surface")
      XCTAssertTrue(
        ThemeContrast.isLegible(palette.primaryText, on: palette.keyCapFill),
        "\(theme.rawValue): the shortcut key caps must carry the same body text")
    }
  }

  /// Typewriter's accent IS its source surface — a deliberate collision, because
  /// that accent was drawn for the light window chrome (see `ThemeContrast`). The
  /// wordmark falls back to another token from the SAME theme, never an invented
  /// hex, and never to an accent that would paint itself invisible.
  func testWordmarkFallsBackWhenTheAccentCollidesWithTheSurface() {
    let palette = EmptyStatePalette(theme: .typewriter)
    let tokens = PensieveTheme.typewriter.tokens

    XCTAssertTrue(WindowChromeRecipe.colorsMatch(tokens.accent.nsColor, tokens.source.nsColor))
    XCTAssertTrue(WindowChromeRecipe.colorsMatch(palette.wordmark, tokens.text.nsColor))
  }

  /// A skin whose accent reads fine on its own surface keeps it.
  func testWordmarkKeepsALegibleAccent() {
    for theme in [PensieveTheme.parchment, .graphite, .ink, .porcelain] {
      XCTAssertTrue(
        WindowChromeRecipe.colorsMatch(
          EmptyStatePalette(theme: theme).wordmark, theme.tokens.accent.nsColor),
        "\(theme.rawValue): a legible accent must stay the wordmark tint")
    }
  }

  /// The adaptive skins keep their catalog colours, which resolve per appearance
  /// at draw time. `ThemeContrast` cannot ratio them (no sRGB components), and an
  /// unmeasurable pair must NOT be mistaken for an illegible one — that would
  /// silently retire the blue wordmark on the default skin.
  func testAdaptiveSkinsKeepTheirCatalogTokens() {
    for theme in [PensieveTheme.default, .raw] {
      let palette = EmptyStatePalette(theme: theme)

      XCTAssertNil(theme.tokens.mode, "precondition: \(theme.rawValue) is adaptive")
      XCTAssertEqual(palette.background, NSColor.textBackgroundColor)
      XCTAssertEqual(palette.primaryText, NSColor.textColor)
      XCTAssertEqual(palette.secondaryText, NSColor.secondaryLabelColor)
      XCTAssertEqual(
        palette.wordmark, theme.tokens.accent.nsColor,
        "\(theme.rawValue): an unmeasurable accent must not trigger the collision fallback")
    }
  }
}
