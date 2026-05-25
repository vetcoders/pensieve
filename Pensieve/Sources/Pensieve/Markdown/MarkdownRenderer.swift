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
    let document = Document(parsing: markdown)
    var emitter = HTMLEmitter()
    let body = emitter.visit(document)
    let output = Output(body: body, paragraphCount: emitter.nextBlockIndex)
    cacheKey = key
    cachedOutput = output
    return output
  }
}
