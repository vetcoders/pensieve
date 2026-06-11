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
      NSWindow.willCloseNotification,
      NSWindow.didMiniaturizeNotification,
      NSWindow.didEndLiveResizeNotification,
    ]
    return names.map { name in
      NotificationCenter.default.addObserver(
        forName: name, object: nil, queue: nil
      ) { notification in
        guard let window = notification.object as? NSWindow else { return }
        let title = window.title.isEmpty ? "<untitled>" : window.title
        let tabs = window.tabbedWindows?.count ?? 1
        log(
          "\(name.rawValue) '\(title)' alpha=\(window.alphaValue) "
            + "visible=\(window.isVisible) tabs=\(tabs)")
      }
    }
  }
}
