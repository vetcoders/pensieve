import XCTest

@testable import Pensieve

@MainActor
final class WorkspaceAskComposerTests: XCTestCase {
  func testWorkspaceComposerPlaceholder() {
    XCTAssertEqual(WorkspaceAskComposer.placeholder, "Ask about this workspace")
    XCTAssertEqual(
      WorkspaceAskComposer.accessibilityIdentifier, "pensieve.workspaceAsk.composer")
    XCTAssertEqual(
      WorkspaceAskComposer.fieldAccessibilityIdentifier, "pensieve.workspaceAsk.field")
    XCTAssertEqual(
      WorkspaceAskComposer.submitAccessibilityIdentifier, "pensieve.workspaceAsk.submit")
    XCTAssertNotEqual(WorkspaceAskComposer.placeholder, "Ask or edit this document")
    XCTAssertEqual(WorkspaceAskComposer.submission(from: "  one shelf  "), "one shelf")
    XCTAssertNil(WorkspaceAskComposer.submission(from: " \n\t "))
  }
}
