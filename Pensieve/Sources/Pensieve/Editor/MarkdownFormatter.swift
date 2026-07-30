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

struct MarkdownFormatEdit: Equatable {
  let range: NSRange
  let replacement: String
  let selectedRange: NSRange
}

enum MarkdownFormatter {
  private struct WrappingDelimiters {
    let opening: String
    let closing: String
    let usesStandaloneAsterisk: Bool
  }

  private struct WrappingSpan {
    let fullRange: NSRange
    let contentRange: NSRange
  }

  private enum AutoconversionPatterns {
    /// `[~]` ("in progress") continues like the other two states — Return on a
    /// `- [~] …` line opens the next item as an empty `- [ ] `, not a bare dash.
    static let taskList = compile(#"^(\s*)([-*+])\s+\[[ xX~]\]\s*(.*)$"#)
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

  static func formatSelection(
    in text: String,
    range: NSRange,
    as format: MarkdownFormat
  ) -> MarkdownFormatEdit? {
    let nsText = text as NSString
    guard range.length > 0, range.location >= 0, NSMaxRange(range) <= nsText.length else {
      return nil
    }

    if let delimiters = wrappingDelimiters(for: format) {
      let spans = wrappingSpans(in: nsText, delimiters: delimiters)
      if let edit = unwrappingEdit(in: nsText, range: range, spans: spans) {
        return edit
      }

      if spans.contains(where: { rangesIntersect(range, $0.fullRange) }) {
        return nil
      }
    }

    let selectedText = nsText.substring(with: range)
    let replacement = Self.format(selectedText, as: format)
    return MarkdownFormatEdit(
      range: range,
      replacement: replacement,
      selectedRange: NSRange(location: range.location, length: (replacement as NSString).length)
    )
  }

  static func autoconversion(
    in text: String,
    range: NSRange,
    replacement: String
  ) -> MarkdownAutoconversion? {
    guard range.length == 0 else { return nil }

    let nsText = text as NSString
    guard range.location >= 0, range.location <= nsText.length else { return nil }

    let line = lineBeforeCaret(in: nsText, caret: range.location)
    guard !line.text.isEmpty else { return nil }

    if replacement == "=" {
      return highlightClosure(in: line, caretRange: range)
    }

    guard replacement == "\n" else { return nil }

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

  private static func highlightClosure(
    in line: CurrentLine,
    caretRange: NSRange
  ) -> MarkdownAutoconversion? {
    guard delimiterCount("==", in: line.text).isMultiple(of: 2) == false else {
      return nil
    }
    guard let openRange = line.text.range(of: "==", options: .backwards) else {
      return nil
    }

    let markedText = line.text[openRange.upperBound...]
    guard !markedText.isEmpty, !markedText.contains("="), !markedText.contains("\n") else {
      return nil
    }
    guard markedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
      return nil
    }

    let replacement = "=="
    let selectedLocation = caretRange.location + (replacement as NSString).length
    return MarkdownAutoconversion(
      range: caretRange,
      replacement: replacement,
      selectedRange: NSRange(location: selectedLocation, length: 0)
    )
  }

  private static func delimiterCount(_ delimiter: String, in text: String) -> Int {
    var count = 0
    var searchStart = text.startIndex
    while let range = text.range(of: delimiter, range: searchStart..<text.endIndex) {
      count += 1
      searchStart = range.upperBound
    }
    return count
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

  private static func wrappingDelimiters(for format: MarkdownFormat) -> WrappingDelimiters? {
    switch format {
    case .bold:
      return WrappingDelimiters(opening: "**", closing: "**", usesStandaloneAsterisk: false)
    case .italic:
      return WrappingDelimiters(opening: "*", closing: "*", usesStandaloneAsterisk: true)
    case .strike:
      return WrappingDelimiters(opening: "~~", closing: "~~", usesStandaloneAsterisk: false)
    case .code:
      return WrappingDelimiters(opening: "```\n", closing: "\n```", usesStandaloneAsterisk: false)
    case .link, .quote, .bulletedList, .numberedList:
      return nil
    }
  }

  private static func wrappingSpans(
    in text: NSString,
    delimiters: WrappingDelimiters
  ) -> [WrappingSpan] {
    var spans: [WrappingSpan] = []
    var searchLocation = 0

    while searchLocation < text.length {
      let openSearchRange = NSRange(location: searchLocation, length: text.length - searchLocation)
      let openRange = text.range(of: delimiters.opening, options: [], range: openSearchRange)
      guard openRange.location != NSNotFound else { break }

      guard delimiterIsValid(openRange, in: text, delimiters: delimiters) else {
        searchLocation = openRange.location + 1
        continue
      }

      var closeSearchLocation = NSMaxRange(openRange)
      var closeRange: NSRange?
      while closeSearchLocation < text.length {
        let closeSearchRange = NSRange(
          location: closeSearchLocation,
          length: text.length - closeSearchLocation)
        let candidate = text.range(of: delimiters.closing, options: [], range: closeSearchRange)
        guard candidate.location != NSNotFound else { break }

        if delimiterIsValid(candidate, in: text, delimiters: delimiters) {
          closeRange = candidate
          break
        }
        closeSearchLocation = candidate.location + 1
      }

      guard let closeRange else { break }

      let contentRange = NSRange(
        location: NSMaxRange(openRange),
        length: closeRange.location - NSMaxRange(openRange))
      let fullRange = NSRange(
        location: openRange.location,
        length: NSMaxRange(closeRange) - openRange.location)
      spans.append(WrappingSpan(fullRange: fullRange, contentRange: contentRange))
      searchLocation = NSMaxRange(closeRange)
    }

    return spans
  }

  private static func delimiterIsValid(
    _ range: NSRange,
    in text: NSString,
    delimiters: WrappingDelimiters
  ) -> Bool {
    guard delimiters.usesStandaloneAsterisk else { return true }

    let before =
      range.location > 0
      ? text.substring(with: NSRange(location: range.location - 1, length: 1))
      : ""
    let afterLocation = NSMaxRange(range)
    let after =
      afterLocation < text.length
      ? text.substring(with: NSRange(location: afterLocation, length: 1))
      : ""
    return before != "*" && after != "*"
  }

  private static func unwrappingEdit(
    in text: NSString,
    range: NSRange,
    spans: [WrappingSpan]
  ) -> MarkdownFormatEdit? {
    guard
      let span = spans.first(where: { span in
        range == span.fullRange
          || (range.location >= span.contentRange.location
            && NSMaxRange(range) <= NSMaxRange(span.contentRange))
      })
    else {
      return nil
    }

    let replacement = text.substring(with: span.contentRange)
    return MarkdownFormatEdit(
      range: span.fullRange,
      replacement: replacement,
      selectedRange: NSRange(
        location: span.fullRange.location, length: (replacement as NSString).length)
    )
  }

  private static func rangesIntersect(_ lhs: NSRange, _ rhs: NSRange) -> Bool {
    NSIntersectionRange(lhs, rhs).length > 0
  }
}
