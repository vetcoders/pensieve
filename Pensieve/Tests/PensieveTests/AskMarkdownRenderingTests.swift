import AppKit
import CoreGraphics
import XCTest

@testable import Pensieve

final class AskMarkdownRenderingTests: XCTestCase {
  func testStructuredBlocksKeepTheExactSourceCopyable() {
    let source = [
      "# Title",
      "",
      "A [Pensieve](https://example.com/ask) note with `code` and **bold**.",
      "",
      "## Section",
      "",
      "- outer",
      "  - inner",
      "    - deep",
      "",
      "12. twelfth",
      "",
      "- [x] shipped",
      "- [ ] open",
      "",
      "> quoted line",
      "> - nested item",
      "",
      "> [!WARNING]",
      "> watch the dose",
      "",
      "```swift",
      "let value = 1",
      "```",
      "",
      "---",
    ].joined(separator: "\n")

    let document = AskMarkdownParser.parse(source)
    XCTAssertEqual(document.copyableSource, source)
    XCTAssertEqual(document.source, source)

    guard case .heading(let titleLevel, let title) = document.blocks[0] else {
      return XCTFail("missing title")
    }
    XCTAssertEqual(titleLevel, 1)
    XCTAssertEqual(title.source, "Title")

    let paragraph = document.blocks.compactMap { block -> AskMarkdownText? in
      if case .paragraph(let text) = block { return text }
      return nil
    }.first
    XCTAssertEqual(
      paragraph?.inlines,
      [
        .text("A "),
        .link(label: "Pensieve", url: "https://example.com/ask"),
        .text(" note with "),
        .code("code"),
        .text(" and "),
        .strong("bold"),
        .text("."),
      ])

    let bullets = document.blocks.compactMap { block -> (Int, String)? in
      if case .bullet(let indent, let text) = block { return (indent, text.source) }
      return nil
    }
    XCTAssertEqual(bullets.map(\.0), [0, 1, 2])
    XCTAssertEqual(bullets.map(\.1), ["outer", "inner", "deep"])

    guard
      let ordered = document.blocks.compactMap({ block -> (Int, String)? in
        if case .ordered(_, let number, let text) = block { return (number, text.source) }
        return nil
      }).first
    else {
      return XCTFail("missing ordered item")
    }
    XCTAssertEqual(ordered.0, 12)
    XCTAssertEqual(ordered.1, "twelfth")

    let tasks = document.blocks.compactMap { block -> (Bool, String)? in
      if case .task(_, let done, let text) = block { return (done, text.source) }
      return nil
    }
    XCTAssertEqual(tasks.map(\.0), [true, false])
    XCTAssertEqual(tasks.map(\.1), ["shipped", "open"])

    guard
      let quote = document.blocks.compactMap({ block -> [AskMarkdownBlock]? in
        if case .blockquote(_, let children) = block { return children }
        return nil
      }).first
    else {
      return XCTFail("missing quote")
    }
    XCTAssertEqual(quote.count, 2)
    guard case .bullet(_, let nested) = quote[1] else {
      return XCTFail("quote did not keep the nested item")
    }
    XCTAssertEqual(nested.source, "nested item")

    guard
      let callout = document.blocks.compactMap({ block -> (AskCalloutKind, String)? in
        if case .callout(let kind, _, let children) = block,
          case .paragraph(let text) = children.first
        {
          return (kind, text.source)
        }
        return nil
      }).first
    else {
      return XCTFail("missing callout")
    }
    XCTAssertEqual(callout.0, .warning)
    XCTAssertEqual(callout.1, "watch the dose")

    guard
      let code = document.blocks.compactMap({ block -> (String?, String)? in
        if case .code(let language, let body) = block { return (language, body) }
        return nil
      }).first
    else {
      return XCTFail("missing code")
    }
    XCTAssertEqual(code.0, "swift")
    XCTAssertEqual(code.1, "let value = 1")
    XCTAssertTrue(
      document.blocks.contains {
        if case .thematicBreak = $0 { return true }
        return false
      })
    XCTAssertTrue(document.copyableSource.contains("```swift"))
    XCTAssertTrue(document.copyableSource.contains("[!WARNING]"))
  }

