import AppKit

/// Routes the active document into the macOS share sheet (`NSSharingServicePicker`).
///
/// File-backed documents share their on-disk URL so recipients get the real
/// `.md` file; an unsaved/untitled buffer shares its text so Share still works
/// before the first save. Shared by the File ▸ Share menu item and the toolbar
/// Share button so both surfaces stay in lockstep.
@MainActor
enum DocumentSharing {
  static func share(session: DocumentSession) {
    guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
      let contentView = window.contentView
    else { return }

    let items = shareItems(for: session)
    guard !items.isEmpty else { return }

    let picker = NSSharingServicePicker(items: items)
    let anchor = NSRect(
      x: contentView.bounds.midX, y: contentView.bounds.maxY - 1, width: 1, height: 1)
    picker.show(relativeTo: anchor, of: contentView, preferredEdge: .minY)
  }

  private static func shareItems(for session: DocumentSession) -> [Any] {
    if let url = session.url {
      return [url]
    }
    if session.hasEditableBuffer {
      return [session.text]
    }
    return []
  }
}
