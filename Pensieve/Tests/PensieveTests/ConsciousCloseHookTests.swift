import AppKit
import XCTest

@testable import Pensieve

/// Stands in for the delegate SwiftUI installs on its own scene windows
/// (`AppKitWindowController`), so the forwarding contract is testable without
/// reaching into SwiftUI internals.
private final class SwiftUIStyleWindowDelegate: NSObject, NSWindowDelegate {
  var vetoesClose = false
  private(set) var shouldCloseAsks = 0
  private(set) var willCloseNotifications = 0

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    shouldCloseAsks += 1
    return !vetoesClose
  }

  func windowWillClose(_ notification: Notification) {
    willCloseNotifications += 1
  }
}

/// #15 P1-01 follow-up: the conscious close lifecycle must reach EVERY
/// document-bearing window, not only the ones this app builds itself.
///
/// The gap it closes was measured, not inferred. Runtime probe on macOS 26
/// (Darwin 25.6), debug build, 2026-08-03: the window SwiftUI auto-presents for
/// the launcher `WindowGroup` at every cold start reports
/// `class=AppKitWindow isDocumentWindow=false delegate=AppKitWindowController`.
/// That window holds the first restored file of the session, a cold-start
/// Finder open, and every ⌘N draft — and its red close button was falling
/// through to the teardown guard, which can only stash a recovery draft and can
/// never ask `Save / Don't Save / Cancel`.
final class ConsciousCloseHookTests: XCTestCase {

  /// The pin. A window whose class is not ours still asks before it closes.
  @MainActor
  func testAWindowThatIsNotADocumentWindowStillAsksBeforeItCloses() throws {
    let window = Self.makeSwiftUIStyleWindow()
    defer { window.close() }
    var asked = 0

    ConsciousCloseHook.install(on: window) { _ in
      asked += 1
      return false
    }

    let delegate = try XCTUnwrap(window.delegate, "the window was left with no veto point at all")
    XCTAssertEqual(
      delegate.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))), true,
      "AppKit asks the DELEGATE first; a delegate that does not answer this is not a veto point")
    XCTAssertEqual(delegate.windowShouldClose?(window), false)
    XCTAssertEqual(asked, 1, "the window's own session was never consulted about the close")
  }

  /// …and through the real AppKit route, not just a direct delegate call: the
  /// red close button and a tab's "×" both land on `performClose`.
  @MainActor
  func testPerformCloseRoutesASwiftUIStyleWindowThroughTheHook() {
    let window = Self.makeSwiftUIStyleWindow()
    defer { window.close() }
    var asked = 0

    ConsciousCloseHook.install(on: window) { _ in
      asked += 1
      return false
    }
    window.performClose(nil)

    XCTAssertEqual(asked, 1, "performClose bypassed the conscious close hook")
    XCTAssertNotNil(window.contentView, "a vetoed close must leave the window standing")
  }

  /// The hook is an ADDITION, not a takeover: everything it does not answer
  /// itself still reaches the delegate SwiftUI installed, or the scene loses
  /// its own lifecycle the moment a document window is guarded.
  @MainActor
  func testTheHookKeepsForwardingToTheDelegateItWrapped() {
    let window = Self.makeSwiftUIStyleWindow()
    defer { window.close() }
    let sceneDelegate = SwiftUIStyleWindowDelegate()
    window.delegate = sceneDelegate

    ConsciousCloseHook.install(on: window) { _ in true }

    let installed = window.delegate
    XCTAssertFalse(installed === sceneDelegate, "the hook never went on")
    XCTAssertEqual(
      installed?.responds(to: #selector(NSWindowDelegate.windowWillClose(_:))), true,
      "a message the wrapped delegate handles must still be advertised as handled")
    installed?.windowWillClose?(
      Notification(name: NSWindow.willCloseNotification, object: window))
    XCTAssertEqual(
      sceneDelegate.willCloseNotifications, 1,
      "the wrapped delegate stopped receiving its own lifecycle")
  }

  /// A refusal from the wrapped delegate is final. SwiftUI saying "no" is not
  /// something this app's dirty guard may overturn — and the guard must not even
  /// run, or a window that is not closing would put up a save sheet.
  @MainActor
  func testAVetoFromTheWrappedDelegateWinsAndSkipsTheSessionGuard() {
    let window = Self.makeSwiftUIStyleWindow()
    defer { window.close() }
    let sceneDelegate = SwiftUIStyleWindowDelegate()
    sceneDelegate.vetoesClose = true
    window.delegate = sceneDelegate
    var asked = 0

    ConsciousCloseHook.install(on: window) { _ in
      asked += 1
      return true
    }

    XCTAssertEqual(window.delegate?.windowShouldClose?(window), false)
    XCTAssertEqual(sceneDelegate.shouldCloseAsks, 1)
    XCTAssertEqual(asked, 0, "the session was asked about a close the scene had already refused")
  }

  /// The accessor that installs this fires on many render passes, and SwiftUI is
  /// free to re-assign `window.delegate` between them. Re-installing must
  /// refresh the hook in place — never wrap the previous proxy in another one,
  /// which would leave a chain of dead closures answering for the window.
  @MainActor
  func testReinstallingRefreshesTheHookInsteadOfStackingProxies() {
    let window = Self.makeSwiftUIStyleWindow()
    defer { window.close() }
    let sceneDelegate = SwiftUIStyleWindowDelegate()
    window.delegate = sceneDelegate

    ConsciousCloseHook.install(on: window) { _ in true }
    let firstProxy = window.delegate
    var secondAsked = 0
    ConsciousCloseHook.install(on: window) { _ in
      secondAsked += 1
      return false
    }

    XCTAssertTrue(window.delegate === firstProxy, "a second install replaced the proxy")
    XCTAssertEqual(window.delegate?.windowShouldClose?(window), false)
    XCTAssertEqual(secondAsked, 1, "the stale closure answered instead of the current one")
    XCTAssertEqual(
      (window.delegate as? ConsciousCloseDelegateProxy)?.wrapped === sceneDelegate, true,
      "re-installing must not wrap the proxy in itself")
  }

  /// Factory-built windows keep the route they already had — `performClose` is
  /// overridden on `DocumentWindow` itself, so their delegate is left alone for
  /// AppKit's tab machinery.
  @MainActor
  func testAFactoryDocumentWindowKeepsItsOwnCloseRouteAndItsDelegate() {
    let window = DocumentWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    var asked = 0

    ConsciousCloseHook.install(on: window) { _ in
      asked += 1
      return false
    }

    XCTAssertNil(window.delegate, "a DocumentWindow needs no delegate proxy; it overrides close")
    window.performClose(nil)
    XCTAssertEqual(asked, 1)
  }

  @MainActor
  private static func makeSwiftUIStyleWindow() -> NSWindow {
    // A plain NSWindow is the honest stand-in for SwiftUI's `AppKitWindow`:
    // what matters is only that it is NOT a `DocumentWindow`, so it carries no
    // `performClose` override of its own.
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
    return window
  }
}
