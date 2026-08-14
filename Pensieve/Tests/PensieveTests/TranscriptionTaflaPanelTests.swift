import AppKit
import XCTest

@testable import Pensieve

@MainActor
final class TranscriptionTaflaPanelTests: XCTestCase {
  func testPanelIsFloatingNonActivatingAndAccessible() {
    let fixture = makeFixture()
    defer { close(fixture) }
    fixture.controller.show()
    let panel = fixture.panel

    assertUnpublished(panel)
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
    let fixture = makeFixture()
    defer { close(fixture) }
    fixture.controller.show()
    let panel = fixture.panel
    let contentView = panel.contentView

    assertUnpublished(panel)
    XCTAssertEqual(panel.contentMinSize, NSSize(width: 560, height: 420))
    XCTAssertEqual(contentView?.subviews.count, 1)
    contentView?.setFrameSize(NSSize(width: 640, height: 460))
    contentView?.layoutSubtreeIfNeeded()
    XCTAssertEqual(contentView?.subviews.first?.frame, contentView?.bounds)
  }

  func testPanelUsesMatureDictationIdentityAndAccessiblePurpose() {
    let fixture = makeFixture()
    defer { close(fixture) }
    fixture.controller.show()
    let panel = fixture.panel

    assertUnpublished(panel)
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
    let fixture = makeFixture()
    defer { close(fixture) }
    fixture.controller.show()
    let panel = fixture.panel

    assertUnpublished(panel)
    XCTAssertGreaterThanOrEqual(panel.frame.width, 680)
    XCTAssertGreaterThanOrEqual(panel.frame.height, 500)
    XCTAssertGreaterThanOrEqual(panel.minSize.width, 520)
    XCTAssertGreaterThanOrEqual(panel.minSize.height, 380)
  }

  func testControllerShowsAndHidesDictationWithoutActivatingItAsTheMainWindow() {
    var presentedPanel: NSPanel?
    var dismissedPanel: NSPanel?
    var visible = false
    let fixture = makeFixture(
      presentPanel: {
        presentedPanel = $0
        visible = true
      },
      dismissPanel: {
        dismissedPanel = $0
        visible = false
      },
      panelIsVisible: { _ in visible })
    defer { close(fixture) }

    fixture.controller.show()
    assertUnpublished(fixture.panel)
    XCTAssertTrue(presentedPanel === fixture.panel)
    XCTAssertTrue(fixture.controller.isVisible)

    fixture.controller.hide()
    assertUnpublished(fixture.panel)
    XCTAssertTrue(dismissedPanel === fixture.panel)
    XCTAssertFalse(fixture.controller.isVisible)
  }

  private struct Fixture {
    let controller: TranscriptionTaflaPanelController
    let panel: NSPanel
  }

  private func makeFixture(
    presentPanel: @escaping @MainActor (NSPanel) -> Void = { _ in },
    dismissPanel: @escaping @MainActor (NSPanel) -> Void = { _ in },
    panelIsVisible: @escaping @MainActor (NSPanel) -> Bool = { _ in false }
  ) -> Fixture {
    let panel = NonActivatingTaflaPanel(
      contentRect: NSRect(x: 160, y: 160, width: 720, height: 520),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    assertUnpublished(panel)
    let controller = TranscriptionTaflaPanelController(
      service: TranscriptionService(),
      panelFactory: { panel },
      presentPanel: presentPanel,
      dismissPanel: dismissPanel,
      panelIsVisible: panelIsVisible
    )
    return Fixture(controller: controller, panel: panel)
  }

  private func close(_ fixture: Fixture) {
    fixture.controller.hide()
    assertUnpublished(fixture.panel)
    fixture.panel.close()
    assertUnpublished(fixture.panel)
  }

  private func assertUnpublished(_ panel: NSPanel) {
    XCTAssertFalse(panel.isVisible)
    XCTAssertEqual(panel.windowNumber, -1)
  }
}
