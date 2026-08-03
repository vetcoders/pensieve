import AppKit
import XCTest

@testable import Pensieve

/// The source panel's typeface contract: every theme dresses it in its own
/// bundled monospace family, and the adaptive skins keep the system face.
final class MonoFontResolverTests: XCTestCase {
  // MARK: - Family resolution

  func testThemedFamilyDressesTheSourcePanel() {
    let highlighter = SyntaxHighlighter()
    highlighter.tokens = PensieveTheme.typewriter.tokens

    XCTAssertEqual(highlighter.baseFont.familyName, "Spline Sans Mono")
  }

  func testEveryThemedMonoFamilyResolvesToItsOwnFace() {
    for theme in PensieveTheme.allCases {
      let family = theme.tokens.monoFamily
      guard !family.isEmpty else { continue }
      let resolved = MonoFontResolver.font(family: family, size: 14)
      XCTAssertEqual(
        resolved.familyName, family,
        "\(theme.rawValue) must render its source panel in \(family)")
    }
  }

  /// `default` and `raw` carry no bundled family and must keep the face the source
  /// panel always had.
  func testAdaptiveThemesKeepTheSystemMonospacedFace() {
    for theme in [PensieveTheme.default, .raw] {
      XCTAssertTrue(theme.tokens.monoFamily.isEmpty, "\(theme.rawValue) must carry no family")
      let highlighter = SyntaxHighlighter()
      highlighter.tokens = theme.tokens
      XCTAssertEqual(
        highlighter.baseFont, NSFont.monospacedSystemFont(ofSize: 14, weight: .regular))
    }
  }

  func testUnresolvableFamilyFallsBackToTheSystemMonospacedFace() {
    XCTAssertEqual(
      MonoFontResolver.font(family: "Pensieve No Such Family", size: 13),
      NSFont.monospacedSystemFont(ofSize: 13, weight: .regular))
  }

  /// The gutter's fallback stays `monospacedDigitSystemFont`, so the adaptive
  /// skins' line numbers keep their historical figures.
  func testGutterFallbackKeepsTheSystemTabularFigures() {
    XCTAssertEqual(
      MonoFontResolver.font(family: "", size: 12, fallback: .monoDigits),
      NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular))
  }

  // MARK: - Weight

  /// IBM Plex Mono is bundled as 400/500/600, and its 500/600 files declare the
  /// family names "IBM Plex Mono Medium"/"IBM Plex Mono SemiBold" in their own
  /// `name` tables — so a family+trait lookup finds no heavier member and bold
  /// would silently collapse onto regular. Resolution goes through the bundled
  /// FILE list precisely so it does not.
  func testBoldResolvesToTheHeaviestBundledFaceEvenOutsideTheFamilyName() {
    let regular = MonoFontResolver.font(family: "IBM Plex Mono", size: 14)
    let bold = MonoFontResolver.font(family: "IBM Plex Mono", size: 14, weight: .bold)

    XCTAssertNotEqual(
      bold.fontName, regular.fontName,
      "bold must not collapse onto the regular face")
    XCTAssertGreaterThan(
      NSFontManager.shared.weight(of: bold), NSFontManager.shared.weight(of: regular))
  }

  // MARK: - Live skin switch

  /// `monoFamily` is a token, so a skin switch has to re-FONT the pane and not
  /// only retint it — the highlighter's font cache is keyed on the family for
  /// exactly this reason.
  func testLiveSkinSwitchRefontsTheSourcePanel() {
    let highlighter = SyntaxHighlighter()
    let storage = NSTextStorage(string: "plain text")
    let fullRange = NSRange(location: 0, length: storage.length)

    highlighter.tokens = PensieveTheme.typewriter.tokens
    highlighter.resetBaseAttributes(storage, range: fullRange)
    XCTAssertEqual(font(in: storage, at: 0)?.familyName, "Spline Sans Mono")

    highlighter.tokens = PensieveTheme.parchment.tokens
    highlighter.resetBaseAttributes(storage, range: fullRange)
    XCTAssertEqual(font(in: storage, at: 0)?.familyName, "Sometype Mono")
  }

  // MARK: - Italic

  /// Sometype Mono ships upright weights only. Without a synthesised slant
  /// `*emphasis*` would be indistinguishable from body text.
  func testItalicIsSynthesisedForAFamilyWithNoItalicFace() {
    let highlighter = SyntaxHighlighter()
    let storage = NSTextStorage(string: "a *word* b")
    highlighter.tokens = PensieveTheme.parchment.tokens
    highlighter.highlight(storage, range: NSRange(location: 0, length: storage.length))

    XCTAssertEqual(font(in: storage, at: 3)?.familyName, "Sometype Mono")
    XCTAssertEqual(
      storage.attribute(.obliqueness, at: 3, effectiveRange: nil) as? CGFloat,
      MonoFontResolver.syntheticItalicObliqueness)
  }

  /// Spline Sans Mono DOES bundle a 400 italic, so typewriter gets the real face
  /// and no faux slant on top of it.
  func testItalicUsesTheRealFaceWhenTheFamilyBundlesOne() {
    let highlighter = SyntaxHighlighter()
    let storage = NSTextStorage(string: "a *word* b")
    highlighter.tokens = PensieveTheme.typewriter.tokens
    highlighter.highlight(storage, range: NSRange(location: 0, length: storage.length))

    let italic = font(in: storage, at: 3)
    XCTAssertEqual(italic?.familyName, "Spline Sans Mono")
    XCTAssertTrue(
      italic?.fontDescriptor.symbolicTraits.contains(.italic) == true,
      "expected a real italic face, got \(italic?.fontName ?? "nil")")
    XCTAssertNil(storage.attribute(.obliqueness, at: 3, effectiveRange: nil))
  }

  /// A synthesised slant lives in `.obliqueness`, which the base-attribute reset
  /// has to strip like every other span attribute — otherwise text that stops
  /// being emphasised keeps leaning.
  func testResetClearsASynthesisedSlant() {
    let highlighter = SyntaxHighlighter()
    let storage = NSTextStorage(string: "a *word* b")
    let fullRange = NSRange(location: 0, length: storage.length)
    highlighter.tokens = PensieveTheme.parchment.tokens
    highlighter.highlight(storage, range: fullRange)
    XCTAssertNotNil(storage.attribute(.obliqueness, at: 3, effectiveRange: nil))

    highlighter.resetBaseAttributes(storage, range: fullRange)

    XCTAssertNil(storage.attribute(.obliqueness, at: 3, effectiveRange: nil))
  }

  // MARK: - Caching

  /// The gutter resolves its number font on EVERY repaint (i.e. every scroll) and
  /// the highlighter on every pass, so resolution has to be a dictionary hit
  /// after the first construction — CoreText lookups here would be a per-scroll
  /// cost.
  func testRepeatedResolutionConstructsTheFaceOnce() {
    // Warm the entry first: its very first construction is the one that is allowed.
    _ = MonoFontResolver.font(family: "JetBrains Mono", size: 11.5, weight: .semibold)
    let before = MonoFontResolver.resolutionCount

    for _ in 0..<50 {
      _ = MonoFontResolver.font(family: "JetBrains Mono", size: 11.5, weight: .semibold)
    }

    XCTAssertEqual(MonoFontResolver.resolutionCount, before)
  }

  private func font(in storage: NSTextStorage, at location: Int) -> NSFont? {
    storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont
  }
}
