import Foundation

enum MarkdownMath {
  static func renderText(_ source: String, wikilinks: Bool) -> String {
    guard source.contains("$") else {
      return renderPlain(source, wikilinks: wikilinks)
    }

    var html = ""
    var plainBuffer = ""
    var index = source.startIndex

    while index < source.endIndex {
      guard source[index] == "$",
        !isEscapedDelimiter(at: index, in: source),
        source.index(after: index) < source.endIndex,
        source[source.index(after: index)] != "$",
        let close = closingInlineDelimiter(after: index, in: source)
      else {
        plainBuffer.append(source[index])
        index = source.index(after: index)
        continue
      }

      if !plainBuffer.isEmpty {
        html += renderPlain(plainBuffer, wikilinks: wikilinks)
        plainBuffer.removeAll(keepingCapacity: true)
      }

      let bodyStart = source.index(after: index)
      let tex = String(source[bodyStart..<close])
      html += renderInline(tex)
      index = source.index(after: close)
    }

    if !plainBuffer.isEmpty {
      html += renderPlain(plainBuffer, wikilinks: wikilinks)
    }

    return html
  }

  static func renderDisplayParagraph(_ source: String) -> String? {
    let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count >= 4 else {
      return nil
    }

    let bodyStart = trimmed.index(trimmed.startIndex, offsetBy: 2)
    let bodyEnd = trimmed.index(trimmed.endIndex, offsetBy: -2)
    let tex = String(trimmed[bodyStart..<bodyEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !tex.isEmpty else { return nil }
    return renderMath(tex, displayMode: true, tag: "div")
  }

  private static func renderInline(_ tex: String) -> String {
    renderMath(tex, displayMode: false, tag: "span")
  }

  private static func renderMath(_ tex: String, displayMode: Bool, tag: String) -> String {
    let modeClass = displayMode ? "vc-math-display" : "vc-math-inline"
    let mode = displayMode ? "display" : "inline"
    let escapedTex = HTMLEmitter.escapeText(tex)
    let attrTex = HTMLEmitter.escapeAttribute(tex)
    return
      "<\(tag) class=\"vc-math \(modeClass)\" data-vc-math=\"\(mode)\" data-vc-tex=\"\(attrTex)\">\(escapedTex)</\(tag)>"
  }

  private static func renderPlain(_ source: String, wikilinks: Bool) -> String {
    wikilinks
      ? MarkdownWikilinks.renderText(source)
      : HTMLEmitter.escapeText(source)
  }

  private static func closingInlineDelimiter(after open: String.Index, in source: String) -> String
    .Index?
  {
    var cursor = source.index(after: open)
    while cursor < source.endIndex {
      if source[cursor] == "$",
        !isEscapedDelimiter(at: cursor, in: source),
        source.index(after: cursor) < source.endIndex
          ? source[source.index(after: cursor)] != "$"
          : true
      {
        return cursor
      }
      cursor = source.index(after: cursor)
    }
    return nil
  }

  private static func isEscapedDelimiter(at index: String.Index, in source: String) -> Bool {
    guard index > source.startIndex else { return false }
    var cursor = source.index(before: index)
    var slashCount = 0
    while true {
      if source[cursor] != "\\" { break }
      slashCount += 1
      if cursor == source.startIndex { break }
      cursor = source.index(before: cursor)
    }
    return slashCount % 2 == 1
  }
}
