import XCTest

@testable import Pensieve

/// The menu bar carries `PensieveCommands` only while the command surface can
/// name a root. `focusedSceneValue`/`focusedSceneObject` publish exclusively
/// while a scene is ACTIVE, so a cold launch that has not been activated yet
/// resolved nil and SwiftUI installed its DEFAULT menu — no `Mode`/`Format`/
/// `Agents`, no app File items. These tests pin the fallback that makes the
/// menu structure independent of activation timing.
final class CommandSurfaceContextTests: XCTestCase {
  @MainActor
  func testAdoptedRootBecomesTheFallbackCommandTarget() {
    let context = CommandSurfaceContext()
    XCTAssertNil(context.appState)
    XCTAssertNil(context.controller)

    let appState = AppState()
    let controller = AppController(appState: appState)
    context.adopt(appState: appState, controller: controller)

    XCTAssertTrue(context.appState === appState)
    XCTAssertTrue(context.controller === controller)
  }

  @MainActor
  func testLaterRootTakesOverTheFallbackAsAPair() {
    let context = CommandSurfaceContext()
    let firstState = AppState()
    let firstController = AppController(appState: firstState)
    let secondState = AppState()
    let secondController = AppController(appState: secondState)

    context.adopt(appState: firstState, controller: firstController)
    context.adopt(appState: secondState, controller: secondController)

    XCTAssertTrue(context.appState === secondState)
    XCTAssertTrue(context.controller === secondController)
  }

  /// A closed window's root must stop serving menu actions and must not be
  /// retained by the app-level fallback.
  @MainActor
  func testReleasingTheAdoptedRootClearsBothHalves() {
    let context = CommandSurfaceContext()
    let appState = AppState()
    let controller = AppController(appState: appState)
    context.adopt(appState: appState, controller: controller)

    context.release(controller: controller)

    XCTAssertNil(context.appState)
    XCTAssertNil(context.controller)
  }

  /// Closing a stale window after another root took over must not blank the
  /// menu bar of the window that is still open.
  @MainActor
  func testReleasingAStaleRootLeavesTheCurrentOneAdopted() {
    let context = CommandSurfaceContext()
    let staleState = AppState()
    let staleController = AppController(appState: staleState)
    let liveState = AppState()
    let liveController = AppController(appState: liveState)

    context.adopt(appState: staleState, controller: staleController)
    context.adopt(appState: liveState, controller: liveController)
    context.release(controller: staleController)

    XCTAssertTrue(context.appState === liveState)
    XCTAssertTrue(context.controller === liveController)
  }

  /// Cold launch: with nothing adopted, the first root's early build-time
  /// `.task` must seed the fallback so the menu bar has content before any
  /// window is key.
  @MainActor
  func testEarlySeedAdoptsWhenNothingHasAdoptedYet() {
    let context = CommandSurfaceContext()
    let appState = AppState()
    let controller = AppController(appState: appState)

    context.adoptIfUnset(appState: appState, controller: controller)

    XCTAssertTrue(context.appState === appState)
    XCTAssertTrue(context.controller === controller)
  }

  /// A background root building AFTER the key window already adopted must not
  /// steal the fallback via its early `.task`; otherwise menu actions during
  /// focus-silent periods target the background document.
  @MainActor
  func testEarlySeedDoesNotStealFromAnAlreadyAdoptedRoot() {
    let context = CommandSurfaceContext()
    let keyState = AppState()
    let keyController = AppController(appState: keyState)
    let backgroundState = AppState()
    let backgroundController = AppController(appState: backgroundState)

    // The key window adopted (e.g. via `didBecomeKey`).
    context.adopt(appState: keyState, controller: keyController)
    // A late-building background root's `.task` seeds — must be a no-op.
    context.adoptIfUnset(appState: backgroundState, controller: backgroundController)

    XCTAssertTrue(context.appState === keyState)
    XCTAssertTrue(context.controller === keyController)
  }

