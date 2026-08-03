import XCTest

@testable import Pensieve

/// A standalone HTML export carries its skin's CSS and nothing that pins the
/// viewer's appearance — so anything in the exported page that reads
/// `prefers-color-scheme` on its own answers a question the export already
/// settled, and answers it differently.
///
/// That is what the Mermaid bootstrap did: the skin block painted Typewriter's
/// white sheet while `matchMedia('(prefers-color-scheme: dark)')` handed the
/// diagram the dark palette, so a Typewriter export opened on a dark Mac drew a
/// dark box on a white page (and Graphite on a light Mac drew the mirror image).
/// The in-app WebView never showed it because `readingSurfaceAppearanceName`
/// pins the appearance there; the export has no such pin.
///
/// The diagram now takes its colours from the `--vc-preview-*` tokens the SKIN
/// defines, which is one source of truth rather than two readers of one setting.
final class PreviewMermaidSkinTests: XCTestCase {
  private func document(skin: PensieveTheme) -> PreviewDocument {
    PreviewDocument.make(
      body: "<div class=\"mermaid\" data-vc-block=\"0\">graph TD\nA--&gt;B</div>",
      css: "",
      fontSize: 14,
      skin: skin,
      baseURL: nil,
      mermaidJavaScript: "window.mermaid = { initialize() {}, parse() {}, run() {} };")
  }

  /// Everything after the article — the runtime and bootstrap `<script>` blocks.
  /// Asserting on the whole page would confuse the STYLESHEET's legitimate
  /// `@media (prefers-color-scheme: dark)` block with the SCRIPT reading the
  /// same setting behind the stylesheet's back.
  private func script(for skin: PensieveTheme) -> String {
    let html = document(skin: skin).html
    let scripts = html.components(separatedBy: "</article>")
    XCTAssertEqual(scripts.count, 2, "composed document has no article to split on")
    return scripts.last ?? ""
  }

  /// A skin whose sheet is LIGHT still gets a light diagram when the export is
  /// opened on a dark Mac, because the palette comes from the tokens Typewriter
  /// writes unconditionally — not from the machine reading the file.
  func testLightSkinExportDerivesMermaidPaletteFromItsOwnTokens() {
    let html = document(skin: .typewriter).html

    // The skin states its diagram surface and its ink outright.
    XCTAssertTrue(html.contains("--vc-preview-diagram-bg: #f7f7f7"), html)
    XCTAssertTrue(html.contains("--vc-preview-text: #1c1c1c"), html)

    // And the bootstrap reads exactly those, instead of asking the viewer.
    let bootstrap = script(for: .typewriter)
    XCTAssertFalse(bootstrap.contains("matchMedia"), bootstrap)
    XCTAssertTrue(bootstrap.contains("--vc-preview-diagram-bg"), bootstrap)
    XCTAssertTrue(bootstrap.contains("--vc-preview-text"), bootstrap)
    XCTAssertTrue(bootstrap.contains("--vc-preview-muted"), bootstrap)
    XCTAssertTrue(bootstrap.contains("--vc-preview-border"), bootstrap)
  }

  /// The mirror leg: a DARK skin exported from — or opened on — a light Mac keeps
  /// its dark diagram. One assertion shape, both directions, so a fix that simply
  /// hardcoded "light" would fail here.
  func testDarkSkinExportDerivesMermaidPaletteFromItsOwnTokens() {
    let html = document(skin: .graphite).html

    XCTAssertTrue(html.contains("--vc-preview-diagram-bg: #161616"), html)
    XCTAssertTrue(html.contains("--vc-preview-text: #d2d2d2"), html)

    let bootstrap = script(for: .graphite)
    XCTAssertFalse(bootstrap.contains("matchMedia"), bootstrap)
    XCTAssertTrue(bootstrap.contains("--vc-preview-diagram-bg"), bootstrap)
    XCTAssertTrue(bootstrap.contains("--vc-preview-text"), bootstrap)
  }

  /// CONTROL LEG. The adaptive skins name no colour of their own, so they must
  /// keep following the viewer — and they do, through the token block's own
  /// `@media` rule rather than through a second reader inside the script. Without
  /// this leg the fix could pin every export to one palette and pass the two legs
  /// above.
  func testAdaptiveSkinStillFollowsTheViewerThroughItsTokens() {
    let html = document(skin: .default).html

    // Light by default, dark when the viewer's system says so — one setting,
    // read once, in the stylesheet.
    XCTAssertTrue(html.contains("--vc-preview-diagram-bg: #ffffff"), html)
    XCTAssertTrue(html.contains("--vc-preview-diagram-bg: #18181b"), html)
    XCTAssertTrue(html.contains("@media (prefers-color-scheme: dark)"), html)

    // The bootstrap is the same bootstrap: it resolves the tokens, whatever the
    // stylesheet resolved them to.
    let bootstrap = script(for: .default)
    XCTAssertFalse(bootstrap.contains("matchMedia"), bootstrap)
    XCTAssertTrue(bootstrap.contains("--vc-preview-diagram-bg"), bootstrap)
  }

  /// CONTROL LEG. Every skin gets a palette — the token lookup is not a branch
  /// that quietly covers two skins and leaves the other five on whatever Mermaid
  /// defaults to.
  func testEverySkinResolvesItsDiagramPaletteFromTokens() {
    for skin in PensieveTheme.allCases {
      let bootstrap = script(for: skin)
      XCTAssertTrue(
        bootstrap.contains("themeVariables"),
        "skin \(skin.rawValue) ships no Mermaid theme variables")
      XCTAssertTrue(
        bootstrap.contains("--vc-preview-diagram-bg"),
        "skin \(skin.rawValue) does not read its own diagram surface")
      XCTAssertFalse(
        bootstrap.contains("matchMedia"),
        "skin \(skin.rawValue) still asks the viewer for its diagram palette")
    }
  }
}
