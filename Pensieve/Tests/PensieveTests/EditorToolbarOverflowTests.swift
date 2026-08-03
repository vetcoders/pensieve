import AppKit
import XCTest

@testable import Pensieve

/// What the operator can still reach once the window is too narrow.
///
/// macOS assembles the clipped-items ("»") menu from the `menuFormRepresentation`
/// of each clipped `NSToolbarItem` — the GROUP's own, never its subitems'
/// (measured against the live bridge). Two consequences the operator met at
/// 1450pt, and this suite exists to keep fixed:
///
///   * A toggle family is bridged into one `NSSegmentedControl` with no menu
///     form at all, so scroll sync, auto reload, dictation and AI autocomplete
///     simply ceased to exist once their families clipped.
///   * Where exactly one subitem DID carry a form, SwiftUI wrapped it in a
///     submenu of the same name, so "Reload Preview" and "Rewrite with AI" each
///     showed up twice — once as a button, once as a chevroned parent of itself.
///
/// `ToolbarOverflowRecipe` authors those group forms instead. These tests read
/// the same public property AppKit reads, and drive the authored entries the
/// same way a click does.
final class EditorToolbarOverflowTests: XCTestCase {
  // MARK: - Shape

  @MainActor
  func testEveryControlGroupFamilyGetsAnAuthoredOverflowEntry() throws {
    let rig = try makeToolbarRig(prefix: "EditorToolbarOverflowTests")
    defer { rig.tearDown() }

    // Production's own triggers only — this never runs the pass, so the claim
    // stays "the app authors these without a test asking".
    XCTAssertTrue(rig.awaitOverflowConvergence(), rig.overflowDiagnostics)

    let families = rig.toolbelt.overflowFamilies
    XCTAssertEqual(
      rig.itemGroups.count, families.count,
      "the recipe maps families onto toolbar groups by declaration order; the two disagree, "
        + "so the pass fails closed and writes nothing")

    for (group, family) in zip(rig.itemGroups, families) where !family.commands.isEmpty {
      let form = try XCTUnwrap(
        group.menuFormRepresentation,
        "family \(family.identifier) has no overflow entry — it vanishes when clipped")
      XCTAssertEqual(
        form.identifier, ToolbarOverflowRecipe.formIdentifier(for: family.identifier),
        "family \(family.identifier) is still carrying SwiftUI's derived form, not the authored "
          + "one — the overflow sink never ran")
      XCTAssertEqual(form.title, family.title)
      XCTAssertEqual(
        form.submenu?.items.map(\.title), family.commands.map(\.title),
        "the authored overflow menu for \(family.identifier) does not list its controls")
    }
  }

  /// The reported bug, pinned: the toggle chips must be nameable in the menu.
  @MainActor
  func testClippedToggleChipsAreReachableFromTheOverflowMenu() throws {
    let rig = try makeToolbarRig(prefix: "EditorToolbarOverflowTests", width: 900)
    defer { rig.tearDown() }

    XCTAssertLessThan(
      rig.visibleItemCount, rig.toolbar?.items.count ?? 0,
      "a 900pt window has to clip something, or this test is not testing the overflow at all")

    let titles = Self.overflowTitles(in: rig)
    for wanted in ["Auto Reload Preview", "Scroll Sync", "Dictation", "AI Autocomplete"] {
      XCTAssertTrue(
        titles.contains(wanted),
        "'\(wanted)' is a toggle chip inside a ControlGroup: once its family clips there is no "
          + "control left to click, and it is not in the » menu either. Got \(titles)")
    }
  }

  /// The second half of the report: each action shows up in the overflow menu
  /// EXACTLY once. A single-entry family wrapped in a submenu of its own name
  /// is what rendered "Reload Preview" and "Rewrite with AI" twice.
  @MainActor
  func testNoActionAppearsTwiceInTheOverflowMenu() throws {
    let rig = try makeToolbarRig(prefix: "EditorToolbarOverflowTests", width: 900)
    defer { rig.tearDown() }

    let titles = Self.overflowTitles(in: rig)
    var seen: [String: Int] = [:]
    for title in titles { seen[title, default: 0] += 1 }
    let duplicates = seen.filter { $0.value > 1 }.keys.sorted()
    XCTAssertTrue(
      duplicates.isEmpty,
      "the » menu lists \(duplicates) more than once — a family is being described both by its "
        + "own entry and by a nested copy of itself")

    for wanted in ["Reload Preview", "Rewrite with AI"] {
      XCTAssertEqual(
        seen[wanted], 1,
        "'\(wanted)' must appear exactly once in the » menu, got \(seen[wanted] ?? 0)")
    }
  }

