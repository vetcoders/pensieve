import AppKit
import SwiftUI
import XCTest

@testable import Pensieve

/// A skin that demands a fixed light or dark must own the WHOLE window, not just
/// the panes that paint themselves from the token table.
///
/// The bug these pins exist for: on a dark system, a restored document under
/// Parchment rendered split — parchment editor and preview (they paint every
/// pixel from `ThemeTokens`), but a DARK sidebar, dark traffic lights and a dark
/// mode picker (system material + AppKit chrome, which follow the window's
/// `effectiveAppearance`). `assertWindowChrome` writes `window.appearance`, but
/// the window restoration loads the recovered document into is the SwiftUI
/// scene's own window, and the scene puts `nil` back after every foreign write —
/// measured on a probe app: `appearance=nil, effective=darkAqua` on 15/15 passes
/// for the scene window while an `NSHostingView`-backed window next to it kept
/// `aqua` on all 15. Re-asserting harder is the start-up hang, not the fix.
///
/// So the appearance is DECLARED in SwiftUI, where the scene already owns it.
final class SkinWindowAppearanceTests: XCTestCase {
  /// The AppKit answer and the SwiftUI answer are the same demand written twice.
  /// Nothing else keeps `assertWindowChrome` and the root view's declaration
  /// pointed at the same skin.
  func testEverySkinsColorSchemeAgreesWithItsWindowAppearance() {
    for skin in PensieveTheme.allCases {
      let appearance = WindowChromeRecipe.windowAppearance(for: skin)?.name
      switch WindowChromeRecipe.preferredColorScheme(for: skin) {
      case .light:
        XCTAssertEqual(appearance, .aqua, "\(skin) is light in SwiftUI but not in AppKit")
      case .dark:
        XCTAssertEqual(appearance, .darkAqua, "\(skin) is dark in SwiftUI but not in AppKit")
      case .none:
        XCTAssertNil(appearance, "\(skin) is adaptive in SwiftUI but pinned in AppKit")
      @unknown default:
        XCTFail("unhandled colour scheme for \(skin)")
      }
    }
  }

  /// THE REGRESSION PIN. Hosting a root that carries `pensieveSkinAppearance`
  /// must move the host window's appearance onto the skin — the step no AppKit
  /// write can be trusted to deliver.
  ///
  /// Both a light-demanding and a dark-demanding skin are checked, so the pin
  /// discriminates whatever appearance the machine running it happens to be in:
  /// one of the two always differs from the system default, so dropping the
  /// modifier (or neutering it to `preferredColorScheme(nil)`) must redden at
  /// least one leg.
  @MainActor
  func testSkinAppearanceDeclarationDrivesTheHostWindow() {
    for (skin, expected) in [(PensieveTheme.parchment, NSAppearance.Name.aqua), (.ink, .darkAqua)] {
      let (window, _, _) = hostSkinRoot(skin)
      defer { window.contentView = nil }
      XCTAssertEqual(
        window.appearance?.name, expected,
        "a \(skin) window must be \(expected.rawValue) whatever the system is set to —"
          + " the sidebar and the titlebar widgets have no other source of truth")
    }
  }

  /// A PAIRED skin is not an adaptive one, and this is the pin that says so.
  ///
  /// It reads as a distinction without a difference — the resolved half always
  /// agrees with the system, so "pin the half" and "follow the system" paint the
  /// same chrome — right up until something else resolves the scene on its own.
  /// That is what shipped in build 446: the pair declared no preference, and the
  /// operator got a window whose titlebar, sidebar and editor were dark while
  /// the trailing toolbar families came back light. The very split this suite's
  /// header describes for Parchment, and for the very reason line 49 names:
  /// a `preferredColorScheme(nil)` is a neutered declaration.
  ///
  /// Both halves are driven, so the pin discriminates on any machine: one leg
  /// always disagrees with whatever the host is set to.
  @MainActor
  func testAPairedSkinPinsTheHostWindowToTheHalfTheSystemChose() throws {
    for dark in [true, false] {
      try withSystemAppearance(dark: dark) {
        let (window, _, _) = hostSkinRoot(.typewriter)
        defer { window.contentView = nil }
        XCTAssertEqual(
          window.appearance?.name, dark ? .darkAqua : .aqua,
          "the \(dark ? "dark" : "light") half must own the whole window —"
            + " an unpinned scene leaves the toolbar free to resolve the other one")
      }
    }
  }

  /// A pinned half is only honest if it MOVES. Pinning made the window's
  /// appearance a function of the system setting rather than of the skin alone,
  /// so "Typewriter still follows your Mac" now rests on the pin being re-derived
  /// when the setting changes — nothing else re-dresses an already-hosted window.
  ///
  /// The flip is driven on an ALREADY HOSTED window and nothing here touches the
  /// view tree, so what this proves is the manager's own system-appearance
  /// observation reaching the declaration.
  @MainActor
  func testAPairedWindowFollowsALiveSystemFlip() throws {
    try withSystemAppearance(dark: true) {
      let (window, _, _) = hostSkinRoot(.typewriter)
      defer { window.contentView = nil }
      XCTAssertEqual(window.appearance?.name, .darkAqua)

      NSApplication.shared.appearance = NSAppearance(named: .aqua)
      for _ in 0..<40 where window.appearance?.name != .aqua { settle(window) }
      XCTAssertEqual(
        window.appearance?.name, .aqua,
        "flipping the Mac to light must take the window with it — a pin that never"
          + " moves is a skin that stopped following the setting it reads")
    }
  }

  /// The adaptive skins must NOT pin the window: they are the ones that are
  /// supposed to follow the system setting.
  @MainActor
  func testAdaptiveSkinsLeaveTheWindowOnTheSystemAppearance() {
    let (window, _, _) = hostSkinRoot(.default)
    defer { window.contentView = nil }
    XCTAssertNil(
      window.appearance,
      "an adaptive skin that pinned the window would stop following the system")
  }

  /// A live skin switch has to take the window with it — WITHOUT the host root
  /// being rebuilt from outside. The modifier observes the manager itself, and
  /// this is the leg that proves it: nothing here touches the view tree, only
  /// `themeManager.skin`.
  @MainActor
  func testASkinSwitchMovesAnAlreadyHostedWindow() {
    let (window, _, manager) = hostSkinRoot(.parchment)
    defer { window.contentView = nil }
    XCTAssertEqual(window.appearance?.name, .aqua)

    manager.skin = .ink
    settle(window)
    XCTAssertEqual(
      window.appearance?.name, .darkAqua,
      "switching to a dark skin must take the whole window with it")

    manager.skin = .default
    settle(window)
    XCTAssertNil(
      window.appearance,
      "switching back to an adaptive skin must release the pin, not keep the last fixed one")
  }

  // MARK: - Harness

  @MainActor
  private func hostSkinRoot(_ skin: PensieveTheme)
    -> (NSWindow, NSHostingView<AnyView>, ThemeManager)
  {
    let manager = ThemeManager(defaults: makeEphemeralDefaults(prefix: "SkinWindowAppearanceTests"))
    manager.skin = skin
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    let hosting = NSHostingView(rootView: AnyView(Text("body").pensieveSkinAppearance(manager)))
    window.contentView = hosting
    settle(window)
    return (window, hosting, manager)
  }

  @MainActor
  private func settle(_ window: NSWindow) {
    window.layoutIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
  }
}
