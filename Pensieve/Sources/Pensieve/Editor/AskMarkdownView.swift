import AppKit
import SwiftUI

/// Turns a parsed link into an actionable attributed run. No I/O and no parse.
///
/// The link is an AppKit attribute. SwiftUI's `AttributeScopes` link subscript
/// crashes the current compiler (bindOverloadType), so the run stays on
/// `NSAttributedString` and is bridged once for `Text`.
enum AskMarkdownPresentation {
  static func run(_ value: String, font: NSFont, color: NSColor) -> NSMutableAttributedString {
    NSMutableAttributedString(
      string: value,
      attributes: [
        .font: font,
        .foregroundColor: color,
      ])
  }

  static func attachLink(_ piece: NSMutableAttributedString, url: String) {
    guard piece.length > 0 else { return }
    guard let destination = URL(string: url), destination.scheme != nil else { return }
    let range = NSRange(location: 0, length: piece.length)
    piece.addAttribute(.link, value: destination, range: range)
    piece.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
  }
}

/// Top-level block budget for one message. A multi-thousand-block answer
/// renders its first page and reveals more on demand — the outer lazy turn
/// list cannot virtualize a single huge message, so the message bounds
/// itself. The exact source stays whole for selection and Copy.
enum AskMarkdownBlockPaging {
  static let pageSize = 120
}

/// Native rendering of an already-parsed Ask document.
///
/// The view does not parse. Tables and fenced code scroll horizontally inside
/// the prose column; headings, lists, quotes, tasks and links stay in the
/// column and wrap. Copy hands back the exact source held by the document.
/// Top-level blocks render in bounded pages; "Show more" reveals the next
/// page, so even a fully revealed reply never materialized all pages at once.
struct AskMarkdownView: View {
  var document: AskMarkdownDocument
  var tokens: ThemeTokens
  var containerWidth: CGFloat
  var showsCaret: Bool = false
  var blockPageSize: Int = AskMarkdownBlockPaging.pageSize

  @State private var revealedBlockCount: Int?

  var body: some View {
    let total = document.blocks.count
    let revealed = min(revealedBlockCount ?? blockPageSize, total)
    VStack(alignment: .leading, spacing: 7) {
      AskMarkdownBlockStack(
        blocks: Array(document.blocks.prefix(revealed)),
        tokens: tokens,
        containerWidth: containerWidth,
        showsCaretOnLast: showsCaret,
        baseSize: 14
      )
      if revealed < total {
        Button {
          revealedBlockCount = min(revealed + blockPageSize, total)
        } label: {
          Text("Show more of this reply · \(total - revealed) remaining")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(nsColor: tokens.accent.nsColor))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show more of this reply")
      }
    }
    .textSelection(.enabled)
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .topTrailing) {
      Button(action: copySource) {
        Image(systemName: "doc.on.doc")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(Color(nsColor: tokens.muted.nsColor))
          .padding(6)
      }
      .buttonStyle(.plain)
      .help("Copy markdown")
      .accessibilityLabel("Copy markdown source")
    }
  }

  private func copySource() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(document.copyableSource, forType: .string)
  }
}

private struct AskMarkdownBlockStack: View {
  let blocks: [AskMarkdownBlock]
  let tokens: ThemeTokens
  let containerWidth: CGFloat
  let showsCaretOnLast: Bool
  let baseSize: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
        AskMarkdownBlockView(
          block: block,
          tokens: tokens,
          containerWidth: containerWidth,
          showsCaret: showsCaretOnLast && index == blocks.count - 1,
          baseSize: baseSize)
      }
    }
  }
}

private struct AskMarkdownBlockView: View {
  let block: AskMarkdownBlock
  let tokens: ThemeTokens
  let containerWidth: CGFloat
  let showsCaret: Bool
  let baseSize: CGFloat
  /// User-driven row reveals for a large table; nil shows the first page.
  @State private var revealedTableRows: Int?

