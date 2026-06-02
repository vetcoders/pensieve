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
  private let workspaceSearchDebounceNanoseconds: UInt64
  private var didStart = false
  private var workspaceSearchTask: Task<Void, Never>?
  private var nextUntitledIndex = 1

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
    importsFoldersInBackground: Bool = false,
    workspaceSearchDebounceNanoseconds: UInt64 = 250_000_000
  ) {
    self.appState = appState
    self.folderManager = folderManager
    self.documentStore = documentStore
    self.indexDatabase = indexDatabase ?? .shared
    self.importsFoldersInBackground = importsFoldersInBackground
    self.workspaceSearchDebounceNanoseconds = workspaceSearchDebounceNanoseconds
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
  func createFolder(url: URL) -> Bool {
    folderManager.createFolder(at: url, into: appState)
  }

  @discardableResult
  func renameItem(url: URL, to name: String) -> Bool {
    folderManager.rename(url: url, to: name, into: appState)
  }

  @discardableResult
  func duplicateItem(url: URL) -> Bool {
    folderManager.duplicate(url: url, into: appState)
  }

  @discardableResult
  func moveItemToTrash(url: URL) -> Bool {
    folderManager.moveToTrash(url: url, into: appState)
  }

  @discardableResult
  func moveItem(url: URL, toFolder folderURL: URL) -> Bool {
    folderManager.move(url: url, toFolder: folderURL, into: appState)
  }

  func reorderOpenFiles(fromOffsets source: IndexSet, toOffset destination: Int) {
    var visibleFiles = appState.sortedOpenFiles
    let moving = source.sorted().map { visibleFiles[$0] }
    visibleFiles.removeAll { ref in
      moving.contains { $0.id.standardizedFileURL == ref.id.standardizedFileURL }
    }
    let lowerRemovedCount = source.filter { $0 < destination }.count
    let insertionIndex = max(0, min(destination - lowerRemovedCount, visibleFiles.count))
    visibleFiles.insert(contentsOf: moving, at: insertionIndex)
    appState.sidebarSortOrder = .manual
    appState.openFiles = visibleFiles
  }

  @discardableResult
  func createUntitledDocument() -> Bool {
    guard documentStore.prepareForDocumentSwitch(appState: appState) else {
      return false
    }

    appState.documentSession.createUntitled(title: nextUntitledTitle())
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

  func closeWorkspace() {
    folderManager.closeWorkspace(into: appState)
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
    workspaceSearchTask?.cancel()
    appState.workspaceSearchQuery = query
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else {
      appState.workspaceSearchResults = []
      workspaceSearchTask = nil
      return
    }

    let documents = appState.allDocuments
    let debounceNanoseconds = workspaceSearchDebounceNanoseconds
    let appState = appState
    let indexDatabase = indexDatabase
    workspaceSearchTask = Task {
      if debounceNanoseconds > 0 {
        do {
          try await Task.sleep(nanoseconds: debounceNanoseconds)
        } catch {
          return
        }
      }
      guard !Task.isCancelled else { return }

      let results = await indexDatabase.searchInBackground(
        query: trimmedQuery,
        documents: documents,
        appState: appState
      )
      guard !Task.isCancelled, appState.workspaceSearchQuery == query else { return }
      appState.workspaceSearchResults = results
    }
  }

  func waitForPendingWorkspaceSearch() async {
    await workspaceSearchTask?.value
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

  func tidyTable() {
    guard appState.documentSession.hasEditableBuffer else { return }
    appState.pendingMarkdownFormatCommand = MarkdownFormatCommand(
      tidyTableAsciiSafe: appState.asciiSafeTables)
  }

  func formatSelection(with wrapper: String) {
    guard let format = MarkdownFormat(wrapper: wrapper) else { return }
    applyMarkdownFormat(format)
  }

  private func nextUntitledTitle() -> String {
    let existingTitles = Set(
      ([appState.documentSession.displayTitle] + appState.documentTabs.map(\.title))
        .filter { $0.hasPrefix("Untitled") }
    )

    var index = max(1, nextUntitledIndex)
    while existingTitles.contains(untitledTitle(for: index)) {
      index += 1
    }
    nextUntitledIndex = index + 1
    return untitledTitle(for: index)
  }

  private func untitledTitle(for index: Int) -> String {
    index == 1 ? "Untitled.md" : "Untitled \(index).md"
  }

  // MARK: - Tab Navigation (Quick Win)

  func selectNextTab() {
    cycleTab(forward: true)
  }

  func selectPreviousTab() {
    cycleTab(forward: false)
  }

  private func cycleTab(forward: Bool) {
    let tabs = appState.documentTabs
    guard !tabs.isEmpty else { return }

    let currentURL = appState.selectedDocumentID?.standardizedFileURL
    let currentIndex = tabs.firstIndex { $0.id.standardizedFileURL == currentURL }

    let nextIndex: Int
    if let currentIndex {
      if forward {
        nextIndex = (currentIndex + 1) % tabs.count
      } else {
        nextIndex = (currentIndex - 1 + tabs.count) % tabs.count
      }
    } else {
      nextIndex = 0
    }

    let target = tabs[nextIndex]
    selectDocument(id: target.id)
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
