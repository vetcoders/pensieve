import Foundation

/// The session a window must ALREADY carry when its SwiftUI root first renders,
/// decided from the intent that window was built with.
///
/// A "+" / ⌘T / ⌘N tab is built, merged into its source tab group and ordered
/// front inside ONE main-actor turn (`DocumentWindowRegistry.newUntitledTab`).
/// Its untitled draft used to arrive several run-loop turns later — root cold
/// start → `LaunchIntentCoordinator.startWhenLaunchIntentsSettle` → `Task` hop →
/// `AppController.start(.newUntitledTab)` — and under load that gap is seconds.
/// The user watched a launcher tab titled "Pensieve" appear between two
/// Untitled.md tabs and could click New File / Open File / RECENT inside it.
///
/// So the draft is seeded where the window is CONSTRUCTED, on the same clock as
/// the presentation. `AppController.start` still asks for it: the seed is
/// idempotent, so whichever of the two runs first owns the draft and the other
/// is a no-op — which is also what keeps async workspace hydration from
/// replacing a buffer the user may already be typing into.
///
/// This is not the app creating an untitled buffer on its own: "+" / ⌘T / ⌘N IS
/// the user action, and the lifecycle contract promises exactly one editable
/// Untitled.md for it.
@MainActor
enum NewTabSessionSeed {
  /// Whether a window built for `intent` owes its first render an editable
  /// untitled draft. A window built FOR a document loads that document instead,
  /// and every other intent legitimately starts on the launcher surface.
  static func seedsUntitledDraft(intent: LaunchIntent, initialDocument: DocumentRef?) -> Bool {
    initialDocument == nil && intent == .newUntitledTab
  }

  @discardableResult
  static func seedIfNeeded(
    controller: AppController,
    intent: LaunchIntent,
    initialDocument: DocumentRef?
  ) -> Bool {
    guard seedsUntitledDraft(intent: intent, initialDocument: initialDocument) else { return false }
    return controller.seedUntitledDraftForNewTab()
  }
}
