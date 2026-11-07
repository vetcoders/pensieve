import AppKit

/// Selection names turns, never rendered blocks or clipped previews. The
/// conversation remains the only owner of message text.
struct AskMessageSelection: Equatable {
  private(set) var isActive = false
  private(set) var ids: Set<String> = []
  private var anchor: String?

  mutating func begin() { isActive = true }

  mutating func end() {
    isActive = false
    ids.removeAll()
    anchor = nil
  }

  mutating func toggle(_ id: String, in order: [String], extending: Bool = false) {
    guard isActive, let end = order.firstIndex(of: id) else { return }
    if extending, let anchor, let start = order.firstIndex(of: anchor) {
      ids.formUnion(order[min(start, end)...max(start, end)])
    } else {
      if !ids.insert(id).inserted { ids.remove(id) }
      anchor = id
    }
  }

  mutating func retain(_ validIDs: Set<String>) {
    ids.formIntersection(validIDs)
    if let anchor, !validIDs.contains(anchor) { self.anchor = nil }
  }
}

struct AskSelectedMessage: Equatable, Sendable {
  var id: String
  var roleLabel: String
  var text: String
}

enum AskMessageCopy {
  /// Called off the UI actor after capturing the selected canonical turns.
  /// Keep Markdown, Unicode, line breaks and conversation order verbatim.
  static func source(_ messages: [AskSelectedMessage]) -> String {
    messages.map { "\($0.roleLabel):\n\($0.text)" }.joined(separator: "\n\n")
  }

  /// A slower export must not overwrite a newer clipboard action while it
  /// was assembling the source. Tests use an independently named pasteboard.
  @MainActor
  static func write(_ text: String, to pasteboard: NSPasteboard, expecting changeCount: Int) -> Bool
  {
    guard !text.isEmpty, pasteboard.changeCount == changeCount else { return false }
    pasteboard.clearContents()
    return pasteboard.setString(text, forType: .string)
  }
}
