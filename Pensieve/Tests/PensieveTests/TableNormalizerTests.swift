import XCTest

@testable import Pensieve

final class TableNormalizerTests: XCTestCase {
  func testAlreadyCleanMarkdownTableIsIdempotent() {
    let input = """
      | a | b |
      |---|---|
      | c | d |
      """

    XCTAssertEqual(TableNormalizer.normalize(input), input)
  }

  func testBoxDrawingTableConvertsToMarkdown() {
    let input = """
      \u{250C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{252C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2510}
      \u{2502} Name \u{2502} Key \u{2502}
      \u{251C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{253C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2524}
      \u{2502} Copy \u{2502} \u{2318}C  \u{2502}
      \u{2514}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2534}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2518}
      """

    XCTAssertEqual(
      TableNormalizer.normalize(input),
      """
      | Name | Key |
      |---|---|
      | Copy | \u{2318}C |
      """
    )
  }

  func testASCIIBorderTableConvertsToMarkdown() {
    let input = """
      +------+-----+
      | a    | b   |
      +------+-----+
      | c    | d   |
      +------+-----+
      """

    XCTAssertEqual(
      TableNormalizer.normalize(input),
      """
      | a | b |
      |---|---|
      | c | d |
      """
    )
  }

  func testContinuationRowsMergeIntoPreviousRow() {
    let input = """
      | Item | Notes |
      |------|-------|
      | A | first |
      | | wrapped |
      | B | done |
      """

    XCTAssertEqual(
      TableNormalizer.normalize(input),
      """
      | Item | Notes |
      |---|---|
      | A | first wrapped |
      | B | done |
      """
    )
  }

  func testRaggedAmbiguousInputIsLeftUnchanged() {
    let input = """
      | a | b |
      | c | d | e |
      | f | g | h | i |
      """

    XCTAssertEqual(TableNormalizer.normalize(input), input)
  }

  func testSurroundingProseIsPreserved() {
    let input = "before  \n| a | b |\n| c | d |\nafter\t"

    XCTAssertEqual(
      TableNormalizer.normalize(input),
      "before  \n| a | b |\n|---|---|\n| c | d |\nafter\t"
    )
  }

  func testANSIEscapedTerminalOutputIsStripped() {
    let input = """
      \u{001B}[31m\u{2502} A \u{2502} B \u{2502}\u{001B}[0m
      \u{2502} C \u{2502} D \u{2502}
      """

    XCTAssertEqual(
      TableNormalizer.normalize(input),
      """
      | A | B |
      |---|---|
      | C | D |
      """
    )
  }

  func testASCIISafeReplacementsAreOptIn() {
    let input = """
      | Key | Done |
      |-----|------|
      | \u{2318}C | \u{2713} |
      """

    XCTAssertEqual(
      TableNormalizer.normalize(input),
      """
      | Key | Done |
      |---|---|
      | \u{2318}C | \u{2713} |
      """
    )
    XCTAssertEqual(
      TableNormalizer.normalize(input, asciiSafe: true),
      """
      | Key | Done |
      |---|---|
      | CmdC | [x] |
      """
    )
  }

  func testEmptyAndNoTableInputReturnUnchanged() {
    XCTAssertEqual(TableNormalizer.normalize(""), "")
    XCTAssertEqual(TableNormalizer.normalize("plain\ntext"), "plain\ntext")
    XCTAssertFalse(TableNormalizer.containsTableSmell("plain\ntext"))
  }

  func testContainsTableSmellRecognizesBoxAndPipeRows() {
    XCTAssertTrue(TableNormalizer.containsTableSmell("\u{2502} a \u{2502} b \u{2502}"))
    XCTAssertTrue(TableNormalizer.containsTableSmell("| a | b | c |"))
  }
}
