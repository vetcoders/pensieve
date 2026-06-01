import AppKit

class CodeBlockHighlighter {
  var baseFontSize: CGFloat = 14

  /// One compiled colorizer rule: a precompiled regex paired with the color it
  /// paints. Patterns are CONSTANT, so they are compiled once per process.
  private struct ColorRule {
    let regex: NSRegularExpression
    let color: NSColor
  }

  /// Compiled-once fence regex + per-language colorizer tables. Previously every
  /// `highlight` call recompiled the fence regex and every matched code block
  /// recompiled 3-4 language regexes FRESH — 15-20+ `NSRegularExpression`
  /// compilations per keystroke on a doc with code blocks. These are all
  /// pattern constants, so `static let` compiles them a single time.
  private enum Patterns {
    static let fence = compile("(?s)```(.*?)\\n(.*?)```")

    /// language (lowercased) -> ordered colorizer rules. Order matters because
    /// later rules can overwrite earlier ones (preserved exactly as before).
    static let languageRules: [String: [ColorRule]] = {
      var table: [String: [ColorRule]] = [:]

      table["json"] = [
        rule("\".*?\"\\s*:", .systemPurple),
        rule(":\\s*\".*?\"", .systemGreen),
        rule("\\b[0-9]+\\b", .systemOrange),
        rule("\\b(true|false|null)\\b", .systemBlue),
      ]
      table["swift"] = [
        rule(
          "\\b(func|var|let|class|struct|enum|if|else|guard|return|import|switch|case)\\b",
          .systemPink),
        rule("\".*?\"", .systemRed),
        rule("//.*$", .systemGray),
      ]
      table["python"] = [
        rule(
          "\\b(def|class|if|else|elif|return|import|from|for|in|while)\\b",
          .systemPink),
        rule("(\"\"\".*?\"\"\"|'''.*?''')", .systemGray),
        rule("(\".*?\"|'.*?')", .systemGreen),
        rule("#.*$", .systemGray),
      ]
      table["rust"] = [
        rule(
          "\\b(fn|let|mut|struct|enum|impl|if|else|match|return|use|mod|pub)\\b",
          .systemPink),
        rule("\".*?\"", .systemGreen),
        rule("//.*$", .systemGray),
      ]
      table["bash"] = [
        rule(
          "\\b(if|fi|then|else|for|do|done|while|echo|export|local)\\b", .systemPink),
        rule("(\".*?\"|'.*?')", .systemGreen),
        rule("#.*$", .systemGray),
      ]
      let yamlRules = [
        rule("^\\s*.*?\\s*:", .systemPurple),
        rule("#.*$", .systemGray),
      ]
      table["yaml"] = yamlRules
      table["yml"] = yamlRules

      return table
    }()

    private static func rule(_ pattern: String, _ color: NSColor) -> ColorRule {
      ColorRule(regex: compile(pattern, options: [.anchorsMatchLines]), color: color)
    }

    private static func compile(
      _ pattern: String, options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
      // Patterns are compile-time constants verified by the test suite; a
      // malformed pattern is a programmer error that should fail loudly.
      try! NSRegularExpression(pattern: pattern, options: options)
    }
  }

  func highlight(_ textStorage: NSTextStorage, range: NSRange) {
    let string = textStorage.string as NSString
    let fullRange = NSRange(location: 0, length: string.length)
    guard NSIntersectionRange(range, fullRange).length > 0 || range.length == 0 else { return }
    let targetRange = NSIntersectionRange(range, fullRange)

    // Bridge the whole document once and reuse for the fence scan.
    let swiftString = string as String

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
      let baseColor = NSColor.secondaryLabelColor
      textStorage.addAttribute(.foregroundColor, value: baseColor, range: match.range)

      guard let rules = Patterns.languageRules[lang] else { return }

      // Highlight actual code. Bridge the code substring once and reuse it
      // across every language rule for this block.
      let codeString = string.substring(with: codeRange)
      let nsCodeString = codeString as NSString
      let codeStart = codeRange.location
      let codeFullRange = NSRange(location: 0, length: nsCodeString.length)

      for rule in rules {
        rule.regex.enumerateMatches(in: codeString, options: [], range: codeFullRange) {
          m, _, _ in
          if let codeMatch = m {
            let finalRange = NSRange(
              location: codeStart + codeMatch.range.location, length: codeMatch.range.length)
            textStorage.addAttribute(.foregroundColor, value: rule.color, range: finalRange)
          }
        }
      }
    }
  }
}
