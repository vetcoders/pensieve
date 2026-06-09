import Combine
import SwiftUI

@MainActor
final class DocumentWindowModel: ObservableObject {
  private static let previewAutoReloadKey = "Pensieve.previewAutoReload"
  private static let tableTidyOnPasteKey = "Pensieve.tableTidyOnPaste"
  private static let asciiSafeTablesKey = "Pensieve.asciiSafeTables"
  private static let aiAutocompleteEnabledKey = "Pensieve.aiAutocompleteEnabled"
  private let defaults: UserDefaults

  @Published var selectedDocumentID: DocumentRef.ID?
  @Published var documentSession: DocumentSession = .empty
  @Published var mode: EditorMode = .split
  @Published var fontSize: CGFloat = 14
  @Published var richMarkdownEnabled: Bool = true
  @Published var pendingMarkdownFormatCommand: MarkdownFormatCommand?
  @Published var findBarVisible: Bool = false
  @Published var findReplaceMode: Bool = false
  @Published var findQuery: String = ""
  @Published var findReplaceQuery: String = ""
  @Published var findFocusToken: Int = 0
  @Published var pendingFindCommand: FindBarCommand?
  @Published var tableTidyOnPaste: Bool {
    didSet {
      defaults.set(tableTidyOnPaste, forKey: Self.tableTidyOnPasteKey)
    }
  }
  @Published var asciiSafeTables: Bool {
    didSet {
      defaults.set(asciiSafeTables, forKey: Self.asciiSafeTablesKey)
    }
  }
  @Published var aiAutocompleteEnabled: Bool {
    didSet {
      defaults.set(aiAutocompleteEnabled, forKey: Self.aiAutocompleteEnabledKey)
    }
  }
  @Published var previewAutoReload: Bool {
    didSet {
      defaults.set(previewAutoReload, forKey: Self.previewAutoReloadKey)
    }
  }
  @Published var previewRefreshToken: Int = 0
  @Published var sidebarVisible: Bool = true
  @Published var lastError: String?

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
