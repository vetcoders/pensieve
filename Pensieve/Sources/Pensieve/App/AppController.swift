import Combine
import CoreGraphics
import Foundation

@MainActor
final class AppController: ObservableObject {
  private let appState: AppState
  private let folderManager: FolderManager
  private let documentStore: DocumentStore
  private let indexDatabase: IndexDatabase
  private let importsFoldersInBackground: Bool
  private var didStart = false

  convenience init(appState: AppState, importsFoldersInBackground: Bool = false) {
    self.init(
      appState: appState,
      folderManager: FolderManager.shared,
      documentStore: DocumentStore.shared,
      indexDatabase: IndexDatabase.shared,
      importsFoldersInBackground: importsFoldersInBackground
    )
  }

  init(
    appState: AppState,
    folderManager: FolderManager,
    documentStore: DocumentStore,
    indexDatabase: IndexDatabase? = nil,
    importsFoldersInBackground: Bool = false
  ) {
    self.appState = appState
    self.folderManager = folderManager
    self.documentStore = documentStore
    self.indexDatabase = indexDatabase ?? .shared
    self.importsFoldersInBackground = importsFoldersInBackground
    self.documentStore.observeSelfWrites { [weak folderManager] url in
      folderManager?.noteSelfWrite(at: url)
    }
  }

  func start(restoringWorkspace: Bool = true) {
    guard !didStart else { return }
    didStart = true

    indexDatabase.open(into: appState)
    guard restoringWorkspace else { return }
    folderManager.restoreLastFolderInBackground(into: appState)
  }

  func openFolder(url: URL) {
    if importsFoldersInBackground {
      folderManager.openInBackground(url: url, into: appState)
    } else {
      folderManager.open(url: url, into: appState)
    }
  }

  func openFile(url: URL) {
    folderManager.openFile(url: url, into: appState)
  }

  @discardableResult
  func createMarkdownFile(url: URL) -> Bool {
    guard documentStore.prepareForDocumentSwitch(appState: appState) else {
      return false
    }

    return folderManager.createMarkdownFile(at: url, into: appState)
  }

  @discardableResult
  func createUntitledDocument() -> Bool {
    guard documentStore.prepareForDocumentSwitch(appState: appState) else {
      return false
    }

    appState.documentSession.createUntitled()
    appState.selectedDocumentID = nil
    appState.lastError = nil
    return true
  }

  func restoreLastFolder() {
    folderManager.restoreLastFolder(into: appState)
  }

  func excludeFromWorkspace(urls: [URL]) {
    folderManager.addExcludedURLs(urls, into: appState)
  }

  func clearWorkspaceExclusions() {
    folderManager.clearExclusions(into: appState)
  }

  func saveActiveDocument() {
    documentStore.save(appState: appState)
  }

  @discardableResult
  func saveActiveDocument(as url: URL) -> Bool {
    let didSave = documentStore.saveAs(appState: appState, to: url)
    if didSave, let savedURL = appState.documentSession.url,
      appState.workspaceRoots.contains(where: { WorkspaceScanner.contains(savedURL, in: $0.url) })
    {
      folderManager.refresh(into: appState)
    }
    return didSave
  }

  @discardableResult
  func applicationShouldTerminate() -> Bool {
    documentStore.prepareForDocumentSwitch(appState: appState)
  }

  /// Closes the active document session without exiting Pensieve.
  /// Dirty sessions are routed through the existing save semantics in
  /// `DocumentStore.select(ref:nil:into:)` before the session is cleared,
  /// so the window stays alive and reverts to its empty state.
  @discardableResult
  func closeActiveDocument() -> Bool {
    documentStore.select(ref: nil, into: appState)
  }

  func selectDocument(id: DocumentRef.ID?) {
    guard let id else {
      _ = documentStore.select(ref: nil, into: appState)
      return
    }

    guard let ref = appState.allDocuments.first(where: { $0.id == id }) else {
      return
    }

    _ = documentStore.select(ref: ref, into: appState)
  }

  func closeDocumentTab(id: DocumentRef.ID) {
    let closingActiveDocument =
      appState.selectedDocumentID?.standardizedFileURL == id.standardizedFileURL
    guard !closingActiveDocument || documentStore.prepareForDocumentSwitch(appState: appState)
    else {
      return
    }

    let currentTabs = appState.documentTabs
    let closingIndex = currentTabs.firstIndex {
      $0.id.standardizedFileURL == id.standardizedFileURL
    }
    appState.forgetDocumentTab(id: id)

    guard closingActiveDocument else { return }

    let remainingTabs = appState.documentTabs
    let replacementIndex = min(closingIndex ?? remainingTabs.count, remainingTabs.count - 1)
    if replacementIndex >= 0, remainingTabs.indices.contains(replacementIndex) {
      _ = documentStore.select(ref: remainingTabs[replacementIndex], into: appState)
    } else {
      _ = documentStore.select(ref: nil, into: appState)
    }
  }

  func selectSearchResult(_ result: WorkspaceSearchResult) {
    selectDocument(id: result.document.id)
  }

  func selectWorkspaceNode(_ node: WorkspaceNode) {
    guard let documentID = node.documentID else { return }
    selectDocument(id: documentID)
  }

  func updateWorkspaceSearch(query: String) {
    appState.workspaceSearchQuery = query
    indexDatabase.refreshSearchResults(in: appState)
  }

  func setMode(_ mode: EditorMode) {
    appState.mode = mode
  }

  func toggleSidebar() {
    appState.sidebarVisible.toggle()
  }

  func toggleRichMarkdown() {
    appState.richMarkdownEnabled.toggle()
  }

  func bumpFontSize(by delta: CGFloat) {
    appState.bumpFontSize(by: delta)
  }

  func resetFontSize() {
    appState.resetFontSize()
  }

  func documentDidChange() {
    documentStore.documentDidChange(appState: appState)
  }

  // MARK: - Toolbar Actions

  func applyMarkdownFormat(_ format: MarkdownFormat) {
    guard appState.documentSession.hasEditableBuffer else { return }
    appState.pendingMarkdownFormatCommand = MarkdownFormatCommand(format: format)
  }

  func formatSelection(with wrapper: String) {
    guard let format = MarkdownFormat(wrapper: wrapper) else { return }
    applyMarkdownFormat(format)
  }
}

extension MarkdownFormat {
  fileprivate init?(wrapper: String) {
    switch wrapper {
    case "**": self = .bold
    case "*": self = .italic
    case "~~": self = .strike
    case "`": self = .code
    case ">": self = .quote
    case "-": self = .bulletedList
    case "1.": self = .numberedList
    case "[]()": self = .link
    default: return nil
    }
  }
}
