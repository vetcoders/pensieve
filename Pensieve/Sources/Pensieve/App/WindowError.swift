import Foundation

/// How badly a window's most recent error hurts, which is the ONE thing that
/// decides how loudly it is surfaced.
///
/// The line is deliberately narrow, because a surface that shouts at everything
/// is a surface nobody reads:
///
///   * `.status` — an action was refused, a read failed, or a piece of
///     housekeeping did not land. Nothing the user typed is at risk of
///     vanishing: the file on disk is intact, or the content lives somewhere
///     durable already. Almost every error in the app is this.
///   * `.dataLoss` — the app failed to put the user's content anywhere durable
///     AND the only remaining copy is the in-memory buffer. Losing the process
///     loses the work. It is dressed more loudly and, unlike a status message,
///     it LATCHES: `DocumentWindowModel.unresolvedDataLoss` outlives both the
///     banner and any later routine message, and only a durable write retires
///     it.
///
/// Classified at the WRITE SITE, never by matching on the message text: the
/// site is the only place that knows whether a durable copy survived the
/// failure. `.status` is the default precisely so that a new error has to be
/// argued INTO the loud class rather than falling into it by accident.
enum WindowErrorSeverity: Equatable {
  case status
  case dataLoss
}

/// A window's most recent error, with the severity that decides how it shows.
///
/// Per WINDOW, not per app — it lives on `DocumentWindowModel`, so an error
/// raised while saving in one window can never appear in the chrome of another
/// one that is working on a different document.
struct WindowError: Equatable {
  let message: String
  let severity: WindowErrorSeverity

  static func status(_ message: String) -> WindowError {
    WindowError(message: message, severity: .status)
  }

  static func dataLoss(_ message: String) -> WindowError {
    WindowError(message: message, severity: .dataLoss)
  }

  var isDataLoss: Bool { severity == .dataLoss }
}

/// What the window chrome must show for a given state, resolved as a VALUE so
/// the decision is testable without standing up a view hierarchy.
///
/// `WindowErrorBanner` renders exactly this and decides nothing of its own —
/// the same split `EmptyStatePalette` and `WindowChromeRecipe` already use for
/// chrome that has to be provable.
enum WindowErrorSurface: Equatable {
  /// Nothing to report.
  case none
  /// A passive line in the chrome. Both severities show one and only one — the
  /// app has no modal error surface at all; severity changes the dressing, not
  /// whether the user is interrupted.
  case banner(WindowError)

  static func resolve(for error: WindowError?) -> WindowErrorSurface {
    guard let error else { return .none }
    return .banner(error)
  }

  var error: WindowError? {
    switch self {
    case .none: return nil
    case .banner(let error): return error
    }
  }

  var showsBanner: Bool { self != .none }
}
