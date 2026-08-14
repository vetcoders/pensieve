import AppKit
import SwiftUI

/// Pensieve's working set and `LaunchSettings` are the only session restore
/// authority. Managed windows must never be serialized by AppKit Saved
/// Application State, otherwise a second owner can resurrect documents that the
/// user disabled or already closed in Pensieve.
@MainActor
enum ManagedWindowRestoration {
  static func disable(on window: NSWindow) {
    window.isRestorable = false
  }
}

/// NSWindow subclass for document windows. Implementing `newWindowForTab(_:)`
/// makes the native tab bar show its "+" button; the handler routes through
/// the registry so the new untitled tab joins this window's tab group instead
/// of spawning a detached standalone window (the system default).
final class DocumentWindow: NSWindow {
  var onNewWindowForTab: ((NSWindow) -> Void)?
  var onClose: ((NSWindow) -> Void)?
  /// Consulted before the red close button or a tab's "×" tears this window
  /// down, with WHICH of the two is asking. Returns true to let AppKit proceed,
  /// false to keep the window — the handler may then run its own async Save /
  /// Don't Save / Cancel sheet and close the window later once the answer
  /// lands, or (for a tab "×" on the last tab) retire the document and leave
  /// the window on its empty state.
  var onShouldClose: ((NSWindow, WindowCloseGesture) -> Bool)?
  private var bypassNextCloseCheck = false

  override func newWindowForTab(_ sender: Any?) {
    DebugTrace.log("newWindowForTab '\(title)'")
    onNewWindowForTab?(self)
  }

  /// The red close button and a tab's "×" both route through `performClose`.
  /// Give this window's controller the same conscious close lifecycle ⌘W has:
  /// `onShouldClose` returns false to keep the window (a sheet is now up, the
  /// user cancelled, or the "×" retired the document into the window's empty
  /// state) and true to let AppKit tear it down. ⌘W does NOT arrive here — the
  /// File ▸ Close menu item owns that key and runs `closeActiveDocument`
  /// directly — so there is no double prompt.
  ///
  /// Measured on macOS 27.0 (two-window probe, native tab group): NEITHER
  /// affordance actually lands here any more — the native tab chrome drives the
  /// terminal `close()` primitive directly for both the "×" and the red button.
  /// The override stays because it is still the documented route (and the one
  /// `Shift+Cmd+W` and older systems take), which is why the gesture is
  /// classified in BOTH entry points rather than in this one.
  override func performClose(_ sender: Any?) {
    if let onShouldClose, !onShouldClose(self, currentCloseGesture()) { return }
    // `super.performClose` reaches our `close()` synchronously. The decision
    // above already consented, so the terminal primitive must consume this
    // one-shot pass instead of asking twice.
    bypassNextCloseCheck = true
    super.performClose(sender)
    bypassNextCloseCheck = false
  }

  /// Which affordance is asking, read from the event AppKit is dispatching at
  /// this instant. Both close entry points are reached SYNCHRONOUSLY from that
  /// dispatch, so `NSApp.currentEvent` is still the click that caused them.
  private func currentCloseGesture() -> WindowCloseGesture {
    WindowChromeRecipe.closeGesture(closing: self, event: NSApp.currentEvent)
  }

  override func close() {
    if bypassNextCloseCheck {
      bypassNextCloseCheck = false
    } else if let onShouldClose, !onShouldClose(self, currentCloseGesture()) {
      return
    }
    DebugTrace.log("DocumentWindow.close '\(title)'")
    onClose?(self)
    super.close()
    // Break the retain cycle window -> NSHostingView -> SwiftUI view graph
    // (@State currentWindow) -> window. With isReleasedWhenClosed = false ARC
    // owns the window; without this teardown every closed tab leaks its
    // window plus the per-window AppState/AppController stack, and the
    // registry mapping would resurrect the closed window as a zombie.
    //
    // The teardown MUST be deferred one runloop turn: closing a tabbed window
    // triggers AppKit's tab-group reshuffle (neighbor selection, host
    // re-parenting), and ripping the content view out synchronously mid-dance
    // leaves a half-dead ghost window on screen (visible, unmovable, invalid
    // for accessibility) and can re-host sibling tabs into phantom windows.
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.contentView = nil
      self.onNewWindowForTab = nil
      self.onClose = nil
      self.onShouldClose = nil
    }
  }

  func closeAfterConsent() {
    bypassNextCloseCheck = true
    close()
  }
}

/// Builds document windows DIRECTLY in AppKit, hosting the same per-window
/// SwiftUI root the WindowGroup scene uses. The factory NEVER shows the
/// window: the registry attaches it as a native tab BEFORE it is ever ordered
/// on screen, so the half-built standalone-window flash of the old
/// `openWindow(value:)` path is impossible by construction.
@MainActor
struct DocumentWindowFactory {
  let workspaceStore: WorkspaceStore
  let launchIntentCoordinator: LaunchIntentCoordinator
  let themeManager: ThemeManager

  /// `document == nil` builds an untitled (launcher-mode) tab — the root view
  /// supports that the same way the WindowGroup scene does. `intent` is baked
  /// into the root view here, at the moment the window is created, so the
  /// window's later (async) startup restores exactly what THIS launch asked
  /// for.
  func makeWindow(for document: DocumentRef?, intent: LaunchIntent) -> NSWindow {
    let visibleFrame = NSScreen.main?.visibleFrame
    let contentRect =
      visibleFrame.map { WindowChromeRecipe.factoryInitialFrame(in: $0) }
      ?? WindowChromeRecipe.defaultContentRect
    let window = DocumentWindow(
      contentRect: contentRect,
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false)
    WindowChromeRecipe.apply(to: window, title: document?.title ?? "Untitled")
    ManagedWindowRestoration.disable(on: window)
    window.onNewWindowForTab = { sourceWindow in
      // ONE call, to the ONE deterministic tab-creation path — the same route
      // scene-owned windows reach through `DocumentWindowTabBridge`.
      DocumentWindowRegistry.shared.newDocumentForTab(from: sourceWindow)
    }
    window.onClose = { closedWindow in
      DocumentWindowRegistry.shared.handleWindowClosed(
        closedWindow,
        tombstonePolicy: .factoryWindow)
    }

    let rootView = DocumentWindowRootView(
      workspaceStore: workspaceStore,
      launchIntentCoordinator: launchIntentCoordinator,
      themeManager: themeManager,
      initialDocument: document,
      launchIntent: intent
    )
    let hostingView = NSHostingView(rootView: rootView)
    if #available(macOS 14.0, *) {
      // Bridge the root view's SwiftUI `.toolbar` content and navigation
      // title into this AppKit window; outside a WindowGroup scene they do
      // not materialize otherwise.
      hostingView.sceneBridgingOptions = [.toolbars, .title]
    }
    window.contentView = hostingView
    if visibleFrame == nil {
      window.center()
    }
    DebugTrace.log("factory created window for \(document?.id.lastPathComponent ?? "untitled")")
    return window
  }
}
