import Foundation

/// Which of the three surfaces a document window is showing, and what the
/// window title says while it does.
///
/// Extracted out of `ContentView` because this is the decision the new-tab
/// lifecycle turns on: a window whose session has not materialized yet resolves
/// to `.launcher` and the literal title "Pensieve", which is what a "+" tab
/// rendered — a full launcher (New File / Open File / RECENT) sitting between
/// two Untitled.md tabs — for as long as its SwiftUI root took to cold-start.
/// Keeping the rule here makes that resolution pinnable without building a view
/// tree, and keeps the content branch and the title from drifting apart.
enum DocumentWindowSurface: Equatable {
  /// A file the user asked for is being read off the main actor. Bufferless,
  /// but working — deliberately distinct from the idle launcher below.
  case opening
  /// The idle empty state: no document, nothing in flight.
  case launcher
  /// An editable buffer, file-backed or untitled.
  case editor

  /// Loading wins over the buffer gate: a staged open is bufferless too, and
  /// the two must not look the same.
  static func resolve(isLoading: Bool, hasEditableBuffer: Bool) -> DocumentWindowSurface {
    if isLoading { return .opening }
    return hasEditableBuffer ? .editor : .launcher
  }

  /// The window/navigation title. The app name is the LAUNCHER's title, never a
  /// document's — a window showing "Pensieve" is telling the user it holds
  /// nothing.
  static let launcherTitle = "Pensieve"

  static func navigationTitle(hasEditableBuffer: Bool, documentTitle: String) -> String {
    hasEditableBuffer ? documentTitle : launcherTitle
  }
}
