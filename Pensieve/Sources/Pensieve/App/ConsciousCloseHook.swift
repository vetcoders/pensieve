import AppKit
import ObjectiveC.runtime

/// Associated-object key for the proxy the window has to keep alive. Its
/// ADDRESS is the token; the value is never read.
private var consciousCloseProxyKey: UInt8 = 0
/// Associated close state survives delegate replacement. Native tab chrome on
/// macOS 27 calls `close()` directly, so a delegate-only guard is insufficient.
private var consciousCloseStateKey: UInt8 = 0

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
/// SwiftUI's window class cannot be subclassed from here, so the hook covers
/// BOTH native routes. A forwarding delegate proxy answers
/// `windowShouldClose:` for `performClose`, while a class-local bridge protects
/// the terminal `close()` primitive used by native tab chrome. The bridge is
/// scoped per window through associated state; other windows of the same class
/// retain their original behavior.
@MainActor
enum ConsciousCloseHook {
  private static let closeSelector = #selector(NSWindow.close)
  private static var bridgedCloseClasses: Set<ObjectIdentifier> = []

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

    let closeState: ConsciousCloseState
    if let installed = objc_getAssociatedObject(window, &consciousCloseStateKey)
      as? ConsciousCloseState
    {
      installed.shouldClose = shouldClose
      closeState = installed
    } else {
      closeState = ConsciousCloseState(shouldClose: shouldClose)
      objc_setAssociatedObject(
        window, &consciousCloseStateKey, closeState, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
    installCloseBridge(for: window)

    if let installed = window.delegate as? ConsciousCloseDelegateProxy {
      installed.shouldClose = closeState.shouldClose
      return
    }

    let proxy = ConsciousCloseDelegateProxy(
      wrapping: window.delegate, shouldClose: closeState.shouldClose)
    // The window is the proxy's only owner: `NSWindow.delegate` is weak, so an
    // unretained proxy would deallocate on the next turn and the window would
    // silently lose its delegate — SwiftUI's included, since the proxy is what
    // forwards to it.
    objc_setAssociatedObject(
      window, &consciousCloseProxyKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    window.delegate = proxy
  }

  /// Closes a window after Save / Don't Save has already settled. Without the
  /// one-shot bypass, the terminal `close()` bridge would ask the same document
  /// a second time when the async sheet completion tears the tab down.
  static func closeAfterConsent(_ window: NSWindow) {
    if let documentWindow = window as? DocumentWindow {
      documentWindow.closeAfterConsent()
      return
    }
    guard let state = closeState(for: window) else {
      window.close()
      return
    }
    state.armBypassForSynchronousClose()
    window.close()
  }

  /// A `true` returned from the delegate lets AppKit continue from
  /// `performClose` into `close()`. Arm exactly that next primitive so the
  /// class bridge does not evaluate the same decision twice.
  static func armCloseFollowingDelegateConsent(on window: NSWindow) {
    closeState(for: window)?.armBypassForSynchronousClose()
  }

  private static func closeState(for window: NSWindow) -> ConsciousCloseState? {
    objc_getAssociatedObject(window, &consciousCloseStateKey) as? ConsciousCloseState
  }

  private static func installCloseBridge(for window: NSWindow) {
    var cls: AnyClass? = object_getClass(window)
    while let current = cls, NSStringFromClass(current).hasPrefix("NSKVONotifying_") {
      cls = class_getSuperclass(current)
    }
    guard let cls, bridgedCloseClasses.insert(ObjectIdentifier(cls)).inserted else { return }

    let inherited = class_getInstanceMethod(cls, closeSelector).map(method_getImplementation)
    let original = CloseOriginalImplementation()
    let block: @convention(block) (NSWindow) -> Void = { window in
      MainActor.assumeIsolated {
        if let state = closeState(for: window) {
          if state.consumeBypass() {
          } else if !state.shouldClose(window) {
            return
          }
        }
        guard let imp = original.imp else { return }
        let callable = unsafeBitCast(
          imp, to: (@convention(c) (NSWindow, Selector) -> Void).self)
        callable(window, closeSelector)
      }
    }
    let replacement = imp_implementationWithBlock(block)

    if class_addMethod(cls, closeSelector, replacement, "v@:") {
      original.imp = inherited
    } else if let method = class_getInstanceMethod(cls, closeSelector) {
      original.imp = method_setImplementation(method, replacement)
    }
  }
}

private final class ConsciousCloseState {
  var shouldClose: @MainActor (NSWindow) -> Bool
  private var nextBypassID: UInt64?
  private var bypassSequence: UInt64 = 0

  init(shouldClose: @escaping @MainActor (NSWindow) -> Bool) {
    self.shouldClose = shouldClose
  }

  @MainActor
  func armBypassForSynchronousClose() {
    bypassSequence &+= 1
    let bypassID = bypassSequence
    nextBypassID = bypassID
    // `performClose` normally reaches `close()` synchronously. If AppKit
    // consents but does not continue, expire the unused pass on the next main
    // queue turn so a later user action can never inherit it.
    DispatchQueue.main.async { [weak self] in
      guard self?.nextBypassID == bypassID else { return }
      self?.nextBypassID = nil
    }
  }

  @MainActor
  func consumeBypass() -> Bool {
    guard nextBypassID != nil else { return false }
    nextBypassID = nil
    return true
  }
}

private final class CloseOriginalImplementation {
  var imp: IMP?
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
  /// Selectors this proxy has already reported refusing, so the trace names each
  /// one once instead of on every `responds(to:)` AppKit asks.
  private var refusedSelectorNames: Set<String> = []

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
    return MainActor.assumeIsolated {
      let allowed = shouldClose(sender)
      if allowed {
        ConsciousCloseHook.armCloseFollowingDelegateConsent(on: sender)
      }
      return allowed
    }
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
    if argumentCount == 1, !Self.pullStyleOneArgSelectors.contains(name) {
      // The refusal above is invisible from the outside: AppKit simply never
      // registers the observer and the wrapped delegate silently stops hearing
      // that callback. Name it once per selector so a "why did SwiftUI stop
      // getting X" trace has the answer in it instead of a gap. Once, because
      // `responds(to:)` is asked on every delegate-set and every pull-style
      // dispatch.
      if refusedSelectorNames.insert(name).inserted {
        DebugTrace.log(
          "conscious-close.proxy refused claim selector='\(name)' "
            + "claimant='\(wrapped.map { String(describing: type(of: $0)) } ?? "nil")' "
            + "reason=notification-family-one-arg-outlives-weak-delegate")
      }
      return false
    }
    return true
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
