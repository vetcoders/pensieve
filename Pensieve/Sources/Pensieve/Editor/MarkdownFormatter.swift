import Foundation

enum MarkdownFormat: CaseIterable, Identifiable {
  case bold
  case strike
  case italic
  case quote
  case code
  case link
  case bulletedList
  case numberedList

  var id: Self { self }

  var label: String {
    switch self {
    case .bold: return "Bold"
    case .strike: return "Strikethrough"
    case .italic: return "Italic"
    case .quote: return "Quote"
    case .code: return "Code"
    case .link: return "Link"
    case .bulletedList: return "Bulleted List"
    case .numberedList: return "Numbered List"
    }
  }

  var systemImageName: String {
    switch self {
    case .bold: return "bold"
    case .strike: return "strikethrough"
    case .italic: return "italic"
    case .quote: return "quote.opening"
    case .code: return "chevron.left.forwardslash.chevron.right"
    case .link: return "link"
    case .bulletedList: return "list.bullet"
    case .numberedList: return "list.number"
    }
  }
}

struct MarkdownFormatCommand: Equatable, Identifiable {
  enum Action: Equatable {
    case format(MarkdownFormat)
    case tidyTable(asciiSafe: Bool)
  }

  let id: UUID
  let action: Action

  init(format: MarkdownFormat, id: UUID = UUID()) {
    self.id = id
    self.action = .format(format)
  }

  init(tidyTableAsciiSafe asciiSafe: Bool, id: UUID = UUID()) {
    self.id = id
    self.action = .tidyTable(asciiSafe: asciiSafe)
  }
}

struct MarkdownAutoconversion: Equatable {
  let range: NSRange
  let replacement: String
  let selectedRange: NSRange
}

enum MarkdownFormatter {
  private enum AutoconversionPatterns {
    static let taskList = compile(#"^(\s*)([-*+])\s+\[[ xX]\]\s*(.*)$"#)
    static let unorderedList = compile(#"^(\s*)([-*+])\s+(.*)$"#)
    static let orderedList = compile(#"^(\s*)(\d+)([.)])\s+(.*)$"#)
    static let blockquote = compile(#"^(\s*)>\s?(.*)$"#)

    private static func compile(_ pattern: String) -> NSRegularExpression {
      try! NSRegularExpression(pattern: pattern, options: [])
    }
  }

  static func format(_ text: String, as format: MarkdownFormat) -> String {
    switch format {
    case .bold:
      return "**\(text)**"
    case .italic:
      return "*\(text)*"
    case .strike:
      return "~~\(text)~~"
    case .code:
      return "```\n\(text)\n```"
    case .link:
      return "[\(text)](url)"
    case .quote:
      return prefixLines(in: text, with: "> ")
    case .bulletedList:
      return prefixLines(in: text, with: "- ")
    case .numberedList:
      return prefixLines(in: text, with: "1. ")
    }
  }

  static func autoconversion(
    in text: String,
    range: NSRange,
    replacement: String
  ) -> MarkdownAutoconversion? {
    guard range.length == 0, replacement == "\n" else { return nil }

    let nsText = text as NSString
    guard range.location >= 0, range.location <= nsText.length else { return nil }

    let line = lineBeforeCaret(in: nsText, caret: range.location)
    guard !line.text.isEmpty else { return nil }

    if let conversion = continuation(
      matching: AutoconversionPatterns.taskList,
      in: line,
      caretRange: range,
      marker: { captures in
        guard !captures[2].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return "\(captures[0])\(captures[1]) [ ] "
      }
    ) {
      return conversion
    }

    if let conversion = continuation(
      matching: AutoconversionPatterns.unorderedList,
      in: line,
      caretRange: range,
      marker: { captures in
        guard !captures[2].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return "\(captures[0])\(captures[1]) "
      }
    ) {
      return conversion
    }

    if let conversion = continuation(
      matching: AutoconversionPatterns.orderedList,
      in: line,
      caretRange: range,
      marker: { captures in
        guard !captures[3].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let nextNumber = (Int(captures[1]) ?? 0) + 1
        return "\(captures[0])\(nextNumber)\(captures[2]) "
      }
    ) {
      return conversion
    }

    return continuation(
      matching: AutoconversionPatterns.blockquote,
      in: line,
      caretRange: range,
      marker: { captures in
        guard !captures[1].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return "\(captures[0])> "
      }
    )
  }

  private static func prefixLines(in text: String, with prefix: String) -> String {
    text
      .components(separatedBy: "\n")
      .map { "\(prefix)\($0)" }
      .joined(separator: "\n") + "\n"
  }

  private struct CurrentLine {
    let start: Int
    let text: String
  }

  private static func lineBeforeCaret(in text: NSString, caret: Int) -> CurrentLine {
    var lineStart = 0
    var lineEnd = 0
    var contentsEnd = 0
    text.getLineStart(
      &lineStart,
      end: &lineEnd,
      contentsEnd: &contentsEnd,
      for: NSRange(location: caret, length: 0)
    )
    let length = max(0, caret - lineStart)
    return CurrentLine(
      start: lineStart,
      text: text.substring(with: NSRange(location: lineStart, length: length))
    )
  }

  private static func continuation(
    matching regex: NSRegularExpression,
    in line: CurrentLine,
    caretRange: NSRange,
    marker: ([String]) -> String?
  ) -> MarkdownAutoconversion? {
    let nsLine = line.text as NSString
    let fullLine = NSRange(location: 0, length: nsLine.length)
    guard let match = regex.firstMatch(in: line.text, options: [], range: fullLine) else {
      return nil
    }

    let captures = (1..<match.numberOfRanges).map { index in
      let range = match.range(at: index)
      return range.location == NSNotFound ? "" : nsLine.substring(with: range)
    }

    guard let nextMarker = marker(captures) else {
      return MarkdownAutoconversion(
        range: NSRange(location: line.start, length: caretRange.location - line.start),
        replacement: "",
        selectedRange: NSRange(location: line.start, length: 0)
      )
    }

    let replacement = "\n\(nextMarker)"
    let selectedLocation = caretRange.location + (replacement as NSString).length
    return MarkdownAutoconversion(
      range: caretRange,
      replacement: replacement,
      selectedRange: NSRange(location: selectedLocation, length: 0)
    )
  }
}
