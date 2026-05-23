import XCTest
import Markdown
@testable import VCNotes

final class HTMLEmitterTests: XCTestCase {
    private func render(_ markdown: String) -> String {
        let document = Document(parsing: markdown)
        var emitter = HTMLEmitter()
        return emitter.visit(document)
    }

    func testHeadings() {
        for level in 1...6 {
            let prefix = String(repeating: "#", count: level)
            let html = render("\(prefix) Title")
            XCTAssertTrue(html.contains("<h\(level)"), "missing <h\(level): \(html)")
            XCTAssertTrue(html.contains(">Title</h\(level)>"), "wrong text: \(html)")
        }
    }

    func testBoldItalicStrikethrough() {
        let html = render("**bold** *italic* ~~gone~~")
        XCTAssertTrue(html.contains("<strong>bold</strong>"), html)
        XCTAssertTrue(html.contains("<em>italic</em>"), html)
        XCTAssertTrue(html.contains("<del>gone</del>"), html)
    }

    func testInlineCode() {
        let html = render("call `foo()` now")
        XCTAssertTrue(html.contains("<code>foo()</code>"), html)
    }

    func testFencedCodeBlockWithLanguage() {
        let html = render("```json\n{\"a\":1}\n```")
        XCTAssertTrue(html.contains("<code class=\"language-json\">"), html)
        XCTAssertTrue(html.contains("{&quot;a&quot;:1}") || html.contains("{\"a\":1}"), html)
        XCTAssertTrue(html.contains("</code></pre>"), html)
    }

    func testFencedCodeBlockNoLanguage() {
        let html = render("```\nplain\n```")
        XCTAssertTrue(html.contains("<pre"), html)
        XCTAssertTrue(html.contains("<code>plain"), html)
        XCTAssertFalse(html.contains("class=\"language-"), html)
    }

    func testUnorderedList() {
        let html = render("- a\n- b\n- c")
        XCTAssertTrue(html.contains("<ul"), html)
        XCTAssertEqual(html.components(separatedBy: "<li>").count - 1, 3, html)
    }

    func testOrderedList() {
        let html = render("1. one\n2. two")
        XCTAssertTrue(html.contains("<ol"), html)
        XCTAssertTrue(html.contains("<li>"), html)
    }

    func testBlockquote() {
        let html = render("> quoted")
        XCTAssertTrue(html.contains("<blockquote"), html)
        XCTAssertTrue(html.contains("quoted"), html)
    }

    func testLink() {
        let html = render("[VetCoders](https://vetcoders.io)")
        XCTAssertTrue(html.contains("<a href=\"https://vetcoders.io\">VetCoders</a>"), html)
    }

    func testHtmlEscapingInText() {
        let html = render("a < b & c > d")
        XCTAssertTrue(html.contains("a &lt; b &amp; c &gt; d"), html)
    }

    func testHardLineBreak() {
        let html = render("line one  \nline two")
        XCTAssertTrue(html.contains("<br />"), html)
    }

    func testParagraphAnchorsCount() {
        let document = Document(parsing: "# A\n\nBody\n\n## B\n\n- l1\n- l2")
        var emitter = HTMLEmitter()
        _ = emitter.visit(document)
        // 4 top-level blocks: h1, p, h2, ul
        XCTAssertGreaterThanOrEqual(emitter.nextBlockIndex, 4,
                                    "expected ≥4 anchors, got \(emitter.nextBlockIndex)")
        XCTAssertTrue(emitter.visit(document).contains("data-vc-block=\""))
    }
}
