import AppKit
import XCTest

@testable import Pensieve

/// The pins that go all the way to the surface: a real window, the real
/// `ContentView`, the real editor, and the layout AppKit actually produces.
///
/// `WindowErrorSurfaceTests` pins the DECISION — which severity a production
/// write site chose, and what the resolver makes of it. These pin the MOUNTING:
/// that `ContentView` really puts the banner into this window's detail pane,
/// that it takes the room back when the error goes away, and that neither
/// transition costs the operator their caret or the sentence they were typing.
///
/// Without them the D.2 failure is available again — a resolver returning
/// `.banner(...)` in a green suite while `ContentView` renders nothing.
final class WindowErrorChromeRenderTests: XCTestCase {

  /// The headline render pin. An error recorded on this window's state has to
  /// change what the window puts on screen; the banner is a sibling of the
  /// editor, so it can only appear by taking room from it.
  @MainActor
  func testRecordingAnErrorMountsTheBannerAndClearingItGivesTheRoomBack() throws {
    let rig = try makeWindowErrorChromeRig(prefix: "errorchrome-mount")
    defer { rig.tearDown() }

    let quiet = try XCTUnwrap(rig.editorPaneHeight())

    rig.appState.lastError = "Could not open Kancelaria: no such directory"
    rig.settle(0.3)
    let withBanner = try XCTUnwrap(rig.editorPaneHeight())

    XCTAssertLessThan(
      withBanner, quiet,
      "recording an error changed nothing in the live window — the banner was never mounted")

    rig.appState.resolveError()
    rig.settle(0.3)

    XCTAssertEqual(
      try XCTUnwrap(rig.editorPaneHeight()), quiet,
      "the banner kept the editor's room after the error it reported was cleared")
  }

  /// The data-loss class mounts the same standing banner. There is no modal
  /// anywhere in this surface, so the line IS the whole report.
  @MainActor
  func testADataLossErrorMountsTheStandingBanner() throws {
    let rig = try makeWindowErrorChromeRig(prefix: "errorchrome-dataloss")
    defer { rig.tearDown() }

    let quiet = try XCTUnwrap(rig.editorPaneHeight())

    rig.appState.reportDataLoss("Could not write recovery draft: no space left on device")
    rig.settle(0.3)

    XCTAssertLessThan(
      try XCTUnwrap(rig.editorPaneHeight()), quiet,
      "losing the only copy of the text put nothing on screen")
    XCTAssertNotNil(rig.appState.unresolvedDataLoss, "the loss was not latched")
  }

  /// RULE 1 on the live surface: a routine message arriving after a data loss
  /// does not take the line. The height alone cannot tell the two banners
  /// apart, so the severity is read from the same state the view renders.
  @MainActor
  func testARoutineMessageDoesNotTakeTheLineFromADataLoss() throws {
    let rig = try makeWindowErrorChromeRig(prefix: "errorchrome-rule1")
    defer { rig.tearDown() }

    let quiet = try XCTUnwrap(rig.editorPaneHeight())
    rig.appState.reportDataLoss("Could not write recovery draft: no space left on device")
    rig.settle(0.3)
    let withBanner = try XCTUnwrap(rig.editorPaneHeight())
    XCTAssertLessThan(withBanner, quiet, "fixture precondition: the banner is up")

    rig.appState.lastError = "Could not open Kancelaria: no such directory"
    rig.settle(0.3)

    XCTAssertEqual(
      try XCTUnwrap(rig.editorPaneHeight()), withBanner,
      "the line changed shape when a routine message arrived over a data loss")
    XCTAssertEqual(
      rig.appState.currentError?.severity, .dataLoss,
      "a routine message displaced the unresolved data loss on screen")
  }

  /// RULE 2 on the live surface: the banner the user closed stays closed while
  /// the same failure keeps repeating. This is the pin that would have caught a
  /// dismissal which resets the condition — the banner would flick back on the
  /// very next autosave tick.
  @MainActor
  func testADismissedDataLossBannerStaysDownAcrossAnIdenticalRetry() throws {
    let rig = try makeWindowErrorChromeRig(prefix: "errorchrome-rule2")
    defer { rig.tearDown() }

    let quiet = try XCTUnwrap(rig.editorPaneHeight())
    let message = "Could not write recovery draft: no space left on device"

    rig.appState.reportDataLoss(message)
    rig.settle(0.3)
    XCTAssertLessThan(
      try XCTUnwrap(rig.editorPaneHeight()), quiet, "fixture precondition: the banner is up")

    rig.appState.dismissVisibleError()
    rig.settle(0.3)
    XCTAssertEqual(
      try XCTUnwrap(rig.editorPaneHeight()), quiet, "the dismiss button did not take the line down")

    // The autosave retries into the same full disk.
    rig.appState.reportDataLoss(message)
    rig.settle(0.3)

    XCTAssertEqual(
      try XCTUnwrap(rig.editorPaneHeight()), quiet,
      "an identical retry put the dismissed banner back on screen")
  }

