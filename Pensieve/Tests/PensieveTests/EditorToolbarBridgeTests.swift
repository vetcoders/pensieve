import AppKit
import SwiftUI
import XCTest

@testable import Pensieve

/// The toolbelt's SwiftUI declaration is only half the truth: what the operator
/// clicks is the AppKit control the bridge builds out of it, and that bridge
/// silently degrades whole controls when a family is declared wrong (a `Picker`
/// nested in a `ControlGroup` becomes ONE DISABLED segment; a `Button` sharing a
/// `ControlGroup` with a `Toggle` becomes a sticky chip). None of that is
/// visible from the SwiftUI side, so these tests host the REAL `EditorToolbelt`
/// in a window (`ToolbarBridgeRig`), read the bridged `NSToolbar`, and drive it
/// with synthesized mouse events — the only way a regression here fails a test
/// instead of an operator.
final class EditorToolbarBridgeTests: XCTestCase {
  // MARK: - Mode picker

  @MainActor
  func testModePickerBridgesToALiveSegmentPerEditorMode() throws {
    let rig = try makeRig()
    defer { rig.tearDown() }

    let picker = try XCTUnwrap(
      rig.modePickerControl(),
      "the mode picker must bridge to a segmented control with one segment per mode")
    XCTAssertEqual(picker.segmentCount, EditorMode.allCases.count)
    for segment in 0..<picker.segmentCount {
      XCTAssertTrue(
        picker.isEnabled(forSegment: segment),
        "mode segment \(segment) came back disabled — the picker is nested in a ControlGroup again")
    }
  }

  @MainActor
  func testClickingAModeSegmentSwitchesTheEditorMode() throws {
    let rig = try makeRig()
    defer { rig.tearDown() }

    let picker = try XCTUnwrap(rig.modePickerControl())
    let before = rig.appState.mode
    // Aim at the last segment; the assertion reads back which segment AppKit
    // actually landed on, so it never depends on exact segment geometry.
    rig.click(picker, segment: picker.segmentCount - 1)
    rig.settle()

    let landed = picker.selectedSegment
    XCTAssertGreaterThanOrEqual(landed, 0, "the click did not select any segment")
    XCTAssertNotEqual(rig.appState.mode, before, "clicking the mode picker changed nothing")
    XCTAssertEqual(
      rig.appState.mode, EditorMode.allCases[landed],
      "the selected segment and the editor mode disagree")
  }

  /// Icon segments cost the operator nothing only while the name is still
  /// reachable without a click. Dropping the titles to buy toolbar width (see
  /// `EditorToolbarWidthBudgetTests`) is allowed to make the mode anonymous ONLY
  /// if the tooltip still names it.
  @MainActor
  func testEveryModeSegmentNamesItselfInATooltip() throws {
    let rig = try makeRig()
    defer { rig.tearDown() }

    let picker = try XCTUnwrap(rig.modePickerControl())
    let tips = (0..<picker.segmentCount).map { picker.toolTip(forSegment: $0) ?? "" }
    XCTAssertEqual(
      tips, EditorMode.allCases.map(\.label),
      "an icon-only mode segment with no tooltip leaves the operator guessing which layout it is")
  }

  // MARK: - Format actions

  @MainActor
  func testFormatButtonsStayMomentaryInsteadOfStickyChips() throws {
    let rig = try makeRig()
    defer { rig.tearDown() }

    let formats = try XCTUnwrap(rig.formatControl(), "the format row must reach the toolbar")
    XCTAssertEqual(
      formats.trackingMode, .momentary,
      "format actions must not share a ControlGroup with a Toggle — \(formats.trackingMode) "
        + "tracking makes every button a sticky on/off chip")
    XCTAssertEqual(formats.segmentCount, MarkdownFormat.allCases.count)
  }

  @MainActor
  func testToolbarBoldEditsTheDocument() throws {
    let rig = try makeRig()
    defer { rig.tearDown() }

    let textView = try XCTUnwrap(rig.textView())
    rig.window.makeFirstResponder(textView)
    textView.setSelectedRange(NSRange(location: 6, length: 5))

    let formats = try XCTUnwrap(rig.formatControl())
    let bold = try XCTUnwrap(
      (0..<formats.segmentCount).first {
        formats.toolTip(forSegment: $0) == MarkdownFormat.bold.label
      })
    rig.click(formats, segment: bold)
    rig.settle()

    XCTAssertEqual(
      textView.string, "hello **brave** new world",
      "the main toolbar's Bold must wrap the selection, like the floating bar does")
  }

  // MARK: - Skin chips

  @MainActor
  func testToggleFamiliesStayPaintableChipGroups() throws {
    let rig = try makeRig()
    defer { rig.tearDown() }

    let chipGroups = WindowChromeRecipe.toolbarSegmentedControls(in: rig.window)
      .filter(WindowChromeRecipe.isToggleChipGroup)
    XCTAssertFalse(
      chipGroups.isEmpty,
      "splitting the families must not cost the toggles their segmented chips — "
        + "assertToolbarChipTint has nothing left to paint from the skin")
    for group in chipGroups {
      for segment in 0..<group.segmentCount {
        XCTAssertNotEqual(
          group.toolTip(forSegment: segment), MarkdownFormat.bold.label,
          "a momentary format action landed in a paintable chip group")
      }
    }
  }

  // MARK: - Overflow menu

  @MainActor
  func testClippedFamiliesStillOfferOverflowMenuEntries() throws {
    let rig = try makeRig()
    defer { rig.tearDown() }

    let entries = rig.itemGroups.flatMap { group in
      group.subitems.compactMap { $0.menuFormRepresentation?.title }.filter { !$0.isEmpty }
    }
    // A family whose whole content sits in a ControlGroup contributes nothing
    // here, which is why the "»" menu used to open on an empty list.
    XCTAssertFalse(
      entries.isEmpty,
      "the clipped-items menu has no named entry to show — every family is ControlGroup-wrapped")
    XCTAssertTrue(
      entries.contains("Mode"),
      "the mode picker must survive a narrow window through the overflow menu, got \(entries)")
  }

  // MARK: - Rig

  @MainActor
  private func makeRig() throws -> ToolbarBridgeRig {
    try makeToolbarRig(prefix: "EditorToolbarBridgeTests")
  }
}
