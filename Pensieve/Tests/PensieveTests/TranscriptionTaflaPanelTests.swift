import AppKit
import XCTest

@testable import Pensieve

@MainActor
final class TranscriptionTaflaPanelTests: XCTestCase {
  func testPanelIsFloatingNonActivatingAndAccessible() {
    let service = TranscriptionService()
    let controller = TranscriptionTaflaPanelController(service: service)
    let panel = controller.makePanelForTesting()

    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertFalse(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
    XCTAssertEqual(panel.level, .floating)
    XCTAssertTrue(panel.isFloatingPanel)
    XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
    XCTAssertFalse(panel.hidesOnDeactivate)
    XCTAssertFalse(panel.isReleasedWhenClosed)
    XCTAssertTrue(panel.styleMask.contains(.resizable))
    XCTAssertEqual(
      panel.collectionBehavior.intersection([
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .ignoresCycle,
      ]),
      [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    )
    XCTAssertEqual(panel.contentView?.accessibilityIdentifier(), "pensieve.tafla.panel")
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertFalse(panel.isMainWindow)
  }
}