  func testFocusedPairWinsOverTheFallback() {
    let focusedState = NSObject()
    let focusedController = NSObject()
    let fallbackState = NSObject()
    let fallbackController = NSObject()

    let resolved = CommandTargetResolution.resolve(
      focusedState: focusedState,
      focusedController: focusedController,
      fallbackState: fallbackState,
      fallbackController: fallbackController)

    XCTAssertTrue(resolved?.state === focusedState)
    XCTAssertTrue(resolved?.controller === focusedController)
  }

  /// Never mix halves: a focused state driven through a different window's
  /// controller would let a menu action mutate the wrong document session.
  func testHalfResolvedFocusFallsBackAsAWholePair() {
    let focusedState = NSObject()
    let fallbackState = NSObject()
    let fallbackController = NSObject()

    let resolved = CommandTargetResolution.resolve(
      focusedState: focusedState,
      focusedController: Optional<NSObject>.none,
      fallbackState: fallbackState,
      fallbackController: fallbackController)

    XCTAssertTrue(resolved?.state === fallbackState)
    XCTAssertTrue(resolved?.controller === fallbackController)
  }

  /// The cold-launch shape: nothing is focused yet, but a root has adopted —
  /// the menu must still be built from it.
  func testUnfocusedColdLaunchStillResolvesTheAdoptedRoot() {
    let fallbackState = NSObject()
    let fallbackController = NSObject()

    let resolved = CommandTargetResolution.resolve(
      focusedState: Optional<NSObject>.none,
      focusedController: Optional<NSObject>.none,
      fallbackState: fallbackState,
      fallbackController: fallbackController)

    XCTAssertTrue(resolved?.state === fallbackState)
    XCTAssertTrue(resolved?.controller === fallbackController)
  }

  // MARK: - Native tab switches

  /// Both triggers filter by window identity: a key transition belonging to a
  /// DIFFERENT window must never make this root adopt.
  @MainActor
  func testARootIgnoresAnotherWindowsKeyTransition() {
    let mine = Self.makeParkedWindow()
    let other = Self.makeParkedWindow()
    defer {
      mine.close()
      other.close()
    }

    XCTAssertFalse(CommandSurfaceAdoption.shouldAdopt(rootWindow: mine, keyWindow: other))
    XCTAssertTrue(CommandSurfaceAdoption.shouldAdopt(rootWindow: mine, keyWindow: mine))
  }

  /// A root that does not yet know its own window cannot adopt — the accessor
  /// callback is what supplies it, and it is async.
  @MainActor
  func testARootWithoutItsWindowYetCannotAdopt() {
    let window = Self.makeParkedWindow()
    defer { window.close() }

    XCTAssertFalse(CommandSurfaceAdoption.shouldAdopt(rootWindow: nil, keyWindow: window))
    XCTAssertFalse(CommandSurfaceAdoption.shouldAdopt(rootWindow: window, keyWindow: nil))
  }