  func testEscapedPipesAndRaggedRowsStayInTheirColumns() {
    let source = "| left \\| mid | right |\n| --- | ---: |\n| only |\n| extra | cells | here |\n"
    let document = AskMarkdownParser.parse(source)
    XCTAssertEqual(document.copyableSource, source)

    guard case .table(let header, let rows, let columnCount) = document.blocks.first else {
      return XCTFail("missing table")
    }
    XCTAssertEqual(columnCount, 3)
    XCTAssertEqual(header.map(\.source), ["left | mid", "right", ""])
    XCTAssertEqual(
      rows.map { $0.map(\.source) },
      [
        ["only", "", ""],
        ["extra", "cells", "here"],
      ])
    XCTAssertFalse(header.contains { $0.source == "---" || $0.source == "---:" })
    XCTAssertTrue(document.copyableSource.contains("\\|"))
  }

  func testWideTableAndCodeScrollInsideTheProseColumn() {
    let plan = AskMarkdownOverflow.plan(containerWidth: 640, codeCharacters: 400, tableColumns: 24)
    XCTAssertTrue(plan.proseStaysInsideContainer)
    XCTAssertTrue(plan.wideContentScrollsInsideMessage)
    XCTAssertLessThanOrEqual(plan.proseWidth, 640)
    XCTAssertEqual(plan.codeViewportWidth, plan.proseWidth)
    XCTAssertEqual(plan.tableViewportWidth, plan.proseWidth)
    XCTAssertGreaterThan(plan.tableContentWidth, plan.tableViewportWidth)
    XCTAssertGreaterThan(plan.codeContentWidth, plan.codeViewportWidth)

    let wideCode = String(repeating: "x", count: 4_000)
    let widened = AskMarkdownOverflow.plan(
      containerWidth: 640, codeCharacters: wideCode.count, tableColumns: 2)
    XCTAssertEqual(widened.proseWidth, plan.proseWidth)
    XCTAssertEqual(widened.codeViewportWidth, plan.proseWidth)
    XCTAssertGreaterThan(widened.codeContentWidth, widened.containerWidth)
  }

  func testALongCellCannotCrushItsNeighbour() {
    let weights = AskMarkdownParser.columnWeights(
      header: ["a", String(repeating: "x", count: 80)],
      rows: [["b", "short"]],
      count: 2)
    XCTAssertEqual(weights, [3, 48])
    XCTAssertTrue(weights.allSatisfy { $0 >= 3 })
  }

  func testFencesKeepInnerCodeAndAnOpenFenceKeepsTheSource() {
    let wrapped = "````md\n```ts\nkeep\n```\n````\n"
    let wrappedDocument = AskMarkdownParser.parse(wrapped)
    XCTAssertEqual(wrappedDocument.copyableSource, wrapped)
    guard case .code(let language, let body) = wrappedDocument.blocks.first else {
      return XCTFail("missing wrapped fence")
    }
    XCTAssertEqual(language, "md")
    XCTAssertEqual(body, "```ts\nkeep\n```")

    let open = "```\nstill open\n"
    let openDocument = AskMarkdownParser.parse(open)
    XCTAssertEqual(openDocument.copyableSource, open)
    guard case .code(let openLanguage, let openBody) = openDocument.blocks.first else {
      return XCTFail("missing open fence")
    }
    XCTAssertNil(openLanguage)
    XCTAssertEqual(openBody, "still open")
  }

  func testAParsedLinkKeepsItsDestinationOnTheAttributedRun() {
    let source = "See [Pensieve](https://example.com/ask) now."
    let document = AskMarkdownParser.parse(source)
    XCTAssertEqual(document.copyableSource, source)
    guard case .paragraph(let text) = document.blocks.first,
      text.inlines.count == 3,
      case .link(let label, let url) = text.inlines[1]
    else {
      return XCTFail("missing link run")
    }
    XCTAssertEqual(label, "Pensieve")
    XCTAssertEqual(url, "https://example.com/ask")

    let piece = NSMutableAttributedString(string: label)
    AskMarkdownPresentation.attachLink(piece, url: url)
    XCTAssertEqual(
      piece.attribute(.link, at: 0, effectiveRange: nil) as? URL,
      URL(string: "https://example.com/ask"))
    XCTAssertEqual(
      piece.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
      NSUnderlineStyle.single.rawValue)

    let plain = NSMutableAttributedString(string: "note")
    AskMarkdownPresentation.attachLink(plain, url: "not a destination")
    XCTAssertNil(plain.attribute(.link, at: 0, effectiveRange: nil))
  }
}
