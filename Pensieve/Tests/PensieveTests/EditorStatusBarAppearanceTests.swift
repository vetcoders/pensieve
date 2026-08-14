import AppKit
import XCTest

@testable import Pensieve

/// The status bar's appearance chip is the PRIMARY home for the two appearance
/// axes: the titlebar's diamond was removed when the toolbar ran out of width,
/// and no menu-bar command carries flavor or theme. Since 14.08.2026 it is not
/// the only home — `Settings ▸ Appearance` mirrors both pickers for the windows
/// the chip does not exist in, and `AppearanceSettingsPaneTests` holds that
/// half. So the chip is pinned as a surface, not as a declaration.
///
/// What a headless `swift test` can and cannot see here was measured, and the
/// split is deliberate:
///
///   * The chip's `Menu` bridges to a real `NSPopUpButton` inside the hosting
///     view, so its presence, its enablement and its live label ARE readable
///     here — and the label is the one thing that carries both axes at once.
///   * SwiftUI populates that popup's `NSMenu` only when a real open lands
///     (measured: `menuNeedsUpdate` + `NSMenu.update()` leave it empty), and
///     `NSHostingView` publishes no accessibility tree in a test process at all
///     (see `WindowErrorChromeRig`). So "the menu contains both pickers" is not
///     provable in-process; `scripts/ui-smoke.sh` opens the chip on the live
///     app and asserts exactly that, keyed on the identifiers pinned below.
@MainActor
final class EditorStatusBarAppearanceTests: XCTestCase {
  /// The identifiers `scripts/ui-smoke.sh` looks the chip up by. A rename here
  /// without the same rename there turns the runtime probe into a lookup that
  /// times out on a control that is perfectly fine.
  func testTheChipsAccessibilityContractIsTheOneTheRuntimeProbeUses() {
    XCTAssertEqual(EditorStatusBar.appearanceIdentifier, "pensieve.statusbar.appearance")
    XCTAssertEqual(EditorStatusBar.flavorPickerIdentifier, "pensieve.statusbar.flavorPicker")
    XCTAssertEqual(EditorStatusBar.skinPickerIdentifier, "pensieve.statusbar.skinPicker")
  }

  /// The chip exists as a live control in the window the operator gets, and its
  /// label answers to BOTH axes — which is what "the chip kept both pickers"
  /// reduces to from outside the menu: a chip bound to one axis only could not
  /// follow the other.
  func testTheChipIsLiveAndItsLabelFollowsBothAppearanceAxes() throws {
    let rig = try makeWindowErrorChromeRig(prefix: "EditorStatusBarAppearanceTests")
    defer { rig.tearDown() }

    let chip = try XCTUnwrap(
      Self.appearanceChip(in: rig), "the status bar laid out no appearance chip")
    XCTAssertTrue(chip.isEnabled, "the only appearance control in the app came back disabled")

    let skin = try XCTUnwrap(PensieveTheme.allCases.last { $0 != rig.themeManager.skin })
    rig.themeManager.skin = skin
    XCTAssertTrue(
      Self.awaitChipLabel(in: rig, skin: skin, flavor: rig.themeManager.current),
      "the chip did not follow a theme change, so the theme axis is not bound to it")

    let flavor = try XCTUnwrap(
      ThemeManager.Theme.allCases.last { $0 != rig.themeManager.current })
    rig.themeManager.current = flavor
    XCTAssertTrue(
      Self.awaitChipLabel(in: rig, skin: skin, flavor: flavor),
      "the chip did not follow a markdown-flavor change, so the flavor axis has no home left: "
        + "the toolbar's appearance menu is gone and no menu-bar command carries it")
  }

  // MARK: - Helpers

  /// The label contract, SPELLED OUT here rather than read back from the view.
  ///
  /// This is the difference between a pin and a tautology, and it was measured:
  /// an earlier version asked production for the expected string, and deleting
  /// the flavor axis from both the chip's label AND its menu left that version
  /// perfectly green — the expectation moved with the mutation. Stating the
  /// format in the test is what makes a dropped axis a failure.
  private static func chipLabel(skin: PensieveTheme, flavor: ThemeManager.Theme) -> String {
    "\(skin.displayName) / \(flavor.displayName)"
  }

  /// The chip, found by that label rather than by accessibility: the identifier
  /// it declares is real in the shipped app but invisible to a headless host,
  /// so a lookup keyed on it would skip itself into a permanent green.
  private static func appearanceChip(in rig: WindowErrorChromeRig) -> NSPopUpButton? {
    let wanted = chipLabel(skin: rig.themeManager.skin, flavor: rig.themeManager.current)
    return popUpButtons(in: rig).first { $0.title == wanted }
  }

  private static func awaitChipLabel(
    in rig: WindowErrorChromeRig, skin: PensieveTheme, flavor: ThemeManager.Theme
  ) -> Bool {
    let wanted = chipLabel(skin: skin, flavor: flavor)
    for _ in 0..<20 {
      if popUpButtons(in: rig).contains(where: { $0.title == wanted }) { return true }
      rig.settle(0.1)
    }
    return popUpButtons(in: rig).contains { $0.title == wanted }
  }

  private static func popUpButtons(in rig: WindowErrorChromeRig) -> [NSPopUpButton] {
    guard let content = rig.window.contentView else { return [] }
    var found: [NSPopUpButton] = []
    func walk(_ view: NSView) {
      if let button = view as? NSPopUpButton { found.append(button) }
      for subview in view.subviews { walk(subview) }
    }
    walk(content)
    return found
  }
}
