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
