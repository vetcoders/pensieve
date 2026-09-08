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
  private(set) var didBecomeKeyNotifications = 0
  private(set) var orderOnScreenNotifications = 0

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    shouldCloseAsks += 1
    return !vetoesClose
  }

  func windowWillClose(_ notification: Notification) {
    willCloseNotifications += 1
  }

  func windowDidBecomeKey(_ notification: Notification) {
    didBecomeKeyNotifications += 1
  }

  // The PRIVATE half of the beta's delegate surface: AppKit's own window
  // delegates implement undocumented order/screen callbacks, and macOS 27
  // posts them through the same snapshot-time observer registration as the
  // public family. This stand-in claims one real private selector and one
  // invented one, so the proxy's claiming policy is testable for both.
  @objc(windowWillOrderOnScreen:) func windowWillOrderOnScreen(_ notification: Notification) {
    orderOnScreenNotifications += 1
  }

  @objc(windowDidFrobnicate:) func windowDidFrobnicate(_ notification: Notification) {}

  func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize { frameSize }

  func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { nil }
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
    defer { ConsciousCloseHook.closeAfterConsent(window) }
    var asked = 0

    ConsciousCloseHook.install(on: window) { _, _ in
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
    defer { ConsciousCloseHook.closeAfterConsent(window) }
    var asked = 0

    ConsciousCloseHook.install(on: window) { _, _ in
      asked += 1
      return false
    }
    window.performClose(nil)

    XCTAssertEqual(asked, 1, "performClose bypassed the conscious close hook")
    XCTAssertNotNil(window.contentView, "a vetoed close must leave the window standing")
  }

  /// Native tab chrome does not consistently send the same message as the red
  /// window button. On the operator's macOS 27 build, AXPress was inert but the
  /// real tab "x" called `close()` directly: the dirty bytes reached the
  /// willClose recovery fallback and the Save / Don't Save / Cancel guard was
  /// never consulted. Protect the terminal close primitive as well as
  /// `performClose` so both AppKit routes have the same contract.
  @MainActor
  func testDirectCloseRoutesASwiftUIStyleWindowThroughTheHook() {
    let window = Self.makeSwiftUIStyleWindow()
    var asked = 0
    var willCloseNotifications = 0
    let token = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { _ in
      willCloseNotifications += 1
    }
    defer { NotificationCenter.default.removeObserver(token) }

    ConsciousCloseHook.install(on: window) { _, _ in
      asked += 1
      return false
    }
    window.close()

    XCTAssertEqual(asked, 1, "a direct native-tab close bypassed the conscious close hook")
    XCTAssertEqual(willCloseNotifications, 0, "a vetoed direct close still tore the window down")
  }

  /// A close that needs no question still evaluates the guard exactly once.
  /// `performClose` reaches `close()` internally, so the delegate consent must
  /// arm a one-shot pass through the terminal bridge rather than running the
  /// save decision twice.
  @MainActor
  func testAllowedPerformCloseAsksOnceAndClosesOnce() {
    let window = Self.makeSwiftUIStyleWindow()
    var asked = 0
    var willCloseNotifications = 0
    let token = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { _ in
      willCloseNotifications += 1
    }
    defer { NotificationCenter.default.removeObserver(token) }

    ConsciousCloseHook.install(on: window) { _, _ in
      asked += 1
      return true
    }
    window.performClose(nil)

    XCTAssertEqual(asked, 1, "performClose evaluated the same close decision twice")
    XCTAssertEqual(willCloseNotifications, 1)
  }

  /// Save / Don't Save has already settled when the controller closes from the
  /// sheet completion. That terminal close must not put up the same question a
  /// second time.
  @MainActor
  func testCloseAfterConsentBypassesExactlyOneGuardPass() {
    let window = Self.makeSwiftUIStyleWindow()
    var asked = 0
    var willCloseNotifications = 0
    let token = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { _ in
      willCloseNotifications += 1
    }
    defer { NotificationCenter.default.removeObserver(token) }

    ConsciousCloseHook.install(on: window) { _, _ in
      asked += 1
      return false
    }
    ConsciousCloseHook.closeAfterConsent(window)

    XCTAssertEqual(asked, 0, "settled sheet completion asked the document again")
    XCTAssertEqual(willCloseNotifications, 1)
  }

  /// A delegate may return consent without AppKit immediately continuing into
  /// `close()`. That abandoned route must not silently authorize a later tab
  /// close; its one-shot pass expires on the next main-queue turn.
  @MainActor
  func testUnusedDelegateConsentCannotBypassALaterDirectClose() async throws {
    let window = Self.makeSwiftUIStyleWindow()
    defer { ConsciousCloseHook.closeAfterConsent(window) }
    var asked = 0

    ConsciousCloseHook.install(on: window) { _, _ in
      asked += 1
      return asked == 1
    }
    XCTAssertEqual(window.delegate?.windowShouldClose?(window), true)

    let mainQueueDrained = expectation(description: "one-shot close consent expired")
    DispatchQueue.main.async { mainQueueDrained.fulfill() }
    await fulfillment(of: [mainQueueDrained], timeout: 1)

    window.close()
    XCTAssertEqual(asked, 2, "an unused delegate consent leaked into a later direct close")
    XCTAssertNotNil(window.contentView, "the later direct close was not vetoed")
  }

  /// The hook is an ADDITION, not a takeover: everything it does not answer
  /// itself still reaches the delegate SwiftUI installed, or the scene loses
  /// its own lifecycle the moment a document window is guarded.
  @MainActor
  func testTheHookKeepsForwardingToTheDelegateItWrapped() {
    let window = Self.makeSwiftUIStyleWindow()
    defer { ConsciousCloseHook.closeAfterConsent(window) }
    let sceneDelegate = SwiftUIStyleWindowDelegate()
    window.delegate = sceneDelegate

    ConsciousCloseHook.install(on: window) { _, _ in true }

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
    defer { ConsciousCloseHook.closeAfterConsent(window) }
    let sceneDelegate = SwiftUIStyleWindowDelegate()
    sceneDelegate.vetoesClose = true
    window.delegate = sceneDelegate
    var asked = 0

    ConsciousCloseHook.install(on: window) { _, _ in
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
    defer { ConsciousCloseHook.closeAfterConsent(window) }
    let sceneDelegate = SwiftUIStyleWindowDelegate()
    window.delegate = sceneDelegate

    ConsciousCloseHook.install(on: window) { _, _ in true }
    let firstProxy = window.delegate
    var secondAsked = 0
    ConsciousCloseHook.install(on: window) { _, _ in
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

  /// The crash pin (0.4.3/684, SIGABRT inside `makeKeyAndOrderFront`): AppKit
  /// registers the delegate as a notification observer for every selector it
  /// claims AT DELEGATE-SET TIME and then dispatches those selectors directly,
  /// with no `responds(to:)` re-check. The proxy's `wrapped` is weak, so a
  /// selector it once claimed must stay callable for the proxy's whole life —
  /// forwarding to a deallocated target is `doesNotRecognizeSelector`.
  @MainActor
  func testAClaimedNotificationSelectorOutlivesTheWrappedDelegate() throws {
    let window = Self.makeSwiftUIStyleWindow()
    defer { ConsciousCloseHook.closeAfterConsent(window) }
    var sceneDelegate: SwiftUIStyleWindowDelegate? = SwiftUIStyleWindowDelegate()
    let becameKey = Notification(name: NSWindow.didBecomeKeyNotification, object: window)

    // The ObjC bridge autoreleases the wrapped delegate on every forwarded
    // call; the pool drains those extra retains so `sceneDelegate = nil` below
    // is a REAL deallocation, not a deferred one.
    let proxy = try autoreleasepool { () -> ConsciousCloseDelegateProxy in
      window.delegate = sceneDelegate
      ConsciousCloseHook.install(on: window) { _, _ in true }
      let proxy = try XCTUnwrap(window.delegate as? ConsciousCloseDelegateProxy)
      XCTAssertEqual(
        proxy.responds(to: #selector(NSWindowDelegate.windowDidBecomeKey(_:))), true,
        "AppKit only registers the observer because the proxy claims the selector")

      proxy.windowDidBecomeKey(becameKey)
      XCTAssertEqual(
        sceneDelegate?.didBecomeKeyNotifications, 1,
        "while the wrapped delegate lives, its lifecycle must keep reaching it")
      return proxy
    }

    sceneDelegate = nil
    XCTAssertNil(proxy.wrapped, "the test proved nothing — the wrapped delegate never deallocated")
    // The notification center's route: raw objc dispatch of the registered
    // selector. Before the fix this aborted the process.
    _ = proxy.perform(#selector(NSWindowDelegate.windowDidBecomeKey(_:)), with: becameKey)
  }

  /// The crash pin (0.4.3/689, SIGABRT inside `makeKeyAndOrderFront` while a
  /// document window attached): the first fix wrote out the PUBLIC
  /// notification family, but the beta also registers the delegate for
  /// PRIVATE one-arg selectors — `windowWillOrderOnScreen:` — and those fell
  /// back to forwarding at a deallocated `wrapped`.
  @MainActor
  func testAPrivateOrderSelectorOutlivesTheWrappedDelegate() throws {
    let window = Self.makeSwiftUIStyleWindow()
    defer { ConsciousCloseHook.closeAfterConsent(window) }
    var sceneDelegate: SwiftUIStyleWindowDelegate? = SwiftUIStyleWindowDelegate()
    let sel = NSSelectorFromString("windowWillOrderOnScreen:")
    let ordered = Notification(
      name: Notification.Name("NSWindowWillOrderOnScreenNotification"), object: window)

    let proxy = try autoreleasepool { () -> ConsciousCloseDelegateProxy in
      window.delegate = sceneDelegate
      ConsciousCloseHook.install(on: window) { _, _ in true }
      let proxy = try XCTUnwrap(window.delegate as? ConsciousCloseDelegateProxy)
      XCTAssertTrue(
        proxy.responds(to: sel),
        "AppKit only registers the observer because the proxy claims the private selector")
      _ = proxy.perform(sel, with: ordered)
      XCTAssertEqual(
        sceneDelegate?.orderOnScreenNotifications, 1,
        "while the wrapped delegate lives, private order callbacks must keep reaching it")
      return proxy
    }

    sceneDelegate = nil
    XCTAssertNil(proxy.wrapped, "the test proved nothing — the wrapped delegate never deallocated")
    // Raw objc dispatch of the registered selector. On 0.4.3(689) this
    // aborted the process.
    _ = proxy.perform(sel, with: ordered)
  }

  /// The class-wide seal: a notification-shaped selector the proxy cannot
  /// serve statically must never be CLAIMED — an unserved claim is a fatal
  /// observer registration waiting for `wrapped` to deallocate. Pull-style
  /// selectors stay claimable: AppKit re-checks `respondsToSelector:` before
  /// each of those calls.
  @MainActor
  func testAnUnknownNotificationShapedSelectorIsNeverClaimed() throws {
    let window = Self.makeSwiftUIStyleWindow()
    defer { ConsciousCloseHook.closeAfterConsent(window) }
    let sceneDelegate = SwiftUIStyleWindowDelegate()
    window.delegate = sceneDelegate

    ConsciousCloseHook.install(on: window) { _, _ in true }
    let proxy = try XCTUnwrap(window.delegate as? ConsciousCloseDelegateProxy)

    let unknown = NSSelectorFromString("windowDidFrobnicate:")
    XCTAssertTrue(sceneDelegate.responds(to: unknown))
    XCTAssertFalse(
      proxy.responds(to: unknown),
      """
      claiming a notification-shaped selector with no static implementation hands AppKit a \
      registration that outlives `wrapped`
      """)

    XCTAssertTrue(
      proxy.responds(to: NSSelectorFromString("windowWillResize:toSize:")),
      "pull-style delegate calls (2+ args) must keep forwarding while the wrapped delegate lives")
    XCTAssertTrue(
      proxy.responds(to: NSSelectorFromString("windowWillReturnUndoManager:")),
      """
      windowWillReturnUndoManager: is pull-style despite its notification shape — blocking it \
      would cost document windows their undo stack
      """)
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
    defer { ConsciousCloseHook.closeAfterConsent(window) }
    var asked = 0
    var willCloseNotifications = 0
    let token = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { _ in
      willCloseNotifications += 1
    }
    defer { NotificationCenter.default.removeObserver(token) }

    ConsciousCloseHook.install(on: window) { _, _ in
      asked += 1
      return false
    }

    XCTAssertNil(window.delegate, "a DocumentWindow needs no delegate proxy; it overrides close")
    window.performClose(nil)
    XCTAssertEqual(asked, 1)
    XCTAssertEqual(willCloseNotifications, 0)

    window.close()
    XCTAssertEqual(asked, 2, "a factory tab's direct close bypassed its own guard")
    XCTAssertEqual(willCloseNotifications, 0)
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
