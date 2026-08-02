import AppKit

class SyntaxHighlighter {
  var baseFontSize: CGFloat = 14

  /// Active theme tokens. The highlighter runs per keystroke, so setting this
  /// invalidates the resolved-`NSColor` cache exactly once (on skin change),
  /// never inside the highlight pass. Defaults to the GitHub `default` surface
  /// (adaptive system colours) so any highlighter built without a theme keeps
  /// the established look.
  var tokens: ThemeTokens = PensieveTheme.default.tokens {
    didSet { cachedColors = nil }
  }

  /// Compiled-once markdown regexes. The patterns are CONSTANT (independent of
  /// font size or runtime state), so compiling them as `static let` happens a
  /// single time per process instead of on every highlight pass / keystroke.
  private enum Patterns {
    static let blockquote = compile("(?m)^>.*$")
    static let horizontalRule = compile(#"(?m)^\s{0,3}([-*_])(?:\s*\1){2,}\s*$"#)
    /// `[~]` is the third state ("in progress") the preview draws as a diamond;
    /// the source panel gives it the same checkbox token as `[ ]`/`[x]`.
    ///
    /// The trailing `(?=\s|$)` is what the EMITTER requires (`HTMLEmitter`'s task
    /// pattern ends in `(?:\s|$)`), so without it the source pane styles
    /// `- [~]wip` as a checkbox while the preview renders it as a plain bullet —
    /// two panes disagreeing about the same line. GFM is on the emitter's side:
    /// a task marker needs a separator after the bracket.
    static let taskCheckbox = compile(#"(?m)^\s{0,3}[-*+]\s+\[[ xX~]\](?=\s|$)"#)
    static let unorderedList = compile(#"(?m)^\s{0,3}[-*+](?=\s+)"#)
    static let orderedList = compile(#"(?m)^\s{0,3}\d+\.(?=\s+)"#)
    static let heading = compile("(?m)^#{1,6}\\s+.*$")
    static let bold = compile("\\*\\*.*?\\*\\*|__.*?__")
    static let strikethrough = compile("~~[^~\n]+~~")
    static let highlight = compile("==[^=\n]+==")
    static let italic = compile(
      "(?<!\\*)\\*(?!\\*).*?(?<!\\*)\\*(?!\\*)|(?<!_)_(?!_).*?(?<!_)_(?!_)")
    static let inlineCode = compile("`[^`\n]+`")
    static let link = compile("\\[.*?\\]\\(.*?\\)")

    private static func compile(_ pattern: String) -> NSRegularExpression {
      // Patterns are compile-time constants verified by the test suite; a
      // malformed pattern is a programmer error that should fail loudly.
      try! NSRegularExpression(pattern: pattern, options: [])
    }
  }

  /// Fonts that depend on `baseFontSize` and the theme's `monoFamily`. Rebuilt
  /// only when one of those two changes (the italic derivation is the most
  /// expensive piece, so caching it is the biggest per-keystroke win).
  private struct FontCache {
    let size: CGFloat
    let family: String
    let base: NSFont
    let bold: NSFont
    let italic: NSFont
    /// Slant to add on top of `italic` when the family ships no italic face —
    /// see `MonoFontResolver.Italic`.
    let italicObliqueness: CGFloat
    let semibold: NSFont
    let inlineCode: NSFont
    /// Bold heading faces for levels 1…6, indexed `level - 1`.
    ///
    /// Headings used to be built inline as `NSFont.systemFont(ofSize:weight:)` —
    /// proportional SF — while every other face in the panel went through
    /// `MonoFontResolver`, so a theme that ships its own monospace family got it
    /// everywhere EXCEPT its headings. Sized here rather than in the pass for
    /// the same reason as every other face: the resolver must never be asked to
    /// construct a font per match.
    let headings: [NSFont]

    init(size: CGFloat, family: String) {
      self.size = size
      self.family = family
      self.base = MonoFontResolver.font(family: family, size: size)
      self.bold = MonoFontResolver.font(family: family, size: size, weight: .bold)
      self.semibold = MonoFontResolver.font(family: family, size: size, weight: .semibold)
      self.inlineCode = MonoFontResolver.font(family: family, size: size)
      let italic = MonoFontResolver.italicFont(family: family, size: size)
      self.italic = italic.font
      self.italicObliqueness = italic.obliqueness
      self.headings = (1...6).map { level in
        MonoFontResolver.font(
          family: family,
          size: size + CGFloat((7 - level) * 2),
          weight: .bold)
      }
    }

    /// Heading face for a 1…6 markdown level. Clamped rather than trusting the
    /// caller: the pattern guarantees the range, the array must not depend on it.
    func heading(level: Int) -> NSFont {
      headings[min(max(level, 1), headings.count) - 1]
    }
  }

  private var cachedFonts: FontCache?

  private func fonts() -> FontCache {
    // `monoFamily` is a token like any other, so the cache key includes it: a live
    // skin switch must re-FONT the source panel, not only retint it. Keying it
    // here rather than invalidating from `tokens.didSet` keeps ONE definition of
    // "this cache is stale".
    let family = tokens.monoFamily
    if let cached = cachedFonts, cached.size == baseFontSize, cached.family == family {
      return cached
    }
    let fresh = FontCache(size: baseFontSize, family: family)
    cachedFonts = fresh
    return fresh
  }

  /// The source panel's base face for the active theme and size — the single
  /// answer every other surface (text view, typing attributes, ghost field) must
  /// agree with, so nothing can drift into a different family.
  var baseFont: NSFont {
    fonts().base
  }

  /// Resolved `NSColor`s for the active `tokens`. Parsing hex → `NSColor`
  /// happens here, ONCE per skin change (mirrors `FontCache`), so the
  /// per-keystroke `applyMarkdownAttributes` pass only reads cached instances.
  private struct ColorCache {
    let text: NSColor
    let heading: NSColor
    let listMarker: NSColor
    let inlineCode: NSColor
    let inlineCodeBackground: NSColor
    let link: NSColor
    let quote: NSColor
    let strike: NSColor
    let highlightBackground: NSColor
    /// Text colour INSIDE the `==highlight==` wash — see `legibleHighlightText`.
    let highlightText: NSColor
    let rule: NSColor

    init(tokens: ThemeTokens) {
      self.text = tokens.text.nsColor
      self.heading = tokens.srcHeading.nsColor
      self.listMarker = tokens.srcListMarker.nsColor
      self.inlineCode = tokens.srcInlineCode.nsColor
      self.inlineCodeBackground = tokens.codeBackground.nsColor
      self.link = tokens.srcLink.nsColor
      self.quote = tokens.srcQuote.nsColor
      self.strike = tokens.srcStrike.nsColor
      self.highlightBackground = tokens.srcHighlightBackground.nsColor
      self.highlightText = ColorCache.legibleHighlightText(tokens)
      self.rule = tokens.border.nsColor
    }

    /// A marked span normally keeps the body text colour on the theme's mark
    /// wash — but a theme is free to pick a wash that IS its own text colour
    /// family. Typewriter paints `#d4d4d4` text on an `#e6e6e6` wash (≈1.2:1):
    /// the highlight literally erases what it marks. When the body text cannot
    /// carry the wash, fall back to the theme's `source` — the pane colour, so
    /// the mark reads as an inverted stamp (typewriter: `#1c1c1c` on `#e6e6e6`),
    /// which is that palette's own idiom. Same shape as
    /// `CodeBlockHighlighter`'s accent guard: another token from the SAME
    /// theme, never an invented per-theme hex. Computed once per token change
    /// (this cache), never inside the highlight pass.
    private static func legibleHighlightText(_ tokens: ThemeTokens) -> NSColor {
      let text = tokens.text.nsColor
      // Adaptive themes (`default`/`raw`) wrap LIVE semantic colours: resolving
      // them here would freeze whichever appearance was active when the cache
      // was built. AppKit already guarantees `textColor` reads on the
      // translucent systemYellow wash, so only fixed palettes need the guard.
      guard tokens.mode != nil else { return text }
      guard ThemeContrast.isLegible(text, on: tokens.srcHighlightBackground.nsColor) else {
        return tokens.source.nsColor
      }
      return text
    }
  }

  private var cachedColors: ColorCache?

  private func colors() -> ColorCache {
    if let cached = cachedColors { return cached }
    let fresh = ColorCache(tokens: tokens)
    cachedColors = fresh
    return fresh
  }

  func highlight(_ textStorage: NSTextStorage, range: NSRange) {
    guard let targetRange = validRange(range, in: textStorage) else { return }
    let string = textStorage.string as NSString
    applyMarkdownAttributes(textStorage, string: string, targetRange: targetRange)
  }

  func resetBaseAttributes(_ textStorage: NSTextStorage, range: NSRange) {
    guard let targetRange = validRange(range, in: textStorage) else { return }
    let baseFont = fonts().base
    let baseColor = colors().text

    textStorage.removeAttribute(.font, range: targetRange)
    textStorage.removeAttribute(.foregroundColor, range: targetRange)
    textStorage.removeAttribute(.backgroundColor, range: targetRange)
    textStorage.removeAttribute(.underlineStyle, range: targetRange)
    textStorage.removeAttribute(.strikethroughStyle, range: targetRange)
    // Synthetic italics live in `.obliqueness`, so a reset that left it behind
    // would keep slanting text that is no longer emphasised.
    textStorage.removeAttribute(.obliqueness, range: targetRange)

    textStorage.addAttribute(.font, value: baseFont, range: targetRange)
    textStorage.addAttribute(.foregroundColor, value: baseColor, range: targetRange)
  }

  private func validRange(_ range: NSRange, in textStorage: NSTextStorage) -> NSRange? {
    let string = textStorage.string as NSString
    let fullRange = NSRange(location: 0, length: string.length)

    guard NSIntersectionRange(range, fullRange).length > 0 || range.length == 0 else { return nil }
    return NSIntersectionRange(range, fullRange)
  }

  private func applyMarkdownAttributes(
    _ textStorage: NSTextStorage, string: NSString, targetRange: NSRange
  ) {
    // Bridge the NSString to a Swift String ONCE and reuse it across every
    // `enumerateMatches` call in this pass, instead of `string as String` per
    // regex (which re-bridges the whole string each time).
    let swiftString = string as String
    let fonts = self.fonts()
    let colors = self.colors()

    // Blockquote: ^> text
    highlightRegex(
      Patterns.blockquote, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .foregroundColor: colors.quote
      ])

    // Horizontal rules: ---, ***, or ___ on their own line
    highlightRegex(
      Patterns.horizontalRule, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .foregroundColor: colors.rule
      ])

    // Task list checkboxes: - [ ] / - [x]. Lists, checkboxes and links share
    // the one theme accent (srcListMarker / srcLink) instead of two different
    // system blues sitting side by side.
    highlightRegex(
      Patterns.taskCheckbox, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .foregroundColor: colors.listMarker,
        .font: fonts.semibold,
      ])

    // Unordered and ordered list markers
    highlightRegex(
      Patterns.unorderedList, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .foregroundColor: colors.listMarker,
        .font: fonts.semibold,
      ])
    highlightRegex(
      Patterns.orderedList, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .foregroundColor: colors.listMarker,
        .font: fonts.semibold,
      ])

