import AppKit

/// The thin UI half of the conscious close lifecycle: presents the save
/// question and hands the answer back. All of the decision-making lives in
/// `DocumentCloseDecision`; this file only knows how to ask.
///
/// The alert is presented WINDOW-modal (a sheet attached to the closing
/// document's window), never app-modal: with tab-per-document, ⌘W on one tab
/// must not freeze every other document the user has open. `runModal()` is the
/// fallback for the case where no host window has resolved yet (headless
/// tests, a close racing window teardown) — mirroring the existing sheet /
/// runModal fallback in `DispatchPopover`.
@MainActor
enum SaveChangesSheet {
  static func present(
    prompt: DocumentClosePrompt,
    session: DocumentSession,
    in window: NSWindow?,
    completion: @escaping @MainActor (SaveChangesResponse) -> Void
  ) {
    let alert = NSAlert()
    let title = session.displayTitle.isEmpty ? "this document" : session.displayTitle
    alert.messageText = "Do you want to save the changes made to \(title)?"
    alert.informativeText = "Your changes will be lost if you don't save them."
    alert.alertStyle = .warning
    // An untitled buffer has nowhere to be saved yet, so its affirmative
    // action opens the save panel; a file-backed one writes in place.
    alert.addButton(withTitle: prompt == .saveAsUntitled ? "Save As…" : "Save")
    alert.addButton(withTitle: "Don't Save")
    alert.addButton(withTitle: "Cancel")
    // Match the platform habits users already have from TextEdit and friends:
    // ⌘D discards, Escape cancels. Escape must never land on "Don't Save".
    alert.buttons[1].keyEquivalent = "d"
    alert.buttons[1].keyEquivalentModifierMask = [.command]
    alert.buttons[2].keyEquivalent = "\u{1b}"

    guard let window, window.isVisible else {
      completion(response(for: alert.runModal()))
      return
    }

    alert.beginSheetModal(for: window) { modalResponse in
      MainActor.assumeIsolated {
        completion(response(for: modalResponse))
      }
    }
  }

  private static func response(for modalResponse: NSApplication.ModalResponse)
    -> SaveChangesResponse
  {
    switch modalResponse {
    case .alertFirstButtonReturn:
      return .save
    case .alertSecondButtonReturn:
      return .discard
    default:
      return .cancel
    }
  }
}