  var body: some View {
    switch block {
    case .paragraph(let text):
      inline(text, size: baseSize, color: bodyColor, weight: .regular)
    case .heading(let level, let text):
      inline(text, size: headingSize(level), color: headingColor, weight: .bold)
        .padding(.top, level <= 2 ? 3 : 1)
        .accessibilityAddTraits(.isHeader)
    case .bullet(let indent, let text):
      listRow(marker: indent >= 2 ? "◦" : "•", indent: indent, text: text, dim: indent >= 2)
    case .ordered(let indent, let number, let text):
      listRow(marker: "\(number).", indent: indent, text: text, dim: false)
    case .task(let indent, let done, let text):
      taskRow(indent: indent, done: done, text: text)
    case .blockquote(_, let children):
      HStack(alignment: .top, spacing: 9) {
        RoundedRectangle(cornerRadius: 1, style: .continuous)
          .fill(Color(nsColor: tokens.accent.nsColor).opacity(0.55))
          .frame(width: 2.5)
        AskMarkdownBlockStack(
          blocks: children,
          tokens: tokens,
          containerWidth: max(0, containerWidth - 12),
          showsCaretOnLast: false,
          baseSize: baseSize)
      }
    case .callout(let kind, _, let children):
      callout(kind, children: children)
    case .table(let header, let rows, let columnCount):
      table(header: header, rows: rows, columnCount: columnCount)
    case .code(let language, let content):
      codeBlock(language: language, content: content)
    case .thematicBreak:
      Rectangle()
        .fill(Color(nsColor: tokens.border.nsColor))
        .frame(height: 1)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
  }

  private var bodyColor: Color { Color(nsColor: tokens.text.nsColor) }
  private var headingColor: Color { Color(nsColor: tokens.text.nsColor) }
  private var mutedColor: Color { Color(nsColor: tokens.muted.nsColor) }
  private var accentColor: Color { Color(nsColor: tokens.accent.nsColor) }
  private var codeColor: Color { Color(nsColor: tokens.srcInlineCode.nsColor) }

  private func headingSize(_ level: Int) -> CGFloat {
    switch level {
    case 1: return baseSize + 7
    case 2: return baseSize + 4
    case 3: return baseSize + 2
    default: return baseSize + 1
    }
  }

  private func uiFont(_ size: CGFloat, weight: NSFont.Weight) -> Font {
    Font(nsFont(size, weight: weight))
  }

  private func monoFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> Font {
    Font(nsMono(size, weight: weight))
  }

  private func nsFont(_ size: CGFloat, weight: NSFont.Weight, italic: Bool = false) -> NSFont {
    let family = tokens.previewFamily.isEmpty ? tokens.previewHeadingFamily : tokens.previewFamily
    let font = ThemeTokens.font(family, size, weight: weight)
    guard italic else { return font }
    return NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
  }

  private func nsMono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
    ThemeTokens.font(tokens.monoFamily, size, weight: weight)
  }

  @ViewBuilder
  private func inline(
    _ text: AskMarkdownText, size: CGFloat, color: Color, weight: NSFont.Weight
  ) -> some View {
    let content = Text(presented(text, size: size, color: color, weight: weight))
      .lineSpacing(5)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    if showsCaret {
      HStack(alignment: .bottom, spacing: 2) {
        content
        caret
      }
    } else {
      content
    }
  }

  private func presented(
    _ text: AskMarkdownText, size: CGFloat, color: Color, weight: NSFont.Weight
  ) -> AttributedString {
    let result = NSMutableAttributedString()
    let prose = NSColor(color)
    for run in text.inlines {
      switch run {
      case .text(let value):
        result.append(
          AskMarkdownPresentation.run(value, font: nsFont(size, weight: weight), color: prose))
      case .strong(let value):
        result.append(
          AskMarkdownPresentation.run(value, font: nsFont(size, weight: .bold), color: prose))
      case .emphasis(let value):
        result.append(
          AskMarkdownPresentation.run(
            value, font: nsFont(size, weight: weight, italic: true), color: prose))
      case .code(let value):
        result.append(
          AskMarkdownPresentation.run(value, font: nsMono(size - 1), color: NSColor(codeColor)))
      case .link(let label, let url):
        let piece = AskMarkdownPresentation.run(
          label, font: nsFont(size, weight: weight), color: NSColor(accentColor))
        AskMarkdownPresentation.attachLink(piece, url: url)
        result.append(piece)
      }
    }
    return AttributedString(result)
  }

  private var caret: some View {
    Rectangle()
      .fill(Color(nsColor: tokens.warning.nsColor))
      .frame(width: 7, height: 15)
      .accessibilityLabel("Streaming")
  }

