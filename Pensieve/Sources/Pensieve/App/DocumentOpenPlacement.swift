import AppKit

/// Where a newly opened document belongs relative to the current document window.
///
/// The policy is deliberately separate from window creation and tab attachment so
/// callers can decide placement without changing UI or document-session state.
enum DocumentOpenPlacement: Equatable {
  case tabIn
  case newWindow

  /// Resolves an injected System Settings preference without reading global state.
  static func resolve(
    preference: NSWindow.UserTabbingPreference,
    sourceIsFullScreen: Bool,
    hasSourceWindow: Bool
  ) -> DocumentOpenPlacement {
    guard hasSourceWindow else { return .newWindow }

    switch preference {
    case .manual:
      return .newWindow
    case .always:
      return .tabIn
    case .inFullScreen:
      return sourceIsFullScreen ? .tabIn : .newWindow
    @unknown default:
      return .newWindow
    }
  }

  /// Reads the source window's shape — "is there one, and is it full screen?" —
  /// and answers with the injected preference.
  ///
  /// Split out of `resolve(for:)` so a test can state the System Settings mode
  /// WITHOUT restating how a window maps onto the policy's two booleans. The
  /// matrix verifiers drive this exact entry point, which is why a test cannot
  /// pass by hardcoding the placement it expects.
  @MainActor
  static func resolve(
    preference: NSWindow.UserTabbingPreference,
    sourceWindow: NSWindow?
  ) -> DocumentOpenPlacement {
    resolve(
      preference: preference,
      sourceIsFullScreen: sourceWindow?.styleMask.contains(.fullScreen) == true,
      hasSourceWindow: sourceWindow != nil
    )
  }

  /// Resolves placement from the live macOS preference for each New gesture.
  ///
  /// `NSWindow.userTabbingPreference` is intentionally read on every call so a
  /// System Settings change takes effect without relaunching Pensieve.
  @MainActor
  static func resolve(for sourceWindow: NSWindow?) -> DocumentOpenPlacement {
    resolve(preference: NSWindow.userTabbingPreference, sourceWindow: sourceWindow)
  }
}
