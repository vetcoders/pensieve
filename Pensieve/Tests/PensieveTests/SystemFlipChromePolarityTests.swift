import AppKit
import XCTest

@testable import Pensieve

/// One window is on ONE half, always — including during the run-loop turn a live
/// system flip takes to reach it.
///
/// The defect these tests pin was photographed on the shipping app (KT-4): with
/// Typewriter active, flipping the Mac's light/dark setting mid-session left the
/// window two-toned — the native tab bar and the toolbar chips in the NEW half
/// while the titlebar, toolbar, sidebar and traffic lights stayed in the OLD
/// one, with the boundary landing on the split divider. Cold starts in either
/// mode were correct; only the live re-dress path was wrong, symmetrically in
/// both directions.
///
/// The cause was two writers of the same fact. The tab bar and the chips are
/// re-asserted from `NSWindow.didUpdateNotification`, and both derived their
/// side from the SKIN — which, for a paired skin, moves the instant the system
/// setting does. The window's own appearance is written only by
/// `assertWindowChrome`, which is deliberately kept off that notification (a
/// per-update `NSWindow.appearance` write is the 99% CPU start-up hang) and
/// therefore arrived a turn later, or — for a background tab that never gets a
/// SwiftUI pass — not at all.
///
/// So the rule these pins hold to is a single-writer rule: `assertWindowChrome`
/// owns the half, the update-cycle repair may only ever paint the half a window
/// ALREADY has, and a flip reaches every document window through one sweep.
final class SystemFlipChromePolarityTests: XCTestCase {

  // MARK: - The invariant

  /// THE INVARIANT PIN: across a live flip, the tab bar and the window are never
  /// found in different halves.
  ///
  /// The step that used to break it is driven literally — the first thing to
  /// reach the window after the setting moves is the repair its own update cycle
  /// runs, with no SwiftUI pass and no sweep behind it. Pre-fix that repair read
  /// the skin's live half and painted the tab bar light while the window was
  /// still dark; the equality below is what that fails.
  @MainActor
  func testTheTabBarNeverOutrunsTheWindowAcrossALiveSystemFlip() throws {
    let window = makeDocumentWindow(title: "Two Tone Probe")
    defer { window.close() }
    let glass = makeTabBarGlass()

    try withSystemAppearance(dark: true) {
      WindowChromeRecipe.assertWindowChrome(on: window, for: .typewriter)
      WindowChromeRecipe.assertTabBarAppearance(
        on: window, for: .typewriter, tabBarViews: [glass])
      XCTAssertEqual(
        WindowChromeRecipe.appearancePolarity(window.appearance), .darkAqua,
        "premise: the window starts in the dark half")
      XCTAssertEqual(
        WindowChromeRecipe.appearancePolarity(glass.appearance), .darkAqua,
        "premise: and so does its tab bar")
    }

    try withSystemAppearance(dark: false) {
      WindowChromeRecipe.assertBetweenPassChrome(
        on: window, for: .typewriter, tabBarViews: [glass])

      XCTAssertEqual(
        WindowChromeRecipe.appearancePolarity(glass.appearance),
        WindowChromeRecipe.appearancePolarity(window.appearance),
        "the tab bar and the window are in different halves — this is the two-tone window,"
          + " with the tab bar a full run-loop turn ahead of the chrome around it")

      // And the way OUT of the old half is the sweep, not the update cycle: it
      // moves the window, and only then does the same repair take the tab bar
      // with it. (The sweep's own tab-bar pass goes through the real discovery
      // walk, which has nothing to find on a headless window with no tab group.)
      WindowChromeRecipe.assertDocumentWindowChrome(among: [window], for: .typewriter)
      WindowChromeRecipe.assertBetweenPassChrome(
        on: window, for: .typewriter, tabBarViews: [glass])

      XCTAssertEqual(WindowChromeRecipe.appearancePolarity(window.appearance), .aqua)
      XCTAssertEqual(
        WindowChromeRecipe.appearancePolarity(glass.appearance), .aqua,
        "the flip finished with the tab bar left behind in the outgoing half")
      XCTAssertEqual(
        glass.appearance?.name, .vibrantLight,
        "the repair flattened the tab bar's glass instead of moving it across")
    }
  }

  // MARK: - Fix A: the sweep

  /// THE SWEEP PIN, end to end through the real `ThemeManager` observation:
  /// flipping the system setting re-dresses EVERY document window, not only one.
  ///
  /// Nothing here touches a view tree, orders a window or changes focus — the
  /// only event is the Mac's setting moving. A window that gets no SwiftUI pass
  /// (a background native tab is the real case) has no other way to learn the
  /// half changed, and pre-fix it kept the outgoing one for the rest of the
  /// session.
  ///
  /// A window that is not a document host is included precisely so the sweep has
  /// something to leave alone.
  @MainActor
  func testASystemFlipReDressesEveryDocumentWindowAndNothingElse() throws {
    let manager = ThemeManager(
      defaults: makeEphemeralDefaults(prefix: "SystemFlipChromePolarityTests"))
    manager.skin = .typewriter
    let previous = NSApplication.shared.appearance
    defer { NSApplication.shared.appearance = previous }

    NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    settle()

    let focused = makeDocumentWindow(title: "Focused Tab")
    let background = makeDocumentWindow(title: "Background Tab")
    let stranger = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: true)
    stranger.isReleasedWhenClosed = false
    defer {
      focused.close()
      background.close()
      stranger.close()
    }

