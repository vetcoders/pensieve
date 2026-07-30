import Foundation
import Markdown

/// Walks a swift-markdown AST and emits HTML.
///
/// Implemented as a MarkupVisitor<String>. swift-markdown does not ship an
/// HTML renderer — Apple's documented pattern is a visitor that concatenates
/// strings while walking. We anchor block-level nodes with `data-vc-block="<index>"`
/// so the editor can drive synced scrolling by paragraph index.
struct HTMLEmitter: MarkupVisitor {
  typealias Result = String

  /// Monotonic counter assigned to top-level block elements while emitting.
  /// MarkdownRenderer reads it back via the returned `paragraphCount` to
  /// build editor↔preview anchor maps.
  var nextBlockIndex: Int = 0
  private var rendersWikilinks = true

  /// The markdown the visited document was parsed from — the SAME string handed
  /// to `Document(parsing:)`, or the source locations below will not line up.
  ///
  /// Needed because cmark resolves backslash escapes before it builds the AST:
  /// `\[~] wip` and `[~] wip` yield an identical `Text.string`, so only the
  /// source can say whether the author escaped the marker.
  private let source: String
  private var sourceIndex: SourceIndex?

  init(source: String) {
    self.source = source
  }

  mutating func defaultVisit(_ markup: any Markup) -> String {
    markup.children.map { visit($0) }.joined()
  }

  // MARK: - Block

  mutating func visitDocument(_ document: Document) -> String {
    document.children.map { visit($0) }.joined(separator: "\n")
  }

  mutating func visitHeading(_ heading: Heading) -> String {
    let inner = heading.children.map { visit($0) }.joined()
    let level = max(1, min(6, heading.level))
    return wrappedBlock("h\(level)", inner: inner)
  }

  mutating func visitParagraph(_ paragraph: Paragraph) -> String {
    if let displayMath = MarkdownMath.renderDisplayParagraph(paragraph.plainText) {
      return wrappedBlock("div", inner: displayMath)
    }
    let inner = paragraph.children.map { visit($0) }.joined()
    return wrappedBlock("p", inner: inner)
  }

  mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
    let inner = blockQuote.children.map { visit($0) }.joined(separator: "\n")
    return wrappedBlock("blockquote", inner: inner)
  }

  mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
    let language = (codeBlock.language ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let escaped = Self.escapeText(codeBlock.code)
    if language.caseInsensitiveCompare("mermaid") == .orderedSame {
      let anchor = nextAnchorAttr()
      return "<div class=\"mermaid\"\(anchor) data-vc-mermaid=\"true\">\(escaped)</div>"
    }
    let classAttr = language.isEmpty ? "" : " class=\"language-\(Self.escapeAttribute(language))\""
    let anchor = nextAnchorAttr()
    return "<pre\(anchor)><code\(classAttr)>\(escaped)</code></pre>"
  }

  mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
    // Preserve raw HTML; this matches CommonMark spec and how preview was
    // expected to behave for embedded snippets.
    let anchor = nextAnchorAttr()
    return "<div\(anchor)>\(html.rawHTML)</div>"
  }

  mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
    let anchor = nextAnchorAttr()
    return "<hr\(anchor) />"
  }

  mutating func visitUnorderedList(_ list: UnorderedList) -> String {
    let items = list.children.map { visit($0) }.joined()
    return wrappedBlock("ul", inner: items)
  }

  mutating func visitOrderedList(_ list: OrderedList) -> String {
    let items = list.children.map { visit($0) }.joined()
    let start = list.startIndex
    let startAttr = start == 1 ? "" : " start=\"\(start)\""
    let anchor = nextAnchorAttr()
    return "<ol\(anchor)\(startAttr)>\(items)</ol>"
  }

  mutating func visitListItem(_ listItem: ListItem) -> String {
    // List items inherit the parent list's block anchor; do not consume one.
    if let checkbox = listItem.checkbox {
      let inner = listItem.children.map { visit($0) }.joined()
      let checked = checkbox == .checked ? " checked" : ""
      return
        "<li class=\"task-list-item\"><input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled\(checked) />\(inner)</li>"
    }
    if let children = strippingInProgressMarker(listItem) {
      let inner = children.map { visit($0) }.joined()
      return
        "<li class=\"task-list-item\"><input type=\"checkbox\" class=\"task-list-item-checkbox\" disabled data-vc-task-state=\"in-progress\" aria-checked=\"mixed\" />\(inner)</li>"
    }
    let inner = listItem.children.map { visit($0) }.joined()
    return "<li>\(inner)</li>"
  }

  mutating func visitTable(_ table: Table) -> String {
    var html = ""
    html += visit(table.head)
    html += visit(table.body)
    return wrappedBlock("table", inner: html)
  }

  mutating func visitTableHead(_ tableHead: Table.Head) -> String {
    let cells = tableHead.children.map { child -> String in
      if let cell = child as? Table.Cell {
        let inner = cell.children.map { visit($0) }.joined()
        return "<th>\(inner)</th>"
      }
      return visit(child)
    }.joined()
    return "<thead><tr>\(cells)</tr></thead>"
  }

  mutating func visitTableBody(_ tableBody: Table.Body) -> String {
    let rows = tableBody.children.map { visit($0) }.joined()
    return "<tbody>\(rows)</tbody>"
  }

  mutating func visitTableRow(_ tableRow: Table.Row) -> String {
    let cells = tableRow.children.map { visit($0) }.joined()
    return "<tr>\(cells)</tr>"
  }

  mutating func visitTableCell(_ tableCell: Table.Cell) -> String {
    let inner = tableCell.children.map { visit($0) }.joined()
    return "<td>\(inner)</td>"
  }

  // MARK: - Inline

  mutating func visitText(_ text: Text) -> String {
    MarkdownMath.renderText(text.string, wikilinks: rendersWikilinks)
  }

  mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
    "\n"
  }

  mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
    "<br />"
  }

  mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
    "<em>\(emphasis.children.map { visit($0) }.joined())</em>"
  }

  mutating func visitStrong(_ strong: Strong) -> String {
    "<strong>\(strong.children.map { visit($0) }.joined())</strong>"
  }

  mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
    "<del>\(strikethrough.children.map { visit($0) }.joined())</del>"
  }

  mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
    "<code>\(Self.escapeText(inlineCode.code))</code>"
  }

  mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
    inlineHTML.rawHTML
  }

  mutating func visitLink(_ link: Link) -> String {
    let previousRendersWikilinks = rendersWikilinks
    rendersWikilinks = false
    let inner = link.children.map { visit($0) }.joined()
    rendersWikilinks = previousRendersWikilinks
    let href = link.destination.map(Self.escapeAttribute) ?? ""
    let title = link.title.map { " title=\"\(Self.escapeAttribute($0))\"" } ?? ""
    return "<a href=\"\(href)\"\(title)>\(inner)</a>"
  }

  mutating func visitImage(_ image: Image) -> String {
    let alt = image.plainText
    let src = image.source.map(Self.escapeAttribute) ?? ""
    let title = image.title.map { " title=\"\(Self.escapeAttribute($0))\"" } ?? ""
    return "<img src=\"\(src)\" alt=\"\(Self.escapeAttribute(alt))\"\(title) />"
  }

  // MARK: - Helpers

  /// The third task-checkbox state: `- [~] …` meaning "in progress".
  ///
  /// GFM — and therefore cmark inside swift-markdown — only knows `[ ]` and
  /// `[x]`, so `listItem.checkbox` is `nil` here and the marker survives as
  /// literal text at the head of the item's first paragraph. Promoting it in the
  /// emitter keeps the parser untouched (it is a vendored dependency) while the
  /// preview still receives a real task-list item.
  private static let inProgressMarker = "[~]"

  /// Returns the item's children with a leading `[~]` marker stripped, or `nil`
  /// when the item is not an in-progress task.
  ///
  /// Mirrors GFM's own rule for `[ ]`/`[x]`: the marker counts only when it
  /// opens the item's first paragraph, is not backslash-escaped, and is followed
  /// by whitespace (or is that paragraph's entire text). `- [~]wip` and
  /// `- \[~] wip` are therefore prose, exactly as `- [x]wip` and `- \[x] done`
  /// are. When stripping empties the paragraph it is dropped, so `- [~]` emits
  /// the same bare `<li>` shape as `- [ ]`.
  private mutating func strippingInProgressMarker(_ listItem: ListItem) -> [any Markup]? {
    var children = Array(listItem.children)
    guard let paragraph = children.first as? Paragraph else { return nil }
    var inlines = Array(paragraph.inlineChildren)
    guard var text = inlines.first as? Text, text.string.hasPrefix(Self.inProgressMarker)
    else { return nil }
    // cmark strips the backslash while building the Text node, so an escaped
    // marker is indistinguishable from a real one in the AST — ask the source.
    guard !isEscaped(text) else { return nil }
    let remainder = text.string.dropFirst(Self.inProgressMarker.count)
    guard remainder.first.map(\.isWhitespace) ?? true else { return nil }

    text.string = String(remainder.drop(while: \.isWhitespace))
    if text.string.isEmpty {
      inlines.removeFirst()
    } else {
      inlines[0] = text
    }
    if inlines.isEmpty {
      children.removeFirst()
    } else {
      children[0] = Paragraph(inlines)
    }
    return children
  }

  /// True when the inline's first source character is a backslash — i.e. what
  /// looks like a marker in the AST was written `\[~]` and is prose.
  ///
  /// Without a source range (source positions disabled, or a `source` that does
  /// not match the parsed string) the answer is "not escaped", which is the
  /// behaviour that predates this check.
  private mutating func isEscaped(_ inline: some InlineMarkup) -> Bool {
    guard let start = inline.range?.lowerBound else { return false }
    if sourceIndex == nil { sourceIndex = SourceIndex(source) }
    return sourceIndex?.byte(at: start) == UInt8(ascii: "\\")
  }

  /// `source` as UTF-8 bytes plus each line's start offset, so a cmark
  /// `SourceLocation` (1-based line, 1-based column) resolves to a byte in O(1).
  /// Built at most once per emitted document, and only when a candidate marker
  /// actually asks — a document with no `[~]` never pays for it.
  private struct SourceIndex {
    private let bytes: [UInt8]
    private let lineStarts: [Int]

    init(_ source: String) {
      let bytes = Array(source.utf8)
      var lineStarts = [0]
      for (offset, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
        lineStarts.append(offset + 1)
      }
      self.bytes = bytes
      self.lineStarts = lineStarts
    }

    func byte(at location: SourceLocation) -> UInt8? {
      guard location.line >= 1, location.line <= lineStarts.count, location.column >= 1
      else { return nil }
      let offset = lineStarts[location.line - 1] + location.column - 1
      guard offset < bytes.count else { return nil }
      return bytes[offset]
    }
  }

  private mutating func wrappedBlock(_ tag: String, inner: String) -> String {
    let anchor = nextAnchorAttr()
    return "<\(tag)\(anchor)>\(inner)</\(tag)>"
  }

  private mutating func nextAnchorAttr() -> String {
    let index = nextBlockIndex
    nextBlockIndex += 1
    return " data-vc-block=\"\(index)\""
  }

  static func escapeText(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
      switch ch {
      case "&": out.append("&amp;")
      case "<": out.append("&lt;")
      case ">": out.append("&gt;")
      default: out.append(ch)
      }
    }
    return out
  }

  static func escapeAttribute(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    for ch in s {
      switch ch {
      case "&": out.append("&amp;")
      case "<": out.append("&lt;")
      case ">": out.append("&gt;")
      case "\"": out.append("&quot;")
      case "'": out.append("&#39;")
      default: out.append(ch)
      }
    }
    return out
  }
}
