import XCTest

@testable import Pensieve

final class DocumentMetricsTests: XCTestCase {
  // MARK: - measure

  func testEmptyDocumentIsOneLineZeroEverythingElse() {
    let m = DocumentMetrics.measure("")
    XCTAssertEqual(m, .empty)
    XCTAssertEqual(m.lines, 1)
    XCTAssertEqual(m.characters, 0)
    XCTAssertEqual(m.words, 0)
    XCTAssertEqual(m.bytes, 0)
  }

  func testAsciiCounts() {
    let m = DocumentMetrics.measure("hello world")
    XCTAssertEqual(m.characters, 11)
    XCTAssertEqual(m.bytes, 11)
    XCTAssertEqual(m.words, 2)
    XCTAssertEqual(m.lines, 1)
  }

  func testEmojiCountsAsOneCodePointButFourBytes() {
    // 😀 is one Unicode scalar (TextForge Array.from semantics) and 4 UTF-8 bytes.
    let m = DocumentMetrics.measure("😀")
    XCTAssertEqual(m.characters, 1)
    XCTAssertEqual(m.bytes, 4)
    XCTAssertEqual(m.words, 1)
  }

  func testMultibyteBytesExceedCharacters() {
    // "łódź" — 4 scalars; ł/ó/ź are 2 UTF-8 bytes each, plain ASCII "d" is 1,
    // so 2+2+1+2 = 7 bytes against 4 code points.
    let m = DocumentMetrics.measure("łódź")
    XCTAssertEqual(m.characters, 4)
    XCTAssertEqual(m.bytes, 7)
    XCTAssertEqual(m.words, 1)
  }

  func testLineCountFollowsNewlines() {
    let m = DocumentMetrics.measure("a\nb\nc")
    XCTAssertEqual(m.lines, 3)
    XCTAssertEqual(m.words, 3)
  }

  func testWordsIgnoreExtraWhitespace() {
    let m = DocumentMetrics.measure("  one   two\tthree\nfour  ")
    XCTAssertEqual(m.words, 4)
  }

  // MARK: - CaretPosition.resolve

  func testCaretAtStart() {
    let c = CaretPosition.resolve(utf16Offset: 0, in: "hello")
    XCTAssertEqual(c, .start)
    XCTAssertEqual(c.line, 1)
    XCTAssertEqual(c.column, 1)
  }

  func testCaretColumnOnFirstLine() {
    let c = CaretPosition.resolve(utf16Offset: 3, in: "hello")
    XCTAssertEqual(c.line, 1)
    XCTAssertEqual(c.column, 4)
    XCTAssertEqual(c.offset, 3)
  }

  func testCaretLineAndColumnAcrossNewlines() {
    let text = "alpha\nbeta\ngamma"
    // Offset 8 = "be|ta" on line 2 (UTF-16: 6 chars of "alpha\n" + "be").
    let c = CaretPosition.resolve(utf16Offset: 8, in: text)
    XCTAssertEqual(c.line, 2)
    XCTAssertEqual(c.column, 3)
  }

  func testCaretColumnCountsEmojiAsOneScalar() {
    // "😀X" — caret after the emoji is at UTF-16 offset 2 (surrogate pair) but
    // column 2 in code-point terms.
    let c = CaretPosition.resolve(utf16Offset: 2, in: "😀X")
    XCTAssertEqual(c.line, 1)
    XCTAssertEqual(c.column, 2)
    XCTAssertEqual(c.offset, 1)
  }

  func testCaretOffsetClampsBeyondBounds() {
    let c = CaretPosition.resolve(utf16Offset: 9_999, in: "abc")
    XCTAssertEqual(c.line, 1)
    XCTAssertEqual(c.column, 4)
    XCTAssertEqual(c.offset, 3)
  }
}
