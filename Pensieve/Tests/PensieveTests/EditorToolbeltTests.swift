import AppKit
import XCTest

@testable import Pensieve

/// Structural smoke for the toolbelt declutter: the appearance controls are
/// preview-scoped, and the popover pickers keep auto-populating from the
/// `CaseIterable` theme axes.
final class EditorToolbeltTests: XCTestCase {
  // MARK: - Appearance visibility gate

  func testAppearanceControlsHiddenInPureSourceMode() {
    XCTAssertFalse(EditorToolbelt.showsAppearanceControls(for: .source))
  }

  func testAppearanceControlsHiddenInFocusMode() {
    // Focus is a source-editing surface — no preview pane, no appearance item.
    XCTAssertFalse(EditorToolbelt.showsAppearanceControls(for: .focus))
  }

  func testAppearanceControlsVisibleWhenPreviewPaneExists() {
    XCTAssertTrue(EditorToolbelt.showsAppearanceControls(for: .preview))
    XCTAssertTrue(EditorToolbelt.showsAppearanceControls(for: .split))
  }

  func testEveryEditorModeHasAnExplicitAppearanceDecision() {
    // Adding a new EditorMode must consciously land on one side of the gate;
    // this pins today's full mapping so a new case shows up as a test edit.
    let visible = EditorMode.allCases.filter(EditorToolbelt.showsAppearanceControls(for:))
    XCTAssertEqual(Set(visible), Set([.preview, .split]))
  }

  // MARK: - Popover pickers stay CaseIterable-driven

  func testFlavorAxisAutoPopulates() {
    XCTAssertFalse(ThemeManager.Theme.allCases.isEmpty)
    XCTAssertTrue(ThemeManager.Theme.allCases.contains(.gfm))
  }

  func testSkinAxisAutoPopulates() {
    // The popover renders one row per case — every skin needs a display name
    // and a symbol, and the ids the picker tags on must stay unique.
    let skins = ThemeManager.PreviewTheme.allCases
    XCTAssertFalse(skins.isEmpty)
    XCTAssertEqual(Set(skins.map(\.id)).count, skins.count)
    for skin in skins {
      XCTAssertFalse(skin.displayName.isEmpty)
      XCTAssertFalse(skin.systemImage.isEmpty)
    }
  }

  // MARK: - Aa Edit menu ↔ floating bar shared contract

  func testEditActionListIsTheSharedAllCasesOrder() {
    // The Aa toolbar menu, the floating selection bar, and the editor context
    // menu ALL iterate `MarkdownFormat.allCases` — this pins the shared order
    // so a reorder (or a fork into a second array) shows up as a test edit.
    XCTAssertEqual(
      MarkdownFormat.allCases,
      [.bold, .strike, .italic, .quote, .code, .link, .bulletedList, .numberedList])
  }

  func testEveryEditActionRendersInMenus() {
    // Menu rows need a title and a symbol; empty metadata would render a
    // blank row in the Aa menu without failing the build.
    for format in MarkdownFormat.allCases {
      XCTAssertFalse(format.label.isEmpty)
      XCTAssertFalse(format.systemImageName.isEmpty)
    }
  }
}

/// Regression at the floating-format-bar positioning seam (operator evidence
/// 2026-07-05 18:47: the bar ghosted UNDER the translucent titlebar). The
/// `allowed` rect models `visibleRect ∩ contentLayoutRect` in the flipped
/// text-view space: content spans y 0…600 but the top 52pt strip (y < 52)
/// lies under the chrome, so allowed = (0, 52, 800, 548).
final class EditorToolbeltFloatingClampTests: XCTestCase {
  private let allowed = NSRect(x: 0, y: 52, width: 800, height: 548)
  private let barSize = NSSize(width: 200, height: 28)

  func testBarPrefersAboveSelectionWhenRoomExists() {
    let selection = NSRect(x: 100, y: 300, width: 120, height: 17)
    let origin = MarkdownTextView.accessoryOrigin(
      for: selection, size: barSize, allowed: allowed, isFlipped: true)
    // Flipped space: "above" the selection = smaller y; 300 - 28 - 6 = 266.
    XCTAssertEqual(origin, NSPoint(x: 100, y: 266))
  }

  func testBarDropsBelowSelectionWhenAnchorTouchesChromeEdge() {
    // Selection first line just under the toolbar edge — no room above
    // inside the allowed region, so the bar flips below: 77 + 6 = 83.
    let selection = NSRect(x: 100, y: 60, width: 120, height: 17)
    let origin = MarkdownTextView.accessoryOrigin(
      for: selection, size: barSize, allowed: allowed, isFlipped: true)
    XCTAssertEqual(origin, NSPoint(x: 100, y: 83))
  }

  func testBarPinsAtChromeEdgeWhenSelectionScrollsUnderTitlebar() {
    // The ghosting bug: the anchor scrolled under the chrome (y < allowed.minY).
    // The bar must pin at the chrome edge, never follow through it.
    let origin = MarkdownTextView.clampedAccessoryOrigin(
      NSPoint(x: 100, y: 10), size: barSize, allowed: allowed)
    XCTAssertEqual(origin.y, allowed.minY)
    XCTAssertEqual(origin.x, 100)
  }

  func testBarStaysInsideTrailingEdge() {
    let origin = MarkdownTextView.clampedAccessoryOrigin(
      NSPoint(x: 790, y: 300), size: barSize, allowed: allowed)
    // 800 - 200 - 4 margin = 596.
    XCTAssertEqual(origin, NSPoint(x: 596, y: 300))
  }

  func testBarStaysInsideBottomEdge() {
    let origin = MarkdownTextView.clampedAccessoryOrigin(
      NSPoint(x: 100, y: 590), size: barSize, allowed: allowed)
    // allowed.maxY(600) - height(28) = 572.
    XCTAssertEqual(origin, NSPoint(x: 100, y: 572))
  }

  func testDegenerateAllowedRectStillReturnsFiniteOrigin() {
    // A collapsed window must not send the bar to ±∞ or crash the clamp.
    let tiny = NSRect(x: 0, y: 52, width: 120, height: 20)
    let origin = MarkdownTextView.clampedAccessoryOrigin(
      NSPoint(x: 300, y: 300), size: barSize, allowed: tiny)
    XCTAssertEqual(origin, NSPoint(x: 4, y: 52))
  }
}
