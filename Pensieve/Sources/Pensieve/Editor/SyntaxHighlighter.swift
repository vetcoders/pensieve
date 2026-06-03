import AppKit

class SyntaxHighlighter {
  var baseFontSize: CGFloat = 14

  /// Compiled-once markdown regexes. The patterns are CONSTANT (independent of
  /// font size or runtime state), so compiling them as `static let` happens a
  /// single time per process instead of on every highlight pass / keystroke.
  private enum Patterns {
    static let blockquote = compile("(?m)^>.*$")
    static let horizontalRule = compile(#"(?m)^\s{0,3}([-*_])(?:\s*\1){2,}\s*$"#)
    static let taskCheckbox = compile(#"(?m)^\s{0,3}[-*+]\s+\[[ xX]\]"#)
    static let unorderedList = compile(#"(?m)^\s{0,3}[-*+](?=\s+)"#)
    static let orderedList = compile(#"(?m)^\s{0,3}\d+\.(?=\s+)"#)
    static let heading = compile("(?m)^#{1,6}\\s+.*$")
    static let bold = compile("\\*\\*.*?\\*\\*|__.*?__")
    static let strikethrough = compile("~~[^~\n]+~~")
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

  /// Fonts that depend on `baseFontSize`. Rebuilt only when the font size
  /// changes (the `NSFontManager.convert` italic derivation is the most
  /// expensive piece, so caching it is the biggest per-keystroke win).
  private struct FontCache {
    let size: CGFloat
    let base: NSFont
    let bold: NSFont
    let italic: NSFont
    let semibold: NSFont
    let inlineCode: NSFont

    init(size: CGFloat) {
      self.size = size
      let base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
      self.base = base
      self.bold = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
      self.semibold = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
      self.inlineCode = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
      self.italic = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }
  }

  private var cachedFonts: FontCache?

  private func fonts() -> FontCache {
    if let cached = cachedFonts, cached.size == baseFontSize {
      return cached
    }
    let fresh = FontCache(size: baseFontSize)
    cachedFonts = fresh
    return fresh
  }

  func highlight(_ textStorage: NSTextStorage, range: NSRange) {
    guard let targetRange = validRange(range, in: textStorage) else { return }
    let string = textStorage.string as NSString
    applyMarkdownAttributes(textStorage, string: string, targetRange: targetRange)
  }

  func resetBaseAttributes(_ textStorage: NSTextStorage, range: NSRange) {
    guard let targetRange = validRange(range, in: textStorage) else { return }
    let baseFont = NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular)
    let baseColor = NSColor.textColor

    textStorage.removeAttribute(.font, range: targetRange)
    textStorage.removeAttribute(.foregroundColor, range: targetRange)
    textStorage.removeAttribute(.backgroundColor, range: targetRange)
    textStorage.removeAttribute(.underlineStyle, range: targetRange)
    textStorage.removeAttribute(.strikethroughStyle, range: targetRange)

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

    // Blockquote: ^> text
    highlightRegex(
      Patterns.blockquote, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .foregroundColor: NSColor.secondaryLabelColor
      ])

    // Horizontal rules: ---, ***, or ___ on their own line
    highlightRegex(
      Patterns.horizontalRule, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .foregroundColor: NSColor.separatorColor
      ])

    // Task list checkboxes: - [ ] / - [x]
    highlightRegex(
      Patterns.taskCheckbox, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .foregroundColor: NSColor.systemBlue,
        .font: fonts.semibold,
      ])

    // Unordered and ordered list markers
    highlightRegex(
      Patterns.unorderedList, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .foregroundColor: NSColor.systemBlue,
        .font: fonts.semibold,
      ])
    highlightRegex(
      Patterns.orderedList, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .foregroundColor: NSColor.systemBlue,
        .font: fonts.semibold,
      ])

    // Headings: ^# text
    Patterns.heading.enumerateMatches(in: swiftString, options: [], range: targetRange) {
      match, _, _ in
      guard let match = match else { return }
      let matchedString = string.substring(with: match.range)
      let level = matchedString.prefix(while: { $0 == "#" }).count
      let size = baseFontSize + CGFloat((7 - level) * 2)
      let font = NSFont.systemFont(ofSize: size, weight: .bold)
      textStorage.addAttribute(.font, value: font, range: match.range)
      textStorage.addAttribute(.foregroundColor, value: NSColor.systemGreen, range: match.range)
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
        .foregroundColor: NSColor.systemOrange,
        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
      ])

    // Italic: *text* or _text_ (basic regex)
    // macOS doesn't have a built-in italic monospaced font easily, we use regular italic trait if available
    highlightRegex(
      Patterns.italic, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .font: fonts.italic
      ])

    // Inline code: `code`
    highlightRegex(
      Patterns.inlineCode, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .font: fonts.inlineCode,
        .backgroundColor: NSColor.textBackgroundColor.withSystemEffect(.disabled),
        .foregroundColor: NSColor.systemPink,
      ])

    // Links: [text](url)
    highlightRegex(
      Patterns.link, in: swiftString, storage: textStorage, targetRange: targetRange,
      attributes: [
        .foregroundColor: NSColor.controlAccentColor,
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
