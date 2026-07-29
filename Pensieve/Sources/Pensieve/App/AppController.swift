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
  typealias FolderTrashConfirmation = @MainActor (URL) -> Bool
  /// Confirms dropping a crash draft for good. Synchronous like the folder
  /// trash question: nothing is being torn down, so a plain alert is enough.
  typealias DraftDiscardConfirmation = @MainActor (RecoveryDraft) -> Bool
  /// Asks the save question for a close and reports the answer back. Async by
  /// construction: the production surface is a window-modal sheet, which can
  /// only answer later. Tests inject a closure that answers immediately.
  typealias SaveChangesConfirmation =
    @MainActor (
      DocumentClosePrompt, DocumentSession, NSWindow?,
      @escaping @MainActor (SaveChangesResponse) -> Void
    ) -> Void

  private let appState: AppState
  private let folderManager: FolderManager
  private let documentStore: DocumentStore
  private let indexDatabase: IndexDatabase
  private let launchSettings: LaunchSettings
  private let documentWindowRegistry: DocumentWindowRegistry
  let recentDocuments: RecentDocumentsStore
  private let agentPromptLauncher: AgentPromptLaunching
  private let agentWorkspaceRoot: URL?
  private let importsFoldersInBackground: Bool
  private let workspaceSearchDebounceNanoseconds: UInt64
  private let confirmFolderTrash: FolderTrashConfirmation
  private let confirmSaveChanges: SaveChangesConfirmation
  private let confirmDiscardDraft: DraftDiscardConfirmation
  /// Unhandled crash drafts, newest first — the model behind the launcher's
  /// "Recovered Drafts" section. Empty means the section is not shown at all.
  @Published private(set) var recoveredDrafts: [RecoveryDraft] = []
  /// Resolves the window the close sheet must hang off. Wired per window by
  /// the document root view; `NSApp.keyWindow` is the fallback for scenes that
  /// never reported one.
  var hostWindowProvider: (@MainActor () -> NSWindow?)?
  /// One close question at a time per window — a second ⌘W while the sheet is
  /// up must not stack another sheet on the same document.
  private var isConfirmingClose = false
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
  /// Capability truth from `vibecrafted capabilities --json` (W2-C): the ONLY
  /// authority on whether a workflow runs one agent or a swarm, who the swarm
  /// members are, and which configured tokens are unsupported. Probed fresh on
  /// every sheet presentation — never cached across the operator's config edits.
  @Published private(set) var workflowCapabilitiesState: WorkflowCapabilitiesState = .idle
  private let workflowCapabilitiesProvider: WorkflowCapabilitiesProviding
  private var workflowCapabilitiesRefreshTask: Task<Void, Never>?
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
    launchSettings: LaunchSettings? = nil,
    documentWindowRegistry: DocumentWindowRegistry? = nil,
    recentDocuments: RecentDocumentsStore? = nil,
    transcriptionService: TranscriptionService? = nil,
    agentPromptLauncher: AgentPromptLaunching = VibecraftedAgentPromptLauncher(),
    workflowCapabilitiesProvider: WorkflowCapabilitiesProviding =
      VibecraftedWorkflowCapabilitiesProvider(),
    agentWorkspaceRoot: URL? = nil,
    importsFoldersInBackground: Bool = false,
    workspaceSearchDebounceNanoseconds: UInt64 = 250_000_000,
    confirmFolderTrash: @escaping FolderTrashConfirmation = { url in
      let alert = NSAlert()
      alert.messageText = "Move \(url.lastPathComponent) to Trash?"
      alert.informativeText = "This folder and its contents will move to the system Trash."
      alert.alertStyle = .warning
      alert.addButton(withTitle: "Move to Trash")
      alert.addButton(withTitle: "Cancel")
      return alert.runModal() == .alertFirstButtonReturn
    },
    confirmSaveChanges: @escaping SaveChangesConfirmation = { prompt, session, window, respond in
      SaveChangesSheet.present(
        prompt: prompt,
        session: session,
        in: window,
        completion: respond)
    },
    confirmDiscardDraft: @escaping DraftDiscardConfirmation = { draft in
      let alert = NSAlert()
      alert.messageText = "Discard this recovered draft?"
      alert.informativeText =
        "\"\(draft.previewSnippet)\" has never been saved to a file. Discarding it cannot be undone."
      alert.alertStyle = .warning
      alert.addButton(withTitle: "Discard")
      alert.addButton(withTitle: "Cancel")
      alert.buttons[1].keyEquivalent = "\u{1b}"
      return alert.runModal() == .alertFirstButtonReturn
    }
  ) {
    self.appState = appState
    self.folderManager = folderManager
    self.documentStore = documentStore
    self.indexDatabase = indexDatabase ?? .shared
    self.launchSettings = launchSettings ?? .shared
    self.documentWindowRegistry = documentWindowRegistry ?? .shared
    self.recentDocuments = recentDocuments ?? .shared
    self.agentPromptLauncher = agentPromptLauncher
    self.workflowCapabilitiesProvider = workflowCapabilitiesProvider
    self.agentWorkspaceRoot = agentWorkspaceRoot
    self.transcriptionService = transcriptionService ?? TranscriptionService()
    self.importsFoldersInBackground = importsFoldersInBackground
    self.workspaceSearchDebounceNanoseconds = workspaceSearchDebounceNanoseconds
    self.confirmFolderTrash = confirmFolderTrash
    self.confirmSaveChanges = confirmSaveChanges
    self.confirmDiscardDraft = confirmDiscardDraft
    self.documentStore.observeSelfWrites { [weak folderManager] url in
      folderManager?.noteSelfWrite(at: url)
    }
  }

  /// Boots THIS window according to why it was opened. The intent answers both
  /// restore questions — rebuild the workspace, pick a document — instead of the
  /// single `restoringWorkspace` boolean that used to conflate them (and treated
  /// a launcher reborn mid-session exactly like a cold launch).
  func start(intent: LaunchIntent = .coldLaunch) {
    guard !didStart else { return }
    didStart = true

    // Crash drafts are surfaced, never adopted: this only fills the launcher's
    // Recovered Drafts list.
    refreshRecoveredDrafts()

    // Warm the index OFF the main thread. Opening the GRDB pool + running migrations (incl. the FTS5
    // content-link rebuild) on main here was the launch-time beachball; the workspace-restore path
    // also opens lazily, so this is just an early, non-blocking warm-up.
    let indexDatabase = indexDatabase
    Task { await indexDatabase.openInBackground(into: appState) }
    guard intent.restoresWorkspace else { return }

    // The workspace roots are configuration, not session state: they come back
    // on EVERY cold launch so the tree is never empty. The restore-session
    // toggle governs ONLY the open-files working set (and the auto-selected
    // document it would display) — a cold launch with it off lands on the
    // restored workspace tree with nothing open and nothing selected. Dock
    // reopen / the tab bar's "+" restore their files as they always did.
    // Persisted bookmarks are untouched either way; only the open-files
    // auto-invoke is gated.
    let restoresOpenFiles =
      intent != .coldLaunch || launchSettings.restoreSessionOnLaunch

    folderManager.restoreLastFolderInBackground(
      into: appState,
      restoresOpenFiles: restoresOpenFiles,
      selectsRestoredDocument: intent.selectsRestoredDocument)
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

  func moveItemToTrash(url: URL) async -> Bool {
    let source = url.standardizedFileURL
    DebugTrace.log("trash request path=\(source.path)")

    guard !isWorkspaceRoot(source) else {
      appState.lastError =
        "Workspace roots can’t be moved to Trash. Remove the folder from the workspace first, then move it in Finder."
      DebugTrace.log("trash request rejected root=\(source.path)")
      return false
    }

    if isDirectory(source), !confirmFolderTrash(source) {
      DebugTrace.log("trash request cancelled path=\(source.path)")
      return false
    }

    guard await folderManager.moveToTrash(url: source, into: appState) else { return false }
    closeDocumentWindowsAffectedByTrash(at: source)
    return true
  }

  private func closeDocumentWindowsAffectedByTrash(at source: URL) {
    let affectedDocumentIDs = documentWindowRegistry.openTabDocumentIDs.filter {
      isAffectedByTrash(documentID: $0, source: source)
    }
    for documentID in affectedDocumentIDs {
      documentWindowRegistry.closeDocumentWindow(documentID)
    }
  }

  private func isWorkspaceRoot(_ source: URL) -> Bool {
    appState.workspaceRoots.contains {
      $0.url.standardizedFileURL == source.standardizedFileURL
    }
  }

  private func isDirectory(_ source: URL) -> Bool {
    var isDirectory = ObjCBool(false)
    return FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
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
    // tab/window. If it is THIS window's active doc it goes through the same
    // conscious close as ⌘W — one lifecycle, whichever gesture triggers it.
    closeOpenDocument(identity: .file(id.standardizedFileURL))
  }

  func closeOpenDocument(identity: DocumentIdentity) {
    // Open Files mirrors EVERY window's documents, so this close may target a
    // document owned by another window. Route the close DECISION to the OWNING
    // window's session — prompting only the caller's would force-close the
    // target, letting its close hook stash a recovery draft and skip the
    // Save / Don't Save / Cancel prompt. Fall back to self when no owner is
    // registered. When the identity is not any window's active document there
    // is no live dirty session to guard, so the tab is torn down directly.
    let owner = documentWindowRegistry.controller(for: identity) ?? self
    guard owner.appState.windowModel.documentIdentity == identity.standardized else {
      documentWindowRegistry.closeDocument(identity)
      return
    }
    owner.closeActiveDocument { [weak self] didClose in
      guard let self, didClose else { return }
      self.documentWindowRegistry.closeDocument(identity)
    }
  }

  /// Phase-1 confirm for THIS window's session, the single source of truth for
  /// every multi-window pass that can still be cancelled after this window has
  /// answered — "Clear Open Files" and ⌘Q alike. Runs the NON-DESTRUCTIVE decide
  /// half: a Save writes its bytes (a write is not a loss, and a failed I/O is
  /// the last thing that can still abort the pass), while a Discard is only
  /// RECORDED, never applied. Returns `nil` when the user cancelled, which the
  /// caller must read as "apply nothing, close nothing".
  func confirmDirtySessionForDeferredClose() -> DocumentStore.DirtySessionResolution? {
    documentStore.confirmDirtySessionForExternalClose(appState: appState)
  }

  /// The "Clear Open Files" entry point: the same phase-1 confirm, gated on the
  /// pass actually targeting this window's active document. When `identity` is
  /// not this window's active doc it is a no-op reporting `.settled`.
  func confirmDirtySessionForExternalClose(
    identity: DocumentIdentity
  ) -> DocumentStore.DirtySessionResolution? {
    guard appState.windowModel.documentIdentity == identity.standardized else { return .settled }
    return confirmDirtySessionForDeferredClose()
  }

  /// Phase-2 apply for a deferred multi-window pass: performs the destructive
  /// step phase 1 deferred for this window — dropping an untitled draft the user
  /// chose to Discard and marking it clean. `.settled` is a no-op.
  func applyDeferredDirtySessionResolution(_ resolution: DocumentStore.DirtySessionResolution) {
    documentStore.applyDeferredDirtySessionResolution(resolution, appState: appState)
  }

  func clearOpenFiles() {
    // Open Files mirrors EVERY window's documents, so "Clear Open Files" tears
    // down tabs owned by other windows too. Guarding only this window's active
    // doc (the old behavior) let closeAllDocumentWindows discard another
    // window's unsaved edits with no prompt. Run each document's dirty guard in
    // its OWNING window's session, mirroring closeOpenDocument.
    //
    // ATOMIC COLLECT-THEN-APPLY over ONE identity snapshot, so a Cancel can
    // never leave a partially-mutated UI — not even a window silently emptied of
    // its recoverable draft:
    //
    //   Phase 1 (COLLECT) — ask every owner and RECORD its resolution without
    //   performing any deferred destruction. A Save (or force-save) does write
    //   bytes — that is not a loss and is the only step where a failed I/O can
    //   still abort — but a Discard is only remembered, its recovery draft left
    //   intact. If ANY owner cancels, apply nothing and close nothing: every
    //   window keeps its content, and an untitled Discard is still recoverable.
    //   The one thing NOT rolled back is a Save already committed in this pass.
    //
    //   Phase 2 (APPLY) — only once EVERY owner resolved, apply the deferred
    //   Discards FIRST (drop the draft, mark clean) so no abandoned draft
    //   resurrects and no stale `isDirty` trips the teardown save hook, THEN
    //   close the windows. No explicit per-window clear is needed: closing a
    //   window discards its `AppState` (and thus its session) outright.
    //
    // DELIBERATE DIVERGENCE from the conscious-close work landing in this same
    // stack: the Save/Don't Save/Cancel SHEET (`closeActiveDocument`,
    // `DocumentCloseDecision`, `SaveChangesSheet`) is NOT used here. That path is
    // asynchronous and asks about ONE window; this pass has to resolve EVERY
    // owning window and stay atomic, which the callback form cannot express
    // today. Routing Clear Open Files through the sheet would have reinstated the
    // single-window guard and with it the silent-loss bug this collect/apply
    // shape exists to prevent.
    //
    // The quit path (`applicationShouldTerminate`) now shares these primitives:
    // it was the other multi-window pass carrying the identical non-atomic
    // defect, and it collects-then-applies through the same
    // `confirmDirtySessionForDeferredClose` / `applyDeferredDirtySessionResolution`
    // pair. FOLLOW-UP, still open but no longer a data-loss one: drive both
    // passes through the sheet, so they are visually consistent with the rest of
    // the close surface.
    let identities = documentWindowRegistry.openDocuments.map(\.identity)

    var deferred: [(owner: AppController, resolution: DocumentStore.DirtySessionResolution)] = []
    for identity in identities {
      let owner = documentWindowRegistry.controller(for: identity) ?? self
      guard let resolution = owner.confirmDirtySessionForExternalClose(identity: identity) else {
        return
      }
      deferred.append((owner, resolution))
    }

    for (owner, resolution) in deferred {
      owner.applyDeferredDirtySessionResolution(resolution)
    }
    documentWindowRegistry.closeAllDocumentWindows()
  }

  /// The New File gesture, from every surface that offers it: ⌘N, the sidebar
  /// header "+", the empty-state button, and a folder's "New File" context menu.
  ///
  /// A new document is a DRAFT — it lives in this session and NOWHERE else.
  /// Creating one writes nothing into the user's workspace: opening a note and
  /// walking away must leave the folder exactly as it was, instead of leaving
  /// `Untitled.md`, `Untitled 3.md`, … behind. The draft reaches disk only when
  /// the user names it (Save panel / Save As…), which is the one gesture that
  /// says where it belongs.
  ///
  /// Unsaved content is not at risk in the meantime: a dirty draft is persisted
  /// into the recovery store by autosave and again on close — the same
  /// crash-safe path an imported Word/PDF draft already uses.
  ///
  /// `folderURL` is only where the gesture happened. It steers the Save panel's
  /// starting directory through the sidebar focus the File menu already reads;
  /// it is never created, written to, or scanned for a free file name.
  @discardableResult
  func createUntitledDocument(in folderURL: URL? = nil) -> Bool {
    guard documentStore.prepareForDocumentSwitch(appState: appState) else {
      return false
    }

    if let folderURL {
      appState.sidebarFocusedURL = folderURL.standardizedFileURL
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
    // ⌘Q must ask about EVERY window's unsaved work, not just the one it fired
    // from. Other windows would otherwise exit through their teardown path,
    // which has no veto point left and can only stash a recovery draft, never
    // ask.
    //
    // ATOMIC COLLECT-THEN-APPLY, on the same primitives "Clear Open Files"
    // uses — a quit is the other multi-window pass a LATE Cancel can abort:
    //
    //   Phase 1 (COLLECT) — ask every window and RECORD its resolution without
    //   performing any deferred destruction. A Save does write bytes (not a
    //   loss, and the last step a failed I/O can still abort the quit on), but
    //   a Discard is only remembered: its recovery draft stays on disk and its
    //   buffer stays dirty. If ANY window cancels, apply nothing and quit
    //   nothing — every window is exactly as it was, and an untitled Discard
    //   answered earlier in this same pass is still recoverable.
    //
    //   Phase 2 (APPLY) — only once EVERY window consented, run the deferred
    //   Discards. Fusing the two (the old `prepareForDocumentSwitch` per
    //   window) meant a "Don't Save" in one window physically deleted its
    //   recovery draft and cleared `isDirty` BEFORE a later window's Cancel
    //   aborted the quit — leaving a still-rendered buffer that no longer
    //   survives a crash and that the next ⌘Q/close no longer asks about.
    //
    // Self is asked LAST so the firing window's own prompt is the final word,
    // exactly as before.
    var deferred: [(controller: AppController, resolution: DocumentStore.DirtySessionResolution)] =
      []
    let others = documentWindowRegistry.registeredControllers().filter { $0 !== self }
    for controller in others {
      guard let resolution = controller.confirmDirtySessionForDeferredClose() else { return false }
      deferred.append((controller, resolution))
    }
    guard let ownResolution = confirmDirtySessionForDeferredClose() else { return false }
    deferred.append((self, ownResolution))

    for (controller, resolution) in deferred {
      controller.applyDeferredDirtySessionResolution(resolution)
    }
    // Only truncate the WAL once quitting is actually going through — a cancelled quit (unsaved
    // work) must leave the index exactly as the still-running session expects it. Bounded so a long
    // in-flight reindex write cannot beachball the quit.
    indexDatabase.checkpointOnTerminate()
    return true
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

  /// Teardown of THIS window/tab: the red close button, the tab's "×", the
  /// sidebar closing another window's document, or ⌘W falling through to a
  /// native window close. Flushes the pending edit exactly as before, then
  /// drops the document from the Open Files working set — a tab closing is a
  /// close like any other, and the list means "open right now".
  ///
  /// Suppressed while the app is terminating: quit tears every window down at
  /// once, and reading that as "the user closed all of these" would erase the
  /// very working set the next launch is supposed to bring back.
  func documentWindowWillClose() {
    savePendingChangesOnClose()
    guard !documentWindowRegistry.isApplicationTerminating else { return }
    guard let url = appState.documentSession.url else { return }
    documentStore.forgetOpenFile(url: url, appState: appState)
  }

  /// Closes the active document session without exiting Pensieve — the window
  /// stays alive and reverts to its empty state.
  ///
  /// A normal close is a CONSCIOUS lifecycle: unsaved work asks
  /// `Save / Don't Save / Cancel` (`Save As…` for a draft that has no file
  /// yet) instead of being silently written, silently dropped, or left for
  /// crash recovery to guess at. Nothing untouched or already-saved asks
  /// anything. `completion` reports whether the document actually closed; it
  /// fires after the sheet is answered, so it is asynchronous whenever the
  /// close needs a decision.
  func closeActiveDocument(completion: (@MainActor (Bool) -> Void)? = nil) {
    let decision = documentStore.closeDecision(appState: appState)

    guard let prompt = decision.prompt else {
      // Bind the result FIRST: `completion?(finishClose(…))` would skip the
      // close entirely whenever the caller passed no completion, because
      // optional chaining never evaluates the argument of a nil call.
      let didClose = documentStore.finishClose(
        decision: decision, response: nil, appState: appState)
      refreshRecoveredDrafts()
      completion?(didClose)
      return
    }

    // A sheet is already asking about this very document — treat the extra ⌘W
    // as a no-op rather than stacking a second question on the same buffer.
    guard !isConfirmingClose else {
      completion?(false)
      return
    }

    isConfirmingClose = true
    let session = appState.documentSession
    confirmSaveChanges(prompt, session, hostWindowProvider?() ?? Self.currentKeyWindow()) {
      [weak self] response in
      guard let self else { return }
      self.isConfirmingClose = false
      let didClose = self.documentStore.finishClose(
        decision: decision, response: response, appState: self.appState)
      self.refreshRecoveredDrafts()
      completion?(didClose)
    }
  }

  /// Whether THIS window may close on the red close button or a tab's "×".
  /// Mirrors the ⌘W conscious lifecycle (`closeActiveDocument`) but ends by
  /// closing the WINDOW instead of reverting it to the empty state — the red
  /// button means "this window goes away". Returns true when AppKit may tear the
  /// window down immediately (nothing unsaved, or auto-save owns the file, in
  /// which case the `willCloseNotification` teardown flushes it). Returns false
  /// when a Save / Don't Save / Cancel sheet is now up: on Save or Don't Save the
  /// window is closed programmatically once the answer lands; on Cancel — or a
  /// failed save — it stays exactly as it was, so no unsaved work is lost to a
  /// close the user did not confirm.
  @discardableResult
  func windowShouldClose(_ window: NSWindow) -> Bool {
    let decision = documentStore.closeDecision(appState: appState)
    guard let prompt = decision.prompt else {
      // closeWithoutPrompting / saveWithoutPrompting: nothing to ask. Let the
      // normal teardown run — for an auto-save-owned file it flushes on close.
      return true
    }

    // A sheet is already asking about this very document — treat the extra close
    // as a no-op rather than stacking a second question on the same buffer.
    guard !isConfirmingClose else { return false }

    isConfirmingClose = true
    let session = appState.documentSession
    confirmSaveChanges(prompt, session, hostWindowProvider?() ?? Self.currentKeyWindow()) {
      [weak self, weak window] response in
      guard let self else { return }
      self.isConfirmingClose = false
      let didClose = self.documentStore.finishClose(
        decision: decision, response: response, appState: self.appState)
      self.refreshRecoveredDrafts()
      // Only a settled close (saved or discarded) tears the window down; its
      // `willCloseNotification` guard is a no-op on the now-clean session. Cancel
      // or a failed save leaves the window — and its buffer — intact.
      guard didClose else { return }
      window?.close()
    }
    return false
  }

  // MARK: - Recovered drafts (launcher surface)

  /// Re-reads the recovery directory. Called whenever the launcher section
  /// appears and after every action that can change the list, so the view never
  /// shows a draft that is already gone.
  func refreshRecoveredDrafts() {
    recoveredDrafts = documentStore.recoveredDrafts()
  }

  /// `Open`: adopt the draft into this (empty) window. The draft stays on disk
  /// until it is saved or discarded — opening is not deciding.
  @discardableResult
  func openRecoveredDraft(_ draft: RecoveryDraft) -> Bool {
    let didOpen = documentStore.openRecoveredDraft(draft, into: appState)
    refreshRecoveredDrafts()
    return didOpen
  }

  /// `Save As…`: pick a location, write the draft there, retire it. A cancelled
  /// panel leaves everything untouched.
  @discardableResult
  func saveRecoveredDraftAs(_ draft: RecoveryDraft) -> Bool {
    let didSave = documentStore.saveRecoveredDraftAs(draft, into: appState)
    refreshRecoveredDrafts()
    return didSave
  }

  /// `Discard`: drop the draft after the user confirms. Returns whether it was
  /// actually discarded.
  @discardableResult
  func discardRecoveredDraft(_ draft: RecoveryDraft) -> Bool {
    guard confirmDiscardDraft(draft) else { return false }
    documentStore.discardRecoveredDraft(draft)
    refreshRecoveredDrafts()
    return true
  }

  /// `NSApp` is an implicitly unwrapped global that stays nil until something
  /// instantiates the application — reading `.keyWindow` off it traps in a
  /// headless test process. Ask only once the app object exists.
  private static func currentKeyWindow() -> NSWindow? {
    guard let app = NSApp else { return nil }
    return app.keyWindow
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

  /// Single click (Open Files list, workspace tree, search result, context-menu
  /// "Open"): open the document as a native window tab through the window
  /// registry — the same route a Finder "Open with Pensieve" takes. A click is
  /// an explicit open, so it never replaces the document in the current pane:
  /// files stay visible in parallel and switching between them is switching
  /// tabs. A document already open elsewhere activates its existing tab instead
  /// of spawning a second one, and clicking the document this window already
  /// shows is a no-op.
  /// Falls back to in-window selection when no routing is wired (tests, headless).
  func openDocumentWindow(id: DocumentRef.ID?) {
    guard let id, let ref = resolveDocumentRef(for: id) else { return }

    if appState.selectedDocumentID?.standardizedFileURL == ref.id.standardizedFileURL {
      return
    }

    guard let requestOpenDocumentWindow else {
      DebugTrace.log(
        "openDocumentWindow -> select in current window (no routing): \(ref.id.lastPathComponent)"
      )
      selectDocument(id: ref.id)
      return
    }

    DebugTrace.log("openDocumentWindow -> registry: \(ref.id.lastPathComponent)")
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
          agents: [agent],
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

  // MARK: - Workflow capability truth (W2-C consumption)

  /// How the sheet may present `workflow` right now, from capability truth.
  /// Pure derivation over the published state — recomputed on every render.
  func dispatchPlan(for workflow: String) -> WorkflowDispatchPlan {
    WorkflowDispatchPlanner.plan(workflow: workflow, state: workflowCapabilitiesState)
  }

  /// Probe `vibecrafted capabilities --json` OFF the main thread. Called on
  /// every sheet presentation (`force: true` from the sheet, so a config edit
  /// between two sheets is always picked up) and from the sheet's Retry
  /// button. Never blocks presentation: the sheet renders the loading state.
  func refreshWorkflowCapabilities(force: Bool = false) {
    guard workflowCapabilitiesRefreshTask == nil else { return }
    if !force, case .loaded = workflowCapabilitiesState { return }
    workflowCapabilitiesState = .loading
    let provider = workflowCapabilitiesProvider
    workflowCapabilitiesRefreshTask = Task.detached(priority: .utility) { [weak self] in
      let result: Result<WorkflowCapabilities, Error>
      do {
        result = .success(try provider.fetchCapabilities())
      } catch {
        result = .failure(error)
      }
      await MainActor.run { [weak self] in
        guard let self else { return }
        self.workflowCapabilitiesRefreshTask = nil
        switch result {
        case .success(let capabilities):
          self.workflowCapabilitiesState = .loaded(capabilities)
          self.adoptCapabilityAgentUniverse(capabilities.agents)
        case .failure(let error):
          self.workflowCapabilitiesState = .failed(error.localizedDescription)
        }
      }
    }
  }

  /// Fold the capability agent universe into the picker: keep the seed's
  /// preference order for tokens the CLI still accepts, append newly supported
  /// ones, drop retired ones. `swarm` is an execution-target token, not a
  /// pickable single-agent lane.
  private func adoptCapabilityAgentUniverse(_ universe: [String]) {
    let lanes = universe.filter { $0 != "swarm" }
    guard !lanes.isEmpty else { return }
    let kept = availableAgents.filter { lanes.contains($0) }
    let added = lanes.filter { !kept.contains($0) }
    availableAgents = kept + added
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
    agents: [String],
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
    // Capability gate: the launch must be a shape the workflow's descriptor
    // sanctions. A single-agent workflow launches with exactly one agent; a
    // swarm launches with none (its configured members run) or with one
    // declared synthesizer choice. Unknown semantics never launch.
    switch dispatchPlan(for: workflow) {
    case .singleAgent:
      guard agents.count == 1 else {
        return .failure(message: "Pick one agent for \(workflow) before dispatching.")
      }
    case .swarm(let plan):
      guard
        agents.isEmpty
          || (agents.count == 1 && plan.synthesizerChoices.contains(agents[0]))
      else {
        return .failure(
          message:
            "\(agents.joined(separator: ", ")) can't take the \(workflow) run. "
            + "Available: \(plan.synthesizerChoices.joined(separator: ", ")).")
      }
    case .loading:
      return .failure(
        message: "Still checking how \(workflow) runs. Try again in a moment.")
    case .unavailable(let reason):
      return .failure(message: reason)
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
    let agentLabel = agents.isEmpty ? "agent team" : agents.joined(separator: ", ")
    do {
      let metadata = try await Task.detached(priority: .userInitiated) {
        try launcher.dispatch(
          workflow: workflow, agents: agents,
          payload: payload, workingDirectoryURL: rootURL)
      }.value
      guard metadata.exitCode == 0 else {
        appState.lastError = metadata.statusLine
        transcriptionService.updateDispatchStatus(metadata.statusLine)
        return .failure(message: metadata.statusLine)
      }
      appState.lastError = nil
      let line =
        "Dispatched \(title) → \(workflow) (\(agentLabel)) in \(rootURL.lastPathComponent)"
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
