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

  func testHeadingIsGreenAndBold() {
    let md = "# Title\n"
    let storage = highlighted(md)
    let at = index(of: "Title", in: md)
    XCTAssertEqual(color(storage, at: at), NSColor.systemGreen)
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

  func testInlineCodeIsPinkWithBackground() {
    let md = "call `foo()` now"
    let storage = highlighted(md)
    let at = index(of: "foo()", in: md)
    XCTAssertEqual(color(storage, at: at), NSColor.systemPink)
    let expectedBackground = NSColor.textBackgroundColor.withSystemEffect(.disabled)
    XCTAssertEqual(backgroundColor(storage, at: at), expectedBackground)
    XCTAssertEqual(
      font(storage, at: at), NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
  }

  // MARK: - Link

  func testLinkIsAccentColorAndUnderlined() {
    let md = "see [docs](https://x.io) here"
    let storage = highlighted(md)
    let at = index(of: "docs", in: md)
    XCTAssertEqual(color(storage, at: at), NSColor.controlAccentColor)
    XCTAssertEqual(underline(storage, at: at), NSUnderlineStyle.single.rawValue)
  }

  // MARK: - Task checkbox

  func testTaskCheckboxIsBlueSemibold() {
    let md = "- [x] done\n"
    let storage = highlighted(md)
    // The marker run is the "- [x]" portion; sample inside the bracket.
    let at = index(of: "[x]", in: md)
    XCTAssertEqual(color(storage, at: at), NSColor.systemBlue)
    XCTAssertEqual(
      font(storage, at: at), NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold))
  }

  // MARK: - List markers

  func testUnorderedListMarkerIsBlue() {
    let md = "- item\n"
    let storage = highlighted(md)
    // The dash marker is at index 0.
    XCTAssertEqual(color(storage, at: 0), NSColor.systemBlue)
  }

  func testOrderedListMarkerIsBlue() {
    let md = "1. item\n"
    let storage = highlighted(md)
    XCTAssertEqual(color(storage, at: 0), NSColor.systemBlue)
  }

  // MARK: - Strikethrough & blockquote

  func testStrikethroughIsOrangeWithLine() {
    let md = "x ~~gone~~ y"
    let storage = highlighted(md)
    let at = index(of: "gone", in: md)
    XCTAssertEqual(color(storage, at: at), NSColor.systemOrange)
    XCTAssertEqual(strikethrough(storage, at: at), NSUnderlineStyle.single.rawValue)
  }

  func testHighlightMarkupGetsInlineBackground() {
    let md = "x ==marked== y"
    let storage = highlighted(md)
    let at = index(of: "marked", in: md)

    XCTAssertEqual(color(storage, at: at), NSColor.labelColor)
    XCTAssertEqual(backgroundColor(storage, at: at), NSColor.systemYellow.withAlphaComponent(0.35))
  }

  func testBlockquoteIsSecondaryLabel() {
    let md = "> quoted line\n"
    let storage = highlighted(md)
    let at = index(of: "quoted", in: md)
    XCTAssertEqual(color(storage, at: at), NSColor.secondaryLabelColor)
  }

  // MARK: - Code block (Swift)

  func testSwiftFencedBlockKeywordsArePink() {
    let md = "```swift\nfunc greet() {}\n```"
    let storage = highlighted(md)
    let at = index(of: "func", in: md)
    XCTAssertEqual(color(storage, at: at), NSColor.systemPink)
  }

  func testSwiftFencedBlockStringIsRed() {
    let md = "```swift\nlet s = \"hi\"\n```"
    let storage = highlighted(md)
    // Sample inside the quoted string literal.
    let at = index(of: "\"hi\"", in: md, offsetWithinNeedle: 1)
    XCTAssertEqual(color(storage, at: at), NSColor.systemRed)
  }

  func testSwiftFencedBlockBaseIsSecondaryLabel() {
    let md = "```swift\nx\n```"
    let storage = highlighted(md)
    // The lone `x` is not a keyword/string/comment, so it keeps the code-block
    // base color (secondaryLabel) applied across the whole match.
    let at = index(of: "\nx\n", in: md, offsetWithinNeedle: 1)
    XCTAssertEqual(color(storage, at: at), NSColor.secondaryLabelColor)
  }

  // MARK: - Code block (JSON)

  func testJSONFencedBlockKeyIsPurpleAndBoolIsBlue() {
    let md = "```json\n{\"k\": true}\n```"
    let storage = highlighted(md)
    let keyAt = index(of: "\"k\"", in: md, offsetWithinNeedle: 1)
    XCTAssertEqual(color(storage, at: keyAt), NSColor.systemPurple)
    let boolAt = index(of: "true", in: md)
    XCTAssertEqual(color(storage, at: boolAt), NSColor.systemBlue)
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