    for window in [focused, background] {
      WindowChromeRecipe.assertWindowChrome(on: window, for: .typewriter)
      XCTAssertEqual(
        window.appearance?.name, .darkAqua,
        "premise: both document windows start dressed in the dark half")
    }
    XCTAssertNil(stranger.appearance, "premise: the stranger carries no half of ours")

    NSApplication.shared.appearance = NSAppearance(named: .aqua)
    settle()

    XCTAssertEqual(
      focused.appearance?.name, .aqua,
      "the flip did not reach a document window that received no SwiftUI pass")
    XCTAssertEqual(
      background.appearance?.name, .aqua,
      "a background tab kept the outgoing half — nothing walks the windows when the setting"
        + " moves, so it stays there until something focuses it")
    XCTAssertNil(
      stranger.appearance,
      "the sweep dressed a window that is not a document host")
  }

  // MARK: - Fix B: the ordering

  /// THE ORDERING PIN: a repair driven from a window's own update cycle may not
  /// move a window into a half it does not have yet.
  ///
  /// This is the single-writer rule stated as a test. `assertWindowChrome` is
  /// the only writer of the half; the update-cycle repair exists for the two
  /// surfaces AppKit rebuilds between SwiftUI passes and must stay strictly
  /// behind it.
  ///
  /// Typewriter's chip fill is the same `#6e6e6e` in both halves, so the tab bar
  /// is the surface that actually carries polarity across this trigger — which
  /// is why it is the one asserted here.
  @MainActor
  func testAnUpdateRepairOnAWindowStillOnTheOldHalfPaintsNothing() throws {
    let window = makeDocumentWindow(title: "Ordering Probe")
    defer { window.close() }
    let glass = makeTabBarGlass()

    try withSystemAppearance(dark: true) {
      WindowChromeRecipe.assertWindowChrome(on: window, for: .typewriter)
      WindowChromeRecipe.assertTabBarAppearance(
        on: window, for: .typewriter, tabBarViews: [glass])
    }

    try withSystemAppearance(dark: false) {
      XCTAssertFalse(
        WindowChromeRecipe.isAssertedToTheSkinsHalf(window, for: .typewriter),
        "premise: the setting moved and nothing has moved the window across yet")

      XCTAssertFalse(
        WindowChromeRecipe.assertBetweenPassChrome(
          on: window, for: .typewriter, tabBarViews: [glass]),
        "the update cycle corrected a window that is still on the other half — whatever it"
          + " wrote there is by definition the wrong half for that window")
      XCTAssertEqual(
        WindowChromeRecipe.appearancePolarity(glass.appearance), .darkAqua,
        "the tab bar was moved into the incoming half by a trigger that does not own it")
    }
  }

  /// The gate is not a mute. It holds back exactly one thing — a window that is
  /// behind its skin — and everything the update-cycle repair existed for keeps
  /// working: a first repair on a window no chrome pass has reached yet (the
  /// launcher's toggle chips), and the healing repair after an external clobber
  /// (a toolbar re-bridge, a tab-group reshuffle).
  @MainActor
  func testTheGateHoldsBackOnlyAWindowThatIsBehindItsSkin() {
    let window = makeDocumentWindow(title: "Gate Probe")
    defer { window.close() }
    let glass = makeTabBarGlass()

    XCTAssertTrue(
      WindowChromeRecipe.assertBetweenPassChrome(on: window, for: .ink, tabBarViews: [glass]),
      "a window the chrome pass has never reached must still be repaired — there is no half"
        + " of ours for it to be behind")
    XCTAssertEqual(WindowChromeRecipe.appearancePolarity(glass.appearance), .darkAqua)

    WindowChromeRecipe.assertWindowChrome(on: window, for: .ink)
    XCTAssertFalse(
      WindowChromeRecipe.assertBetweenPassChrome(on: window, for: .ink, tabBarViews: [glass]),
      "an already-correct tab bar was rewritten — on a didUpdate trigger that is the loop")

    glass.appearance = NSAppearance(named: .vibrantLight)
    XCTAssertTrue(
      WindowChromeRecipe.assertBetweenPassChrome(on: window, for: .ink, tabBarViews: [glass]),
      "an external clobber must still heal on the next update cycle")
    XCTAssertEqual(WindowChromeRecipe.appearancePolarity(glass.appearance), .darkAqua)
  }

  // MARK: - Harness

  @MainActor
  private func makeDocumentWindow(title: String) -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: true)
    // Carries the document tabbing identifier, which is what makes it a
    // document host for the sweep's filter.
    WindowChromeRecipe.apply(to: window, title: title)
    return window
  }

  /// The measured shape of a tab bar's self-selecting node: a glass view that
  /// picked its own vibrant appearance. Injected through the polarity seam,
  /// because the discovery walk needs a real native tab group.
  @MainActor
  private func makeTabBarGlass() -> NSView {
    let glass = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 28))
    glass.appearance = NSAppearance(named: .vibrantLight)
    return glass
  }

  @MainActor
  private func settle(_ seconds: TimeInterval = 0.25) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }
}