  /// THE CROSS-WIRE PIN. The f_013 constellation: the user leaves a file-backed
  /// tab for a second tab in the same group. The second tab's window becomes
  /// key BEFORE its root's (coalesced, async) accessor reports that window, so
  /// the key notification is filtered out; the accessor lands a moment later.
  ///
  /// With only the key-notification trigger the second tab never adopts. Focus
  /// then goes silent — routine during native tab switches and menu tracking —
  /// and `CommandTargetResolution` falls back to the LAST-adopted pair, which
  /// is still the first tab. A model-side edit taken while the user looks at
  /// the second tab therefore lands in the FIRST tab's session: the buffer the
  /// chrome is not showing.
  @MainActor
  func testAnEditAfterATabSwitchLandsInTheTabTheUserIsLookingAt() {
    let surface = CommandSurfaceContext()

    let leftBehind = AppState()
    let leftBehindController = AppController(appState: leftBehind)
    leftBehind.documentSession.text = "left-behind"

    let lookedAt = AppState()
    let lookedAtController = AppController(appState: lookedAt)
    lookedAt.documentSession.createUntitled()
    lookedAt.documentSession.text = "looked-at"

    let leftBehindWindow = Self.makeParkedWindow()
    let lookedAtWindow = Self.makeParkedWindow()
    defer {
      leftBehindWindow.close()
      lookedAtWindow.close()
    }

    // The first tab is key and owns the surface.
    Self.windowDidBecomeKey(
      leftBehindWindow, surface: surface, appState: leftBehind,
      controller: leftBehindController, rootWindow: leftBehindWindow)
    XCTAssertTrue(surface.appState === leftBehind)

    // The user switches. The new tab's window becomes key, but its root has not
    // yet been told which window is its own, so the identity filter drops it.
    Self.windowDidBecomeKey(
      lookedAtWindow, surface: surface, appState: lookedAt,
      controller: lookedAtController, rootWindow: nil)
    // ...and the notification never fires again. The ONLY remaining chance to
    // adopt is the accessor resolving this root's window while it is key.
    Self.accessorResolvedWindow(
      lookedAtWindow, surface: surface, appState: lookedAt,
      controller: lookedAtController, keyWindow: lookedAtWindow)

    // Focus is extinguished, so the menu resolves through the fallback.
    guard
      let target = CommandTargetResolution.resolve(
        focusedState: Optional<AppState>.none,
        focusedController: Optional<AppController>.none,
        fallbackState: surface.appState,
        fallbackController: surface.controller)
    else {
      return XCTFail("the command surface resolved no target at all")
    }

    // A model-side edit, exactly as a menu/paste action performs it.
    target.state.documentSession.text = "pasted"
    target.state.documentSession.isDirty = true

    XCTAssertEqual(
      lookedAt.documentSession.text, "pasted",
      "the edit must land in the session whose tab the user is looking at")
    XCTAssertEqual(
      leftBehind.documentSession.text, "left-behind",
      "the tab the user navigated away from must not receive the edit")
    XCTAssertFalse(
      leftBehind.documentSession.isDirty,
      "the left-behind session must not be dirtied by another tab's edit")
  }

  /// Trigger 1, mirroring `.onReceive(didBecomeKeyNotification)`: a key
  /// transition, filtered against the window this root currently knows about.
  @MainActor
  private static func windowDidBecomeKey(
    _ keyWindow: NSWindow,
    surface: CommandSurfaceContext,
    appState: AppState,
    controller: AppController,
    rootWindow: NSWindow?
  ) {
    guard CommandSurfaceAdoption.shouldAdopt(rootWindow: rootWindow, keyWindow: keyWindow) else {
      return
    }
    surface.adopt(appState: appState, controller: controller)
  }

  /// Trigger 2, mirroring `.onChange(of: currentWindow)`: the accessor finally
  /// reports this root's window, which is checked against the window that is
  /// key AT THAT MOMENT.
  @MainActor
  private static func accessorResolvedWindow(
    _ rootWindow: NSWindow,
    surface: CommandSurfaceContext,
    appState: AppState,
    controller: AppController,
    keyWindow: NSWindow?
  ) {
    guard CommandSurfaceAdoption.shouldAdopt(rootWindow: rootWindow, keyWindow: keyWindow) else {
      return
    }
    surface.adopt(appState: appState, controller: controller)
  }

  /// Parked far offscreen and fully transparent: these windows exist only as
  /// identities for the adoption rule, and must never flash on a display.
  @MainActor
  private static func makeParkedWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: -9000, y: -9000, width: 200, height: 120),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true)
    window.alphaValue = 0
    // This initializer defaults to `isReleasedWhenClosed = true`; the `close()`
    // in each test's `defer` would then over-release an ARC-owned window and
    // segfault the whole test process.
    window.isReleasedWhenClosed = false
    return window
  }

  func testNoRootAtAllResolvesToNothing() {
    let resolved = CommandTargetResolution.resolve(
      focusedState: Optional<NSObject>.none,
      focusedController: Optional<NSObject>.none,
      fallbackState: Optional<NSObject>.none,
      fallbackController: Optional<NSObject>.none)

    XCTAssertNil(resolved)
  }
}
