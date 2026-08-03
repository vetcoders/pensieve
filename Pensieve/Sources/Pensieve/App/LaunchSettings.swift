import Foundation
import Observation

/// The app-wide restore-on-launch preference (Settings ▸ General).
///
/// Governs exactly ONE thing: whether a genuine cold launch (the process just
/// started, no explicit document) rebuilds the previous workspace and reopens
/// its documents. Persisted workspace bookmarks are never touched by this
/// setting — turning it off only skips auto-opening them on a cold launch;
/// turning it back on picks them up again on the next one. Dock reopen, the
/// tab bar's "+", and any explicit open/restore action are different
/// `LaunchIntent` cases and are not affected by this setting at all.
@Observable
@MainActor
final class LaunchSettings {
  static let shared = LaunchSettings()

  /// The default the app registers for a first launch: restore ON — today's
  /// behavior, unchanged for existing users.
  static let restoreSessionOnLaunchDefault = true

  private static let restoreSessionOnLaunchKey = "Pensieve.restoreSessionOnLaunch"

  private let defaults: UserDefaults

  var restoreSessionOnLaunch: Bool {
    didSet {
      defaults.set(restoreSessionOnLaunch, forKey: Self.restoreSessionOnLaunchKey)
    }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // An absent key is a first launch, not "off": `bool(forKey:)` would read a
    // missing value as false and silently ship the opposite default.
    if defaults.object(forKey: Self.restoreSessionOnLaunchKey) == nil {
      self.restoreSessionOnLaunch = Self.restoreSessionOnLaunchDefault
    } else {
      self.restoreSessionOnLaunch = defaults.bool(forKey: Self.restoreSessionOnLaunchKey)
    }
  }
}
