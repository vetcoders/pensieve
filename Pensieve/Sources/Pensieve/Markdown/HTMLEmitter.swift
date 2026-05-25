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
    let inner = listItem.children.map { visit($0) }.joined()
    if let checkbox = listItem.checkbox {
      let checked = checkbox == .checked ? " checked" : ""
      return "<li><input type=\"checkbox\" disabled\(checked) />\(inner)</li>"
    }
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
    Self.escapeText(text.string)
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
    let inner = link.children.map { visit($0) }.joined()
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
