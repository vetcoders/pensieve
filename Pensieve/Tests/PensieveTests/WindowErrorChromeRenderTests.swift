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

    rig.appState.clearError()
    rig.settle(0.3)

    XCTAssertEqual(
      try XCTUnwrap(rig.editorPaneHeight()), quiet,
      "the banner kept the editor's room after the error it reported was cleared")
  }

  /// The data-loss class mounts the same standing banner, not only an alert.
  /// The modal is answered and gone; the reminder that the work is not safe has
  /// to outlive it.
  @MainActor
  func testADataLossErrorAlsoMountsTheStandingBanner() throws {
    let rig = try makeWindowErrorChromeRig(prefix: "errorchrome-dataloss")
    defer { rig.tearDown() }

    let quiet = try XCTUnwrap(rig.editorPaneHeight())

    rig.appState.reportDataLoss("Could not write recovery draft: no space left on device")
    rig.settle(0.3)

    XCTAssertLessThan(
      try XCTUnwrap(rig.editorPaneHeight()), quiet,
      "the window raised an alert and left nothing standing behind it")
    XCTAssertNotNil(
      rig.appState.pendingDataLossAlert, "losing the only copy of the text asked the user nothing")
  }

  // MARK: - The passive surface stays passive

  /// The operator requirement, pinned: the status line may appear and disappear
  /// UNDER a live editing session without taking the caret or dropping a
  /// keystroke. A passive surface that interrupts typing is not passive — and
  /// the banner carries a focusable dismiss button, exactly the kind of thing
  /// SwiftUI can hand first responder to on insertion.
  ///
  /// The data-loss alert is the deliberate exception and is not under test
  /// here: it is modal by design, and it is reserved for losing the only copy
  /// of the user's text.
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
    rig.appState.clearError()
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
