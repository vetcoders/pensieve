import Foundation

/// Answer to a "do you want to save the changes?" confirmation.
enum SaveChangesResponse: Equatable {
  case save
  case saveAs
  case discard
  case cancel
}

/// Which confirmation a close needs. The two prompts differ only in the
/// affirmative verb: an untitled buffer has no file yet, so saving it means
/// choosing a location ("Save As…"); a file-backed buffer writes in place.
enum DocumentClosePrompt: Equatable {
  case saveAsUntitled
  case savePathed
  case saveRecoveredFile
}

/// What `File > Close` (⌘W) must do with the active session — decided BEFORE
/// any UI exists, so the whole lifecycle is testable without an alert.
///
/// The governing rule (operator decisions, 2026-07-24 and 2026-08-10): a
/// normal close is a CONSCIOUS lifecycle. Recovery drafts cover abnormal
/// endings (crash, forced quit); they are not a substitute for asking when the
/// user owns saving. With auto-save OFF, a dirty file-backed buffer therefore
/// asks before close. With auto-save ON, Pensieve owns that write and may close
/// without a question only after it has flushed the current bytes somewhere
/// durable. No mode ever permits a silent discard.
enum DocumentCloseDecision: Equatable {
  /// Nothing at stake: an empty session, or a buffer with no unsaved edits.
  case closeWithoutPrompting
  /// Flush to the existing file and close, without asking. Reached only when
  /// auto-save owns file-backed documents (see `autoSavesPathedDocuments`).
  /// The flush matters: the last edit may still be inside the autosave debounce,
  /// so closing without it would drop exactly the change auto-save promised.
  case saveWithoutPrompting
  /// Ask the user before anything is lost.
  case confirm(DocumentClosePrompt)

  /// - Parameters:
  ///   - session: the window's active session.
  ///   - autoSavesPathedDocuments: the auto-save setting
  ///     (`DocumentSavingSettings`, default ON), read per close so a flip in
  ///     Settings applies without a restart. When auto-save owns documents that
  ///     already have a location, their edits are on disk already and "Don't
  ///     Save" would be a lie, so those close after a flush instead of asking.
  ///     A dirty UNTITLED buffer still asks even then: it has no file to be
  ///     auto-saved into.
  static func resolve(
    for session: DocumentSession,
    autoSavesPathedDocuments: Bool = false
  ) -> DocumentCloseDecision {
    guard session.hasEditableBuffer, session.isDirty else {
      return .closeWithoutPrompting
    }
    if session.recoverySourceURL != nil {
      return .confirm(.saveRecoveredFile)
    }
    if session.isUntitled {
      return .confirm(.saveAsUntitled)
    }
    return autoSavesPathedDocuments ? .saveWithoutPrompting : .confirm(.savePathed)
  }

  var prompt: DocumentClosePrompt? {
    guard case .confirm(let prompt) = self else { return nil }
    return prompt
  }
}