  private func listRow(
    marker: String, indent: Int, text: AskMarkdownText, dim: Bool
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Text(marker)
        .font(monoFont(dim ? baseSize - 4 : baseSize - 2))
        .foregroundStyle(dim ? mutedColor.opacity(0.8) : mutedColor)
        .frame(minWidth: 14, alignment: .trailing)
      inline(text, size: baseSize, color: bodyColor, weight: .regular)
    }
    .padding(.leading, CGFloat(min(indent, 4)) * 16)
  }

  private func taskRow(indent: Int, done: Bool, text: AskMarkdownText) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 7) {
      Image(systemName: done ? "checkmark.square.fill" : "square")
        .font(uiFont(baseSize - 1, weight: done ? .semibold : .regular))
        .foregroundStyle(done ? Color(nsColor: tokens.srcInlineCode.nsColor) : mutedColor)
        .frame(minWidth: 14, alignment: .trailing)
        .accessibilityLabel(done ? "Completed task" : "Open task")
      inline(
        text,
        size: baseSize,
        color: done ? mutedColor : bodyColor,
        weight: .regular)
    }
    .padding(.leading, CGFloat(min(indent, 4)) * 16)
  }

  private func callout(_ kind: AskCalloutKind, children: [AskMarkdownBlock]) -> some View {
    let tint =
      kind == .warning || kind == .caution
      ? Color(nsColor: tokens.warning.nsColor)
      : accentColor
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: kind.systemImage)
        Text(kind.label)
          .font(monoFont(baseSize - 4, weight: .semibold))
      }
      .foregroundStyle(tint)
      if !children.isEmpty {
        AskMarkdownBlockStack(
          blocks: children,
          tokens: tokens,
          containerWidth: max(0, containerWidth - 22),
          showsCaretOnLast: false,
          baseSize: baseSize)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .background(tint.opacity(0.08))
    .overlay(alignment: .leading) {
      Rectangle().fill(tint.opacity(0.8)).frame(width: 2.5)
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func table(
    header: [AskMarkdownText], rows: [[AskMarkdownText]], columnCount: Int
  ) -> some View {
    // One block can hold thousands of rows; the block page cannot bound that.
    // Render rows in bounded pages and scan weights only over a bounded
    // sample — never the whole grid in a view body. Full source stays on the
    // document for selection/copy; later rows reveal on demand.
    let visible = AskMarkdownTableBudget.visibleRowCount(
      total: rows.count, revealed: revealedTableRows)
    let shownRows = Array(rows.prefix(visible))
    let scanCount = AskMarkdownTableBudget.weightScanCount(
      visible: visible, total: rows.count)
    let plan = AskMarkdownOverflow.plan(
      containerWidth: containerWidth, codeCharacters: 0, tableColumns: columnCount)
    let weights = AskMarkdownParser.columnWeights(
      header: header.map(\.source),
      rows: shownRows.prefix(scanCount).map { $0.map(\.source) },
      count: columnCount)
    return VStack(alignment: .leading, spacing: 4) {
      ScrollView(.horizontal, showsIndicators: true) {
        AskMarkdownTableLayout(
          columns: columnCount, rowCount: shownRows.count + 1, weights: weights
        ) {
          ForEach(0..<columnCount, id: \.self) { column in
            tableCell(cell(header, column), isHeader: true, isLastRow: shownRows.isEmpty)
          }
          ForEach(Array(shownRows.enumerated()), id: \.offset) { index, row in
            ForEach(0..<columnCount, id: \.self) { column in
              tableCell(
                cell(row, column),
                isHeader: false,
                isLastRow: index == shownRows.count - 1)
            }
          }
        }
        .frame(minWidth: plan.tableContentWidth)
      }
      .frame(width: plan.tableViewportWidth, alignment: .leading)
      if visible < rows.count {
        Button {
          revealedTableRows = AskMarkdownTableBudget.nextReveal(
            current: visible, total: rows.count)
        } label: {
          Text("Show more rows · \(rows.count - visible) remaining")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(nsColor: tokens.accent.nsColor))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show more table rows")
      }
    }
  }

  private func cell(_ row: [AskMarkdownText], _ column: Int) -> AskMarkdownText {
    column < row.count ? row[column] : AskMarkdownText(source: "", inlines: [])
  }

  private func tableCell(_ text: AskMarkdownText, isHeader: Bool, isLastRow: Bool) -> some View {
    let size = isHeader ? baseSize - 2 : baseSize - 1
    return Text(
      presented(
        text,
        size: size,
        color: isHeader ? headingColor : bodyColor,
        weight: isHeader ? .semibold : .regular)
    )
    .lineSpacing(3)
    .multilineTextAlignment(.leading)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(isHeader ? Color(nsColor: tokens.codeBackground.nsColor) : Color.clear)
    .overlay(alignment: .bottom) {
      if !isLastRow {
        Rectangle()
          .fill(Color(nsColor: tokens.border.nsColor).opacity(isHeader ? 0.9 : 0.45))
          .frame(height: 1)
      }
    }
  }

  private func codeBlock(language: String?, content: String) -> some View {
    let longest =
      content.split(separator: "\n", omittingEmptySubsequences: false).map(\.count).max()
      ?? 0
    let plan = AskMarkdownOverflow.plan(
      containerWidth: containerWidth, codeCharacters: longest, tableColumns: 0)
    return VStack(alignment: .leading, spacing: 4) {
      if let language, !language.isEmpty {
        Text(language)
          .font(monoFont(baseSize - 4, weight: .medium))
          .foregroundStyle(mutedColor)
      }
      ScrollView(.horizontal, showsIndicators: true) {
        Text(content.isEmpty ? " " : content)
          .font(monoFont(baseSize - 1))
          .foregroundStyle(bodyColor)
          .lineSpacing(4)
          .fixedSize(horizontal: true, vertical: true)
          .frame(minWidth: plan.codeContentWidth, alignment: .leading)
      }
      .frame(width: plan.codeViewportWidth, alignment: .leading)
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .background(Color(nsColor: tokens.codeBackground.nsColor))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(Color(nsColor: tokens.border.nsColor).opacity(0.6), lineWidth: 1)
    )
  }
}

/// Column widths follow the longest cell, floored so one long column cannot
/// crush its neighbours, then placed row-major.
struct AskMarkdownTableLayout: Layout {
  var columns: Int
  var rowCount: Int
  var weights: [CGFloat]
  var minColumn: CGFloat = AskMarkdownOverflow.minColumn

  struct Cache {
    var columnWidths: [CGFloat] = []
    var rowHeights: [CGFloat] = []
    var width: CGFloat = -1
  }

  func makeCache(subviews: Subviews) -> Cache { Cache() }

  private func columnWidths(for total: CGFloat) -> [CGFloat] {
    guard columns > 0 else { return [] }
    var widths = [CGFloat](repeating: minColumn, count: columns)
    var active = Array(0..<columns)
    var remaining = total
    while !active.isEmpty {
      let weightSum = active.reduce(CGFloat(0)) { $0 + weight($1) }
      guard weightSum > 0 else {
        let each = max(minColumn, remaining / CGFloat(active.count))
        for column in active { widths[column] = each }
        break
      }
      var pinned: [Int] = []
      for column in active where remaining * weight(column) / weightSum < minColumn {
        pinned.append(column)
      }
      if pinned.isEmpty {
        for column in active {
          widths[column] = remaining * weight(column) / weightSum
        }
        break
      }
      for column in pinned {
        widths[column] = minColumn
        remaining -= minColumn
      }
      active.removeAll { pinned.contains($0) }
      if remaining <= 0 { break }
    }
    return widths
  }

  private func weight(_ column: Int) -> CGFloat {
    column < weights.count ? weights[column] : 1
  }

  private func resolve(_ subviews: Subviews, total: CGFloat, cache: inout Cache) {
    if cache.width == total, !cache.columnWidths.isEmpty { return }
    let widths = columnWidths(for: max(total, CGFloat(columns) * minColumn))
    var heights = [CGFloat](repeating: 0, count: max(rowCount, 0))
    for (offset, subview) in subviews.enumerated() {
      let row = offset / max(columns, 1)
      let column = offset % max(columns, 1)
      guard row < heights.count, column < widths.count else { continue }
      let height = subview.sizeThatFits(ProposedViewSize(width: widths[column], height: nil)).height
      heights[row] = max(heights[row], height)
    }
    cache.columnWidths = widths
    cache.rowHeights = heights
    cache.width = total
  }

  func sizeThatFits(
    proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
  ) -> CGSize {
    let total = proposal.width ?? max(320, CGFloat(columns) * minColumn)
    resolve(subviews, total: total, cache: &cache)
    return CGSize(
      width: max(total, cache.columnWidths.reduce(0, +)), height: cache.rowHeights.reduce(0, +))
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
  ) {
    resolve(subviews, total: bounds.width, cache: &cache)
    let widths = cache.columnWidths
    let heights = cache.rowHeights
    var xOffsets = [CGFloat](repeating: 0, count: columns)
    var accX: CGFloat = 0
    for column in 0..<columns where column < widths.count {
      xOffsets[column] = accX
      accX += widths[column]
    }
    var yOffsets = [CGFloat](repeating: 0, count: rowCount)
    var accY: CGFloat = 0
    for row in 0..<rowCount where row < heights.count {
      yOffsets[row] = accY
      accY += heights[row]
    }
    for (offset, subview) in subviews.enumerated() {
      let row = offset / max(columns, 1)
      let column = offset % max(columns, 1)
      guard row < rowCount, column < columns, row < heights.count, column < widths.count else {
        subview.place(at: bounds.origin, proposal: ProposedViewSize(width: 0, height: 0))
        continue
      }
      subview.place(
        at: CGPoint(x: bounds.minX + xOffsets[column], y: bounds.minY + yOffsets[row]),
        proposal: ProposedViewSize(width: widths[column], height: heights[row]))
    }
  }
}
