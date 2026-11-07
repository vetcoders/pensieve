import AppKit
import XCTest

@testable import Pensieve

final class DocumentFindOptionsTests: XCTestCase {
  private func hits(_ text: String, _ query: String, _ options: DocumentFindOptions) -> [String] {
    let source = text as NSString
    return options.matches(in: source, query: query).map { source.substring(with: $0) }
  }

  func testCaseAndWholeWordOptionsAreIndependent() {
    let text = "cat Cat CAT scatter cat_ cat2 (cat)"
    XCTAssertEqual(hits(text, "cat", .init()).count, 7)
    XCTAssertEqual(hits(text, "cat", .init(matchCase: true)).count, 5)
    XCTAssertEqual(hits(text, "cat", .init(wholeWords: true)), ["cat", "Cat", "CAT", "cat"])
    XCTAssertEqual(hits(text, "cat", .init(matchCase: true, wholeWords: true)), ["cat", "cat"])
  }

  func testLiteralQueriesNeverBecomeRegexOrLoseAccents() {
    XCTAssertEqual(hits("a.b axb A.B", "a.b", .init()), ["a.b", "A.B"])
    XCTAssertEqual(hits("e é E É", "e", .init()), ["e", "E"])
    XCTAssertEqual(hits("e é E É", "é", .init(matchCase: true)), ["é"])
    XCTAssertTrue(hits("anything", "", .init()).isEmpty)
  }

  func testUnicodeWordBoundariesAndUTF16Offsets() {
    let text = "😀kot kotek kot_ kot2 kot\u{301} 𐐀kot kot𐐀 żkot kotż kot‿ kot."
    let source = text as NSString
    let ranges = DocumentFindOptions(wholeWords: true).matches(in: source, query: "kot")
    XCTAssertEqual(ranges.count, 2)
    XCTAssertEqual(ranges.first, NSRange(location: 2, length: 3))
    XCTAssertEqual(ranges.last, NSRange(location: source.length - 4, length: 3))
    XCTAssertEqual(hits("Żółć żółć półżółć", "żółć", .init(wholeWords: true)), ["Żółć", "żółć"])
  }

  @MainActor
  func testChangingOnlyOptionsRefreshesCountAndNavigation() {
    let surface = MarkdownEditorSurface(text: "cat Cat scatter", fontSize: 14)
    var count = 0
    var active: Int?
    surface.onFindStateChanged = {
      count = $0
      active = $1
    }
    surface.updateFind(query: "cat", visible: true)
    XCTAssertEqual(count, 3)
    surface.selectFindMatch(direction: .forward)
    surface.updateFind(
      query: "cat", visible: true, options: .init(matchCase: true, wholeWords: true))
    XCTAssertEqual(count, 1)
    XCTAssertNil(active)
    surface.selectFindMatch(direction: .forward)
    XCTAssertEqual(surface.textView.selectedRange(), NSRange(location: 0, length: 3))
  }

  @MainActor
  func testReplaceOneAndAllUseTheDisplayedOptionsAndLiteralReplacement() {
    let surface = MarkdownEditorSurface(text: "Cat cat CAT scatter cat", fontSize: 14)
    surface.updateFind(
      query: "cat", visible: true, options: .init(matchCase: true, wholeWords: true))
    surface.replaceCurrentFindMatch(query: "cat", replacement: "dog")
    XCTAssertEqual(surface.textStorage.string, "Cat dog CAT scatter cat")
    surface.replaceAllFindMatches(query: "cat", replacement: "$1\\word")
    XCTAssertEqual(surface.textStorage.string, "Cat dog CAT scatter $1\\word")
    XCTAssertEqual(surface.findOptions, .init(matchCase: true, wholeWords: true))
  }

  @MainActor
  func testReplaceCanChangeJustOneLetterCase() {
    let surface = MarkdownEditorSurface(text: "a A aA", fontSize: 14)
    surface.updateFind(query: "a", visible: true, options: .init(matchCase: true))
    surface.replaceAllFindMatches(query: "a", replacement: "A")
    XCTAssertEqual(surface.textStorage.string, "A A AA")
  }

  @MainActor
  func testZeroResultsAndUnchangedOptionsDoNotMutateStorageOnRerender() {
    let surface = MarkdownEditorSurface(text: "Cat", fontSize: 14)
    let options = DocumentFindOptions(matchCase: true, wholeWords: true)
    surface.updateFind(query: "cat", visible: true, options: options)
    let edits = LockedCounter()
    let observer = NotificationCenter.default.addObserver(
      forName: NSTextStorage.didProcessEditingNotification, object: surface.textStorage, queue: nil
    ) { _ in edits.add(1) }
    defer { NotificationCenter.default.removeObserver(observer) }
    surface.updateFind(query: "cat", visible: true, options: options)
    surface.replaceAllFindMatches(query: "cat", replacement: "dog")
    XCTAssertEqual(edits.value, 0)
    XCTAssertEqual(surface.textStorage.string, "Cat")
  }

  @MainActor
  func testOptionsAreScopedToTheDocumentWindow() {
    let first = AppState(defaults: makeEphemeralDefaults(prefix: "FindOptionsFirst"))
    let second = AppState(defaults: makeEphemeralDefaults(prefix: "FindOptionsSecond"))
    first.findOptions = .init(matchCase: true, wholeWords: true)
    XCTAssertEqual(first.windowModel.findOptions, first.findOptions)
    XCTAssertEqual(second.findOptions, .init())
  }

  @MainActor
  func testExternalDocumentChangeInvalidatesEvenAnEmptyMatchCache() {
    let surface = MarkdownEditorSurface(text: "Cat", fontSize: 14)
    let options = DocumentFindOptions(matchCase: true, wholeWords: true)
    var count = 0
    surface.onFindStateChanged = {
      count = $0
      _ = $1
    }
    surface.updateFind(query: "cat", visible: true, options: options)
    XCTAssertEqual(count, 0)
    surface.update(
      text: "cat catapult cat", fontSize: 14, syntaxHighlightingEnabled: true,
      tableTidyOnPaste: true, asciiSafeTables: false, aiAutocompleteEnabled: false,
      findQuery: "cat", findBarVisible: true, findOptions: options)
    XCTAssertEqual(count, 2)
    surface.replaceAllFindMatches(query: "cat", replacement: "dog")
    XCTAssertEqual(surface.textStorage.string, "dog catapult dog")
  }
}