  /// RULE 3 on the live surface: once resolved, the same problem happening
  /// again is news and the window shows it. Rule 2 must not harden into
  /// permanent silence for that message.
  @MainActor
  func testAFreshOccurrenceAfterResolutionMountsTheBannerAgain() throws {
    let rig = try makeWindowErrorChromeRig(prefix: "errorchrome-rule3")
    defer { rig.tearDown() }

    let quiet = try XCTUnwrap(rig.editorPaneHeight())
    let message = "Could not write recovery draft: no space left on device"

    rig.appState.reportDataLoss(message)
    rig.appState.dismissVisibleError()
    rig.appState.resolveError()
    rig.settle(0.3)
    XCTAssertEqual(
      try XCTUnwrap(rig.editorPaneHeight()), quiet, "fixture precondition: the window is quiet")

    rig.appState.reportDataLoss(message)
    rig.settle(0.3)

    XCTAssertLessThan(
      try XCTUnwrap(rig.editorPaneHeight()), quiet,
      "a fresh occurrence after a resolved one never reached the screen")
  }

  // MARK: - The passive surface stays passive

  /// The operator requirement, pinned: the status line may appear and disappear
  /// UNDER a live editing session without taking the caret or dropping a
  /// keystroke. A passive surface that interrupts typing is not passive — and
  /// the banner carries a focusable dismiss button, exactly the kind of thing
  /// SwiftUI can hand first responder to on insertion.
  ///
  /// Nothing in this surface is modal, data loss included, so this contract has
  /// no exception: no error Pensieve can raise may take the caret.
  @MainActor
  func testTheBannerNeitherTakesFocusNorInterruptsTyping() throws {
    let rig = try makeWindowErrorChromeRig(prefix: "errorchrome-focus")
    defer { rig.tearDown() }

    let editor = try XCTUnwrap(rig.textView(), "the rig hosted no editor to hold focus")
    let quiet = try XCTUnwrap(rig.editorPaneHeight())
    XCTAssertTrue(
      rig.window.makeFirstResponder(editor), "the editor would not take first responder")
    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
    editor.insertText(" — Zarząd", replacementRange: editor.selectedRange())
    let typedSoFar = editor.string
    let caretBefore = editor.selectedRange()

    // Mid-sentence, something elsewhere in the app fails.
    rig.appState.lastError = "Could not reach the index: database is locked"
    rig.settle(0.3)

    XCTAssertLessThan(
      try XCTUnwrap(rig.editorPaneHeight()), quiet, "fixture precondition: the banner is up")
    XCTAssertTrue(
      rig.window.firstResponder === editor,
      "the status banner took first responder from the editor mid-sentence")
    XCTAssertEqual(typedSoFar, editor.string, "the banner appearing disturbed the text")
    XCTAssertEqual(caretBefore, editor.selectedRange(), "the banner appearing moved the caret")

    // …and the next keystroke still lands in the document.
    editor.insertText(" uchwalił", replacementRange: editor.selectedRange())
    XCTAssertTrue(
      editor.string.hasSuffix(" — Zarząd uchwalił"),
      "typing did not continue into the document after the banner appeared: \(editor.string)")

    // Its disappearance is the same contract: the layout changes, focus does not.
    rig.appState.resolveError()
    rig.settle(0.3)

    XCTAssertEqual(
      try XCTUnwrap(rig.editorPaneHeight()), quiet, "fixture precondition: the banner is gone")
    XCTAssertTrue(
      rig.window.firstResponder === editor,
      "the status banner took first responder from the editor as it disappeared")
    editor.insertText(" jednogłośnie", replacementRange: editor.selectedRange())
    XCTAssertTrue(
      editor.string.hasSuffix(" uchwalił jednogłośnie"),
      "typing did not survive the banner going away: \(editor.string)")
  }
}
