import Foundation
import Markdown

/// Orchestrates markdown→HTML conversion with a single-slot cache.
///
/// MVP keeps caching trivial: the most recent (sourceHash, fontSize, theme)
/// triple wins. The preview only cares about the latest text, so a 1-entry
/// LRU avoids re-parsing identical input when SwiftUI re-renders the view.
final class MarkdownRenderer {
  struct Output {
    let body: String
    let paragraphCount: Int
  }

  private struct CacheKey: Equatable {
    let sourceHash: Int
    let length: Int
  }

  private var cacheKey: CacheKey?
  private var cachedOutput: Output?

  func render(_ markdown: String) -> Output {
    let key = CacheKey(sourceHash: markdown.hashValue, length: markdown.count)
    if let cached = cachedOutput, cacheKey == key {
      return cached
    }
    let document = Document(parsing: Self.strippingLeadingFrontmatter(markdown))
    var emitter = HTMLEmitter()
    let body = emitter.visit(document)
    let output = Output(body: body, paragraphCount: emitter.nextBlockIndex)
    cacheKey = key
    cachedOutput = output
    return output
  }

  /// Hides a leading YAML frontmatter block from the rendered preview, matching
  /// the Jekyll / Hugo / Obsidian convention (and gray-matter): a fence that is
  /// the document's VERY FIRST line and has a matching `---` or `...` close.
  ///
  /// Only the leading block counts. A `---` anywhere else is a genuine thematic
  /// break (or a setext heading underline) and is left untouched — that mid-doc
  /// case is correct CommonMark, not metadata. If the opening `---` has no
  /// closing fence it is not frontmatter either, so the text is returned as-is.
  static func strippingLeadingFrontmatter(_ markdown: String) -> String {
    var text = Substring(markdown)
    if text.first == "\u{FEFF}" {  // tolerate a leading BOM
      text = text.dropFirst()
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    guard let first = lines.first,
      first.trimmingCharacters(in: .whitespaces) == "---"
    else {
      return markdown
    }
    for index in 1..<lines.count {
      let fence = lines[index].trimmingCharacters(in: .whitespaces)
      guard fence == "---" || fence == "..." else { continue }
      // Everything after the closing fence is the real document body; drop the
      // blank line(s) the fence usually leaves so rendering starts cleanly.
      let remainder = lines[(index + 1)...].joined(separator: "\n")
      return String(remainder.drop(while: { $0 == "\n" }))
    }
    return markdown  // open fence with no close → not frontmatter
  }
}
