import Foundation

/// A typed request to CONFIGURE an agent dispatch — never to launch one.
///
/// Every UI dispatch surface (toolbar ✈, Agents menu, Agents workflow submenu,
/// sidebar file actions) produces an intent and hands it to the focused
/// window's `AppState.pendingDispatchIntent`; only the canonical configuration
/// sheet (`DispatchPopover`) may turn an intent into a launch, after the user
/// presses Dispatch. The subject is snapshotted at request time so the sheet
/// stays honest about WHAT will be dispatched.
struct DispatchIntent: Equatable, Identifiable {
  /// WHAT gets dispatched. Saved documents and sidebar files launch as
  /// `--file` payloads; an unsaved buffer launches its text as `--prompt`.
  enum Subject: Equatable {
    case savedDocument(URL)
    case unsavedBuffer(title: String, text: String)
    case fileURL(URL)
  }

  /// WHERE the request came from. Preselection truth for the sheet and the
  /// discriminator in routing tests.
  enum Source: String, Equatable {
    case toolbar
    case agentsMenu
    case agentsWorkflowMenu
    case sidebar
  }

  let id = UUID()
  let subject: Subject
  let workflow: String
  let source: Source

  var payload: AgentDispatchPayload {
    switch subject {
    case .savedDocument(let url), .fileURL(let url):
      return .file(url.path)
    case .unsavedBuffer(_, let text):
      return .prompt(text)
    }
  }

  var subjectLabel: String {
    switch subject {
    case .savedDocument(let url), .fileURL(let url):
      return url.lastPathComponent
    case .unsavedBuffer(let title, _):
      return "\(title) (unsaved draft)"
    }
  }

  /// True when confirming would hand the launcher an empty payload — the
  /// sheet disables Dispatch on this instead of failing after the click.
  var subjectIsEmpty: Bool {
    payload.isEmpty
  }
}
