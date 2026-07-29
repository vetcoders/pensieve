import AppKit
import SwiftUI

/// NSWindow subclass for document windows. Implementing `newWindowForTab(_:)`
/// makes the native tab bar show its "+" button; the handler routes through
/// the registry so the new untitled tab joins this window's tab group instead
/// of spawning a detached standalone window (the system default).
final class DocumentWindow: NSWindow {
  var onNewWindowForTab: ((NSWindow) -> Void)?
  var onClose: ((NSWindow) -> Void)?

  override func newWindowForTab(_ sender: Any?) {
    DebugTrace.log("newWindowForTab '\(title)'")
    onNewWindowForTab?(self)
  }

  override func close() {
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
    }
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
  /// supports that the same way the WindowGroup scene does.
  func makeWindow(for document: DocumentRef?) -> NSWindow {
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
    window.onNewWindowForTab = { sourceWindow in
      DocumentWindowRegistry.shared.newUntitledTab(from: sourceWindow)
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
      initialDocument: document
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
