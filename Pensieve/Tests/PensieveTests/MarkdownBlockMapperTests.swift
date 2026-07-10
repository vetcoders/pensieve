import XCTest

@testable import Pensieve

final class MarkdownBlockMapperTests: XCTestCase {
  func testBlockStartsTrackNonEmptyRunsSeparatedByBlankLines() {
    let markdown = "# One\nline\n\n## Two\nbody\n\n- three\n- more\n"

    XCTAssertEqual(MarkdownBlockMapper.blockStarts(in: markdown), [0, 12, 25])
    XCTAssertEqual(MarkdownBlockMapper.blockIndex(atUTF16Location: 0, in: markdown), 0)
    XCTAssertEqual(MarkdownBlockMapper.blockIndex(atUTF16Location: 13, in: markdown), 1)
    XCTAssertEqual(MarkdownBlockMapper.blockIndex(atUTF16Location: 30, in: markdown), 2)
  }

  func testLocationForBlockIndexReturnsSourceStart() {
    let markdown = "\n\nFirst paragraph\n\nSecond paragraph"

    XCTAssertEqual(MarkdownBlockMapper.utf16Location(forBlockIndex: 0, in: markdown), 2)
    XCTAssertEqual(MarkdownBlockMapper.utf16Location(forBlockIndex: 1, in: markdown), 19)
    XCTAssertNil(MarkdownBlockMapper.utf16Location(forBlockIndex: 2, in: markdown))
  }

  func testEmptyAndBlankOnlyDocumentsHaveNoBlocks() {
    XCTAssertNil(MarkdownBlockMapper.blockIndex(atUTF16Location: 0, in: ""))
    XCTAssertNil(MarkdownBlockMapper.blockIndex(atUTF16Location: 0, in: "\n  \n\t\n"))
    XCTAssertEqual(MarkdownBlockMapper.blockStarts(in: "\n  \n\t\n"), [])
  }

  func testOffsetBeforeFirstBlockClampsToFirstBlock() {
    let markdown = "\n\n# Heading"

    XCTAssertEqual(MarkdownBlockMapper.blockIndex(atUTF16Location: 0, in: markdown), 0)
    XCTAssertEqual(MarkdownBlockMapper.blockIndex(atUTF16Location: 999, in: markdown), 0)
  }
}
