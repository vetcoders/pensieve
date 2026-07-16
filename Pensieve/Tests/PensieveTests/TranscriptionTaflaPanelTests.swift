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
    XCTAssertEqual(panel.contentView?.accessibilityIdentifier(), "pensieve.dictation.panel")
    XCTAssertFalse(panel.isKeyWindow)
    XCTAssertFalse(panel.isMainWindow)
  }

  func testPanelUsesMatureDictationIdentityAndAccessiblePurpose() {
    let service = TranscriptionService()
    let controller = TranscriptionTaflaPanelController(service: service)
    let panel = controller.makePanelForTesting()

    XCTAssertEqual(panel.title, "Dictation")
    XCTAssertEqual(panel.contentView?.accessibilityLabel(), "Dictation controls")
    XCTAssertEqual(
      panel.contentView?.accessibilityHelp(),
      "Record speech, review the transcript, and insert it into the active document."
    )
  }

  func testPanelStartsAtAStableWorkingSizeAndCannotCollapseIntoACrampedLayout() {
    let service = TranscriptionService()
    let controller = TranscriptionTaflaPanelController(service: service)
    let panel = controller.makePanelForTesting()

    XCTAssertGreaterThanOrEqual(panel.frame.width, 680)
    XCTAssertGreaterThanOrEqual(panel.frame.height, 500)
    XCTAssertGreaterThanOrEqual(panel.minSize.width, 520)
    XCTAssertGreaterThanOrEqual(panel.minSize.height, 380)
  }

  func testControllerShowsAndHidesDictationWithoutActivatingItAsTheMainWindow() {
    let service = TranscriptionService()
    let controller = TranscriptionTaflaPanelController(service: service)

    controller.show()
    XCTAssertTrue(controller.isVisible)

    controller.hide()
    XCTAssertFalse(controller.isVisible)
  }
}
