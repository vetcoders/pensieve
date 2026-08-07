import AppKit
import ObjectiveC.runtime

/// Associated-object key for the proxy the window has to keep alive. Its
/// ADDRESS is the token; the value is never read.
private var consciousCloseProxyKey: UInt8 = 0

/// Gives EVERY document-bearing window the conscious close lifecycle — the red
/// close button and a tab's "×" ask `Save / Don't Save / Cancel` on unsaved
/// work, exactly like ⌘W.
///
/// Two window classes carry documents in production and only one of them is
/// ours. `DocumentWindow` (the AppKit factory's tabs) overrides `performClose`
/// and exposes `onShouldClose`. The other is `SwiftUI.AppKitWindow` — verified
/// at runtime on macOS 26 (Darwin 25.6), debug build, 2026-08-03: the window
/// SwiftUI auto-presents for the launcher `WindowGroup` at every cold start
/// reports `class=AppKitWindow isDocumentWindow=false
/// delegate=AppKitWindowController`. That window is not a rare restored-scene
/// edge case: it is the FIRST window of every launch, the one
/// `reopenRestoredOpenFiles` loads the first restored file into, the one a
/// cold-start Finder open is reused for, and the one ⌘N types an untitled draft
/// into. Before this hook it fell through to the teardown guard, which can only
/// stash a recovery draft — the user closed a dirty window and got a "Recovered
/// Drafts" row instead of the question.
///
/// SwiftUI's window class cannot be subclassed from here, so the hook goes on
/// the delegate instead: a forwarding proxy that answers `windowShouldClose:`
/// itself and passes every other message straight through to the delegate
/// SwiftUI installed.
@MainActor
enum ConsciousCloseHook {
  /// Installs — or refreshes — the conscious close hook on `window`.
  ///
  /// Idempotent by design and safe to call on every accessor pass: SwiftUI is
  /// free to re-assign `window.delegate` during a scene update, and re-running
  /// this re-wraps whatever is there now instead of leaving the window
  /// unguarded.
  static func install(
    on window: NSWindow,
    shouldClose: @escaping @MainActor (NSWindow) -> Bool
  ) {
    if let documentWindow = window as? DocumentWindow {
      documentWindow.onShouldClose = shouldClose
      return
    }

    if let installed = window.delegate as? ConsciousCloseDelegateProxy {
      installed.shouldClose = shouldClose
      return
    }

    let proxy = ConsciousCloseDelegateProxy(
      wrapping: window.delegate, shouldClose: shouldClose)
    // The window is the proxy's only owner: `NSWindow.delegate` is weak, so an
    // unretained proxy would deallocate on the next turn and the window would
    // silently lose its delegate — SwiftUI's included, since the proxy is what
    // forwards to it.
    objc_setAssociatedObject(
      window, &consciousCloseProxyKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    window.delegate = proxy
  }
}

/// `NSWindowDelegate` shim that adds `windowShouldClose:` to a window whose
/// delegate belongs to someone else.
///
/// Everything it does not implement itself is forwarded to `wrapped` through
/// `responds(to:)` + `forwardingTarget(for:)`, so SwiftUI's own delegate keeps
/// receiving the full lifecycle it expects. `wrapped` is WEAK on purpose:
/// `NSWindow.delegate` is a weak reference, so SwiftUI must already own its
/// controller elsewhere — retaining it here would only risk a cycle through the
/// window the controller holds.
final class ConsciousCloseDelegateProxy: NSObject, NSWindowDelegate {
  var shouldClose: @MainActor (NSWindow) -> Bool
  weak var wrapped: NSWindowDelegate?

  init(wrapping wrapped: NSWindowDelegate?, shouldClose: @escaping @MainActor (NSWindow) -> Bool) {
    self.wrapped = wrapped
    self.shouldClose = shouldClose
  }

