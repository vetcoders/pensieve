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
    XCTAssertTrue(panel.canBecomeKey)
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

  func testPanelOwnsSizingAndKeepsHostedContentPinnedToItsBounds() {
    let service = TranscriptionService()
    let controller = TranscriptionTaflaPanelController(service: service)
    let panel = controller.makePanelForTesting()
    let contentView = panel.contentView

    XCTAssertEqual(panel.contentMinSize, NSSize(width: 560, height: 420))
    XCTAssertEqual(contentView?.subviews.count, 1)
    contentView?.setFrameSize(NSSize(width: 640, height: 460))
    contentView?.layoutSubtreeIfNeeded()
    XCTAssertEqual(contentView?.subviews.first?.frame, contentView?.bounds)
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

  func testDictationAIActionsExplainTheirEffectWithoutLegacyKurierLanguage() {
    XCTAssertEqual(TranscriptionFormatMode.cleanUp.title, "Clean Up")
    XCTAssertEqual(TranscriptionFormatMode.cleanUp.actionTitle, "Clean Up Text")
    XCTAssertFalse(TranscriptionFormatMode.cleanUp.assistive)
    XCTAssertTrue(TranscriptionFormatMode.cleanUp.detail.contains("without changing"))

    XCTAssertEqual(TranscriptionFormatMode.writingAssistant.title, "Writing Assistant")
    XCTAssertEqual(
      TranscriptionFormatMode.writingAssistant.actionTitle, "Run Writing Assistant")
    XCTAssertTrue(TranscriptionFormatMode.writingAssistant.assistive)
    XCTAssertTrue(TranscriptionFormatMode.writingAssistant.detail.contains("message yours"))
    XCTAssertFalse(TranscriptionFormatMode.allCases.map(\.title).contains("Kurier"))
  }

  func testDictationDestinationDrivesThePrimaryActionCopy() {
    XCTAssertEqual(TranscriptionSendTarget.editor.title, "Editor")
    XCTAssertEqual(TranscriptionSendTarget.editor.actionTitle, "Insert")
    XCTAssertEqual(TranscriptionSendTarget.agent.title, "Agent")
    XCTAssertEqual(TranscriptionSendTarget.agent.actionTitle, "Dispatch")
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
