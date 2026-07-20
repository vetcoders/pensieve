import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class DocumentWindowModel {
  private static let previewAutoReloadKey = "Pensieve.previewAutoReload"
  private static let tableTidyOnPasteKey = "Pensieve.tableTidyOnPaste"
  private static let asciiSafeTablesKey = "Pensieve.asciiSafeTables"
  private static let aiAutocompleteEnabledKey = "Pensieve.aiAutocompleteEnabled"
  private static let scrollSyncEnabledKey = "Pensieve.scrollSyncEnabled"
  private let defaults: UserDefaults
  private var ephemeralAIDocumentID = UUID()

  var selectedDocumentID: DocumentRef.ID?

  /// The single source of truth for the open document (kind + text + dirty).
  /// Typing reassigns this struct on every keystroke, so any view that reads
  /// `documentSession` directly re-renders per keystroke. The editor and the
  /// preview WANT that (they read `.text`). The window chrome (title bar, split
  /// gating, sidebar) must NOT — it reads the discrete mirrors below instead,
  /// which only change when the metadata actually changes (guarded didSet).
  var documentSession: DocumentSession = .empty {
    didSet {
      if oldValue.persistentAIDocumentID != documentSession.persistentAIDocumentID,
        documentSession.persistentAIDocumentID == nil
      {
        ephemeralAIDocumentID = UUID()
      }
      let title = documentSession.displayTitle
      if documentTitle != title { documentTitle = title }
      let editable = documentSession.hasEditableBuffer
      if documentHasEditableBuffer != editable { documentHasEditableBuffer = editable }
      let url = documentSession.url
      if documentURL != url { documentURL = url }
      if documentIsDirty != documentSession.isDirty { documentIsDirty = documentSession.isDirty }
    }
  }

  var aiDocumentID: String {
    documentSession.persistentAIDocumentID
      ?? "window:\(ephemeralAIDocumentID.uuidString.lowercased())"
  }

  /// Discrete, low-frequency mirrors of `documentSession` metadata. Chrome views
  /// read THESE (not `documentSession`) so a text-only edit never invalidates
  /// them — that is what stops the whole window re-rendering on every keystroke.
  private(set) var documentTitle: String = ""
  private(set) var documentHasEditableBuffer: Bool = false
  private(set) var documentURL: URL?
  private(set) var documentIsDirty: Bool = false

  var mode: EditorMode = .split
  var fontSize: CGFloat = 14
  var richMarkdownEnabled: Bool = true
  var pendingMarkdownFormatCommand: MarkdownFormatCommand?
  var pendingAIRewriteCommand: AIRewriteCommand?
  var aiRewritePreview: AIRewritePreview?
  var findBarVisible: Bool = false
  var findReplaceMode: Bool = false
  var findQuery: String = ""
  var findReplaceQuery: String = ""
  var findFocusToken: Int = 0
  var pendingFindCommand: FindBarCommand?
  var findMatchCount: Int = 0
  var findActiveMatchIndex: Int?
  /// Caret/selection state surfaced by the editor for the status bar. UTF-16
  /// units, as AppKit reports them; the status bar resolves line/column lazily.
  var caretUTF16Offset: Int = 0
  var selectionUTF16Length: Int = 0
  var tableTidyOnPaste: Bool {
    didSet {
      defaults.set(tableTidyOnPaste, forKey: Self.tableTidyOnPasteKey)
    }
  }
  var asciiSafeTables: Bool {
    didSet {
      defaults.set(asciiSafeTables, forKey: Self.asciiSafeTablesKey)
    }
  }
  var aiAutocompleteEnabled: Bool {
    didSet {
      defaults.set(aiAutocompleteEnabled, forKey: Self.aiAutocompleteEnabledKey)
    }
  }
  var scrollSyncEnabled: Bool {
    didSet {
      defaults.set(scrollSyncEnabled, forKey: Self.scrollSyncEnabledKey)
    }
  }
  var previewAutoReload: Bool {
    didSet {
      defaults.set(previewAutoReload, forKey: Self.previewAutoReloadKey)
    }
  }
  var previewRefreshToken: Int = 0
  var sidebarVisible: Bool = true
  var lastError: String?

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if defaults.object(forKey: Self.previewAutoReloadKey) == nil {
      self.previewAutoReload = false
    } else {
      self.previewAutoReload = defaults.bool(forKey: Self.previewAutoReloadKey)
    }
    if defaults.object(forKey: Self.tableTidyOnPasteKey) == nil {
      self.tableTidyOnPaste = true
    } else {
      self.tableTidyOnPaste = defaults.bool(forKey: Self.tableTidyOnPasteKey)
    }
    if defaults.object(forKey: Self.asciiSafeTablesKey) == nil {
      self.asciiSafeTables = false
    } else {
      self.asciiSafeTables = defaults.bool(forKey: Self.asciiSafeTablesKey)
    }
    if defaults.object(forKey: Self.aiAutocompleteEnabledKey) == nil {
      self.aiAutocompleteEnabled = false
    } else {
      self.aiAutocompleteEnabled = defaults.bool(forKey: Self.aiAutocompleteEnabledKey)
    }
    if defaults.object(forKey: Self.scrollSyncEnabledKey) == nil {
      self.scrollSyncEnabled = false
    } else {
      self.scrollSyncEnabled = defaults.bool(forKey: Self.scrollSyncEnabledKey)
    }
    // Seed the metadata mirrors from the initial (empty) session. didSet does
    // not fire during init, so prime them explicitly to stay consistent.
    self.documentTitle = documentSession.displayTitle
    self.documentHasEditableBuffer = documentSession.hasEditableBuffer
    self.documentURL = documentSession.url
    self.documentIsDirty = documentSession.isDirty
  }

  func bumpFontSize(by delta: CGFloat) {
    fontSize = max(8, min(48, fontSize + delta))
  }

  func resetFontSize() {
    fontSize = 14
  }

  func requestPreviewRefresh() {
    previewRefreshToken &+= 1
  }
}
