import XCTest

@testable import Pensieve

final class PreviewThemeTests: XCTestCase {
  // MARK: - skinCSS overlay composition

  func testDefaultSkinEmitsNoOverlayRules() {
    let css = PreviewWebView.skinCSS(for: .default)
    // Default is a comment marker only — the established GitHub surface stays
    // byte-for-byte unchanged.
    XCTAssertTrue(css.contains("vc-skin:default"))
    XCTAssertFalse(css.contains(".markdown-body"))
  }

  func testPaperSkinIsSerifAndNarrow() {
    let css = PreviewWebView.skinCSS(for: .paper)
    XCTAssertTrue(css.contains("vc-skin:paper"))
    XCTAssertTrue(css.contains("serif"))
    XCTAssertTrue(css.contains("max-width: 720px"))
  }

  func testCodeSkinIsMonospace() {
    let css = PreviewWebView.skinCSS(for: .code)
    XCTAssertTrue(css.contains("vc-skin:code"))
    XCTAssertTrue(css.contains("monospace"))
  }

  func testRawSkinStripsChrome() {
    let css = PreviewWebView.skinCSS(for: .raw)
    XCTAssertTrue(css.contains("vc-skin:raw"))
    XCTAssertTrue(css.contains("max-width: none"))
  }

  func testNotionSkinUsesNotionTokens() {
    let css = PreviewWebView.skinCSS(for: .notion)
    XCTAssertTrue(css.contains("vc-skin:notion"))
    // Notion ink + red inline-code accent are the signature tokens.
    XCTAssertTrue(css.contains("#37352f"))
    XCTAssertTrue(css.contains("--vc-preview-notion-code"))
  }

  func testVistaSkinBandsTables() {
    let css = PreviewWebView.skinCSS(for: .vista)
    XCTAssertTrue(css.contains("vc-skin:vista"))
    XCTAssertTrue(css.contains("Helvetica"))
    // Banded rows are the VISTA table signature.
    XCTAssertTrue(css.contains("tbody tr:nth-child(even)"))
  }

  func testMLASkinIsSerifAndDoubleSpaced() {
    let css = PreviewWebView.skinCSS(for: .mla)
    XCTAssertTrue(css.contains("vc-skin:mla"))
    XCTAssertTrue(css.contains("serif"))
    XCTAssertTrue(css.contains("line-height: 2.0"))
  }

  func testJamstaticSkinIsPoppinsWithLilacAccent() {
    let css = PreviewWebView.skinCSS(for: .jamstatic)
    XCTAssertTrue(css.contains("vc-skin:jamstatic"))
    XCTAssertTrue(css.contains("Poppins"))
    XCTAssertTrue(css.contains("#b1a3cc"))
  }

  func testVercelSkinIsBlueLinkOnNearBlackInk() {
    let css = PreviewWebView.skinCSS(for: .vercel)
    XCTAssertTrue(css.contains("vc-skin:vercel"))
    XCTAssertTrue(css.contains("#171717"))
    XCTAssertTrue(css.contains("Geist"))
  }

  func testThemeableSkinIsInterOnSlate() {
    let css = PreviewWebView.skinCSS(for: .themeable)
    XCTAssertTrue(css.contains("vc-skin:themeable"))
    XCTAssertTrue(css.contains("Inter"))
    XCTAssertTrue(css.contains("#1e293b"))
  }

  func testGlassSkinIsBackdropBlurred() {
    let css = PreviewWebView.skinCSS(for: .glass)
    XCTAssertTrue(css.contains("vc-skin:glass"))
    XCTAssertTrue(css.contains("backdrop-filter: blur"))
    XCTAssertTrue(css.contains("linear-gradient"))
  }

  func testEverySkinIsExhaustivelyCovered() {
    // Guards against an enum case being added without a skinCSS branch + marker.
    for skin in ThemeManager.PreviewTheme.allCases {
      let css = PreviewWebView.skinCSS(for: skin)
      XCTAssertTrue(
        css.contains("vc-skin:\(skin.rawValue)"),
        "skin \(skin.rawValue) is missing its overlay marker")
    }
  }

  // MARK: - appearanceCSS threads the skin through

  func testAppearanceCSSAppendsSkinOverlay() {
    let base = PreviewWebView.appearanceCSS(fontSize: 14, skin: .default)
    let paper = PreviewWebView.appearanceCSS(fontSize: 14, skin: .paper)

    // Both carry the shared base tokens...
    XCTAssertTrue(base.contains("--vc-preview-text"))
    XCTAssertTrue(paper.contains("--vc-preview-text"))
    // ...but only the paper skin appends its overlay marker.
    XCTAssertFalse(base.contains("vc-skin:paper"))
    XCTAssertTrue(paper.contains("vc-skin:paper"))
  }

  func testAppearanceCSSDefaultsToDefaultSkin() {
    // The skin parameter is defaulted so legacy call sites keep compiling and
    // render the established surface.
    let css = PreviewWebView.appearanceCSS(fontSize: 14)
    XCTAssertTrue(css.contains("vc-skin:default"))
  }

  func testAppearanceCSSKeepsTitlebarOverlapTransparent() {
    let css = PreviewWebView.appearanceCSS(fontSize: 14, skin: .paper)

    XCTAssertTrue(css.contains("--vc-preview-titlebar-glass-height: 64px"))
    XCTAssertTrue(css.contains("body::before"))
    XCTAssertTrue(css.contains("top: var(--vc-preview-titlebar-glass-height)"))
    XCTAssertTrue(css.contains("background: var(--vc-preview-page-background)"))
    XCTAssertTrue(css.contains("--vc-preview-page-background: var(--vc-preview-paper-bg)"))
    XCTAssertFalse(css.contains("background: var(--vc-preview-paper-bg) !important"))
  }

  func testOpaqueSkinsRouteBackgroundThroughPageBackdropToken() {
    let skins: [ThemeManager.PreviewTheme] = [
      .paper,
      .code,
      .notion,
      .vista,
      .mla,
      .jamstatic,
      .vercel,
      .themeable,
      .glass,
    ]

    for skin in skins {
      XCTAssertTrue(
        PreviewWebView.skinCSS(for: skin).contains("--vc-preview-page-background"),
        "skin \(skin.rawValue) should keep its pane background below the glass strip")
    }

    XCTAssertFalse(PreviewWebView.skinCSS(for: .default).contains("--vc-preview-page-background"))
    XCTAssertFalse(PreviewWebView.skinCSS(for: .raw).contains("--vc-preview-page-background"))
  }

  // MARK: - request carries the skin axis

  func testRenderRequestCarriesSkinAndDefaultsToDefault() {
    let withDefault = PreviewRenderRequest(
      markdown: "x", fontSize: 14, theme: .gfm, documentURL: nil)
    XCTAssertEqual(withDefault.skin, .default)

    let withCode = PreviewRenderRequest(
      markdown: "x", fontSize: 14, theme: .gfm, skin: .code, documentURL: nil)
    XCTAssertEqual(withCode.skin, .code)
    // Skin participates in equality so a skin change is a distinct request.
    XCTAssertNotEqual(withDefault, withCode)
  }

  // MARK: - ThemeManager persists the skin

  func testThemeManagerPersistsSkinSelection() {
    let suiteName = "pensieve.preview.skin.tests"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let manager = ThemeManager(defaults: defaults)
    XCTAssertEqual(manager.skin, .default)
    manager.skin = .paper

    let reloaded = ThemeManager(defaults: defaults)
    XCTAssertEqual(reloaded.skin, .paper)

    defaults.removePersistentDomain(forName: suiteName)
  }
}
