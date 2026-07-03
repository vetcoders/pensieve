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
}