  /// The veto point. The wrapped delegate is asked FIRST — a `false` from
  /// SwiftUI is a refusal this app has no business overturning — and only a
  /// window it is willing to close reaches the session's own dirty guard.
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if let wrapped, wrapped.responds(to: #selector(NSWindowDelegate.windowShouldClose(_:))),
      wrapped.windowShouldClose?(sender) == false
    {
      return false
    }
    // AppKit only ever asks this on the main thread; the hop exists because the
    // proxy itself cannot be actor-isolated (`responds(to:)` is not).
    return MainActor.assumeIsolated { shouldClose(sender) }
  }

  /// One-arg `windowWill*`/`windowDid*` selectors that are NOT snapshot-time
  /// observer registrations: AppKit pulls these per call, re-checking
  /// `respondsToSelector:` first, so forwarding stays safe for them and
  /// refusing to claim them would silently cost real behavior (the undo
  /// manager provider above all).
  private static let pullStyleOneArgSelectors: Set<String> = [
    "windowWillReturnUndoManager:",
    "windowDidFailToEnterFullScreen:",
    "windowDidFailToExitFullScreen:",
  ]

  override func responds(to aSelector: Selector!) -> Bool {
    if super.responds(to: aSelector) { return true }
    guard wrapped?.responds(to: aSelector) == true else { return false }
    // AppKit turns every one-argument `windowWill*`/`windowDid*` selector the
    // delegate claims into a notification-observer registration made ONCE, at
    // delegate-set time — and that registration outlives the weak `wrapped`.
    // Every such selector this proxy can serve is implemented statically
    // below (so `super.responds` already said yes). Claiming any OTHER one
    // hands AppKit a registration with no receiver left once `wrapped`
    // deallocates: 0.4.3(689) died exactly there, on the beta's private
    // `windowWillOrderOnScreen:` posted from `makeKeyAndOrderFront`. Unknown
    // notification-shaped selectors are therefore never claimed — losing an
    // exotic callback is recoverable, a SIGABRT is not. Pull-style calls
    // (2+ args, or the listed one-arg exceptions) keep forwarding.
    let name = NSStringFromSelector(aSelector)
    guard name.hasPrefix("windowWill") || name.hasPrefix("windowDid") else { return true }
    let argumentCount = name.reduce(into: 0) { if $1 == ":" { $0 += 1 } }
    return argumentCount != 1 || Self.pullStyleOneArgSelectors.contains(name)
  }

  override func forwardingTarget(for aSelector: Selector!) -> Any? {
    guard wrapped?.responds(to: aSelector) == true else { return nil }
    return wrapped
  }

  // MARK: - Notification family — written out, never left to forwarding
  //
  // AppKit snapshots `responds(to:)` ONCE, when this proxy becomes the
  // window's delegate, and registers the proxy as a notification OBSERVER for
  // every `windowDid*`/`windowWill*` selector it claimed. That registration
  // outlives the answer: `wrapped` is weak, and once it deallocates a
  // claimed-but-unimplemented selector arrives with no forwarding target left,
  // which is `doesNotRecognizeSelector` — a SIGABRT in the middle of
  // `makeKeyAndOrderFront`. Pull-style delegate methods can stay on the
  // forwarding path because AppKit re-checks `respondsToSelector:` right
  // before each of those calls; the notification family cannot, so every
  // member is implemented here as a forward-if-alive no-op-otherwise.

