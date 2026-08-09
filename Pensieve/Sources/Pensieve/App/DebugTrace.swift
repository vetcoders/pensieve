import AppKit
import Foundation

/// Opt-in runtime tracing for diagnosing window/document flow issues.
/// Enabled with `PENSIEVE_TRACE=1` in the environment; a release build with
/// the flag unset pays a single cached bool check per call site.
enum DebugTrace {
  static let isEnabled = ProcessInfo.processInfo.environment["PENSIEVE_TRACE"] == "1"

  static func log(_ message: @autoclosure () -> String) {
    guard isEnabled else { return }
    NSLog("%@", "[pensieve-trace] \(message())")
  }

  /// Stable-enough identity and ownership facts for reconstructing the first
  /// bad AppKit transition. The object address distinguishes two native
  /// surfaces that reused a title; `windowNumber` joins the app trace to AX,
  /// CGWindow/WindowServer evidence and screenshots captured in the same run.
  @MainActor
  static func windowSnapshot(_ window: NSWindow) -> String {
    let objectID = String(describing: ObjectIdentifier(window))
    let className = String(describing: type(of: window))
    let title = window.title.isEmpty ? "<untitled>" : window.title
    let parent = window.parent.map { String($0.windowNumber) } ?? "nil"
    let sheetParent = window.sheetParent.map { String($0.windowNumber) } ?? "nil"
    let attachedSheet = window.attachedSheet.map { String($0.windowNumber) } ?? "nil"
    let tabGroup = window.tabGroup.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
    let selected = window.tabGroup?.selectedWindow.map { String($0.windowNumber) } ?? "nil"
    let tabs = (window.tabbedWindows ?? [window]).map(\.windowNumber)
    return
      "object=\(objectID) number=\(window.windowNumber) class=\(className) title='\(title)' "
      + "frame=\(NSStringFromRect(window.frame)) level=\(window.level.rawValue) "
      + "visible=\(window.isVisible) key=\(window.isKeyWindow) main=\(window.isMainWindow) "
      + "alpha=\(window.alphaValue) parent=\(parent) sheetParent=\(sheetParent) "
      + "attachedSheet=\(attachedSheet) tabMode=\(window.tabbingMode.rawValue) "
      + "tabID='\(window.tabbingIdentifier)' tabGroup=\(tabGroup) selected=\(selected) tabs=\(tabs)"
  }

  @MainActor
  static func logWindowEvent(_ event: String, window: NSWindow) {
    guard isEnabled else { return }
    let key = NSApp.keyWindow.map { String($0.windowNumber) } ?? "nil"
    let main = NSApp.mainWindow.map { String($0.windowNumber) } ?? "nil"
    let modal = NSApp.modalWindow.map { String($0.windowNumber) } ?? "nil"
    log(
      "window-event=\(event) pid=\(ProcessInfo.processInfo.processIdentifier) "
        + "appKey=\(key) appMain=\(main) appModal=\(modal) \(windowSnapshot(window))")
  }

  @MainActor
  static func logWindowMutation(
    _ event: String,
    owner: NSWindow,
    member: NSWindow
  ) {
    guard isEnabled else { return }
    logWindowEvent("\(event).owner", window: owner)
    logWindowEvent("\(event).member", window: member)
  }

  @MainActor
  static func logWindowGraph(_ event: String) {
    guard isEnabled else { return }
    let windows = NSApp.windows
    log("window-graph=\(event) count=\(windows.count)")
    for window in windows {
      logWindowEvent("\(event).graph", window: window)
    }
  }

  /// Subscribes to the window lifecycle notifications that matter when
  /// chasing phantom windows, tab merges, and focus problems. Returns the
  /// observer tokens so the caller keeps them alive.
  @MainActor
  static func installWindowLifecycleObservers() -> [NSObjectProtocol] {
    guard isEnabled else { return [] }
    let names: [Notification.Name] = [
      NSWindow.didBecomeKeyNotification,
      NSWindow.didBecomeMainNotification,
      NSWindow.didResignKeyNotification,
      NSWindow.didResignMainNotification,
      NSWindow.willBeginSheetNotification,
      NSWindow.didEndSheetNotification,
      NSWindow.willCloseNotification,
      NSWindow.didMiniaturizeNotification,
      NSWindow.didMoveNotification,
      NSWindow.didResizeNotification,
      NSWindow.didEndLiveResizeNotification,
    ]
    return names.map { name in
      NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: nil
      ) { notification in
        guard let window = notification.object as? NSWindow else { return }
        MainActor.assumeIsolated {
          logWindowEvent(name.rawValue, window: window)
        }
      }
    }
  }
}