    // Headings: ^# text. The heading colour is a variant of the theme text
    // colour (or a neutral palette tone), never an accent — hierarchy comes
    // from weight + size, which stay unchanged.
    Patterns.heading.enumerateMatches(in: swiftString, options: [], range: targetRange) {
      match, _, _ in
      guard let match = match else { return }
      let matchedString = string.substring(with: match.range)
      let level = matchedString.prefix(while: { $0 == "#" }).count
      textStorage.addAttribute(.font, value: fonts.heading(level: level), range: match.range)
      textStorage.addAttribute(.foregroundColor, value: colors.heading, range: match.range)
    }

    // Bold: **text** or __text__
    highlightRegex(
      Patterns.bold, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .font: fonts.bold
      ])

    // Strikethrough: ~~text~~
    highlightRegex(
      Patterns.strikethrough, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .foregroundColor: colors.strike,
        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
      ])

    // Highlight: ==text== — theme mark background instead of systemYellow @ 35%.
    // The foreground is the body text token unless it would be illegible on the
    // theme's own wash (see `ColorCache.legibleHighlightText`).
    highlightRegex(
      Patterns.highlight, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .foregroundColor: colors.highlightText,
        .backgroundColor: colors.highlightBackground,
      ])

    // Italic: *text* or _text_ (basic regex). Most bundled mono families ship no
    // italic face at all, so when the resolver could not find one the slant is
    // synthesised with `.obliqueness` — otherwise `*emphasis*` would be
    // indistinguishable from body text on parchment, graphite, ink and porcelain.
    var italicAttributes: [NSAttributedString.Key: Any] = [.font: fonts.italic]
    if fonts.italicObliqueness != 0 {
      italicAttributes[.obliqueness] = fonts.italicObliqueness
    }
    highlightRegex(
      Patterns.italic, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: italicAttributes)

    // Inline code: `code` — the one warm token in the source panel.
    highlightRegex(
      Patterns.inlineCode, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .font: fonts.inlineCode,
        .backgroundColor: colors.inlineCodeBackground,
        .foregroundColor: colors.inlineCode,
      ])

    // Links: [text](url)
    highlightRegex(
      Patterns.link, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .foregroundColor: colors.link,
        .underlineStyle: NSUnderlineStyle.single.rawValue,
      ])
  }

  private func highlightRegex(
    _ regex: NSRegularExpression, in string: String, storage: NSTextStorage, targetRange: NSRange,
    attributes: [NSAttributedString.Key: Any]
  ) {
    regex.enumerateMatches(in: string, options: [], range: targetRange) { match, _, _ in
      if let range = match?.range {
        storage.addAttributes(attributes, range: range)
      }
    }
  }
}
