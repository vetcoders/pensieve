import XCTest

@testable import Pensieve

@MainActor
final class SidebarHoverTests: XCTestCase {
  func testLateExitCannotEraseTheNextDocumentHover() {
    let first = URL(fileURLWithPath: "/tmp/first.md")
    let second = URL(fileURLWithPath: "/tmp/second.md")
    var hovered = SidebarView.updatedHover(nil, eventID: first, isHovered: true)
    hovered = SidebarView.updatedHover(hovered, eventID: second, isHovered: true)
    hovered = SidebarView.updatedHover(hovered, eventID: first, isHovered: false)
    XCTAssertEqual(hovered, second)
    XCTAssertNil(SidebarView.updatedHover(hovered, eventID: second, isHovered: false))
  }

  func testLateFolderExitUsesTheSameOwnershipRule() {
    XCTAssertEqual(
      SidebarView.updatedHover("new-folder", eventID: "old-folder", isHovered: false),
      "new-folder")
  }

  func testHoveringAnotherResultDoesNotChangeSelection() {
    let active = URL(fileURLWithPath: "/tmp/active.md")
    let other = URL(fileURLWithPath: "/tmp/other.md")
    var hovered = SidebarView.updatedHover(nil, eventID: other, isHovered: true)
    XCTAssertEqual(hovered, other)
    XCTAssertFalse(
      SidebarView.searchResultIsSelected(other, selectedIDs: [], activeDocumentID: active))
    XCTAssertTrue(
      SidebarView.searchResultIsSelected(active, selectedIDs: [], activeDocumentID: active))
    hovered = SidebarView.updatedHover(hovered, eventID: other, isHovered: false)
    XCTAssertNil(hovered)
    XCTAssertTrue(
      SidebarView.searchResultIsSelected(active, selectedIDs: [], activeDocumentID: active))
  }

  func testExplicitMultiSelectionTakesPrecedenceOverActiveDocument() {
    let active = URL(fileURLWithPath: "/tmp/active.md")
    let first = URL(fileURLWithPath: "/tmp/first.md")
    let second = URL(fileURLWithPath: "/tmp/second.md")
    for id in [first, second] {
      XCTAssertTrue(
        SidebarView.searchResultIsSelected(
          id, selectedIDs: [first, second], activeDocumentID: active))
    }
    XCTAssertFalse(
      SidebarView.searchResultIsSelected(
        active, selectedIDs: [first, second], activeDocumentID: active))
  }
}
