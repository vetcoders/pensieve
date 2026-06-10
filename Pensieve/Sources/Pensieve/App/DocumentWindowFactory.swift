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
    contentView = nil
    onNewWindowForTab = nil
    onClose = nil
  }
}

/// Builds document windows DIRECTLY in AppKit, hosting the same per-window
/// SwiftUI root the WindowGroup scene uses. The factory NEVER shows the
/// window: the registry attaches it as a native tab BEFORE it is ever ordered
/// on screen, so the half-built standalone-window flash of the old
/// `openWindow(value:)` path is impossible by construction.
@MainActor
struct DocumentWindowFactory {
  static let documentTabbingIdentifier = "Pensieve.DocumentWindow"

  let workspaceStore: WorkspaceStore
  let launchIntentCoordinator: LaunchIntentCoordinator
  let themeManager: ThemeManager

  /// `document == nil` builds an untitled (launcher-mode) tab — the root view
  /// supports that the same way the WindowGroup scene does.
  func makeWindow(for document: DocumentRef?) -> NSWindow {
    let window = DocumentWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
      // Matches the SwiftUI WindowGroup windows (.windowStyle(.titleBar) with
      // a unified toolbar) so a factory window is indistinguishable as a tab.
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    // ARC owns the single reference; AppKit retains the window while it is on
    // screen / in a tab group. The default (true) would double-release.
    window.isReleasedWhenClosed = false
    window.toolbarStyle = .unified
    window.tabbingMode = .preferred
    window.tabbingIdentifier = Self.documentTabbingIdentifier
    // Placeholder until the scene's first registry attach sets the real title.
    window.title = document?.title ?? "Untitled"
    window.contentMinSize = NSSize(width: 720, height: 480)
    window.onNewWindowForTab = { sourceWindow in
      DocumentWindowRegistry.shared.newUntitledTab(from: sourceWindow)
    }
    window.onClose = { closedWindow in
      DocumentWindowRegistry.shared.handleDocumentWindowClosed(closedWindow)
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
    window.center()
    DebugTrace.log("factory created window for \(document?.id.lastPathComponent ?? "untitled")")
    return window
  }
}
