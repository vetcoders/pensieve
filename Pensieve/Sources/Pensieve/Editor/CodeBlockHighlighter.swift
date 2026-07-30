import AppKit

class CodeBlockHighlighter {
  var baseFontSize: CGFloat = 14

  /// Active theme tokens. Like `SyntaxHighlighter`, this runs per keystroke, so
  /// setting it invalidates the resolved-`NSColor` cache exactly once (on skin
  /// change) and never inside the highlight pass. Defaults to the GitHub
  /// `default` surface so a highlighter built without a theme still paints.
  var tokens: ThemeTokens = PensieveTheme.default.tokens {
    didSet { cachedColors = nil }
  }

  /// The colour roles a fenced block distinguishes. Deliberately FIVE, not one
  /// per language construct: the theme spends its accent on structure
  /// (keywords / object keys), the warm code token on string literals, the quiet
  /// quote token on comments, and plain body text on values. Everything else in
  /// the block stays muted. One accent family per theme, no rainbow.
  private enum Role {
    /// Language keywords and structural keys (JSON/YAML `key:`) — `accent`.
    case keyword
    /// String literals — `srcInlineCode`, the source panel's one warm token.
    case string
    /// Comments and docstrings — `srcQuote`, the de-emphasised token.
    case comment
    /// Numbers, booleans, `null` — `text`: the payload reads at body strength,
    /// achromatic, so values never compete with the accent.
    case literal
  }

  /// Compiled-once fence regex + per-language colorizer tables. Previously every
  /// `highlight` call recompiled the fence regex and every matched code block
  /// recompiled 3-4 language regexes FRESH — 15-20+ `NSRegularExpression`
  /// compilations per keystroke on a doc with code blocks. These are all
  /// pattern constants, so `static let` compiles them a single time. Colours are
  /// NOT baked in here: rules carry a `Role`, resolved against the cached theme
  /// colours in the pass.
  private enum Patterns {
    static let fence = compile("(?s)```(.*?)\\n(.*?)```")

    /// One compiled colorizer rule: a precompiled regex paired with the role it
    /// paints. Patterns are CONSTANT, so they are compiled once per process.
    struct ColorRule {
      let regex: NSRegularExpression
      let role: Role
    }

    /// language (lowercased) -> ordered colorizer rules. Order matters because
    /// later rules can overwrite earlier ones (preserved exactly as before).
    static let languageRules: [String: [ColorRule]] = {
      var table: [String: [ColorRule]] = [:]

      table["json"] = [
        rule("\".*?\"\\s*:", .keyword),
        rule(":\\s*\".*?\"", .string),
        rule("\\b[0-9]+\\b", .literal),
        rule("\\b(true|false|null)\\b", .literal),
      ]
      table["swift"] = [
        rule(
          "\\b(func|var|let|class|struct|enum|if|else|guard|return|import|switch|case)\\b",
          .keyword),
        rule("\".*?\"", .string),
        rule("//.*$", .comment),
      ]
      table["python"] = [
        rule(
          "\\b(def|class|if|else|elif|return|import|from|for|in|while)\\b",
          .keyword),
        rule("(\"\"\".*?\"\"\"|'''.*?''')", .comment),
        rule("(\".*?\"|'.*?')", .string),
        rule("#.*$", .comment),
      ]
      table["rust"] = [
        rule(
          "\\b(fn|let|mut|struct|enum|impl|if|else|match|return|use|mod|pub)\\b",
          .keyword),
        rule("\".*?\"", .string),
        rule("//.*$", .comment),
      ]
      table["bash"] = [
        rule(
          "\\b(if|fi|then|else|for|do|done|while|echo|export|local)\\b", .keyword),
        rule("(\".*?\"|'.*?')", .string),
        rule("#.*$", .comment),
      ]
      let yamlRules = [
        rule("^\\s*.*?\\s*:", .keyword),
        rule("#.*$", .comment),
      ]
      table["yaml"] = yamlRules
      table["yml"] = yamlRules

      return table
    }()

    private static func rule(_ pattern: String, _ role: Role) -> ColorRule {
      ColorRule(regex: compile(pattern, options: [.anchorsMatchLines]), role: role)
    }

    private static func compile(
      _ pattern: String, options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
      // Patterns are compile-time constants verified by the test suite; a
      // malformed pattern is a programmer error that should fail loudly.
      try! NSRegularExpression(pattern: pattern, options: options)
    }
  }

