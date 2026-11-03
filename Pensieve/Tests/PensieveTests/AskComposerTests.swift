import XCTest

@testable import Pensieve

@MainActor
final class AskComposerTests: XCTestCase {
  func testUnifiedComposerTrimsSubmissionsAndExposesOneField() {
    XCTAssertEqual(AskComposerView.placeholder, "Ask a question")
    XCTAssertEqual(
      AskComposerView.accessibilityPrefix, "pensieve.ask")
    XCTAssertEqual(
      AskComposerView.fieldAccessibilityIdentifier, "pensieve.ask.draft")
    XCTAssertEqual(
      AskComposerView.submitAccessibilityIdentifier, "pensieve.ask.send")
    XCTAssertEqual(AskComposerView.submission(from: "  one shelf  "), "one shelf")
    XCTAssertNil(AskComposerView.submission(from: " \n\t "))
  }
}
