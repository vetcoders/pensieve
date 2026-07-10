import Foundation

/// Maps source offsets to the preview block anchors emitted by `HTMLEmitter`.
///
/// This is intentionally approximate: top-level markdown blocks are treated as
/// non-empty line runs separated by blank lines, which matches the product
/// requirement for paragraph-index scroll sync without coupling editor scrolling
/// to the full markdown AST.
struct MarkdownBlockMapper {
  static func blockIndex(atUTF16Location location: Int, in markdown: String) -> Int? {
    let starts = blockStarts(in: markdown)
    guard !starts.isEmpty else { return nil }

    let clamped = max(0, min(location, (markdown as NSString).length))
    var resolved = 0
    for (index, start) in starts.enumerated() {
      if start > clamped { break }
      resolved = index
    }
    return resolved
  }

  static func utf16Location(forBlockIndex index: Int, in markdown: String) -> Int? {
    let starts = blockStarts(in: markdown)
    guard starts.indices.contains(index) else { return nil }
    return starts[index]
  }

  static func blockStarts(in markdown: String) -> [Int] {
    let ns = markdown as NSString
    guard ns.length > 0 else { return [] }

    var starts: [Int] = []
    var insideBlock = false
    ns.enumerateSubstrings(
      in: NSRange(location: 0, length: ns.length),
      options: [.byLines, .substringNotRequired]
    ) { _, lineRange, _, _ in
      let line = ns.substring(with: lineRange)
      let isBlank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      if isBlank {
        insideBlock = false
      } else if !insideBlock {
        starts.append(lineRange.location)
        insideBlock = true
      }
    }
    return starts
  }
}
