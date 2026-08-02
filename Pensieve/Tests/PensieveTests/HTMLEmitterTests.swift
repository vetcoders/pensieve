import Markdown
import XCTest

@testable import Pensieve

final class HTMLEmitterTests: XCTestCase {
  private func render(_ markdown: String) -> String {
    let document = Document(parsing: markdown)
    var emitter = HTMLEmitter(source: markdown)
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

  func testMermaidFencedCodeBlockEmitsDiagramContainer() {
    let html = render("```mermaid\ngraph TD\n  A-->B\n```")
    XCTAssertTrue(html.contains("<div class=\"mermaid\""), html)
    XCTAssertTrue(html.contains("data-vc-mermaid=\"true\""), html)
    XCTAssertTrue(html.contains("graph TD"), html)
    XCTAssertTrue(html.contains("A--&gt;B"), html)
    XCTAssertFalse(html.contains("language-mermaid"), html)
  }

  func testInlineMathEmitsMathNodeWithoutChangingSourceText() {
    let html = render("Energy is $E = mc^2$ today.")
    XCTAssertTrue(html.contains("class=\"vc-math vc-math-inline\""), html)
    XCTAssertTrue(html.contains("data-vc-math=\"inline\""), html)
    XCTAssertTrue(html.contains("data-vc-tex=\"E = mc^2\""), html)
    XCTAssertTrue(html.contains(">E = mc^2</span>"), html)
    XCTAssertTrue(html.contains("Energy is "), html)
  }

  func testDisplayMathParagraphEmitsBlockMathNode() {
    let html = render("$$\n\\int_0^1 x^2 dx\n$$")
    XCTAssertTrue(html.contains("class=\"vc-math vc-math-display\""), html)
    XCTAssertTrue(html.contains("data-vc-math=\"display\""), html)
    XCTAssertTrue(html.contains("data-vc-tex=\"\\int_0^1 x^2 dx\""), html)
    XCTAssertTrue(html.contains(">\\int_0^1 x^2 dx</div>"), html)
  }

  func testMathEscapesHtmlAndLeavesEscapedDelimiterAlone() {
    let html = render("Safe $a < b & c$ and cost \\$5")
    XCTAssertTrue(html.contains("data-vc-tex=\"a &lt; b &amp; c\""), html)
    XCTAssertTrue(html.contains(">a &lt; b &amp; c</span>"), html)
    XCTAssertTrue(html.contains("cost $5"), html)
  }

  func testMathAndWikilinksCanCoexistInPlainText() {
    let html = render("See [[Draft]] and $x+y$.")
    XCTAssertTrue(html.contains("class=\"wikilink\""), html)
    XCTAssertTrue(html.contains("data-vc-tex=\"x+y\""), html)
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

  func testTaskListEmitsCheckboxClassesAndState() {
    let html = render("- [ ] todo\n- [x] done")
    XCTAssertTrue(html.contains("<li class=\"task-list-item\">"), html)
    XCTAssertTrue(
      html.contains("class=\"task-list-item-checkbox\" disabled />"), html)
    XCTAssertTrue(
      html.contains("class=\"task-list-item-checkbox\" disabled checked />"), html)
  }

  func testInProgressTaskEmitsThirdStateWithoutTheLiteralMarker() {
    let html = render("- [~] wip")
    XCTAssertTrue(html.contains("<li class=\"task-list-item\">"), html)
    XCTAssertTrue(
      html.contains(
        "class=\"task-list-item-checkbox\" disabled data-vc-task-state=\"in-progress\" aria-checked=\"mixed\" />"
      ), html)
    XCTAssertFalse(html.contains("[~]"), html)
    XCTAssertTrue(html.contains(">wip</p>"), html)
    // The third state is never `checked` — that would make it read as done.
    XCTAssertFalse(html.contains("checked />"), html)
  }

  func testInProgressTaskKeepsInlineChildrenAndNestedBlocks() {
    let html = render("- [~] **bold** tail\n  - [~] inner")
    XCTAssertEqual(html.components(separatedBy: "data-vc-task-state").count - 1, 2, html)
    XCTAssertTrue(html.contains("<strong>bold</strong> tail"), html)
    XCTAssertTrue(html.contains(">inner</p>"), html)
    XCTAssertFalse(html.contains("[~]"), html)
  }

  func testEmptyInProgressTaskEmitsBareItemLikeAnEmptyUncheckedTask() {
    let html = render("- [~]")
    XCTAssertTrue(html.contains("data-vc-task-state=\"in-progress\""), html)
    XCTAssertFalse(html.contains("[~]"), html)
    XCTAssertFalse(html.contains("<p"), html)
  }

  /// `[~]` is a checkbox only where GFM would accept one: opening the item and
  /// followed by whitespace. Everything else stays prose.
  func testTildeMarkerOutsideTaskPositionStaysLiteralText() {
    for markdown in ["- [~]wip", "- wip [~] tail", "[~] loose paragraph"] {
      let html = render(markdown)
      XCTAssertFalse(html.contains("task-list-item"), "\(markdown) → \(html)")
      XCTAssertTrue(html.contains("[~]"), "\(markdown) → \(html)")
    }
  }

  /// GFM keeps an escaped `\[x]` as prose; the third state must obey the same
  /// escape. cmark resolves `\[` before it builds the Text node, so the AST alone
  /// cannot tell `\[~] wip` from `[~] wip` — the emitter has to consult the
  /// source. An author who escaped the marker asked for literal text.
  func testEscapedMarkerStaysProseInsteadOfBecomingATask() {
    let html = render("- \\[~] wip")
    XCTAssertFalse(html.contains("task-list-item"), html)
    XCTAssertFalse(html.contains("data-vc-task-state"), html)
    XCTAssertTrue(html.contains("[~] wip"), html)
  }

  /// The escape must not disarm the marker for the whole document: the unescaped
  /// sibling in the same list still promotes, and the escaped one is untouched.
  func testEscapedAndRealMarkersCoexistInOneList() {
    let html = render("- \\[~] literal\n- [~] real\n")
    XCTAssertEqual(html.components(separatedBy: "data-vc-task-state").count - 1, 1, html)
    XCTAssertTrue(html.contains("[~] literal"), html)
    XCTAssertFalse(html.contains("[~] real"), html)
    XCTAssertTrue(html.contains(">real</p>"), html)
  }

  /// The source lookup is by line + column, so a marker that is not on line 1
  /// (and sits behind a longer prefix) must resolve just as exactly.
  func testEscapeDetectionHoldsForLaterLinesAndNestedItems() {
    let html = render("intro\n\n- first\n- [~] real\n  - \\[~] literal\n")
    XCTAssertEqual(html.components(separatedBy: "data-vc-task-state").count - 1, 1, html)
    XCTAssertTrue(html.contains("[~] literal"), html)
  }

  /// The source check asked the WRONG question: "is the first byte a
  /// backslash?" A backslash is not the only way to reach a `[` that the author
  /// did not type — cmark decodes character references during inline parsing, so
  /// `&#91;~] wip` arrives in the AST as a pristine `[~] wip` whose first source
  /// byte is `&`. That is not a backslash, so the old test said "not escaped"
  /// and promoted a task GFM would never promote. Ask the positive question
  /// instead: the marker counts only when the source really begins with `[`.
  func testEntityEncodedMarkerStaysProseInsteadOfBecomingATask() {
    let html = render("- &#91;~] wip")
    XCTAssertFalse(html.contains("task-list-item"), html)
    XCTAssertFalse(html.contains("data-vc-task-state"), html)
    XCTAssertTrue(html.contains("[~] wip"), html)
  }

  /// THE CONTROL LEG for the positive test. Turning "not a backslash" into "is a
  /// `[`" must not disarm the plainly written marker beside it.
  func testAPlainlyWrittenMarkerStillPromotesBesideAnEncodedOne() {
    let html = render("- &#91;~] encoded\n- [~] real\n")
    XCTAssertEqual(html.components(separatedBy: "data-vc-task-state").count - 1, 1, html)
    XCTAssertTrue(html.contains("[~] encoded"), html)
    XCTAssertFalse(html.contains("[~] real"), html)
    XCTAssertTrue(html.contains(">real</p>"), html)
  }

  /// The source index counted a line start only at `\n`, but cmark treats a
  /// LONE CR as a line ending too and advances its line numbers accordingly. In
  /// a CR-only document the index therefore ran one line short at every marker:
  /// `byte(at:)` resolved past the end and answered nil, the check fell back to
  /// "allow", and an escaped marker was promoted. Nothing normalizes lone CR on
  /// the render path, so a document saved by a classic-Mac-era tool (or pasted
  /// out of one) hit this directly.
  func testEscapedMarkerStaysProseInACROnlyDocument() {
    let html = render("intro\r\r- first\r- \\[~] literal\r")
    XCTAssertFalse(html.contains("task-list-item"), html)
    XCTAssertFalse(html.contains("data-vc-task-state"), html)
    XCTAssertTrue(html.contains("[~] literal"), html)
  }

  /// CONTROL LEG (a): the same CR-only document must still promote a marker the
  /// author DID write, or "treat CR as a line ending" would have degenerated
  /// into "never promote anything in a CR document".
  func testRealMarkerStillPromotesInACROnlyDocument() {
    let html = render("intro\r\r- first\r- [~] real\r")
    XCTAssertEqual(html.components(separatedBy: "data-vc-task-state").count - 1, 1, html)
    XCTAssertTrue(html.contains(">real</p>"), html)
    XCTAssertFalse(html.contains("[~] real"), html)
  }

  /// CONTROL LEG (b): CRLF must not gain a second line start from its CR half —
  /// that would push every later offset one byte early and break the documents
  /// that already worked.
  func testEscapeDetectionSurvivesCRLFLineEndings() {
    let html = render("intro\r\n\r\n- first\r\n- [~] real\r\n  - \\[~] literal\r\n")
    XCTAssertEqual(html.components(separatedBy: "data-vc-task-state").count - 1, 1, html)
    XCTAssertTrue(html.contains("[~] literal"), html)
    XCTAssertTrue(html.contains(">real</p>"), html)
  }

  /// GFM's own escaped checkbox is unaffected — the byte-parity guard for the
  /// two states cmark already owns.
  func testEscapedGFMCheckboxStillRendersAsProse() {
    let html = render("- \\[x] done\n- \\[ ] todo\n")
    XCTAssertFalse(html.contains("task-list-item"), html)
    XCTAssertTrue(html.contains("[x] done"), html)
    XCTAssertTrue(html.contains("[ ] todo"), html)
  }

  /// A single `~` is also a GFM strikethrough delimiter; promoting the marker
  /// must not swallow a later `~pair~` on the same line.
  func testInProgressTaskLeavesStrikethroughOnTheSameLineIntact() {
    let html = render("- [~] wip ~gone~ tail")
    XCTAssertTrue(html.contains("data-vc-task-state=\"in-progress\""), html)
    XCTAssertTrue(html.contains("wip <del>gone</del> tail"), html)
  }

  /// Guards the `default` theme's GitHub contract: the two states GFM already
  /// knows emit exactly the same bytes as before the third state existed.
  func testExistingCheckboxStatesEmitNoThirdStateAttributes() {
    let html = render("- [ ] todo\n- [x] done\n- [X] shouted")
    XCTAssertFalse(html.contains("data-vc-task-state"), html)
    XCTAssertFalse(html.contains("aria-checked"), html)
    let unchecked = "class=\"task-list-item-checkbox\" disabled />"
    let checked = "class=\"task-list-item-checkbox\" disabled checked />"
    XCTAssertEqual(html.components(separatedBy: unchecked).count - 1, 1, html)
    XCTAssertEqual(html.components(separatedBy: checked).count - 1, 2, html)
  }

  func testBlockquote() {
    let html = render("> quoted")
    XCTAssertTrue(html.contains("<blockquote"), html)
    XCTAssertTrue(html.contains("quoted"), html)
  }

  func testLink() {
    let html = render("[Vetcoders](https://vetcoders.io)")
    XCTAssertTrue(html.contains("<a href=\"https://vetcoders.io\">Vetcoders</a>"), html)
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
    let markdown = "# A\n\nBody\n\n## B\n\n- l1\n- l2"
    let document = Document(parsing: markdown)
    var emitter = HTMLEmitter(source: markdown)
    _ = emitter.visit(document)
    // 4 top-level blocks: h1, p, h2, ul
    XCTAssertGreaterThanOrEqual(
      emitter.nextBlockIndex, 4,
      "expected ≥4 anchors, got \(emitter.nextBlockIndex)")
    XCTAssertTrue(emitter.visit(document).contains("data-vc-block=\""))
  }
}
