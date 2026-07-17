import AppKit
import Combine
import CoreGraphics
import Foundation

private enum DocumentImportOutcome: Sendable {
  case success(ImportedMarkdownDocument)
  case failure(String)
}

@MainActor
final class AppController: ObservableObject {
  private let appState: AppState
  private let folderManager: FolderManager
  private let documentStore: DocumentStore
  private let indexDatabase: IndexDatabase
  private let documentWindowRegistry: DocumentWindowRegistry
  let recentDocuments: RecentDocumentsStore
  private let agentPromptLauncher: AgentPromptLaunching
  private let agentWorkspaceRoot: URL?
  private let importsFoldersInBackground: Bool
  private let workspaceSearchDebounceNanoseconds: UInt64
  let agentWorkflows: [String] = [
    "audit", "decorate", "delegate", "dou", "followup", "hydrate", "implement", "intents",
    "justdo", "marbles", "ownership", "partner", "polarize", "prune", "release", "research",
    "review", "scaffold", "workflow",
  ]
  let defaultAgent = "codex"
  /// Agents discovered at runtime from `vibecrafted doctor` (agent-stream:<name>).
  /// `discoverAgents()` refines this, but it only overwrites on a NON-empty probe,
  /// and current `vibecrafted doctor` output no longer emits `agent-stream:<name>`
  /// markers — so this seed is what the picker actually shows. Seed the canonical
  /// fleet the live CLI actually accepts (gemini was removed from the deployed
  /// AGENTS set); offering an agent the CLI rejects turns a confirmed dispatch
  /// into a guaranteed failure.
  @Published var availableAgents: [String] = [
    "claude", "codex", "agy", "junie", "grok",
  ]
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
  private var isAgentDispatchInFlight = false
  private var documentImportTask: Task<Void, Never>?
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
    documentWindowRegistry: DocumentWindowRegistry? = nil,
    recentDocuments: RecentDocumentsStore? = nil,
    transcriptionService: TranscriptionService? = nil,
    agentPromptLauncher: AgentPromptLaunching = VibecraftedAgentPromptLauncher(),
    agentWorkspaceRoot: URL? = nil,
    importsFoldersInBackground: Bool = false,
    workspaceSearchDebounceNanoseconds: UInt64 = 250_000_000
  ) {
    self.appState = appState
    self.folderManager = folderManager
    self.documentStore = documentStore
    self.indexDatabase = indexDatabase ?? .shared
    self.documentWindowRegistry = documentWindowRegistry ?? .shared
    self.recentDocuments = recentDocuments ?? .shared
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
    // Recovery drafts belong to the plain-launch restore path ONLY. A window
    // started for a specific document (`restoringWorkspace: false` — a new
    // document tab, an explicit file launch) must keep its buffer empty:
    // adopting the pending draft here hijacked every new tab with "Recovered
    // Untitled", and the dirty untitled session then blocked the load of the
    // document the window was opened for.
    guard restoringWorkspace else { return }
    if documentStore.restoreRecoveredDraft(into: appState) {
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

  /// External/explicit file opens (⌘O, Finder, recents): tab per document.
  /// An empty window (no editable buffer) is reused in place; once this
  /// window shows a document, further opens route through the window registry
  /// and appear as native tabs. Falls back to in-window load when no routing
  /// is wired (tests, headless).
  func openFile(url: URL) {
    let standardizedURL = url.standardizedFileURL

    // OS-level opens (Finder, Dock drop, `open -a`, launch URLs) funnel every
    // URL kind here. A directory is a workspace, not a document: it must route
    // to the folder-open path BEFORE the registry/markdown handling below, or
    // a first-class workspace open is refused with a misleading
    // "unsupported file type" error (and could even route to a document tab).
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      DebugTrace.log("openFile -> openFolder (directory): \(standardizedURL.lastPathComponent)")
      openFolder(url: standardizedURL)
      return
    }

    if DocumentTransfer.isImportable(standardizedURL) {
      importDocument(url: standardizedURL)
      return
    }

    if appState.selectedDocumentID?.standardizedFileURL == standardizedURL {
      noteRecentDocumentIfOpened(standardizedURL)
      return
    }

    // The registry route below bypasses registerOpenFile (the destination
    // window registers the file during its own load), so unsupported types
    // must be rejected HERE — otherwise they would open an empty tab whose
    // load is refused only afterwards.
    guard WorkspaceScanner.isMarkdownFile(standardizedURL) else {
      appState.lastError = WorkspaceScanner.unsupportedOpenMessage
      return
    }

    // When the file routes to its own window/tab, do NOT register it into
    // THIS window's working set first — the destination window registers it
    // during its own load, and a premature registration leaves the
    // originating sidebar permanently listing a file it never displays.
    if appState.documentSession.hasEditableBuffer, let requestOpenDocumentWindow {
      DebugTrace.log("openFile -> registry: \(standardizedURL.lastPathComponent)")
      requestOpenDocumentWindow(DocumentRef(id: standardizedURL, isAdHoc: true))
      return
    }

    guard let ref = folderManager.registerOpenFile(url: url, into: appState) else {
      return
    }
    DebugTrace.log("openFile -> load in current window: \(ref.id.lastPathComponent)")
    documentStore.load(ref: ref, into: appState)
    noteRecentDocumentIfOpened(standardizedURL)
  }

  func openFileInCurrentWindow(url: URL) {
    if DocumentTransfer.isImportable(url) {
      // Import SOURCE files (Word/PDF) become unsaved drafts; the source is
      // not a recent document. The draft enters history once saved (saveAs).
      importDocument(url: url)
      return
    }
    folderManager.openFile(url: url, into: appState)
    noteRecentDocumentIfOpened(url)
  }

  /// Open Recent menu action: same routing discipline as any explicit open
  /// (an empty window is reused in place, otherwise the file lands as a native
  /// tab via the window registry — never a competing window path).
  func openRecentDocument(url: URL) {
    let standardizedURL = url.standardizedFileURL
    guard FileManager.default.fileExists(atPath: standardizedURL.path) else {
      appState.lastError =
        "Could not open \(standardizedURL.lastPathComponent): the file has been moved or deleted."
      recentDocuments.refresh()
      return
    }
    openFile(url: standardizedURL)
  }

  /// Records `url` into Open Recent only when this window's session actually
  /// shows it — the one truthful post-condition every synchronous open path
  /// shares. Failed loads (unreadable, dirty-session cancel) never record.
  private func noteRecentDocumentIfOpened(_ url: URL) {
    let standardizedURL = url.standardizedFileURL
    guard appState.documentSession.url?.standardizedFileURL == standardizedURL else { return }
    recentDocuments.noteOpened(standardizedURL)
  }

  /// Converts a Word/PDF source off the main actor and opens the result as an
  /// unsaved Markdown draft. The source file remains untouched; Save therefore
  /// follows the normal untitled-document Save As path.
  func importDocument(url: URL) {
    let sourceURL = url.standardizedFileURL
    documentImportTask?.cancel()
    documentImportTask = Task { [weak self] in
      let outcome = await Task.detached(priority: .userInitiated) {
        let scopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
          if scopedAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        do {
          return DocumentImportOutcome.success(
            try DocumentTransfer.importMarkdown(from: sourceURL)
          )
        } catch {
          return DocumentImportOutcome.failure(error.localizedDescription)
        }
      }.value

      guard !Task.isCancelled, let self else { return }
      documentImportTask = nil
      switch outcome {
      case .success(let imported):
        guard documentStore.prepareForDocumentSwitch(appState: appState) else { return }
        appState.selectedDocumentID = nil
        appState.documentSession.restoreUntitled(
          title: imported.suggestedFileName,
          text: imported.markdown,
          recoveryID: UUID()
        )
        // The conversion result has no source-backed autosave target. Persist
        // the dirty untitled session immediately so a crash cannot erase the handoff.
        documentStore.savePendingChangesOnClose(appState: appState)
        appState.lastError = nil
        DebugTrace.log("importDocument -> Markdown draft: \(sourceURL.lastPathComponent)")
      case .failure(let message):
        appState.lastError = "Import failed: \(message)"
      }
    }
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
    let source = url.standardizedFileURL
    guard closeDocumentsAffectedByTrash(at: source) else { return false }
    return folderManager.moveToTrash(url: source, into: appState)
  }

  @discardableResult
  private func closeDocumentsAffectedByTrash(at source: URL) -> Bool {
    if let selected = appState.selectedDocumentID,
      isAffectedByTrash(documentID: selected, source: source)
    {
      guard documentStore.select(ref: nil, into: appState) else { return false }
    }

    let affectedDocumentIDs = documentWindowRegistry.openTabDocumentIDs.filter {
      isAffectedByTrash(documentID: $0, source: source)
    }
    for documentID in affectedDocumentIDs {
      documentWindowRegistry.closeDocumentWindow(documentID)
    }
    return true
  }

  private func isAffectedByTrash(documentID: URL, source: URL) -> Bool {
    let standardizedDocumentID = documentID.standardizedFileURL
    let standardizedSource = source.standardizedFileURL
    return standardizedDocumentID == standardizedSource
      || WorkspaceScanner.contains(standardizedDocumentID, in: standardizedSource)
  }

  @discardableResult
  func moveItem(url: URL, toFolder folderURL: URL) -> Bool {
    folderManager.move(url: url, toFolder: folderURL, into: appState)
  }

  func closeOpenFile(id: DocumentRef.ID) {
    // Open Files mirrors the live tab group, so closing from the list closes the
    // tab/window. If it is THIS window's active doc, run the dirty-session guard
    // first (untitled → Save/Discard/Cancel with Cancel aborting; existing →
    // force-save) so the sidebar close never silently drops unsaved edits.
    let standardizedID = id.standardizedFileURL
    if appState.selectedDocumentID?.standardizedFileURL == standardizedID {
      guard documentStore.select(ref: nil, into: appState) else { return }
    }
    documentWindowRegistry.closeDocumentWindow(standardizedID)
  }

  func clearOpenFiles() {
    // Guard this window's active doc before tearing every tab down.
    if appState.selectedDocumentID != nil {
      guard documentStore.select(ref: nil, into: appState) else { return }
    }
    documentWindowRegistry.closeAllDocumentWindows()
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

  func excludeFromWorkspace(url: URL) {
    folderManager.addExcludedURLs([url], into: appState)
  }

  func removeWorkspaceRoot(url: URL) {
    folderManager.removeRoot(url, into: appState)
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
    if didSave, let savedURL = appState.documentSession.url {
      // A draft (untitled or imported Word/PDF) becomes a real file document
      // here — that is the moment it earns its Open Recent entry.
      recentDocuments.noteOpened(savedURL)
      if appState.workspaceRoots.contains(where: { WorkspaceScanner.contains(savedURL, in: $0.url) }
      ) {
        folderManager.refresh(into: appState)
      }
    }
    return didSave
  }

  @discardableResult
  func applicationShouldTerminate() -> Bool {
    documentStore.prepareForDocumentSwitch(appState: appState)
  }

  /// Save-on-close guard for THIS window's session. Routed from the shared
  /// document-window root on `NSWindow.willCloseNotification`, it flushes a
  /// pending (debounced) edit synchronously before the window/tab tears down,
  /// closing the ≤1.5s data-loss window on every close trigger (red button,
  /// tab "×", sidebar close, ⌘W). No-op for a clean buffer.
  @discardableResult
  func savePendingChangesOnClose() -> Bool {
    documentStore.savePendingChangesOnClose(appState: appState)
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
    noteRecentDocumentIfOpened(ref.id)
  }

  /// Resolves a sidebar/search row ID to a `DocumentRef`. Resolves via the
  /// workspace/working-set scan, falling back to a synthesized ref for a live
  /// registry tab whose ref was evicted past the open-files cap — otherwise the
  /// registry-sourced sidebar row exists but its click is dead.
  private func resolveDocumentRef(for id: DocumentRef.ID) -> DocumentRef? {
    appState.allDocuments.first(where: { $0.id == id })
      ?? (documentWindowRegistry.openTabDocumentIDs.contains(id.standardizedFileURL)
        ? appState.makeDocumentRef(for: id) : nil)
  }

  /// Default click (Open Files list, workspace tree, search result, context-menu
  /// "Open"): load the document in the current window, reusing the active editor
  /// pane. This is the VS Code / Zed model — a single click never spawns a window
  /// or tab. New tabs come only from the explicit `openDocumentInNewWindow`
  /// gesture. Clicking the currently displayed document is a no-op.
  func openDocumentWindow(id: DocumentRef.ID?) {
    guard let id, let ref = resolveDocumentRef(for: id) else { return }

    if appState.selectedDocumentID?.standardizedFileURL == ref.id.standardizedFileURL {
      return
    }

    DebugTrace.log("openDocumentWindow -> select in current window: \(ref.id.lastPathComponent)")
    selectDocument(id: ref.id)
  }

  /// Explicit "Open in New Window" context-menu gesture: route through the window
  /// registry to open the document in a native tab (or activate the window
  /// already showing it). Clicking the currently displayed document is a no-op.
  /// Falls back to in-window selection when no routing is wired (tests, headless).
  func openDocumentInNewWindow(id: DocumentRef.ID?) {
    guard let id, let ref = resolveDocumentRef(for: id) else { return }

    if appState.selectedDocumentID?.standardizedFileURL == ref.id.standardizedFileURL {
      return
    }

    guard let requestOpenDocumentWindow else {
      DebugTrace.log(
        "openDocumentInNewWindow -> select in current window (no routing): \(ref.id.lastPathComponent)"
      )
      selectDocument(id: ref.id)
      return
    }

    DebugTrace.log("openDocumentInNewWindow -> registry: \(ref.id.lastPathComponent)")
    requestOpenDocumentWindow(ref)
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
      appState.lastError = "Open an editable document before inserting Dictation."
      return false
    }

    if let textView = activeTextView ?? NSApp.keyWindow?.firstResponder as? MarkdownTextView,
      textView.insertDictationAtSelection(text)
    {
      transcriptionService.resetTranscript()
      transcriptionService.updateDispatchStatus("Inserted into the active document.")
      appState.lastError = nil
      return true
    }

    appendTranscriptionToDocument(text)
    transcriptionService.resetTranscript()
    transcriptionService.updateDispatchStatus("Inserted at the end of the active document.")
    appState.lastError = nil
    return true
  }

  @discardableResult
  private func dispatchTranscriptionToAgent() -> Bool {
    let prompt = transcriptionService.rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else { return false }

    return dispatchToAgent(
      workflow: "implement",
      payload: .prompt(prompt),
      label: "transcription",
      startStatus: "Dispatching to agent...",
      onSuccess: { [transcriptionService] in
        transcriptionService.resetTranscript()
      }
    )
  }

  // MARK: - Dispatch gateway (request → sheet → confirm)

  /// Gateway entry for the CURRENT document (toolbar ✈, Agents menu, Agents
  /// workflow submenu). Builds the typed intent and asks THIS window's
  /// `ContentView` to present the canonical configuration sheet — it never
  /// launches anything. A saved document dispatches as a file, an unsaved
  /// buffer as its text; both stay editable in the sheet before Dispatch.
  @discardableResult
  func requestCurrentDocumentDispatch(
    workflow: String,
    source: DispatchIntent.Source,
    allowsExternalDispatch: Bool = SandboxCapabilities.allowsExternalAgentDispatch()
  ) -> Bool {
    guard allowsExternalDispatch else {
      appState.lastError = SandboxCapabilities.dispatchUnavailableExplanation
      return false
    }
    guard appState.documentSession.hasEditableBuffer else {
      appState.lastError = "Open an editable document before dispatching to an agent."
      return false
    }

    let subject: DispatchIntent.Subject
    if let url = appState.documentSession.url {
      subject = .savedDocument(url)
    } else {
      subject = .unsavedBuffer(
        title: appState.documentSession.displayTitle,
        text: appState.activeDocumentText
      )
    }
    appState.pendingDispatchIntent = DispatchIntent(
      subject: subject, workflow: workflow, source: source)
    return true
  }

  /// Gateway entry for a sidebar file action: same sheet, `.file` subject.
  @discardableResult
  func requestFileDispatch(
    url: URL,
    workflow: String,
    source: DispatchIntent.Source,
    allowsExternalDispatch: Bool = SandboxCapabilities.allowsExternalAgentDispatch()
  ) -> Bool {
    guard allowsExternalDispatch else {
      appState.lastError = SandboxCapabilities.dispatchUnavailableExplanation
      return false
    }
    appState.pendingDispatchIntent = DispatchIntent(
      subject: .fileURL(url.standardizedFileURL), workflow: workflow, source: source)
    return true
  }

  /// Default run root the sheet opens with: the injected override (tests,
  /// scripted launches) wins, then the W1-B remembered root, then workspace/
  /// document/home fallbacks — the same chain the launch itself uses.
  func defaultDispatchRoot() -> URL {
    appState.resolveDispatchRoot(explicitOverride: agentWorkspaceRoot)
  }

  /// Transcription tafla's "send to agent" funnel. This is NOT a blind UI
  /// route: it only fires from the tafla's explicit send control, on the
  /// dictated text itself. Private so no menu/toolbar/sidebar surface can
  /// reach a launch without the gateway sheet.
  @discardableResult
  private func dispatchToAgent(
    workflow: String,
    payload: AgentDispatchPayload,
    label: String,
    startStatus: String? = nil,
    onSuccess: (@MainActor @Sendable () -> Void)? = nil
  ) -> Bool {
    // Sandboxed (App Store) build: spawning the vibecrafted CLI is denied by
    // the sandbox. The UI already disables its entry points; this guard keeps
    // any other path honest instead of dying inside Process.run().
    guard SandboxCapabilities.allowsExternalAgentDispatch() else {
      appState.lastError = SandboxCapabilities.dispatchUnavailableExplanation
      return false
    }
    guard !isAgentDispatchInFlight else { return false }
    guard !payload.isEmpty else { return false }

    isAgentDispatchInFlight = true
    transcriptionService.updateDispatchStatus(
      startStatus ?? "Dispatching \(label) to \(workflow)...")
    let launcher = agentPromptLauncher
    let agent = defaultAgent
    let workingDirectoryURL = appState.resolveDispatchRoot(
      explicitOverride: agentWorkspaceRoot)
    let appState = appState
    let transcriptionService = transcriptionService

    Task.detached(priority: .utility) { [weak self] in
      do {
        let metadata = try launcher.dispatch(
          workflow: workflow,
          agent: agent,
          payload: payload,
          workingDirectoryURL: workingDirectoryURL
        )
        await self?.completeAgentDispatch(
          metadata: metadata,
          appState: appState,
          transcriptionService: transcriptionService,
          onSuccess: onSuccess
        )
      } catch {
        let message = "Dispatch failed: \(error.localizedDescription)"
        await self?.failAgentDispatch(
          message: message,
          appState: appState,
          transcriptionService: transcriptionService
        )
      }
    }

    return true
  }

  private func completeAgentDispatch(
    metadata: AgentDispatchMetadata,
    appState: AppState,
    transcriptionService: TranscriptionService,
    onSuccess: (@MainActor @Sendable () -> Void)?
  ) {
    if metadata.exitCode == 0 {
      onSuccess?()
      appState.lastError = nil
    } else {
      appState.lastError = metadata.statusLine
    }
    transcriptionService.updateDispatchStatus(metadata.statusLine)
    isAgentDispatchInFlight = false
  }

  private func failAgentDispatch(
    message: String,
    appState: AppState,
    transcriptionService: TranscriptionService
  ) {
    transcriptionService.updateDispatchStatus(message)
    appState.lastError = message
    isAgentDispatchInFlight = false
  }

  // MARK: - Agent discovery + Terminal dispatch

  /// Refresh `availableAgents` from `vibecrafted doctor` (dynamic, not hardcoded).
  /// Safe to call repeatedly (e.g. from the dispatch popover's onAppear).
  func discoverAgents() {
    Task.detached(priority: .utility) {
      let discovered = Self.probeAgents()
      guard !discovered.isEmpty else { return }
      await MainActor.run { [weak self] in self?.availableAgents = discovered }
    }
  }

  nonisolated private static func probeAgents() -> [String] {
    guard let exe = try? VibecraftedAgentPromptLauncher.resolveExecutablePath() else { return [] }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exe)
    process.arguments = ["doctor"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""
    return agentStreamNames(in: output)
  }

  /// Parse `vibecrafted doctor` output for `agent-stream:<name>` agent names,
  /// in first-seen order, deduplicated. Pure + testable.
  nonisolated static func agentStreamNames(in output: String) -> [String] {
    // Lines look like: "ok: agent-stream:codex - codex-cli 0.137.0"
    var names: [String] = []
    for line in output.split(separator: "\n") {
      guard let marker = line.range(of: "agent-stream:") else { continue }
      let tail = line[marker.upperBound...]
      let name = String(tail.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        .trimmingCharacters(in: .whitespaces)
      if !name.isEmpty, !names.contains(name) { names.append(name) }
    }
    return names
  }

  /// Outcome of a document dispatch surfaced to the dispatch sheet for an
  /// explicit, unmissable in-app confirmation (the user must know it fired).
  enum DocumentDispatchOutcome: Sendable {
    case success(runID: String?, reportPath: String?, statusLine: String)
    case failure(message: String)
  }

  /// The ONLY UI → launch path: headless dispatch of a confirmed intent via
  /// the canonical uv-core entry, which prints a parseable launch receipt
  /// (run_id / report path) and detaches. Called exclusively by the gateway
  /// sheet's Dispatch button; the sheet shows "Dispatched ✓ run: …" from the
  /// returned outcome. `workflow`/`agent`/`rootURL` are the sheet's edited
  /// values; the payload comes from the intent's subject snapshot. Terminal
  /// observability is a separate, user-triggered affordance
  /// (`observeRunInTerminal`) so a successful run never depends on a terminal.
  func confirmDispatch(
    intent: DispatchIntent,
    workflow: String,
    agent: String,
    rootURL: URL,
    allowsExternalDispatch: Bool = SandboxCapabilities.allowsExternalAgentDispatch()
  ) async -> DocumentDispatchOutcome {
    guard allowsExternalDispatch else {
      return .failure(message: SandboxCapabilities.dispatchUnavailableExplanation)
    }
    let payload = intent.payload
    guard !payload.isEmpty else {
      return .failure(message: "There is nothing to dispatch — the document is empty.")
    }
    // Second line of defense behind the sheet's synchronous phase guard: even
    // if two confirmations race in, only one may reach the launcher.
    guard !isAgentDispatchInFlight else {
      return .failure(message: "A dispatch is already running. Wait for it to finish.")
    }
    isAgentDispatchInFlight = true
    defer { isAgentDispatchInFlight = false }

    let launcher = agentPromptLauncher
    let title = intent.subjectLabel
    do {
      let metadata = try await Task.detached(priority: .userInitiated) {
        try launcher.dispatch(
          workflow: workflow, agent: agent,
          payload: payload, workingDirectoryURL: rootURL)
      }.value
      guard metadata.exitCode == 0 else {
        appState.lastError = metadata.statusLine
        transcriptionService.updateDispatchStatus(metadata.statusLine)
        return .failure(message: metadata.statusLine)
      }
      appState.lastError = nil
      let line = "Dispatched \(title) → \(workflow) (\(agent)) in \(rootURL.lastPathComponent)"
      transcriptionService.updateDispatchStatus(
        metadata.runID.map { "\(line) · run: \($0)" } ?? line)
      return .success(
        runID: metadata.runID, reportPath: metadata.reportPath, statusLine: line)
    } catch {
      let message = "Dispatch failed: \(error.localizedDescription)"
      appState.lastError = message
      transcriptionService.updateDispatchStatus(message)
      return .failure(message: message)
    }
  }

  /// Best-effort: open Terminal tailing a launched run via the receipt's
  /// `vibecrafted <agent> observe --run-id <id>`. User-triggered from the sheet;
  /// failure is swallowed because the in-app confirmation is the source of truth.
  nonisolated func observeRunInTerminal(agent: String, runID: String) {
    // Sandboxed build: osascript/Terminal automation is unavailable; only
    // reachable after a dispatch, which the sandbox guard already blocks.
    guard SandboxCapabilities.allowsExternalAgentDispatch() else { return }
    // Defense-in-depth before the values are composed into the Terminal command
    // below: agent/runID are parsed from the launcher receipt, so fail closed on
    // anything outside a strict shell-safe charset instead of relying solely on
    // the quoting/AppleScript-escaping. (The proper fix — dropping AppleScript for
    // `open -a Terminal` — is tracked separately as it changes terminal-spawn UX.)
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    guard !agent.isEmpty, agent.unicodeScalars.allSatisfy(allowed.contains),
      !runID.isEmpty, runID.unicodeScalars.allSatisfy(allowed.contains)
    else { return }
    guard let exe = try? VibecraftedAgentPromptLauncher.resolveExecutablePath() else { return }
    func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let command = "\(quote(exe)) \(quote(agent)) observe --run-id \(quote(runID))"
    let asEscaped =
      command
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let script = """
      tell application "Terminal"
        activate
        do script "\(asEscaped)"
      end tell
      """
    let osa = Process()
    osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    osa.arguments = ["-e", script]
    try? osa.run()
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