  // MARK: - Liveness

  @MainActor
  func testOverflowTogglesReflectAndChangeTheSameStateAsTheChips() throws {
    let rig = try makeToolbarRig(prefix: "EditorToolbarOverflowTests")
    defer { rig.tearDown() }

    let item = try XCTUnwrap(
      Self.authoredItem(named: "Scroll Sync", in: rig), "no authored Scroll Sync entry")
    let before = rig.appState.scrollSyncEnabled

    // What AppKit does right before drawing the menu: the check mark and the
    // enablement are read from the model, not frozen at build time.
    let validator = try XCTUnwrap(item.target as? ToolbarOverflowController)
    _ = validator.validateMenuItem(item)
    XCTAssertEqual(
      item.state, before ? .on : .off,
      "the menu entry shows a different on/off state than the chip it stands in for")

    Self.fire(item)
    rig.settle(0.1)
    XCTAssertNotEqual(
      rig.appState.scrollSyncEnabled, before,
      "firing the » menu's Scroll Sync entry did nothing — the entry is decoration")

    _ = validator.validateMenuItem(item)
    XCTAssertEqual(
      item.state, rig.appState.scrollSyncEnabled ? .on : .off,
      "the menu entry did not follow the state it just changed")
  }

  @MainActor
  func testOverflowFormatActionEditsTheDocumentLikeTheChip() throws {
    let rig = try makeToolbarRig(prefix: "EditorToolbarOverflowTests")
    defer { rig.tearDown() }

    let textView = try XCTUnwrap(rig.textView())
    rig.window.makeFirstResponder(textView)
    textView.setSelectedRange(NSRange(location: 6, length: 5))

    let item = try XCTUnwrap(
      Self.authoredItem(named: MarkdownFormat.bold.label, in: rig), "no authored Bold entry")
    Self.fire(item)
    rig.settle()

    XCTAssertEqual(
      textView.string, "hello **brave** new world",
      "the » menu's Bold must land the same edit the toolbar's Bold does")
  }

  @MainActor
  func testOverflowRewriteEntryCarriesItsIntentsAndRaisesTheCommand() throws {
    let rig = try makeToolbarRig(prefix: "EditorToolbarOverflowTests")
    defer { rig.tearDown() }

    let rewrite = try XCTUnwrap(Self.authoredItem(named: "Rewrite with AI", in: rig))
    XCTAssertEqual(
      rewrite.submenu?.items.map(\.title), RewriteIntent.allCases.map(\.label),
      "the rewrite entry must still offer every intent when the assistants family is clipped")

    let intent = try XCTUnwrap(rewrite.submenu?.items.first)
    XCTAssertNil(rig.appState.pendingAIRewriteCommand)
    Self.fire(intent)
    rig.settle(0.1)
    XCTAssertNotNil(
      rig.appState.pendingAIRewriteCommand,
      "the » menu's rewrite intent did not raise a rewrite command")
  }

  /// The view family is authored too, because icon segments cost the bridged
  /// picker its menu-form TITLE (measured: the derived entry comes back blank).
  /// An unnamed entry is as unreachable as a missing one, so the family's own
  /// entries have to carry the mode names, the flavor and the skin — and have to
  /// actually switch them.
  ///
  /// Run at TWO widths this test chooses itself, and asserts it got: 1600pt,
  /// where the rig proves nothing is clipped, and 900pt, where it proves the
  /// view family IS behind the chevron. Neither number is a guess about the
  /// machine — `ToolbarBridgeRig` keeps the width it asks for whatever the
  /// display is (`UnconstrainedWindow`), and the pair is what makes the claim
  /// screen-independent: an authored menu form lives on the `NSToolbarItem`, not
  /// in the view tree, so it must read the same whether macOS is showing that
  /// family or hiding it. The earlier single-width version asserted only
  /// whichever state the host machine happened to produce.
  @MainActor
  func testOverflowViewFamilyStillSwitchesModeAndSkinWhetherClippedOrNot() throws {
    for width in [1600, 900] as [CGFloat] {
      try runViewFamilyScenario(width: width)
    }
  }

