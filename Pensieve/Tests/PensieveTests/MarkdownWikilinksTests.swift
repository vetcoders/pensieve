import Markdown
import XCTest

@testable import Pensieve

final class MarkdownWikilinksTests: XCTestCase {
  func testExtractsTargetsLabelsAndStableSlugs() {
    let links = MarkdownWikilinks.extract(
      from: "See [[Daily Note]] and [[Project Alpha|the plan]]."
    )

    XCTAssertEqual(
      links,
      [
        MarkdownWikilink(target: "Daily Note", label: "Daily Note", slug: "daily-note"),
        MarkdownWikilink(target: "Project Alpha", label: "the plan", slug: "project-alpha"),
      ]
    )
  }

  func testRenderTextConvertsWikilinksAndEscapesContent() {
    let html = MarkdownWikilinks.renderText("Open [[A&B <Draft>|draft <one>]].")

    XCTAssertTrue(html.contains("class=\"wikilink\""), html)
    XCTAssertTrue(html.contains("href=\"pensieve://wikilink/A%26B%20%3CDraft%3E\""), html)
    XCTAssertTrue(html.contains("data-vc-wikilink-target=\"a-b-draft\""), html)
    XCTAssertTrue(html.contains("data-vc-wikilink-title=\"A&amp;B &lt;Draft&gt;\""), html)
    XCTAssertTrue(html.contains(">draft &lt;one&gt;</a>"), html)
  }

  func testLeavesUnclosedWikilinkAsEscapedText() {
    let html = MarkdownWikilinks.renderText("Broken [[Draft")

    XCTAssertEqual(html, "Broken [[Draft")
  }

  func testHTMLEmitterDoesNotNestWikilinkAnchorsInsideMarkdownLinks() {
    let html = render("[[A]] and [label [[B]]](https://example.com)")

    XCTAssertTrue(html.contains("class=\"wikilink\""), html)
    XCTAssertTrue(html.contains("<a href=\"https://example.com\">label [[B]]</a>"), html)
    XCTAssertFalse(html.contains("<a href=\"https://example.com\">label <a"), html)
  }

  private func render(_ markdown: String) -> String {
    let document = Document(parsing: markdown)
    var emitter = HTMLEmitter()
    return emitter.visit(document)
  }
}