  /// Resolved `NSColor`s for the active `tokens` — the code-block twin of
  /// `SyntaxHighlighter.ColorCache`. Hex → `NSColor` parsing happens here ONCE
  /// per skin change, so the per-keystroke pass only reads cached instances.
  private struct ColorCache {
    /// Whole-block wash applied before the language rules repaint spans.
    let base: NSColor
    let keyword: NSColor
    let string: NSColor
    let comment: NSColor
    let literal: NSColor

    init(tokens: ThemeTokens) {
      self.base = tokens.muted.nsColor
      self.keyword = ColorCache.legibleAccent(tokens)
      self.string = tokens.srcInlineCode.nsColor
      self.comment = tokens.srcQuote.nsColor
      self.literal = tokens.text.nsColor
    }

    /// Below this contrast against the source surface an accent cannot carry
    /// text. WCAG's large-text / non-text threshold; every fixed palette's
    /// accent clears it comfortably except a deliberate collision.
    private static let minimumKeywordContrast: CGFloat = 3

    /// Keywords lean on the theme accent — but a theme is free to pick an accent
    /// that IS its own source surface. Typewriter's ink `#1c1c1c` on a `#1c1c1c`
    /// panel is correct for chrome (where it sits on the light window surface)
    /// and invisible in the editor. When the accent cannot carry text on the
    /// source panel, fall back to `srcHeading` — the theme's strong neutral —
    /// rather than inventing a per-theme hex in the highlighter.
    private static func legibleAccent(_ tokens: ThemeTokens) -> NSColor {
      let accent = tokens.accent.nsColor
      // Adaptive themes (`default`/`raw`) wrap LIVE semantic colours: resolving
      // them here would freeze the appearance that happened to be active at
      // cache-build time. AppKit already guarantees `linkColor` reads on
      // `textBackgroundColor`, so only fixed palettes need the guard.
      guard tokens.mode != nil else { return accent }
      guard let ratio = contrast(accent, tokens.source.nsColor),
        ratio >= minimumKeywordContrast
      else {
        return tokens.srcHeading.nsColor
      }
      return accent
    }

    /// WCAG relative luminance, or `nil` when the colour cannot be expressed in
    /// sRGB (pattern/catalog colours) — the caller then keeps the accent.
    private static func relativeLuminance(_ color: NSColor) -> CGFloat? {
      guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
      func channel(_ value: CGFloat) -> CGFloat {
        value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
      }
      return 0.2126 * channel(srgb.redComponent)
        + 0.7152 * channel(srgb.greenComponent)
        + 0.0722 * channel(srgb.blueComponent)
    }

    private static func contrast(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat? {
      guard let left = relativeLuminance(lhs), let right = relativeLuminance(rhs) else {
        return nil
      }
      return (max(left, right) + 0.05) / (min(left, right) + 0.05)
    }

    func color(for role: Role) -> NSColor {
      switch role {
      case .keyword: return keyword
      case .string: return string
      case .comment: return comment
      case .literal: return literal
      }
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
    let string = textStorage.string as NSString
    let fullRange = NSRange(location: 0, length: string.length)
    guard NSIntersectionRange(range, fullRange).length > 0 || range.length == 0 else { return }
    let targetRange = NSIntersectionRange(range, fullRange)

    // Bridge the whole document once and reuse for the fence scan.
    let swiftString = string as String
    let colors = self.colors()

    Patterns.fence.enumerateMatches(in: swiftString, options: [], range: targetRange) {
      match, _, _ in
      guard let match = match else { return }
      let langRange = match.range(at: 1)
      let codeRange = match.range(at: 2)

      let lang =
        langRange.length > 0
        ? string.substring(with: langRange).trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased() : ""

      // Base code block styling
      textStorage.addAttribute(.foregroundColor, value: colors.base, range: match.range)

      guard let rules = Patterns.languageRules[lang] else { return }

      // Highlight actual code. Bridge the code substring once and reuse it
      // across every language rule for this block.
      let codeString = string.substring(with: codeRange)
      let nsCodeString = codeString as NSString
      let codeStart = codeRange.location
      let codeFullRange = NSRange(location: 0, length: nsCodeString.length)

      for rule in rules {
        let color = colors.color(for: rule.role)
        rule.regex.enumerateMatches(in: codeString, options: [], range: codeFullRange) {
          m, _, _ in
          if let codeMatch = m {
            let finalRange = NSRange(
              location: codeStart + codeMatch.range.location, length: codeMatch.range.length)
            textStorage.addAttribute(.foregroundColor, value: color, range: finalRange)
          }
        }
      }
    }
  }
}
