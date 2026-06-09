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
    XCTAssertEqual(
      panel.collectionBehavior.intersection([.canJoinAllSpaces, .fullScreenAuxiliary]),
      [.canJoinAllSpaces, .fullScreenAuxiliary]
    )
    XCTAssertEqual(panel.contentView?.accessibilityIdentifier(), "pensieve.tafla.panel")
  }
}