  @MainActor
  private func runViewFamilyScenario(width: CGFloat) throws {
    let rig = try makeToolbarRig(prefix: "EditorToolbarOverflowTests", width: width)
    defer { rig.tearDown() }
    let declared = try XCTUnwrap(rig.toolbar?.items.count)
    if width >= 1600 {
      XCTAssertEqual(rig.visibleItemCount, declared, "the wide leg must clip nothing")
    } else {
      XCTAssertLessThan(rig.visibleItemCount, declared, "the narrow leg must clip something")
    }

    // Establish the baseline before asserting on it. Construction settles once,
    // but SwiftUI can still re-derive a group's menu form after the sink ran —
    // and it re-derives the view family specifically, because that is the group
    // whose content it rewrites. Waiting on production's own triggers (this
    // never calls the pass) is the difference between a scenario that starts
    // from a known toolbar and one that starts from whatever the machine
    // happened to finish.
    XCTAssertTrue(
      rig.awaitOverflowConvergence(),
      "the toolbar never reached agreement with its overflow menus at \(Int(width))pt — "
        + rig.overflowDiagnostics)

    let theme = try XCTUnwrap(
      Self.authoredItem(named: "Theme", in: rig),
      "no authored Theme entry at \(Int(width))pt — " + rig.overflowDiagnostics)
    XCTAssertEqual(theme.submenu?.items.map(\.title), PensieveTheme.allCases.map(\.displayName))
    let wantedSkin = try XCTUnwrap(PensieveTheme.allCases.last { $0 != rig.themeManager.skin })
    let skinItem = try XCTUnwrap(theme.submenu?.items.first { $0.title == wantedSkin.displayName })
    let validator = try XCTUnwrap(skinItem.target as? ToolbarOverflowController)
    XCTAssertEqual(validator.validateMenuItem(skinItem), true)
    XCTAssertEqual(skinItem.state, .off, "an unselected skin must not read as the active one")
    Self.fire(skinItem)
    XCTAssertEqual(
      rig.themeManager.skin, wantedSkin, "the » menu's theme entry did not change the skin")
    _ = validator.validateMenuItem(skinItem)
    XCTAssertEqual(skinItem.state, .on, "the active skin is not marked in the » menu")

    // A skin switch re-bridges the toolbar (the appearance control's label
    // carries the skin name), so the menu is re-read only after the toolbar and
    // its authored forms are back in agreement — never after a bare sleep.
    XCTAssertTrue(
      rig.syncOverflowMenus(),
      "the overflow menus never came back into agreement with the toolbar at \(Int(width))pt — "
        + rig.overflowDiagnostics)

    // Switching to focus mode takes the appearance control off the toolbar
    // (`showsAppearanceControls`), so the authored menu has to follow the
    // toolbar rather than describe a control that is no longer there.
    let mode = try XCTUnwrap(
      Self.authoredItem(named: "Mode", in: rig),
      "no authored Mode entry at \(Int(width))pt — " + rig.overflowDiagnostics)
    XCTAssertEqual(mode.submenu?.items.map(\.title), EditorMode.allCases.map(\.label))
    let modeItem = try XCTUnwrap(mode.submenu?.items.first { $0.title == EditorMode.focus.label })
    Self.fire(modeItem)
    XCTAssertEqual(
      rig.appState.mode, .focus, "the » menu's mode entry did not change the editor layout")

    XCTAssertTrue(
      rig.syncOverflowMenus(),
      "the overflow menus did not follow the mode switch — " + rig.overflowDiagnostics)
    XCTAssertNil(
      Self.authoredItem(named: "Theme", in: rig),
      "focus mode has no preview surface to dress, but the » menu still offers its theme picker")
  }

  /// The ordering that made CI red while this machine stayed green.
  ///
  /// A state change schedules a SwiftUI rebuild, and nothing says the rebuild
  /// lands before the overflow pass runs. On a slower runner it landed AFTER —
  /// inside the settle the check verifies from — so a single-shot sync authored
  /// the menus, watched SwiftUI take them straight back, and reported failure at
  /// a 1600pt window where nothing was even clipped. Forcing that ordering here
  /// (the clobber is scheduled to land mid-settle) reproduces the runner exactly
  /// and keeps the retry honest: with one attempt this fails, as it did on CI.
  @MainActor
  func testOverflowSyncSurvivesARebuildThatLandsAfterThePass() throws {
    let rig = try makeToolbarRig(prefix: "EditorToolbarOverflowTests")
    defer { rig.tearDown() }
    XCTAssertTrue(rig.overflowMatches(rig.toolbelt.overflowFamilies), rig.overflowDiagnostics)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
      MainActor.assumeIsolated {
        for group in rig.itemGroups {
          group.menuFormRepresentation = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        }
      }
    }

