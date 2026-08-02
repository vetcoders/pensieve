import AppKit
import XCTest

@testable import Pensieve

/// Behavior-preservation tests for the syntax + code-block highlighters.
///
/// The regex-cache refactor (compile-once `static let` tables, single string
/// bridge, cached fonts) must NOT change the OUTPUT — same matched ranges, same
/// attributes/colors/fonts, same order of application. These tests pin the
/// observable attribute output for representative markdown so a future change to
/// caching can't silently alter highlighting.
final class SyntaxHighlighterTests: XCTestCase {
  private let fontSize: CGFloat = 14

  /// Builds a fully highlighted `NSTextStorage` the same way `MarkdownTextStorage`
  /// does for a full refresh: reset base attributes, then markdown, then code blocks.
  private func highlighted(_ markdown: String) -> NSTextStorage {
    let storage = NSTextStorage(string: markdown)
    let fullRange = NSRange(location: 0, length: (markdown as NSString).length)

    let syntax = SyntaxHighlighter()
    syntax.baseFontSize = fontSize
    let codeBlocks = CodeBlockHighlighter()
    codeBlocks.baseFontSize = fontSize

    storage.beginEditing()
    syntax.resetBaseAttributes(storage, range: fullRange)
    syntax.highlight(storage, range: fullRange)
    codeBlocks.highlight(storage, range: fullRange)
    storage.endEditing()
    return storage
  }

  /// Locates the first occurrence of `needle` and returns the index of the
  /// `offsetWithinNeedle`-th character of that occurrence (UTF-16 / NSString).
  private func index(of needle: String, in haystack: String, offsetWithinNeedle: Int = 0) -> Int {
    let ns = haystack as NSString
    let range = ns.range(of: needle)
    XCTAssertNotEqual(range.location, NSNotFound, "needle \(needle) not found in \(haystack)")
    return range.location + offsetWithinNeedle
  }

  private func color(_ storage: NSTextStorage, at index: Int) -> NSColor? {
    storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
  }

  private func font(_ storage: NSTextStorage, at index: Int) -> NSFont? {
    storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
  }

  private func backgroundColor(_ storage: NSTextStorage, at index: Int) -> NSColor? {
    storage.attribute(.backgroundColor, at: index, effectiveRange: nil) as? NSColor
  }

  private func underline(_ storage: NSTextStorage, at index: Int) -> Int? {
    storage.attribute(.underlineStyle, at: index, effectiveRange: nil) as? Int
  }

  private func strikethrough(_ storage: NSTextStorage, at index: Int) -> Int? {
    storage.attribute(.strikethroughStyle, at: index, effectiveRange: nil) as? Int
  }

  // MARK: - Heading

  func testHeadingUsesThemeHeadingColorAndBold() {
    // Default theme: headings are a neutral variant of the text colour
    // (labelColor), never the old systemGreen accent.
    let md = "# Title\n"
    let storage = highlighted(md)
    let at = index(of: "Title", in: md)
    XCTAssertEqual(color(storage, at: at), NSColor.labelColor)
    let f = font(storage, at: at)
    XCTAssertNotNil(f)
    // Level-1 heading: baseFontSize + (7-1)*2 = 14 + 12 = 26, bold system font.
    XCTAssertEqual(f?.pointSize, fontSize + CGFloat((7 - 1) * 2))
    XCTAssertTrue(
      f.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false,
      "heading font should carry the bold trait")
  }

  func testHeadingLevelControlsSize() {
    let md = "### Sub\n"
    let storage = highlighted(md)
    let at = index(of: "Sub", in: md)
    XCTAssertEqual(font(storage, at: at)?.pointSize, fontSize + CGFloat((7 - 3) * 2))
  }

  // MARK: - Bold

  func testBoldUsesBoldMonospacedFont() {
    let md = "a **strong** b"
    let storage = highlighted(md)
    let at = index(of: "strong", in: md)
    let expected = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    XCTAssertEqual(font(storage, at: at), expected)
  }

  // MARK: - Italic

  func testItalicUsesItalicTraitFont() {
    let md = "a *slanted* b"
    let storage = highlighted(md)
    let at = index(of: "slanted", in: md)
    let f = font(storage, at: at)
    XCTAssertNotNil(f)
    XCTAssertTrue(
      f.map { NSFontManager.shared.traits(of: $0).contains(.italicFontMask) } ?? false,
      "italic font should carry the italic trait")
  }

