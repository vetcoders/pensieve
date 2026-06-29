import Foundation

/// Pure, testable document measurements for the editor status bar.
///
/// This is the Swift foundation for the TextForge status surface (see the
/// `unicode-puzzles-portal` reference): the counting semantics mirror
/// TextForge's `measureText` so a future Swift TextForge can share this type.
///
///   * `characters` — Unicode *scalar* count (code points). Matches JS
///     `Array.from(text).length`, NOT UTF-16 `.count` (a 😀 is one character,
///     not two).
///   * `bytes` — UTF-8 byte length, matching `TextEncoder().encode(text)`.
///   * `words` — whitespace-delimited runs; markdown punctuation rides along
///     with its word, which is what a writer expects from a word count.
///   * `lines` — newline count + 1; an empty document is one line.
struct DocumentMetrics: Equatable {
  let characters: Int
  let words: Int
  let lines: Int
  let bytes: Int

  static let empty = DocumentMetrics(characters: 0, words: 0, lines: 1, bytes: 0)

  static func measure(_ text: String) -> DocumentMetrics {
    if text.isEmpty { return .empty }

    let characters = text.unicodeScalars.count
    let bytes = text.utf8.count

    var lines = 1
    for scalar in text.unicodeScalars where scalar == "\n" {
      lines += 1
    }

    let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count

    return DocumentMetrics(
      characters: characters,
      words: words,
      lines: lines,
      bytes: bytes
    )
  }
}

/// 1-based caret line/column plus a code-point offset, derived from the
/// UTF-16 selection offset reported by AppKit's `NSTextView`.
///
/// The column is counted in Unicode scalars (TextForge's `Array.from(lastLine)`
/// semantics), so a caret after an emoji reads as column 2, not column 3.
struct CaretPosition: Equatable {
  let line: Int
  let column: Int
  let offset: Int

  static let start = CaretPosition(line: 1, column: 1, offset: 0)

  /// Resolve a caret position from a UTF-16 offset into `text` (the unit AppKit
  /// hands back from `selectedRange().location`). Out-of-range offsets clamp to
  /// the document bounds so a stale selection never crashes the status bar.
  static func resolve(utf16Offset: Int, in text: String) -> CaretPosition {
    let ns = text as NSString
    let clamped = min(max(utf16Offset, 0), ns.length)

    // Prefix up to the caret, then split into lines. The last element is the
    // current line; its scalar length + 1 is the column.
    let prefix = ns.substring(to: clamped)
    let linePieces = prefix.components(separatedBy: "\n")
    let line = linePieces.count
    let column = (linePieces.last?.unicodeScalars.count ?? 0) + 1
    let offset = prefix.unicodeScalars.count

    return CaretPosition(line: line, column: column, offset: offset)
  }
}
