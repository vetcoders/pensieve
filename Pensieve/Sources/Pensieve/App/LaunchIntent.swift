import Foundation

/// Why a window is starting up — assigned at the point the window/scene is
/// created and carried WITH that window, never stored process-wide.
///
/// The predecessor was a single sticky `hasExplicitURLIntent` boolean on
/// `LaunchIntentCoordinator`: once a session had been launched by opening a
/// file from the Finder it stayed `true` for the whole process, so two visually
/// identical sessions restored differently for the rest of their lives. Intent
/// is a property of ONE launch, so it lives on the launch.
///
/// The four cases are the four ways a window with no document of its own comes
/// into existence; each one answers the restore question below.
///
/// Two things are deliberately NOT questions here. Picking a document is not:
/// restoration re-selects only what a window already showed and never chooses
/// one for the user, on any intent (`selectRestoredDocument`). Claiming a
/// crash-recovery draft is not either: no intent adopts a draft. W2-D moved
/// recovery to the launcher's explicit "Recovered Drafts" section, so a draft is
/// only ever opened because the user pointed at it.
enum LaunchIntent: Equatable, Sendable {
  /// The process just started with no explicit document — the only intent that
  /// brings the previous session back in full.
  case coldLaunch

  /// The app puts a launcher back while the process keeps running: the Dock
  /// icon clicked with no visible windows, or the registry re-opening one after
  /// the last content window closed. Both mean the user consciously emptied the
  /// app; the workspace comes back, the documents do not.
  case dockReopen

  /// The tab bar's "+" — a new, deliberately empty tab.
  case newUntitledTab

  /// The window exists FOR a specific document (Finder/`open` URL, a document
  /// tab from the registry, a state-restored document scene).
  case explicitDocument

  /// Whether this launch rebuilds the workspace (roots, tree, sidebar) from the
  /// persisted bookmarks. A window opened for a document shows that document
  /// and nothing else.
  var restoresWorkspace: Bool {
    switch self {
    case .coldLaunch, .dockReopen, .newUntitledTab: return true
    case .explicitDocument: return false
    }
  }
}
