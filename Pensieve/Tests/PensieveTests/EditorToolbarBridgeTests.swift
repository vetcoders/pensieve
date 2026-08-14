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
    XCTAssertEqual(
      picker.accessibilityIdentifier(), EditorToolbelt.modePickerIdentifier,
      "the toolbar recipe must stamp the bridged control with its AppKit identity")
    XCTAssertEqual(picker.segmentCount, EditorMode.allCases.count)
    for segment in 0..<picker.segmentCount {
      XCTAssertTrue(
        picker.isEnabled(forSegment: segment),
        "mode segment \(segment) came back disabled — the picker is nested in a ControlGroup again")
    }
  }

  /// macOS 27 changed the ambient toolbar control size. The declaration pins
  /// regular explicitly so a future SDK default cannot silently grow the
  /// toolbar past its width budget again.
  @MainActor
  func testEveryBridgedToolbarControlUsesRegularControlSize() throws {
    let rig = try makeRig()
    defer { rig.tearDown() }

    let controls = bridgedControls(in: rig)
    XCTAssertFalse(controls.isEmpty, "premise: the bridged toolbar must expose controls")
    for control in controls {
      XCTAssertEqual(
        control.controlSize, .regular,
        "\(type(of: control)) inherited the OS toolbar default instead of the pinned regular size")
    }
  }

  /// THE PIN THAT CAN ACTUALLY FAIL HERE. `testEveryBridged…` above reads the
  /// RESOLVED control size, and on a runner whose ambient toolbar default is
  /// already regular — every macOS 26 machine, including CI's
  /// `macos-26-arm64` — deleting every `.controlSize(.regular)` from
  /// `EditorToolbelt` leaves that assertion perfectly green. The regression it
  /// was written for is therefore invisible to the only OS the gate runs on,
  /// and would be caught by macOS 27 alone.
  ///
  /// So the ambient default is moved out from under the declaration: the rig
  /// hosts the same toolbar under an inherited `.mini`, which is what a future
  /// SDK bump does in spirit. A control that comes back regular is stating its
  /// size; a control that comes back mini inherited it. That distinction is
  /// OS-independent, so this pin bites on macOS 26 and macOS 27 alike.
  @MainActor
  func testBridgedToolbarControlsDeclareRegularRatherThanInheritingTheAmbientSize() throws {
    let rig = try makeRig(ambientControlSize: .mini)
    defer { rig.tearDown() }

    let controls = bridgedControls(in: rig)
    XCTAssertFalse(controls.isEmpty, "premise: the bridged toolbar must expose controls")
    // The premise, asserted rather than assumed: if the bridge dropped the
    // inherited size on the floor, nothing below would be measuring anything.
    XCTAssertTrue(
      controls.contains { $0.controlSize == .regular },
      "premise: an ambient .mini reached this toolbar and NOTHING came back regular — the rig is "
        + "not exercising the inherited-size path any more")
    for control in controls {
      XCTAssertEqual(
        control.controlSize, .regular,
        "\(type(of: control)) came back at \(control.controlSize.rawValue) under an ambient "
          + ".mini: it is inheriting the surrounding control size instead of declaring its own, "
          + "so the toolbar's width is at the mercy of whatever default the next SDK ships")
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

  /// SwiftUI's late toolbar derivation can clear the AppKit-side tooltip after
  /// the sink authored it. The same window-update repair that restores menu
  /// forms must restore this accessibility contract without another SwiftUI
  /// body pass.
  @MainActor
  func testAModeTooltipClearedBetweenPassesIsRepairedOnAWindowUpdate() throws {
    let rig = try makeRig()
    defer { rig.tearDown() }

    let picker = try XCTUnwrap(rig.modePickerControl())
    let segment = picker.segmentCount - 1
    picker.setToolTip(nil, forSegment: segment)

    for _ in 0..<40 {
      if picker.toolTip(forSegment: segment) == EditorMode.allCases[segment].label { break }
      rig.window.update()
      rig.settle(0.02)
    }

    XCTAssertEqual(
      picker.toolTip(forSegment: segment), EditorMode.allCases[segment].label,
      "a late toolbar derivation cleared the mode tooltip and the window-update repair ignored it")
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

  /// THE EDITOR-LESS PIN. A window with no editor and no preview anywhere in its
  /// tree still has toggle chips, and they still have to come from the skin.
  ///
  /// This is the launcher / empty-workspace window, and it used to receive NO
  /// AppKit chrome pass at all: `assertWindowChrome` had exactly two production
  /// callers, `EditorView`'s representable and `PreviewWebView`, so a window
  /// hosting neither kept AppKit's `controlAccentColor` fill on every chip under
  /// every skin.
  ///
  /// Typewriter, not an adaptive skin, because an adaptive skin's `chromeAccent`
  /// IS `controlAccentColor` — under `.default` an unpainted chip and a correctly
  /// painted one are the same pixels, and this pin would pass on the bug.
  @MainActor
  func testAnEditorLessWindowStillGetsTheSkinsChipTint() throws {
    let rig = try makeRig(hostsEditor: false)
    defer { rig.tearDown() }

    XCTAssertNil(
      rig.textView(),
      "premise: this rig must host no editor — otherwise the editor's own chrome pass "
        + "is what paints the chips and the pin proves nothing")

    rig.themeManager.skin = .typewriter
    let chips = try awaitChipGroups(rig)
    for group in chips {
      XCTAssertEqual(
        group.selectedSegmentBezelColor?.usingColorSpace(.sRGB),
        WindowChromeRecipe.toolbarChipBezelColor(for: .typewriter).usingColorSpace(.sRGB),
        "a window with no editor and no preview never received the chrome pass, so its "
          + "chips stayed on AppKit's system accent")
    }
  }

  /// THE SKIN-SWITCH PIN, on a window that DOES host an editor.
  ///
  /// The editor asserts the chrome on every update pass, and that was still not
  /// enough: switching skins rebuilds the toolbar (the view hosting it observes
  /// the theme manager), the re-bridge lands AFTER the editor's pass, and it
  /// takes `selectedSegmentBezelColor` back to `nil`. Measured on this rig before
  /// the sink existed: the bezel reads `nil` at +50 ms, +350 ms and +1.35 s after
  /// the switch, and only an UNRELATED later SwiftUI pass ever repaints it. So
  /// the chips were correct right up until the operator picked a skin — the first
  /// moment a non-system chip colour is visible at all.
  @MainActor
  func testASkinSwitchLeavesTheChipsPaintedWithoutAFurtherEdit() throws {
    let rig = try makeRig()
    defer { rig.tearDown() }

    rig.themeManager.skin = .typewriter
    let chips = try awaitChipGroups(rig)
    for group in chips {
      XCTAssertEqual(
        group.selectedSegmentBezelColor?.usingColorSpace(.sRGB),
        WindowChromeRecipe.toolbarChipBezelColor(for: .typewriter).usingColorSpace(.sRGB),
        "the skin switch's own toolbar re-bridge cleared the chip tint and nothing "
          + "re-asserted it — waiting never restores it, only the next unrelated edit does")
    }
  }

  /// The REPAIR TRIGGER, pinned on its own.
  ///
  /// The two pins above prove the outcome; this one proves which mechanism
  /// delivers it. A chip cleared BETWEEN SwiftUI passes — which is exactly what a
  /// toolbar re-bridge does — must come back on a window update cycle, with no
  /// SwiftUI pass anywhere in between. Without the window observation the sink's
  /// only triggers are a body re-evaluation and the runloop turn after it, and a
  /// clobber that lands later than that would stay on screen until the operator
  /// happened to type. Same shape, same trigger and same measured reason as
  /// `ToolbarOverflowController.repairClobberedBridge`.
  @MainActor
  func testAChipClearedBetweenPassesIsRepairedOnAWindowUpdate() throws {
    let rig = try makeRig(hostsEditor: false)
    defer { rig.tearDown() }

    rig.themeManager.skin = .typewriter
    let chips = try awaitChipGroups(rig)

    for group in chips { group.selectedSegmentBezelColor = nil }
    // No SwiftUI pass: only the update cycle the window posts on its own.
    for _ in 0..<40 {
      if chips.allSatisfy({ $0.selectedSegmentBezelColor != nil }) { break }
      rig.window.update()
      rig.settle(0.02)
    }

    for group in chips {
      XCTAssertEqual(
        group.selectedSegmentBezelColor?.usingColorSpace(.sRGB),
        WindowChromeRecipe.toolbarChipBezelColor(for: .typewriter).usingColorSpace(.sRGB),
        "a chip cleared between SwiftUI passes was never repaired — the sink is not "
          + "watching the window, so a re-bridge outlives the next runloop turn")
    }
  }

  /// Settles the toolbar and hands back the chip groups, WITHOUT the test
  /// authoring a chrome pass of its own: only the window update cycles the app
  /// already runs are driven, so what converges here is production's own repair.
  ///
  /// It gives up on a bound rather than timing out into a green — a chip that
  /// never converges fails the pin.
  @MainActor
  private func awaitChipGroups(_ rig: ToolbarBridgeRig) throws -> [NSSegmentedControl] {
    func groups() -> [NSSegmentedControl] {
      WindowChromeRecipe.toolbarSegmentedControls(in: rig.window)
        .filter(WindowChromeRecipe.isToggleChipGroup)
    }
    let wanted = WindowChromeRecipe.toolbarChipBezelColor(for: rig.themeManager.skin)
    for _ in 0..<40 {
      let found = groups()
      if !found.isEmpty,
        found.allSatisfy({ WindowChromeRecipe.colorsMatch($0.selectedSegmentBezelColor, wanted) })
      {
        break
      }
      rig.window.update()
      rig.settle(0.02)
    }
    let found = groups()
    XCTAssertFalse(
      found.isEmpty, "premise: this toolbar must carry at least one paintable chip group")
    return found
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
  private func makeRig(
    hostsEditor: Bool = true, ambientControlSize: ControlSize? = nil
  ) throws -> ToolbarBridgeRig {
    try makeToolbarRig(
      prefix: "EditorToolbarBridgeTests", hostsEditor: hostsEditor,
      ambientControlSize: ambientControlSize)
  }

  /// Every `NSControl` the bridged toolbar put on screen, groups included.
  @MainActor
  private func bridgedControls(in rig: ToolbarBridgeRig) -> [NSControl] {
    var controls: [NSControl] = []
    func collect(from view: NSView) {
      if let control = view as? NSControl { controls.append(control) }
      for subview in view.subviews { collect(from: subview) }
    }
    for item in rig.toolbar?.items ?? [] {
      if let view = item.view { collect(from: view) }
      if let group = item as? NSToolbarItemGroup {
        for subitem in group.subitems {
          if let view = subitem.view { collect(from: view) }
        }
      }
    }
    return controls
  }
}
