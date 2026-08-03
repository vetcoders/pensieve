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

  override func responds(to aSelector: Selector!) -> Bool {
    if super.responds(to: aSelector) { return true }
    return wrapped?.responds(to: aSelector) ?? false
  }

  override func forwardingTarget(for aSelector: Selector!) -> Any? {
    guard wrapped?.responds(to: aSelector) == true else { return nil }
    return wrapped
  }
}