  func windowDidBecomeKey(_ n: Notification) { wrapped?.windowDidBecomeKey?(n) }
  func windowDidResignKey(_ n: Notification) { wrapped?.windowDidResignKey?(n) }
  func windowDidBecomeMain(_ n: Notification) { wrapped?.windowDidBecomeMain?(n) }
  func windowDidResignMain(_ n: Notification) { wrapped?.windowDidResignMain?(n) }
  func windowWillClose(_ n: Notification) { wrapped?.windowWillClose?(n) }
  func windowWillMove(_ n: Notification) { wrapped?.windowWillMove?(n) }
  func windowDidMove(_ n: Notification) { wrapped?.windowDidMove?(n) }
  func windowDidResize(_ n: Notification) { wrapped?.windowDidResize?(n) }
  func windowWillStartLiveResize(_ n: Notification) { wrapped?.windowWillStartLiveResize?(n) }
  func windowDidEndLiveResize(_ n: Notification) { wrapped?.windowDidEndLiveResize?(n) }
  func windowWillMiniaturize(_ n: Notification) { wrapped?.windowWillMiniaturize?(n) }
  func windowDidMiniaturize(_ n: Notification) { wrapped?.windowDidMiniaturize?(n) }
  func windowDidDeminiaturize(_ n: Notification) { wrapped?.windowDidDeminiaturize?(n) }
  func windowDidExpose(_ n: Notification) { wrapped?.windowDidExpose?(n) }
  func windowDidChangeScreen(_ n: Notification) { wrapped?.windowDidChangeScreen?(n) }
  func windowDidChangeScreenProfile(_ n: Notification) { wrapped?.windowDidChangeScreenProfile?(n) }
  func windowDidChangeBackingProperties(_ n: Notification) {
    wrapped?.windowDidChangeBackingProperties?(n)
  }
  func windowDidUpdate(_ n: Notification) { wrapped?.windowDidUpdate?(n) }
  func windowWillBeginSheet(_ n: Notification) { wrapped?.windowWillBeginSheet?(n) }
  func windowDidEndSheet(_ n: Notification) { wrapped?.windowDidEndSheet?(n) }
  func windowDidChangeOcclusionState(_ n: Notification) {
    wrapped?.windowDidChangeOcclusionState?(n)
  }
  func windowWillEnterFullScreen(_ n: Notification) { wrapped?.windowWillEnterFullScreen?(n) }
  func windowDidEnterFullScreen(_ n: Notification) { wrapped?.windowDidEnterFullScreen?(n) }
  func windowWillExitFullScreen(_ n: Notification) { wrapped?.windowWillExitFullScreen?(n) }
  func windowDidExitFullScreen(_ n: Notification) { wrapped?.windowDidExitFullScreen?(n) }
  func windowWillEnterVersionBrowser(_ n: Notification) {
    wrapped?.windowWillEnterVersionBrowser?(n)
  }
  func windowDidEnterVersionBrowser(_ n: Notification) { wrapped?.windowDidEnterVersionBrowser?(n) }
  func windowWillExitVersionBrowser(_ n: Notification) { wrapped?.windowWillExitVersionBrowser?(n) }
  func windowDidExitVersionBrowser(_ n: Notification) { wrapped?.windowDidExitVersionBrowser?(n) }

  // MARK: - Private order/screen family (macOS 26/27 beta)
  //
  // Outside the public protocol, same snapshot-time registration trap:
  // 0.4.3(689) aborted on `windowWillOrderOnScreen:` posted from
  // `makeKeyAndOrderFront` while a document window attached. These are not in
  // `NSWindowDelegate`, so forwarding goes through `perform` — if-alive,
  // no-op otherwise.

  @objc(windowWillOrderOnScreen:) func windowWillOrderOnScreen(_ n: Notification) {
    forwardPrivateNotification("windowWillOrderOnScreen:", n)
  }
  @objc(windowDidOrderOnScreen:) func windowDidOrderOnScreen(_ n: Notification) {
    forwardPrivateNotification("windowDidOrderOnScreen:", n)
  }
  @objc(windowWillOrderOffScreen:) func windowWillOrderOffScreen(_ n: Notification) {
    forwardPrivateNotification("windowWillOrderOffScreen:", n)
  }
  @objc(windowDidOrderOffScreen:) func windowDidOrderOffScreen(_ n: Notification) {
    forwardPrivateNotification("windowDidOrderOffScreen:", n)
  }

  private func forwardPrivateNotification(_ name: String, _ n: Notification) {
    let sel = NSSelectorFromString(name)
    guard let wrapped, wrapped.responds(to: sel) else { return }
    _ = wrapped.perform(sel, with: n)
  }
}