    XCTAssertTrue(
      rig.syncOverflowMenus(),
      "a rebuild landing after the pass must be repaired by the next attempt, not reported as a "
        + "toolbar that never converges — " + rig.overflowDiagnostics)
    XCTAssertNotNil(
      Self.authoredItem(named: "Mode", in: rig),
      "the menu converged but has no Mode entry — " + rig.overflowDiagnostics)
  }

  /// The CI shape, reproduced exactly: at 900pt the view family is behind the
  /// chevron AND is the only group SwiftUI re-derives, because its appearance
  /// control is labelled with the live skin name. The runner caught five of six
  /// families authored and that one back on SwiftUI's derived form — which for
  /// an icon-segment picker is a blank title over blank children, i.e. an
  /// overflow entry the operator cannot read or reach.
  ///
  /// Clipping is not what breaks it and this pins that too: the other two
  /// clipped families must stay authored throughout, exactly as they did on the
  /// runner.
  @MainActor
  func testALateRederiveOfTheClippedViewFamilyIsRecovered() throws {
    let rig = try makeToolbarRig(prefix: "EditorToolbarOverflowTests", width: 900)
    defer { rig.tearDown() }
    XCTAssertTrue(rig.awaitOverflowConvergence(), rig.overflowDiagnostics)
    XCTAssertLessThan(rig.visibleItemCount, rig.itemGroups.count, "the view family must be clipped")

    let viewIdentifier = ToolbarOverflowRecipe.formIdentifier(for: .view)
    let viewGroup = try XCTUnwrap(
      rig.itemGroups.first { $0.menuFormRepresentation?.identifier == viewIdentifier },
      "no authored view family to re-derive — " + rig.overflowDiagnostics)
    // Exactly what SwiftUI hands back for an icon-segment picker: no title, and
    // one blank child per formed subitem.
    let derived = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "")
    submenu.addItem(withTitle: "", action: nil, keyEquivalent: "")
    submenu.addItem(withTitle: "", action: nil, keyEquivalent: "")
    derived.submenu = submenu
    viewGroup.menuFormRepresentation = derived

    XCTAssertNil(
      Self.authoredItem(named: "Theme", in: rig), "the re-derive did not take the view family")
    XCTAssertNotNil(
      Self.authoredItem(named: "Reload Preview", in: rig),
      "a clipped family that SwiftUI did NOT rewrite must keep its authored form — "
        + rig.overflowDiagnostics)

    XCTAssertTrue(
      rig.awaitOverflowConvergence(),
      "production never took the view family back from SwiftUI's derived form — "
        + rig.overflowDiagnostics)
    XCTAssertNotNil(
      Self.authoredItem(named: "Theme", in: rig),
      "the view family converged without its theme picker — " + rig.overflowDiagnostics)
    XCTAssertNotNil(Self.authoredItem(named: "Mode", in: rig), rig.overflowDiagnostics)
  }

  /// The repair trigger itself, driven by the cycle the app really uses.
  ///
  /// SwiftUI can hand a rebuilt group its own derived form back at any moment,
  /// and the sink only runs on a body re-evaluation — measured: a form taken
  /// away between two SwiftUI passes is never restored by waiting. So the
  /// controller watches the window, and this pins that watch against a clobber
  /// that no SwiftUI pass follows.
  @MainActor
  func testAClobberedFormIsRepairedOnAWindowUpdate() throws {
    let rig = try makeToolbarRig(prefix: "EditorToolbarOverflowTests")
    defer { rig.tearDown() }
    XCTAssertNotNil(Self.authoredItem(named: "Mode", in: rig))

    for group in rig.itemGroups {
      group.menuFormRepresentation = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    }
    XCTAssertNil(
      Self.authoredItem(named: "Mode", in: rig), "the clobber did not take the authored forms")

    rig.settle(0.15)
    XCTAssertNil(
      Self.authoredItem(named: "Mode", in: rig),
      "if waiting alone repaired this, the repair is riding a trigger this test does not name")

    rig.window.update()
    XCTAssertNotNil(
      Self.authoredItem(named: "Mode", in: rig),
      "a window update must put the authored overflow menus back, with no SwiftUI pass to help")
  }

  // MARK: - Re-assertion

  /// SwiftUI hands a rebuilt toolbar group a freshly derived form — a skin
  /// switch rebuilds the toolbar every time, because the appearance menu's label
  /// carries the skin name. The pass has to win that back, and has to stay quiet
  /// when there is nothing to win.
  @MainActor
  func testOverflowMenusAreReassertedAfterAClobberAndSilentOtherwise() throws {
    let rig = try makeToolbarRig(prefix: "EditorToolbarOverflowTests")
    defer { rig.tearDown() }
    let families = rig.toolbelt.overflowFamilies

    XCTAssertFalse(
      ToolbarOverflowRecipe.assertOverflowMenus(on: rig.window, families: families),
      "a converged toolbar must not be rewritten on every pass")

    let clobbered = try XCTUnwrap(
      rig.itemGroups.first { $0.menuFormRepresentation?.identifier != nil })
    clobbered.menuFormRepresentation = NSMenuItem(
      title: "SwiftUI derived", action: nil, keyEquivalent: "")

    XCTAssertTrue(
      ToolbarOverflowRecipe.assertOverflowMenus(on: rig.window, families: families),
      "the pass did not notice that a group lost its authored overflow entry")
    XCTAssertNotNil(clobbered.menuFormRepresentation?.identifier)
  }

  /// The recipe refuses to guess. A family list that does not match the toolbar
  /// writes nothing rather than labelling the wrong group.
  @MainActor
  func testMismatchedFamilyListIsRefused() throws {
    let rig = try makeToolbarRig(prefix: "EditorToolbarOverflowTests")
    defer { rig.tearDown() }

    let truncated = Array(rig.toolbelt.overflowFamilies.dropLast())
    XCTAssertFalse(
      ToolbarOverflowRecipe.assertOverflowMenus(on: rig.window, families: truncated),
      "a family list that does not line up with the toolbar must be refused, not applied")
  }

  // MARK: - AppKit's own menu

  /// End to end through the real chevron: the menu AppKit builds for a narrow
  /// window, not just the property it builds it from.
  @MainActor
  func testAppKitsClippedItemsMenuCarriesTheAuthoredFamilies() throws {
    let rig = try makeToolbarRig(prefix: "EditorToolbarOverflowTests", width: 900)
    defer { rig.tearDown() }

    let indicator = try XCTUnwrap(rig.clippedItemsIndicator(), "no » chevron at a 900pt window")
    let build = NSSelectorFromString("_computeMenuForClippedItems")
    guard indicator.responds(to: build) else {
      throw XCTSkip("AppKit no longer exposes the clipped-items menu build under a known name")
    }
    // AppKit fills this menu when the chevron is clicked; the test asks for the
    // same build instead of running a modal menu loop offscreen.
    indicator.perform(build)

    let titles = (indicator.menu?.items ?? []).map(\.title)
    XCTAssertFalse(titles.isEmpty, "the » menu opens on an empty list")
    XCTAssertTrue(
      titles.contains("Assistants"),
      "the assistants family — dictation, AI autocomplete, rewrite — is not in the » menu at all, "
        + "got \(titles)")
    XCTAssertTrue(
      titles.contains("Preview Runtime"),
      "the preview runtime family is not in the » menu, got \(titles)")
    XCTAssertFalse(
      titles.contains("Reload Preview"),
      "a whole family is still being named after its single formed control, which is what "
        + "rendered it twice; got \(titles)")
  }

  // MARK: - Helpers

  /// Every name the overflow menu can show: the authored family submenus and
  /// the forms SwiftUI builds for the families that need no authoring, flattened
  /// through one level of nesting.
  @MainActor
  private static func overflowTitles(in rig: ToolbarBridgeRig) -> [String] {
    var titles: [String] = []
    for group in rig.itemGroups {
      guard let form = group.menuFormRepresentation else { continue }
      if let children = form.submenu?.items, !children.isEmpty {
        titles.append(contentsOf: children.map(\.title))
      } else if !form.title.isEmpty {
        titles.append(form.title)
      }
    }
    return titles
  }

  @MainActor
  private static func authoredItem(named title: String, in rig: ToolbarBridgeRig) -> NSMenuItem? {
    for group in rig.itemGroups {
      for item in group.menuFormRepresentation?.submenu?.items ?? [] where item.title == title {
        return item
      }
    }
    return nil
  }

  @MainActor
  private static func fire(_ item: NSMenuItem) {
    guard let action = item.action else {
      return XCTFail("menu item '\(item.title)' has no action")
    }
    NSApp.sendAction(action, to: item.target, from: item)
  }
}
