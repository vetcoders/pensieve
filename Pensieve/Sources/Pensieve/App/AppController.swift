import AppKit
import Combine
import CoreGraphics
import Foundation

@MainActor
final class AppController: ObservableObject {
  private let appState: AppState
  private let folderManager: FolderManager
  private let documentStore: DocumentStore
  private let indexDatabase: IndexDatabase
  private let agentPromptLauncher: AgentPromptLaunching
  private let agentWorkspaceRoot: URL
  private let importsFoldersInBackground: Bool
  private let workspaceSearchDebounceNanoseconds: UInt64
  let transcriptionService: TranscriptionService
  private lazy var transcriptionTaflaPanel: TranscriptionTaflaPanelController = {
    let panel = TranscriptionTaflaPanelController(
      service: transcriptionService,
      onSend: { [weak self] target in self?.sendTranscription(target: target) == true }
    )
    panel.onVisibilityChanged = { [weak self] in
      self?.objectWillChange.send()
    }
    return panel
  }()
  private var didStart = false
  private var workspaceSearchTask: Task<Void, Never>?
  private var nextUntitledIndex = 1
  var requestOpenDocumentWindow: ((DocumentRef) -> Void)?
  var requestCloseCurrentWindowIfEmpty: (() -> Void)?

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
    transcriptionService: TranscriptionService? = nil,
    agentPromptLauncher: AgentPromptLaunching = VibecraftedAgentPromptLauncher(),
    agentWorkspaceRoot: URL = URL(
      fileURLWithPath: "/Users/maciejgad/vc-workspace/vetcoders/pensieve"),
    importsFoldersInBackground: Bool = false,
    workspaceSearchDebounceNanoseconds: UInt64 = 250_000_000
  ) {
    self.appState = appState
    self.folderManager = folderManager
    self.documentStore = documentStore
    self.indexDatabase = indexDatabase ?? .shared
    self.agentPromptLauncher = agentPromptLauncher
    self.agentWorkspaceRoot = agentWorkspaceRoot
    self.transcriptionService = transcriptionService ?? TranscriptionService()
    self.importsFoldersInBackground = importsFoldersInBackground
    self.workspaceSearchDebounceNanoseconds = workspaceSearchDebounceNanoseconds
    self.documentStore.observeSelfWrites { [weak folderManager] url in
      folderManager?.noteSelfWrite(at: url)
    }
  }

  func start(restoringWorkspace: Bool = true) {
    guard !didStart else { return }
    didStart = true

    // Warm the index OFF the main thread. Opening the GRDB pool + running migrations (incl. the FTS5
    // content-link rebuild) on main here was the launch-time beachball; the workspace-restore path
    // also opens lazily, so this is just an early, non-blocking warm-up.
    let indexDatabase = indexDatabase
    Task { await indexDatabase.openInBackground(into: appState) }
    let restoredDraft = documentStore.restoreRecoveredDraft(into: appState)
    guard restoringWorkspace else { return }
    if restoredDraft {
      appState.lastError = nil
    }
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
    guard let ref = folderManager.registerOpenFile(url: url, into: appState) else {
      return
    }

    if appState.selectedDocumentID?.standardizedFileURL == ref.id.standardizedFileURL {
      return
    }

    guard appState.documentSession.hasEditableBuffer else {
      documentStore.load(ref: ref, into: appState)
      return
    }

    if let requestOpenDocumentWindow {
      requestOpenDocumentWindow(ref)
    } else {
      documentStore.load(ref: ref, into: appState)
    }
  }

  func openFileInCurrentWindow(url: URL) {
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
  func createDocument(in folderURL: URL?) -> URL? {
    guard documentStore.prepareForDocumentSwitch(appState: appState) else {
      return nil
    }
    guard let directoryURL = documentCreationDirectory(folderURL) else {
      appState.lastError = "Open a workspace folder before creating a workspace file."
      return nil
    }

    let targetURL = availableSiblingURL(
      for: directoryURL.appendingPathComponent("Untitled").appendingPathExtension("md")
    )
    appState.documentSession.createUntitled(title: targetURL.lastPathComponent)
    appState.selectedDocumentID = nil
    appState.lastError = nil

    guard saveActiveDocument(as: targetURL) else {
      return nil
    }

    let standardizedURL = targetURL.standardizedFileURL
    appState.pendingSidebarRenameURL = standardizedURL
    reindexCreatedDocument(at: standardizedURL)
    return standardizedURL
  }

  @discardableResult
  func createFolder(url: URL) -> Bool {
    folderManager.createFolder(at: url, into: appState)
  }

  @discardableResult
  func createFolder(in folderURL: URL?) -> URL? {
    guard let directoryURL = documentCreationDirectory(folderURL) else {
      appState.lastError = "Open a workspace folder before creating a workspace folder."
      return nil
    }

    let targetURL = availableSiblingURL(for: directoryURL.appendingPathComponent("New Folder"))
    guard folderManager.createFolder(at: targetURL, into: appState) else {
      return nil
    }

    let standardizedURL = targetURL.standardizedFileURL
    appState.pendingSidebarRenameURL = standardizedURL
    return standardizedURL
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

  func closeOpenFile(id: DocumentRef.ID) {
    let standardizedID = id.standardizedFileURL
    if appState.selectedDocumentID?.standardizedFileURL == standardizedID {
      guard documentStore.select(ref: nil, into: appState) else { return }
    }
    appState.openFiles.removeAll { $0.id.standardizedFileURL == standardizedID }
  }

  func clearOpenFiles() {
    appState.openFiles = []
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

  func openDocumentWindow(id: DocumentRef.ID?) {
    guard let id, let ref = appState.allDocuments.first(where: { $0.id == id }) else {
      return
    }

    if appState.selectedDocumentID?.standardizedFileURL == ref.id.standardizedFileURL {
      return
    }

    guard appState.documentSession.hasEditableBuffer else {
      selectDocument(id: ref.id)
      return
    }

    if let requestOpenDocumentWindow {
      requestOpenDocumentWindow(ref)
    } else {
      selectDocument(id: ref.id)
    }
  }

  func selectSearchResult(_ result: WorkspaceSearchResult) {
    openDocumentWindow(id: result.document.id)
  }

  func selectWorkspaceNode(_ node: WorkspaceNode) {
    guard let documentID = node.documentID else { return }
    openDocumentWindow(id: documentID)
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

  var isTranscriptionTaflaVisible: Bool {
    transcriptionTaflaPanel.isVisible
  }

  func toggleTranscriptionTafla() {
    transcriptionTaflaPanel.toggle()
  }

  func showTranscriptionTafla() {
    transcriptionTaflaPanel.show()
  }

  func hideTranscriptionTafla() {
    transcriptionTaflaPanel.hide()
  }

  @discardableResult
  func sendTranscription(
    target: TranscriptionSendTarget,
    activeTextView: MarkdownTextView? = nil
  ) -> Bool {
    switch target {
    case .editor:
      return sendTranscriptionToActiveEditor(activeTextView: activeTextView)
    case .agent:
      return dispatchTranscriptionToAgent()
    }
  }

  @discardableResult
  func sendTranscriptionToActiveEditor(activeTextView: MarkdownTextView? = nil) -> Bool {
    let text = transcriptionService.rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return false }
    guard appState.documentSession.hasEditableBuffer else {
      appState.lastError = "Open an editable document before sending from Tafla."
      return false
    }

    if let textView = activeTextView ?? NSApp.keyWindow?.firstResponder as? MarkdownTextView,
      textView.insertTextAtSelection(text)
    {
      transcriptionService.resetTranscript()
      appState.lastError = nil
      return true
    }

    appendTranscriptionToDocument(text)
    transcriptionService.resetTranscript()
    appState.lastError = nil
    return true
  }

  @discardableResult
  private func dispatchTranscriptionToAgent() -> Bool {
    let prompt = transcriptionService.rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return false }

    transcriptionService.updateDispatchStatus("Dispatching to agent...")
    let launcher = agentPromptLauncher
    let workingDirectoryURL = agentWorkspaceRoot
    let transcriptionService = transcriptionService

    Task.detached(priority: .utility) {
      do {
        let metadata = try launcher.dispatch(
          prompt: prompt,
          workingDirectoryURL: workingDirectoryURL
        )
        await MainActor.run {
          if metadata.exitCode == 0 {
            transcriptionService.resetTranscript()
          }
          transcriptionService.updateDispatchStatus(metadata.statusLine)
        }
      } catch {
        await MainActor.run {
          transcriptionService.updateDispatchStatus(
            "Dispatch failed: \(error.localizedDescription)")
        }
      }
    }

    return true
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
      [appState.documentSession.displayTitle].filter { $0.hasPrefix("Untitled") }
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

  private func documentCreationDirectory(_ folderURL: URL?) -> URL? {
    if let folderURL {
      return folderURL.standardizedFileURL
    }
    return appState.workspaceRoots.first?.url.standardizedFileURL ?? appState.folderURL
  }

  private func availableSiblingURL(for url: URL) -> URL {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return url.standardizedFileURL }

    let directory = url.deletingLastPathComponent()
    let ext = url.pathExtension
    let base =
      ext.isEmpty
      ? url.lastPathComponent
      : url.deletingPathExtension().lastPathComponent
    var index = 2
    while true {
      let name = "\(base) \(index)"
      let candidate =
        ext.isEmpty
        ? directory.appendingPathComponent(name)
        : directory.appendingPathComponent(name).appendingPathExtension(ext)
      if !fm.fileExists(atPath: candidate.path) {
        return candidate.standardizedFileURL
      }
      index += 1
    }
  }

  private func reindexCreatedDocument(at url: URL) {
    let ref = appState.documentRef(for: url.standardizedFileURL)
    let indexDatabase = indexDatabase
    let appState = appState
    Task {
      _ = await indexDatabase.reindexInBackground(documents: [ref], appState: appState)
    }
  }

  private func appendTranscriptionToDocument(_ text: String) {
    if appState.documentSession.text.isEmpty {
      appState.documentSession.text = text
    } else {
      appState.documentSession.text += "\n" + text
    }
    appState.documentSession.isDirty = true
    documentDidChange()
  }

  func selectNextTab() {
    NSApp.sendAction(#selector(NSWindow.selectNextTab(_:)), to: nil, from: nil)
  }

  func selectPreviousTab() {
    NSApp.sendAction(#selector(NSWindow.selectPreviousTab(_:)), to: nil, from: nil)
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
