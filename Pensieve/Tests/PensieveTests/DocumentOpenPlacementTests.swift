import AppKit
import XCTest

@testable import Pensieve

final class DocumentOpenPlacementTests: XCTestCase {
  func testAlwaysTabsOnlyWhenASourceWindowExists() {
    XCTAssertEqual(
      DocumentOpenPlacement.resolve(
        preference: .always,
        sourceIsFullScreen: false,
        hasSourceWindow: true
      ),
      .tabIn
    )
    XCTAssertEqual(
      DocumentOpenPlacement.resolve(
        preference: .always,
        sourceIsFullScreen: false,
        hasSourceWindow: false
      ),
      .newWindow
    )
  }

  func testManualAlwaysCreatesANewWindow() {
    for hasSourceWindow in [false, true] {
      for sourceIsFullScreen in [false, true] {
        XCTAssertEqual(
          DocumentOpenPlacement.resolve(
            preference: .manual,
            sourceIsFullScreen: sourceIsFullScreen,
            hasSourceWindow: hasSourceWindow
          ),
          .newWindow
        )
      }
    }
  }

  func testInFullScreenTabsOnlyFromAFullScreenSourceWindow() {
    XCTAssertEqual(
      DocumentOpenPlacement.resolve(
        preference: .inFullScreen,
        sourceIsFullScreen: true,
        hasSourceWindow: true
      ),
      .tabIn
    )
    XCTAssertEqual(
      DocumentOpenPlacement.resolve(
        preference: .inFullScreen,
        sourceIsFullScreen: false,
        hasSourceWindow: true
      ),
      .newWindow
    )
  }

  func testInFullScreenWithoutASourceAlwaysCreatesANewWindow() {
    for sourceIsFullScreen in [false, true] {
      XCTAssertEqual(
        DocumentOpenPlacement.resolve(
          preference: .inFullScreen,
          sourceIsFullScreen: sourceIsFullScreen,
          hasSourceWindow: false
        ),
        .newWindow
      )
    }
  }
}