  // MARK: - Inline code

  func testInlineCodeUsesThemeCodeColorWithBackground() {
    // Default theme: inline code foreground is the theme's srcInlineCode token
    // (labelColor for the adaptive default); the code background is unchanged.
    let md = "call `foo()` now"
    let storage = highlighted(md)
    let at = index(of: "foo()", in: md)
    XCTAssertEqual(color(storage, at: at), NSColor.labelColor)
    let expectedBackground = NSColor.textBackgroundColor.withSystemEffect(.disabled)
    XCTAssertEqual(backgroundColor(storage, at: at), expectedBackground)
    XCTAssertEqual(
      font(storage, at: at), NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
  }

  // MARK: - Link

  func testLinkUsesThemeLinkColorAndUnderlined() {
    // Default theme: links use the srcLink token (linkColor for the adaptive
    // default) instead of controlAccentColor, so links and list markers share
    // one theme accent family rather than two different system blues.
    let md = "see [docs](https://x.io) here"
    let storage = highlighted(md)
    let at = index(of: "docs", in: md)
    XCTAssertEqual(color(storage, at: at), NSColor.linkColor)
    XCTAssertEqual(underline(storage, at: at), NSUnderlineStyle.single.rawValue)
  }

  // MARK: - Task checkbox

  func testTaskCheckboxUsesThemeListMarkerColorSemibold() {
    // Default theme: list markers/checkboxes use the srcListMarker token
    // (secondaryLabelColor for the adaptive default), not systemBlue.
    let md = "- [x] done\n"
    let storage = highlighted(md)
    // The marker run is the "- [x]" portion; sample inside the bracket.
    let at = index(of: "[x]", in: md)
    XCTAssertEqual(color(storage, at: at), NSColor.secondaryLabelColor)
    XCTAssertEqual(
      font(storage, at: at), NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold))
  }

