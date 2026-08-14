import XCTest

@testable import Pensieve

/// `Settings ▸ Appearance` — the second home for the two appearance axes.
///
/// Operator decision, 14.08.2026. Removing the titlebar's appearance menu left
/// the status-bar chip as the only way to change theme or flavor, and that chip
/// is mounted only in a window that already has an editable buffer
/// (`ContentView` gates `EditorStatusBar` on `documentHasEditableBuffer`). On a
/// freshly launched or restored window both axes were therefore unreachable by
/// mouse, keyboard, menu and Settings alike — while the launcher itself is
/// painted from the skin the user could not change. A Settings pane answers
/// that because ⌘, reaches it from every window, and it doubles as the fallback
/// when the chip is clipped at the minimum window width.
///
/// Deliberately a MIRROR and nothing more: the same two pickers, bound to the
/// same object. Richer appearance UI is explicitly deferred.
///
/// Pinned structurally, for the reason `EditorStatusBarAppearanceTests` records
/// at length: `NSHostingView` publishes no accessibility tree in a test process,
/// and SwiftUI populates a `Picker`'s menu only when a real open lands. A pin
/// that asked the rendered pane what it contains would skip itself into a
/// permanent green. `scripts/ui-smoke.sh` is where the live surface is asserted,
/// keyed on the identifiers pinned below.
@MainActor
final class AppearanceSettingsPaneTests: XCTestCase {

  // MARK: - The pane exists and is selectable

  /// The window can actually be asked for this pane. Without the enum case the
  /// tab could exist and still be unreachable from `showSettings(section:)`.
  func testTheSettingsWindowHasAnAppearanceSection() {
    XCTAssertNotEqual(PensieveSettingsSection.appearance, .general)
    XCTAssertNotEqual(PensieveSettingsSection.appearance, .ai)

    let selection = PensieveSettingsSelection(selectedSection: .appearance)
    XCTAssertEqual(selection.selectedSection, .appearance)
  }

  /// …and the tab view really tags a tab with it, so selecting the section
  /// lands somewhere instead of silently falling back to the first tab.
  func testTheTabViewMountsTheAppearancePane() throws {
    let view = try Self.source(of: "App/PensieveSettingsView.swift")

    XCTAssertTrue(
      view.contains("AppearanceSettingsView(themeManager: themeManager)"),
      "the Appearance tab must host the pane, and hand it the window's manager")
    XCTAssertTrue(
      view.contains(".tag(PensieveSettingsSection.appearance)"),
      "an untagged tab cannot be selected by `showSettings(section: .appearance)`")
  }

  // MARK: - Both axes, and the identifiers the runtime probe uses

  /// The AX contract, spelled out here rather than read back from the pane —
  /// `scripts/ui-smoke.sh` looks these up by string, so a rename that only
  /// travelled through production would turn the live probe into a lookup that
  /// times out on a control that is perfectly fine.
  func testThePanesAccessibilityContractIsStable() {
    XCTAssertEqual(AppearanceSettingsView.paneIdentifier, "pensieve.settings.appearance")
    XCTAssertEqual(
      AppearanceSettingsView.skinPickerIdentifier, "pensieve.settings.appearance.skinPicker")
    XCTAssertEqual(
      AppearanceSettingsView.flavorPickerIdentifier, "pensieve.settings.appearance.flavorPicker")
  }

  /// Both axes are present, and both are BOUND — a pane that showed one picker,
  /// or showed two but wrote a local copy, would leave the reachability hole
  /// exactly where it was.
  func testThePaneOffersBothAxesBoundToTheManager() throws {
    let view = try Self.source(of: "App/PensieveSettingsView.swift")
    let pane = try XCTUnwrap(
      Self.declarationBody(named: "struct AppearanceSettingsView: View {", in: view),
      "the Appearance pane has moved; re-point this pin before trusting it")

    XCTAssertTrue(
      pane.contains("selection: $themeManager.skin"),
      "the theme axis must write through the manager, not a copy of it")
    XCTAssertTrue(
      pane.contains("selection: $themeManager.current"),
      "the flavor axis must write through the manager, not a copy of it")
    XCTAssertTrue(
      pane.contains("PensieveTheme.allCases") && pane.contains("ThemeManager.Theme.allCases"),
      "both pickers offer every case, or an axis loses values the chip still has")
  }

  // MARK: - One source of truth

  /// The chip and the pane must write the SAME object.
  ///
  /// This is the pin that matters most and the one a reviewer cannot see by
  /// reading either surface alone. The Settings window is an ordinary `NSWindow`
  /// owned by a singleton controller, outside the SwiftUI scene that carries the
  /// manager as an `@EnvironmentObject`. The obvious way to give the pane a
  /// manager is to construct one — and two managers would each persist to the
  /// same `UserDefaults` keys while holding their own `@Published` copies, so
  /// the chip and Settings would disagree until a relaunch.
  func testTheChipAndTheSettingsPaneShareOneManager() throws {
    let app = try Self.source(of: "App/PensieveApp.swift")
    let controller = try Self.source(of: "App/PensieveSettingsWindowController.swift")

    XCTAssertTrue(
      app.contains("ThemeManager.shared"),
      "the scene must adopt the shared manager, or Settings edits a different object")
    XCTAssertFalse(
      app.contains("let themeManager = ThemeManager()"),
      "a freshly constructed manager here forks the appearance state in two")
    XCTAssertTrue(
      controller.contains("themeManager: ThemeManager = .shared"),
      "the Settings window defaults to the shared manager for the same reason")
  }

  // MARK: - Source access

  private static func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private static func source(of relativePath: String) throws -> String {
    try String(
      contentsOf: packageRoot().appendingPathComponent("Sources/Pensieve/\(relativePath)"),
      encoding: .utf8)
  }

  /// The body of a declaration, brace-matched from its opening line. Same shape
  /// as `EmptyStateCompositionTests` uses, so a pin cannot accidentally match
  /// text belonging to a neighbouring type.
  private static func declarationBody(named opening: String, in source: String) -> String? {
    guard let start = source.range(of: opening) else { return nil }
    var depth = 0
    var body = ""
    for character in source[start.lowerBound...] {
      body.append(character)
      if character == "{" {
        depth += 1
      } else if character == "}" {
        depth -= 1
        if depth == 0 { return body }
      }
    }
    return nil
  }
}
