import Foundation

/// Literal document search. Both replacement paths consume these same ranges.
struct DocumentFindOptions: Equatable {
  var matchCase = false
  var wholeWords = false

  func matches(in text: NSString, query: String) -> [NSRange] {
    guard !query.isEmpty else { return [] }
    let comparison: NSString.CompareOptions = matchCase ? [] : [.caseInsensitive]
    var ranges: [NSRange] = []
    var remaining = NSRange(location: 0, length: text.length)
    while remaining.length > 0 {
      let found = text.range(of: query, options: comparison, range: remaining)
      guard found.location != NSNotFound, found.length > 0 else { break }
      if !wholeWords
        || (!Self.isWordScalar(in: text, at: found.location - 1)
          && !Self.isWordScalar(in: text, at: NSMaxRange(found)))
      {
        ranges.append(found)
      }
      let next = NSMaxRange(found)
      remaining = NSRange(location: next, length: text.length - next)
    }
    return ranges
  }

  /// Letters, combining marks, numbers and connector punctuation belong to a
  /// word. Decode at most two UTF-16 units, including supplementary letters;
  /// never copy or walk the document again for each boundary check.
  private static let wordCharacters = CharacterSet.alphanumerics
    .union(.nonBaseCharacters)

  private static func isWordScalar(in text: NSString, at index: Int) -> Bool {
    guard index >= 0, index < text.length else { return false }
    let unit = UInt32(text.character(at: index))
    let value: UInt32
    if (0xD800...0xDBFF).contains(unit), index + 1 < text.length {
      let low = UInt32(text.character(at: index + 1))
      guard (0xDC00...0xDFFF).contains(low) else { return false }
      value = 0x10000 + ((unit - 0xD800) << 10) + low - 0xDC00
    } else if (0xDC00...0xDFFF).contains(unit), index > 0 {
      let high = UInt32(text.character(at: index - 1))
      guard (0xD800...0xDBFF).contains(high) else { return false }
      value = 0x10000 + ((high - 0xD800) << 10) + unit - 0xDC00
    } else {
      value = unit
    }
    guard let scalar = UnicodeScalar(value) else { return false }
    return wordCharacters.contains(scalar)
      || scalar.properties.generalCategory == .connectorPunctuation
  }
}
