import XCTest

@testable import Pensieve

final class MarkdownRendererTests: XCTestCase {
  // MARK: - strippingLeadingFrontmatter

  func testStripsLeadingFrontmatter() {
    let input = "---\nname: doc\nmode: x\n---\n\n# Title\n\nBody."
    let out = MarkdownRenderer.strippingLeadingFrontmatter(input)
    XCTAssertFalse(out.contains("name: doc"))
    XCTAssertFalse(out.contains("mode: x"))
    XCTAssertTrue(out.hasPrefix("# Title"))
    XCTAssertTrue(out.contains("Body."))
  }

  /// A `---` block in the MIDDLE of the document is a real thematic break /
  /// setext heading, not frontmatter — must be left exactly as-is.
  func testLeavesMidDocumentDelimiterUntouched() {
    let input = "# Heading\n\nText.\n\n---\nname: x\nmode: y\n---\n\n# Next"
    XCTAssertEqual(MarkdownRenderer.strippingLeadingFrontmatter(input), input)
  }

  func testNoFrontmatterUnchanged() {
    let input = "# Title\n\nJust prose, no fences."
    XCTAssertEqual(MarkdownRenderer.strippingLeadingFrontmatter(input), input)
  }

  func testYamlDocEndCloseSupported() {
    let input = "---\nname: x\n...\n# Title"
    XCTAssertEqual(MarkdownRenderer.strippingLeadingFrontmatter(input), "# Title")
  }

  /// An opening `---` with no matching close is a horizontal rule, not
  /// frontmatter — do not swallow the document.
  func testOpenFenceWithoutCloseIsNotFrontmatter() {
    let input = "---\njust an hr then text\nmore text"
    XCTAssertEqual(MarkdownRenderer.strippingLeadingFrontmatter(input), input)
  }

  func testToleratesLeadingBOM() {
    let input = "\u{FEFF}---\nname: x\n---\n# Title"
    XCTAssertEqual(MarkdownRenderer.strippingLeadingFrontmatter(input), "# Title")
  }

  func testWholeDocumentFrontmatterRendersEmpty() {
    let input = "---\nname: x\nmode: y\n---\n"
    XCTAssertEqual(MarkdownRenderer.strippingLeadingFrontmatter(input), "")
  }

  // MARK: - render() integration (the daily SKILL.md case)

  func testRenderHidesFrontmatterFromBody() {
    let skill = "---\nname: my-skill\ndescription: does things\n---\n\n# My Skill\n\nContent."
    let output = MarkdownRenderer().render(skill)
    XCTAssertFalse(output.body.contains("my-skill"))
    XCTAssertFalse(output.body.contains("description"))
    XCTAssertTrue(output.body.contains("My Skill"))
  }
}