  func testInProgressTaskCheckboxGetsTheSameMarkerTreatment() {
    // `[~]` is the third state ("in progress"); the source panel must not leave
    // it looking like prose next to `[ ]` and `[x]`.
    let md = "- [~] wip\n"
    let storage = highlighted(md)
    let at = index(of: "[~]", in: md)
    XCTAssertEqual(color(storage, at: at), NSColor.secondaryLabelColor)
    XCTAssertEqual(
      font(storage, at: at), NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold))
  }

  /// A task marker needs a separator after the bracket, exactly like the emitter
  /// demands (`HTMLEmitter` drops the marker unless the remainder starts with
  /// whitespace or is empty). Without the trailing lookahead the source pane
  /// styled `- [~]wip` as a checkbox while the preview rendered a plain bullet —
  /// the two panes describing the same line differently.
  func testCheckboxNeedsASeparatorAfterTheBracket() {
    let semibold = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
    for md in ["- [~]wip\n", "- [x]wip\n", "- [ ]wip\n"] {
      let storage = highlighted(md)
      // Index 2 is the `[`: inside the bracket, past the `-` the plain
      // unordered-list rule legitimately still claims.
      XCTAssertNotEqual(
        font(storage, at: 2), semibold,
        "\(md) has no separator after the bracket — the preview renders a bullet")
      XCTAssertNotEqual(color(storage, at: 2), NSColor.secondaryLabelColor, md)
    }
  }

  /// Control leg: the tightened pattern must not stop matching a WELL-FORMED
  /// marker, in any of the three states or at end of line without a trailing
  /// space.
  func testCheckboxStillMatchesWithASeparatorOrAtEndOfLine() {
    let semibold = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
    for md in ["- [~] wip\n", "- [x] done\n", "- [ ] todo\n", "- [x]\n", "- [ ]"] {
      let storage = highlighted(md)
      XCTAssertEqual(font(storage, at: 2), semibold, md)
      XCTAssertEqual(color(storage, at: 2), NSColor.secondaryLabelColor, md)
    }
  }

  func testEmptyAndCheckedCheckboxesStillMatchAfterThirdState() {
    for md in ["- [ ] todo\n", "* [x] done\n", "+ [X] shouted\n"] {
      let storage = highlighted(md)
      XCTAssertEqual(
        font(storage, at: 2), NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
        md)
    }
  }

  // MARK: - List markers

  func testUnorderedListMarkerUsesThemeListMarkerColor() {
    let md = "- item\n"
    let storage = highlighted(md)
    // The dash marker is at index 0.
    XCTAssertEqual(color(storage, at: 0), NSColor.secondaryLabelColor)
  }

  func testOrderedListMarkerUsesThemeListMarkerColor() {
    let md = "1. item\n"
    let storage = highlighted(md)
    XCTAssertEqual(color(storage, at: 0), NSColor.secondaryLabelColor)
  }

  // MARK: - Strikethrough & blockquote

  func testStrikethroughUsesThemeStrikeColorWithLine() {
    // Default theme: strikethrough uses the srcStrike token
    // (secondaryLabelColor for the adaptive default), not systemOrange.
    let md = "x ~~gone~~ y"
    let storage = highlighted(md)
    let at = index(of: "gone", in: md)
    XCTAssertEqual(color(storage, at: at), NSColor.secondaryLabelColor)
    XCTAssertEqual(strikethrough(storage, at: at), NSUnderlineStyle.single.rawValue)
  }

  func testHighlightMarkupGetsThemeMarkBackground() {
    let md = "x ==marked== y"
    let storage = highlighted(md)
    let at = index(of: "marked", in: md)

    // Default theme: highlight foreground is the theme text token (textColor);
    // the mark background is the theme highlight token (systemYellow @ 35% for
    // the adaptive default).
    XCTAssertEqual(color(storage, at: at), NSColor.textColor)
    XCTAssertEqual(backgroundColor(storage, at: at), NSColor.systemYellow.withAlphaComponent(0.35))
  }

  /// The mark wash against the body ink, on BOTH halves of the Typewriter pair —
  /// which is to say in a dark office and a light one, because that is what
  /// picks the half.
  ///
  /// On the DARK half the wash (`#e6e6e6`) is one step from the body text
  /// (`#d4d4d4`) — ≈1.2:1, a highlight that erases what it marks — so the marked
  /// span falls back to the theme's own `source` token and reads as an inverted
  /// stamp. On the LIGHT half the same wash carries `#1c1c1c` ink at ≈13.7:1, so
  /// there is nothing to fall back FROM and the span keeps the body colour.
  ///
  /// The half is passed in rather than read from the machine. `tokens` resolves
  /// a paired skin against the LIVE system setting, so a test that reads it is
  /// measuring the Mac it happens to run on: this pair of assertions used to
  /// pass on a dark laptop and fail on a light CI runner, describing the same
  /// correct product either way.
  func testHighlightForegroundHonoursTheWashOnBothHalvesOfThePair() {
    for isDark in [true, false] {
      let tokens = PensieveTheme.typewriter.tokens(underDarkSystem: isDark)
      let half = isDark ? "dark" : "light"
      let md = "x ==marked== y"
      let storage = NSTextStorage(string: md)
      let fullRange = NSRange(location: 0, length: (md as NSString).length)

      let syntax = SyntaxHighlighter()
      syntax.baseFontSize = fontSize
      syntax.tokens = tokens

      storage.beginEditing()
      syntax.resetBaseAttributes(storage, range: fullRange)
      syntax.highlight(storage, range: fullRange)
      storage.endEditing()

      let at = index(of: "marked", in: md)
      XCTAssertEqual(
        backgroundColor(storage, at: at), tokens.srcHighlightBackground.nsColor, "\(half) half")

      let painted = color(storage, at: at)
      if isDark {
        XCTAssertEqual(
          painted, tokens.source.nsColor,
          "\(half) half: the wash swallows the body ink, so the stamp must invert")
        XCTAssertNotEqual(
          painted, tokens.text.nsColor,
          "\(half) half: the body text colour is invisible on this wash")
      } else {
        XCTAssertEqual(
          painted, tokens.text.nsColor,
          "\(half) half: the body ink carries on this wash — falling back would discard it")
      }

      // Whatever it chose, what it chose has to be readable on the wash.
      let ratio = ThemeContrast.ratio(painted ?? .clear, tokens.srcHighlightBackground.nsColor)
      XCTAssertNotNil(ratio, "\(half) half")
      XCTAssertGreaterThanOrEqual(
        ratio ?? 0, ThemeContrast.minimumTextContrast,
        "\(half) half: the marked span is not legible on its own wash")
    }
  }

  /// Every other fixed palette already reads on its own wash, so the marked span
  /// keeps the body text colour — the fallback must not fire wholesale.
  func testHighlightForegroundKeepsTheTextColourWhenTheWashIsLegible() {
    for skin in [PensieveTheme.parchment, .graphite, .ink, .porcelain] {
      let tokens = skin.tokens
      let md = "x ==marked== y"
      let storage = NSTextStorage(string: md)
      let fullRange = NSRange(location: 0, length: (md as NSString).length)

      let syntax = SyntaxHighlighter()
      syntax.baseFontSize = fontSize
      syntax.tokens = tokens

      storage.beginEditing()
      syntax.resetBaseAttributes(storage, range: fullRange)
      syntax.highlight(storage, range: fullRange)
      storage.endEditing()

      XCTAssertEqual(
        color(storage, at: index(of: "marked", in: md)), tokens.text.nsColor, skin.rawValue)
    }
  }

  func testBlockquoteIsSecondaryLabel() {
    let md = "> quoted line\n"
    let storage = highlighted(md)
    let at = index(of: "quoted", in: md)
    XCTAssertEqual(color(storage, at: at), NSColor.secondaryLabelColor)
  }

  // MARK: - Theme tokens drive the source-panel colours

  func testHighlighterHonoursThemeTokens() {
    // A fixed-palette theme replaces every adaptive default: heading and link
    // resolve to the theme's own hex tokens, proving the source panel is driven
    // by ThemeTokens rather than hardcoded system colours.
    let md = "# Title\nsee [docs](https://x.io)\n"
    let storage = NSTextStorage(string: md)
    let fullRange = NSRange(location: 0, length: (md as NSString).length)

    let syntax = SyntaxHighlighter()
    syntax.baseFontSize = fontSize
    syntax.tokens = PensieveTheme.ink.tokens

    storage.beginEditing()
    syntax.resetBaseAttributes(storage, range: fullRange)
    syntax.highlight(storage, range: fullRange)
    storage.endEditing()

    let headingAt = index(of: "Title", in: md)
    XCTAssertEqual(
      color(storage, at: headingAt), PensieveTheme.ink.tokens.srcHeading.nsColor)
    let linkAt = index(of: "docs", in: md)
    XCTAssertEqual(color(storage, at: linkAt), PensieveTheme.ink.tokens.srcLink.nsColor)
    // Base text also follows the theme text token.
    let baseAt = index(of: "see", in: md)
    XCTAssertEqual(color(storage, at: baseAt), PensieveTheme.ink.tokens.text.nsColor)
  }

  // MARK: - Code block (Swift)

  func testSwiftFencedBlockKeywordsUseThemeAccent() {
    // Fenced code spends the theme's ONE accent on keywords (linkColor for the
    // adaptive default), never the old systemPink.
    let md = "```swift\nfunc greet() {}\n```"
    let storage = highlighted(md)
    let at = index(of: "func", in: md)
    XCTAssertEqual(color(storage, at: at), PensieveTheme.default.tokens.accent.nsColor)
  }

  func testSwiftFencedBlockStringUsesThemeCodeToken() {
    // String literals take srcInlineCode — the source panel's one warm token —
    // so prose code and fenced strings read as the same family.
    let md = "```swift\nlet s = \"hi\"\n```"
    let storage = highlighted(md)
    // Sample inside the quoted string literal.
    let at = index(of: "\"hi\"", in: md, offsetWithinNeedle: 1)
    XCTAssertEqual(color(storage, at: at), PensieveTheme.default.tokens.srcInlineCode.nsColor)
  }

  func testSwiftFencedBlockCommentUsesThemeQuoteToken() {
    let md = "```swift\n// note\n```"
    let storage = highlighted(md)
    let at = index(of: "// note", in: md)
    XCTAssertEqual(color(storage, at: at), PensieveTheme.default.tokens.srcQuote.nsColor)
  }

  func testSwiftFencedBlockBaseUsesThemeMutedToken() {
    let md = "```swift\nx\n```"
    let storage = highlighted(md)
    // The lone `x` is not a keyword/string/comment, so it keeps the code-block
    // base wash (the theme's muted token) applied across the whole match.
    let at = index(of: "\nx\n", in: md, offsetWithinNeedle: 1)
    XCTAssertEqual(color(storage, at: at), PensieveTheme.default.tokens.muted.nsColor)
  }

  // MARK: - Code block (JSON)

  func testJSONFencedBlockKeyIsAccentAndBoolIsBodyText() {
    // Object keys are structure → accent (same family as keywords, which JSON
    // has none of). Values are payload → the achromatic text token, so numbers
    // and booleans never compete with the accent.
    let md = "```json\n{\"k\": true}\n```"
    let storage = highlighted(md)
    let keyAt = index(of: "\"k\"", in: md, offsetWithinNeedle: 1)
    XCTAssertEqual(color(storage, at: keyAt), PensieveTheme.default.tokens.accent.nsColor)
    let boolAt = index(of: "true", in: md)
    XCTAssertEqual(color(storage, at: boolAt), PensieveTheme.default.tokens.text.nsColor)
  }

  // MARK: - Code block honours theme tokens

  /// A fixed-palette theme must reach the fenced-code table too: every role
  /// resolves to the theme's own hex tokens, proving the code-block highlighter
  /// is driven by `ThemeTokens` rather than hardcoded system colours.
  func testCodeBlockHighlighterHonoursThemeTokens() {
    let md = "```swift\nfunc greet() { let s = \"hi\" } // note\nx\n```"
    let storage = NSTextStorage(string: md)
    let fullRange = NSRange(location: 0, length: (md as NSString).length)

    let codeBlocks = CodeBlockHighlighter()
    codeBlocks.baseFontSize = fontSize
    codeBlocks.tokens = PensieveTheme.parchment.tokens

    storage.beginEditing()
    codeBlocks.highlight(storage, range: fullRange)
    storage.endEditing()

    let tokens = PensieveTheme.parchment.tokens
    XCTAssertEqual(color(storage, at: index(of: "func", in: md)), tokens.accent.nsColor)
    XCTAssertEqual(
      color(storage, at: index(of: "\"hi\"", in: md, offsetWithinNeedle: 1)),
      tokens.srcInlineCode.nsColor)
    XCTAssertEqual(color(storage, at: index(of: "// note", in: md)), tokens.srcQuote.nsColor)
    XCTAssertEqual(
      color(storage, at: index(of: "\nx\n", in: md, offsetWithinNeedle: 1)),
      tokens.muted.nsColor)
  }

  /// Fenced keywords on BOTH halves of the Typewriter pair.
  ///
  /// Typewriter's accent is `#1c1c1c` on both sides, but what that means depends
  /// on the half it lands on. On the DARK half it is all but the source surface
  /// itself (`#171717`) — correct for the chrome, invisible in the editor — so
  /// keywords fall back to the theme's strong neutral. On the LIGHT half the
  /// same ink sits on white at ≈17:1, so the accent is exactly right and keeping
  /// it is the correct answer.
  ///
  /// Driven from an explicit half for the same reason as the wash pin above: a
  /// test that reads `tokens` on a paired skin is measuring the machine, and
  /// this one used to disagree with CI purely because the two ran in different
  /// office lighting.
  func testFencedKeywordsStayLegibleOnBothHalvesOfThePair() {
    for isDark in [true, false] {
      let tokens = PensieveTheme.typewriter.tokens(underDarkSystem: isDark)
      let half = isDark ? "dark" : "light"
      let md = "```swift\nfunc greet() {}\n```"
      let storage = NSTextStorage(string: md)
      let fullRange = NSRange(location: 0, length: (md as NSString).length)

      let codeBlocks = CodeBlockHighlighter()
      codeBlocks.baseFontSize = fontSize
      codeBlocks.tokens = tokens

      storage.beginEditing()
      codeBlocks.highlight(storage, range: fullRange)
      storage.endEditing()

      let at = index(of: "func", in: md)
      let painted = color(storage, at: at)
      XCTAssertEqual(
        painted, isDark ? tokens.srcHeading.nsColor : tokens.accent.nsColor,
        "\(half) half: keyword ink")
      XCTAssertNotEqual(
        painted, tokens.source.nsColor,
        "\(half) half: keywords must never be painted in the source surface colour")

      // The invariant underneath both branches: whatever it picked, it reads.
      let ratio = ThemeContrast.ratio(painted ?? .clear, tokens.source.nsColor)
      XCTAssertNotNil(ratio, "\(half) half")
      XCTAssertGreaterThanOrEqual(
        ratio ?? 0, ThemeContrast.minimumTextContrast,
        "\(half) half: keywords are not legible on the source surface")
    }
  }

  /// Live-switch pin: pushing new tokens onto the SAME highlighter instance must
  /// invalidate the cached colours, so the next pass repaints fenced code in the
  /// new skin instead of serving the previous skin's cache.
  func testCodeBlockHighlighterRetintsWhenTokensChange() {
    let md = "```swift\nfunc greet() { let s = \"hi\" }\n```"
    let fullRange = NSRange(location: 0, length: (md as NSString).length)
    let keywordAt = index(of: "func", in: md)
    let stringAt = index(of: "\"hi\"", in: md, offsetWithinNeedle: 1)

    let codeBlocks = CodeBlockHighlighter()
    codeBlocks.baseFontSize = fontSize
    codeBlocks.tokens = PensieveTheme.ink.tokens

    let storage = NSTextStorage(string: md)
    storage.beginEditing()
    codeBlocks.highlight(storage, range: fullRange)
    storage.endEditing()

    XCTAssertEqual(color(storage, at: keywordAt), PensieveTheme.ink.tokens.accent.nsColor)

    codeBlocks.tokens = PensieveTheme.parchment.tokens
    storage.beginEditing()
    codeBlocks.highlight(storage, range: fullRange)
    storage.endEditing()

    XCTAssertEqual(color(storage, at: keywordAt), PensieveTheme.parchment.tokens.accent.nsColor)
    XCTAssertEqual(
      color(storage, at: stringAt), PensieveTheme.parchment.tokens.srcInlineCode.nsColor)
    XCTAssertNotEqual(
      color(storage, at: keywordAt), PensieveTheme.ink.tokens.accent.nsColor,
      "stale cached colours would leave fenced code on the previous skin")
  }

  // MARK: - Idempotence / cache reuse

  func testRepeatedHighlightingIsStable() {
    // Caching means regexes/fonts are reused across calls; re-running the full
    // pass many times must produce identical attributes (proves no state drift).
    let md = "# H\n**b** *i* `c` [l](u)\n```swift\nlet x = \"s\"\n```"
    let first = highlighted(md)

    let storage = NSTextStorage(string: md)
    let fullRange = NSRange(location: 0, length: (md as NSString).length)
    let syntax = SyntaxHighlighter()
    syntax.baseFontSize = fontSize
    let codeBlocks = CodeBlockHighlighter()
    codeBlocks.baseFontSize = fontSize

    for _ in 0..<5 {
      storage.beginEditing()
      syntax.resetBaseAttributes(storage, range: fullRange)
      syntax.highlight(storage, range: fullRange)
      codeBlocks.highlight(storage, range: fullRange)
      storage.endEditing()
    }

    XCTAssertTrue(
      first.isEqual(to: storage),
      "repeated highlighting drifted from the single-pass result")
  }

  func testFontSizeChangeInvalidatesFontCache() {
    // Changing baseFontSize between calls must rebuild the cached fonts.
    let md = "**bold**"
    let storage = NSTextStorage(string: md)
    let fullRange = NSRange(location: 0, length: (md as NSString).length)
    let syntax = SyntaxHighlighter()

    syntax.baseFontSize = 14
    storage.beginEditing()
    syntax.resetBaseAttributes(storage, range: fullRange)
    syntax.highlight(storage, range: fullRange)
    storage.endEditing()
    let at = index(of: "bold", in: md)
    XCTAssertEqual(font(storage, at: at)?.pointSize, 14)

    syntax.baseFontSize = 20
    storage.beginEditing()
    syntax.resetBaseAttributes(storage, range: fullRange)
    syntax.highlight(storage, range: fullRange)
    storage.endEditing()
    XCTAssertEqual(font(storage, at: at)?.pointSize, 20)
  }
}
