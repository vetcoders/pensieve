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

  func testNoRootAtAllResolvesToNothing() {
    let resolved = CommandTargetResolution.resolve(
      focusedState: Optional<NSObject>.none,
      focusedController: Optional<NSObject>.none,
      fallbackState: Optional<NSObject>.none,
      fallbackController: Optional<NSObject>.none)

    XCTAssertNil(resolved)
  }
}
