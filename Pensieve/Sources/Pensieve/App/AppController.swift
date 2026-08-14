import AppKit
import Combine
import CoreGraphics
import Foundation

private enum DocumentImportOutcome: Sendable {
  case success(ImportedMarkdownDocument)
  case failure(String)
}

/// The application's ONE startup restore, as a process-wide fact.
///
/// Bringing the working set back is something the APPLICATION does once, when
/// it starts — not something every window that runs `start(intent:)` does.
/// Launchers created later by an explicit Dock reopen must not repeat that
/// startup restore. Closing a WINDOW deliberately leaves its files in the
/// working set — retiring a file is what closing the DOCUMENT does (⌘W, a
/// tab's "×", "Close from Open Files"; operator decision 2026-08-03) — while
/// closing the last window leaves the running app windowless until Dock reopen.
///
/// Production shares `.shared`; a test that simulates a launch holds its own
/// instance, because "once per process" is otherwise once per test BUNDLE.
@MainActor
final class ApplicationStartupRestore {
  static let shared = ApplicationStartupRestore()

  private var isUnclaimed = true

  /// True for the FIRST caller in this process, false for every one after it.
  func claimStartupRestore() -> Bool {
    defer { isUnclaimed = false }
    return isUnclaimed
  }
}

/// Becoming active is an APPLICATION event, so the working-set reconcile it
/// triggers is subscribed ONCE per process — not once per window.
///
/// It used to be armed in every `AppController.init`: with N windows open, one
/// activation ran N identical passes over the SAME shared working set (each a
/// `stat` plus a Trash `getRelationship` per open file, all on the main actor).
/// The subscription now lives here and fans out to one live controller per
/// distinct working set.
@MainActor
final class AppActivationReconciler {
  static let shared = AppActivationReconciler()

  /// Which working set a controller's reconcile would touch. Two windows of the
  /// same app share the process's one `WorkspaceStore` (`PensieveApp` builds it
  /// and hands it to every window's `AppState`), so they collapse to a single
  /// pass; a test harness with its own store still gets its own.
  struct WorkingSetKey: Hashable {
    let folderManager: ObjectIdentifier
    let workingSet: ObjectIdentifier
  }

  /// Weak by construction: a closed window's controller drops out on dealloc,
  /// so the process-wide subscription can outlive every window without holding
  /// one alive and without dangling. Last window closed ⇒ the pass is a no-op;
  /// a controller that appears later is served again.
  private let controllers = NSHashTable<AppController>.weakObjects()
  private var cancellable: AnyCancellable?

  private init() {}

  /// Registers a window's controller and arms the one subscription on first
  /// use. Nothing is ever unregistered by hand.
  func register(_ controller: AppController) {
    controllers.add(controller)
    guard cancellable == nil else { return }
    cancellable = NotificationCenter.default.publisher(
      for: NSApplication.didBecomeActiveNotification
    ).sink { _ in
      Task { @MainActor in AppActivationReconciler.shared.reconcile() }
    }
  }

  func reconcile() {
    for controller in Self.reconcilePass(over: controllers.allObjects) {
      controller.reconcileWorkingSetForAppActivation()
    }
  }

  /// One controller per distinct working set, in registration order. Pure, so
  /// the fan-out rule is pinnable without posting a notification.
  static func reconcilePass(over controllers: [AppController]) -> [AppController] {
    var seen = Set<WorkingSetKey>()
    return controllers.filter { seen.insert($0.workingSetKey).inserted }
  }
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
  /// Asks whether a global quit may continue while leaving a recovery copy on
  /// disk. The title identifies the document whose cleanup failed.
  typealias QuitAfterRecoveryRetirementFailureConfirmation = @MainActor (String) -> Bool

  private let appState: AppState
  private let folderManager: FolderManager
  private let documentStore: DocumentStore
  private let indexDatabase: IndexDatabase
  private let launchSettings: LaunchSettings
  private let documentWindowRegistry: DocumentWindowRegistry
  private let startupRestore: ApplicationStartupRestore
  let recentDocuments: RecentDocumentsStore
  private let agentPromptLauncher: AgentPromptLaunching
  private let agentWorkspaceRoot: URL?
  private let importsFoldersInBackground: Bool
  private let workspaceSearchDebounceNanoseconds: UInt64
  private let confirmFolderTrash: FolderTrashConfirmation
  private let confirmSaveChanges: SaveChangesConfirmation
  private let confirmDiscardDraft: DraftDiscardConfirmation
  private let confirmQuitAfterRecoveryRetirementFailure:
    QuitAfterRecoveryRetirementFailureConfirmation
  /// How many app-activation reconcile passes THIS controller ran. Per instance
  /// on purpose: the fan-out pin reads it instead of a process-wide counter, so
  /// whatever else is alive in the test bundle cannot move it.
  private(set) var appActivationReconcilePassCount = 0

  /// Identifies the working set this controller's activation reconcile touches.
  /// See `AppActivationReconciler.WorkingSetKey`.
  var workingSetKey: AppActivationReconciler.WorkingSetKey {
    AppActivationReconciler.WorkingSetKey(
      folderManager: ObjectIdentifier(folderManager),
      workingSet: ObjectIdentifier(appState.workspaceStore))
  }

  /// Finder can move an ad-hoc working-set file to Trash while no watched
  /// workspace root covers it. Returning to Pensieve is where the live working
  /// set finds out. Driven by `AppActivationReconciler`, once per activation.
  func reconcileWorkingSetForAppActivation() {
    appActivationReconcilePassCount += 1
    folderManager.reconcileExternalWorkingSetChanges(into: appState)
  }
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
  /// One-way, per window: this session's new-tab draft has been created. Set by
  /// `seedUntitledDraftForNewTab`, which both the window's construction and
  /// `start(.newUntitledTab)` call.
  private var didSeedUntitledDraftForNewTab = false
  var requestOpenDocumentWindow: ((DocumentRef) -> Void)?
  /// The launch restore's bulk route. One call for the WHOLE working set, so
  /// the registry can join every tab to the group and bring exactly one window
  /// front at the end instead of paying a full window presentation — and the
  /// tab-group frame sync that comes with it — per restored file. Unwired
  /// (tests, headless) falls back to the per-file route.
  var requestOpenRestoredDocumentWindows: (([DocumentRef]) -> Void)?
  /// Tells the registry a document is already on screen in THIS window, so
  /// nothing orders a window front for it afterwards. The launch window loads
  /// the first restored file into itself; its attach lands asynchronously, and
  /// without this the registry counts that as the document's first presentation
  /// and pulls this window in front of the tab the restore just fronted.
  var requestNoteDocumentAlreadyOnScreen: ((URL) -> Void)?
  var requestCloseCurrentWindowIfEmpty: (() -> Void)?
  /// Marks this window as holding content the sweep must not reap. Called when
  /// the window adopts a recovery draft, which carries no URL for the accessor
  /// to publish. Unwired (tests, headless) is harmless: nothing sweeps there.
  var requestPromoteWindowToContent: (() -> Void)?
  /// Re-runs the launcher sweep once this window's launch decision settles, so
  /// protecting an in-flight restore delays the reap instead of cancelling it.
  var requestLauncherSweepReconcile: (() -> Void)?

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
    startupRestore: ApplicationStartupRestore = .shared,
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
    },
    confirmQuitAfterRecoveryRetirementFailure:
      @escaping
    QuitAfterRecoveryRetirementFailureConfirmation = { title in
      let alert = NSAlert()
      alert.messageText = "The recovery copy couldn’t be removed."
      alert.informativeText =
        "Pensieve can keep “\(title)” open so you can retry, or quit without removing its recovery copy. If you quit, the discarded copy may appear in Recovered Drafts the next time Pensieve opens."
      alert.alertStyle = .warning
      let keepOpenButton = alert.addButton(withTitle: "Keep Pensieve Open")
      keepOpenButton.keyEquivalent = "\u{1b}"
      let quitAnywayButton = alert.addButton(withTitle: "Quit Anyway")
      quitAnywayButton.hasDestructiveAction = true
      alert.window.defaultButtonCell = keepOpenButton.cell as? NSButtonCell
      return alert.runModal() == .alertSecondButtonReturn
    }
  ) {
    self.appState = appState
    self.folderManager = folderManager
    self.documentStore = documentStore
    self.indexDatabase = indexDatabase ?? .shared
    self.launchSettings = launchSettings ?? .shared
    self.documentWindowRegistry = documentWindowRegistry ?? .shared
    self.startupRestore = startupRestore
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
    self.confirmQuitAfterRecoveryRetirementFailure =
      confirmQuitAfterRecoveryRetirementFailure
    self.documentStore.observeSelfWrites { [weak folderManager] url in
      folderManager?.noteSelfWrite(at: url)
    }
    AppActivationReconciler.shared.register(self)
  }

  /// Whether this window's session holds work the user could lose — an
  /// untitled draft or a loaded document. The window registry's launcher sweep
  /// asks this, because registry bookkeeping alone cannot see it: a recovered
  /// crash draft has no URL, so the accessor never publishes a document
  /// identity and the window would look like an empty launcher forever.
  var hasEditableBuffer: Bool { appState.documentSession.hasEditableBuffer }

  /// The identity this window's session holds RIGHT NOW — which is not
  /// necessarily the identity a caller snapshotted before prompting it. A Save
  /// on a dirty untitled draft turns `.untitled(UUID)` into `.file(url)` inside
  /// the prompt, and anything retiring by the pre-prompt snapshot then misses
  /// the file that was just created.
  var currentDocumentIdentity: DocumentIdentity? { appState.documentSession.identity }

  /// True while a Word/PDF conversion started in this window is still running.
  /// The same "does this window hold live work" question the sweep asks — and
  /// an import is the one kind of live work that shows up NOWHERE else: the
  /// conversion runs off the main actor, so the session is still empty, and the
  /// initial load is already marked resolved, so the accessor publishes no
  /// document identity and the tab is filed back as an empty launcher. Reaping
  /// it deallocates the window's controller and the conversion is discarded.
  var hasPendingImportWork: Bool { documentImportTask != nil }

  /// True while this window is reading a large document off the main actor.
  ///
  /// The twin of `hasPendingImportWork`, and it exists for the identical reason:
  /// the session has no buffer until the work lands, so `hasEditableBuffer`
  /// cannot see the window is spoken for. Everything that asks "is this window
  /// free?" — the registry's launcher sweep, the open router choosing between
  /// this window and a new tab, the empty-window close — has to ask this too.
  var hasPendingDocumentLoad: Bool { appState.documentIsLoading }

  /// "Is this window already spoken for?" — the single question every open
  /// router asks before choosing between loading in place and handing the
  /// document to the registry. An empty, idle window is the one that may be
  /// reused; a buffer, a conversion in flight or a staged read all claim it.
  /// One expression so `openFile` (⌘O, Finder, recents) and
  /// `openDocumentWindow` (every click) cannot drift apart.
  var holdsLiveDocumentWork: Bool {
    appState.documentSession.hasEditableBuffer || hasPendingImportWork || hasPendingDocumentLoad
  }

  /// True until this window's launch-time restore resolves. A window waiting
  /// for its document must not be reaped as an "empty launcher" just because
  /// the document has not reached the accessor yet — the sweep fires on a
  /// timer and would otherwise win that race on a slow workspace.
  private(set) var isAwaitingLaunchRestore = true

  /// Boots THIS window according to why it was opened. The intent answers the
  /// one restore question left — rebuild the workspace — instead of the single
  /// `restoringWorkspace` boolean that used to conflate it with picking a
  /// document and claiming the crash draft (and treated a launcher reborn
  /// mid-session exactly like a cold launch).
  func start(intent: LaunchIntent = .coldLaunch) {
    guard !didStart else { return }
    didStart = true
    // Whatever this window turns out to be, its launch decision is settled by
    // the time `start` returns. Clearing the flag re-runs the sweep, so a
    // genuinely empty launcher is still reaped — just one pass later.
    defer {
      isAwaitingLaunchRestore = false
      requestLauncherSweepReconcile?()
    }

    // Crash drafts are surfaced, never adopted: this only fills the launcher's
    // Recovered Drafts list.
    refreshRecoveredDrafts()

    // Warm the index OFF the main thread. Opening the GRDB pool + running migrations (incl. the FTS5
    // content-link rebuild) on main here was the launch-time beachball; the workspace-restore path
    // also opens lazily, so this is just an early, non-blocking warm-up.
    let indexDatabase = indexDatabase
    Task { await indexDatabase.openInBackground(into: appState) }
    guard intent.restoresWorkspace else { return }

    // A factory-built New tab is not a launcher waiting to be restored. Its
    // root starts bufferless while SwiftUI attaches, so materialize the empty
    // editable draft here before the launcher sweep can mistake it for idle.
    // It must also never claim the process-wide cold-start restore: New creates
    // one document and may rebuild workspace configuration, but it does not
    // reopen the previous working set.
    if intent == .newUntitledTab {
      folderManager.restoreLastFolderInBackground(into: appState)
      // Idempotent: the window's construction already seeded this draft (see
      // `NewTabSessionSeed`), so this is the fallback for a controller that
      // never went through a factory window — and, just as importantly, the
      // guarantee that the late workspace hydration above cannot replace a
      // buffer the user has been typing into since the tab appeared.
      seedUntitledDraftForNewTab()
      return
    }

    // Claim the application's one startup restore BEFORE anything else in this
    // branch can return early: whichever window gets here first IS the launch,
    // and every launcher after it must be an empty launcher.
    let isApplicationStartupRestore = startupRestore.claimStartupRestore()

    // WORKSPACE IS CONFIGURATION — IT ALWAYS COMES BACK (decision 26.07, W9).
    // The toggle governs the SESSION: the files a launch reopens and the
    // selection it would restore, never the roots, the tree or the sidebar.
    // Skipping the whole restore here was the fracture — a user who only asked
    // not to have her tabs reopened lost the workspace with them, and the
    // launcher came up with nothing to open FROM.
    //
    // It also governs LAUNCH only: Dock reopen / the tab bar's "+" never asked
    // to restore a whole session, only to put a launcher back, so they are not
    // gated on it at all. Persisted bookmarks are untouched on every path.
    let reopensWorkingSet = intent != .coldLaunch || launchSettings.restoreSessionOnLaunch

    folderManager.restoreLastFolderInBackground(into: appState)
    // The claim above is taken FIRST on purpose, and the reopen is gated on it
    // rather than on the intent: a cold launch that declines the working set is
    // still the application's one startup restore, so the launcher that appears
    // later cannot inherit the document reopen the user just turned off.
    guard isApplicationStartupRestore, reopensWorkingSet else { return }
    reopenRestoredOpenFiles()
  }

  /// Reopens the ad-hoc files the user left open at quit. THE APPLICATION'S
  /// STARTUP ONLY — see `ApplicationStartupRestore`; a launcher that appears
  /// later in the same process must open nothing, or closing the last document
  /// window immediately brings it back.
  ///
  /// `prepareWorkspaceShell` runs synchronously inside the restore above, so
  /// `appState.openFiles` is already populated when it returns — and for a long
  /// time that was mistaken for "the files came back". They did not. Open Files
  /// renders from the WINDOW REGISTRY (`windowRegistry.openDocuments`), and the
  /// only production caller of `DocumentWindowRegistry.open` is
  /// `requestOpenDocumentWindow`, which the launch path never invoked. So a file
  /// left open at quit returned as a model entry with no window, no tab and no
  /// sidebar row: from the user's side it did not come back at all.
  ///
  /// Only AD-HOC refs qualify. Workspace documents live in the sidebar tree, and
  /// `applyWorkspaceScans` deliberately keeps them out of Open Files rather than
  /// listing them twice.
  private func reopenRestoredOpenFiles() {
    // ONE identity set for the whole pass, seeded with what is already open and
    // grown as refs are taken. Computing "already open" once and then trusting
    // the working set to hold each file at most once was a duplicate tab
    // waiting to happen: a persisted set that names the same file twice — which
    // `BookmarkStore` used to produce, since a bookmark blob is not a stable
    // identity for the file it points at — asked the registry to open it twice
    // before either request had registered a window.
    var claimed = Set(documentWindowRegistry.openDocuments.map(\.identity))
    var pending: [DocumentRef] = []
    for ref in appState.openFiles where ref.isAdHoc {
      guard claimed.insert(.file(ref.id.standardizedFileURL)).inserted else { continue }
      pending.append(ref)
    }
    guard !pending.isEmpty else { return }

    // This is the launch window and it is still empty, so the first restored
    // document belongs IN it. Routing every ref to the factory instead would
    // spawn a window per file and leave this one to be reaped — a visible flash
    // in the commonest case of exactly one file. Mirrors `openFile`, which also
    // loads in place when the window holds nothing.
    if !appState.documentSession.hasEditableBuffer {
      let inPlace = pending.removeFirst()
      documentStore.load(ref: inPlace, into: appState)
      // This window is on screen and now shows `inPlace` — the restore never
      // has to order anything for it. Say so BEFORE the bulk route runs: this
      // window's own attach is asynchronous and lands after the pass has
      // fronted its last tab, and the registry would read it as the document's
      // first presentation and front this window instead. The user left a
      // different tab in front; that is the one that must come back in front.
      requestNoteDocumentAlreadyOnScreen?(inPlace.id)
    }
    guard !pending.isEmpty else { return }

    // The bulk route exists because the per-file one cost a full window
    // presentation — and AppKit's tab-group frame sync, which lays out every
    // tab already in the group — for each restored file. See
    // `DocumentWindowRegistry.openRestoredDocuments`.
    if let requestOpenRestoredDocumentWindows {
      requestOpenRestoredDocumentWindows(pending)
      return
    }
    guard let requestOpenDocumentWindow else { return }
    for ref in pending {
      requestOpenDocumentWindow(ref)
    }
  }

  /// Whether an explicit open of `documentID` must go to the window registry
  /// instead of loading into THIS window.
  ///
  /// One predicate, two callers, because there is one policy — and it used to be
  /// written down twice. `openDocumentWindow` (the sidebar/search click) had both
  /// terms; `openFile` (⌘O, Finder, Open Recent, the launcher's RECENT list) had
  /// only the first, so an idle window asked to open a document that already had
  /// a tab elsewhere loaded it in place and put the same file on screen twice.
  ///
  /// - a window holding LIVE WORK is spoken for: an editable buffer, a pending
  ///   import, or a staged read whose bytes have not landed yet. Loading over any
  ///   of them throws the user's document away.
  /// - a document ALREADY IN SOME TAB routes even from an idle window, precisely
  ///   because the window is free: rendering it here would be the second copy.
  ///   The registry activates the tab that already shows it.
  private func routesToOwnTab(_ documentID: URL) -> Bool {
    holdsLiveDocumentWork || documentWindowRegistry.openTabDocumentIDs.contains(documentID)
  }

  func openFolder(url: URL) {
    if importsFoldersInBackground {
      folderManager.openInBackground(url: url, into: appState)
    } else {
      folderManager.open(url: url, into: appState)
    }
  }

  /// External/explicit file opens (⌘O, Finder, recents): tab per document.
  /// An empty, idle window is reused in place; a window holding live work — or
  /// an open request for a document that already has a tab somewhere — routes
  /// through the window registry and appears as a native tab. Both terms live in
  /// `routesToOwnTab`, shared with `openDocumentWindow`. Falls back to in-window
  /// load when no routing is wired (tests, headless).
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

    if appState.selectedDocumentID?.standardizedFileURL == standardizedURL {
      noteRecentDocumentIfOpened(standardizedURL)
      return
    }

    // The registry route below bypasses registerOpenFile (the destination
    // window registers the file during its own load), so unsupported types
    // must be rejected HERE — otherwise they would open an empty tab whose
    // load is refused only afterwards. Import SOURCES (Word/PDF) are not
    // Markdown but ARE openable, so they pass this gate too.
    let isImportable = DocumentTransfer.isImportable(standardizedURL)
    guard isImportable || WorkspaceScanner.isMarkdownFile(standardizedURL) else {
      appState.lastError = WorkspaceScanner.unsupportedOpenMessage
      return
    }

    // When the file routes to its own window/tab, do NOT register it into
    // THIS window's working set first — the destination window registers it
    // during its own load, and a premature registration leaves the
    // originating sidebar permanently listing a file it never displays.
    //
    // Import sources route here for the SAME reason every other open does: an
    // import replaces this window's session wholesale (`restoreUntitled`), so
    // running it against a window that already shows a document silently threw
    // that document away and left the conversion sitting under its title. The
    // destination tab performs the import itself via `openFileInCurrentWindow`.
    //
    // A CONVERSION IN FLIGHT OCCUPIES THIS WINDOW TOO. It runs off the main
    // actor and leaves the session empty until it lands, so a multi-file open —
    // Finder multi-select, a Dock drop — answered "empty, use this window" for
    // every URL after the first: a second import called `documentImportTask?
    // .cancel()` and the user's first file vanished without a word, while a
    // Markdown URL loaded into the session the pending conversion was about to
    // overwrite. `hasEditableBuffer` cannot see that work; `hasPendingImportWork`
    // is what says this window is spoken for.
    //
    // A STAGED OPEN OCCUPIES IT THE SAME WAY, for the same reason: a file past
    // `LargeDocument.sizeBudget` is read off the main actor and the session holds
    // no buffer until the bytes land. Without `hasPendingDocumentLoad` the second
    // URL of a multi-file open would answer "empty, use this window", invalidate
    // the first file's claim, and the file the user clicked first would vanish
    // exactly the way an import used to.
    if routesToOwnTab(standardizedURL), let requestOpenDocumentWindow {
      DebugTrace.log("openFile -> registry: \(standardizedURL.lastPathComponent)")
      requestOpenDocumentWindow(DocumentRef(id: standardizedURL, isAdHoc: true))
      return
    }

    // This window is empty, so the import is safe to run in place.
    if isImportable {
      importDocument(url: standardizedURL)
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
  ///
  /// The conversion and the recovery write are reported SEPARATELY. A conversion
  /// that lands but cannot be backed by a draft is not a success: the converted
  /// text exists only in the buffer, so the error stays on screen rather than
  /// being cleared, and the buffer stays open and dirty.
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
        documentStore.releaseRecoveryClaimBeforeReplacingSession(appState: appState)
        appState.selectedDocumentID = nil
        appState.documentSession.restoreUntitled(
          title: imported.suggestedFileName,
          text: imported.markdown,
          recoveryID: UUID()
        )
        // The conversion result has no source-backed autosave target. Persist
        // the dirty untitled session immediately so a crash cannot erase the handoff.
        //
        // `releasesDraftClaim: false` because this window STAYS OPEN holding the
        // buffer that draft belongs to. The flush's default is a close, where
        // releasing the claim is the point — the buffer dies and its draft goes
        // back on the launcher. Here it would publish a LIVE buffer's draft as
        // unhandled: every other launcher surface would offer it, and adopting it
        // into a second window would put two buffers on one recovery ID,
        // autosaving over each other.
        let persisted = documentStore.savePendingChangesOnClose(
          appState: appState, releasesDraftClaim: false)
        guard persisted else {
          // The conversion succeeded and its ONLY copy is the buffer on screen —
          // there is no source-backed file to fall back to and no draft on disk.
          // Clearing `lastError` here (which this path did unconditionally) left
          // the app unable to tell a completed import from a failed one, so a
          // crash before Save As… took the conversion with nothing having
          // recorded the risk. The buffer is left open and dirty, and the stakes
          // are appended to the recovery-snapshot error already reported.
          //
          // Reported through `reportDataLoss`, not a plain `lastError` write:
          // the assignment lands in the STATUS slot, so it would leave the
          // sharper sentence sitting behind the unresolved data loss
          // the snapshot write just latched and never reach the screen. See
          // the lifecycle contract's Recovery section.
          appState.reportDataLoss(
            (appState.lastError ?? "Could not write recovery draft.")
              + " The text converted from \(sourceURL.lastPathComponent) is open but has no"
              + " recovery copy — save it with Save As… before quitting.")
          DebugTrace.log(
            "importDocument -> Markdown draft NOT persisted: \(sourceURL.lastPathComponent)")
          return
        }
        appState.lastError = nil
        DebugTrace.log("importDocument -> Markdown draft: \(sourceURL.lastPathComponent)")
      case .failure(let message):
        appState.lastError = "Import failed: \(message)"
      }
    }
  }

  /// Termination command from `TerminationSequence` (quiescence phase), routed through the registry's
  /// live controllers.
  ///
  /// The import task has a semantic boundary in the middle of it. Before publication it is a
  /// CONVERSION: a Word/PDF file read on a detached task into a temporary Markdown string, owned by
  /// nobody, and cancelling it loses nothing. After publication it mutates the document session AND
  /// persists a recovery draft — managed persistence, which must not appear after the flush phase has
  /// already run. Cancelling here settles both halves at once: the task re-checks `Task.isCancelled`
  /// between the conversion and the publication, and this call and that check are both on the main
  /// actor, so there is no interleaving in which a cancelled import still publishes.
  func quiesceForTermination() {
    documentImportTask?.cancel()
    documentImportTask = nil
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
    documentStore.releaseRecoveryClaimBeforeReplacingSession(appState: appState)
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
    //
    // Closing the WINDOW is not the whole intent here. This affordance retires
    // the file from the LIST, so it must also leave the working set a relaunch
    // restores from — and only when the close actually went through, so a
    // cancelled Save / Don't Save / Cancel forgets nothing. The conscious close
    // answers asynchronously, so the retire hangs off its completion rather
    // than a synchronous return.
    let url = id.standardizedFileURL
    closeOpenDocument(identity: .file(url)) { [weak self] didClose in
      guard let self, didClose else { return }
      self.documentStore.forgetOpenFile(url, into: self.appState)
    }
  }

  /// Closes `identity` wherever it lives, running the conscious close in the
  /// OWNING window's session.
  ///
  /// The return value answers "was the close ACCEPTED": `false` means it was
  /// refused outright because no window owns the identity (see `closeOwner`).
  /// Whether an accepted close actually went through is reported by
  /// `completion`, which fires after the Save / Don't Save / Cancel sheet is
  /// answered and is therefore asynchronous whenever a decision is needed.
  @discardableResult
  func closeOpenDocument(
    identity: DocumentIdentity,
    completion: (@MainActor (Bool) -> Void)? = nil
  ) -> Bool {
    // Open Files mirrors EVERY window's documents, so this close may target a
    // document owned by another window. Route the close DECISION to the OWNING
    // window's session — prompting only the caller's would force-close the
    // target, letting its close hook stash a recovery draft and skip the
    // Save / Don't Save / Cancel prompt.
    guard let owner = closeOwner(for: identity) else {
      completion?(false)
      return false
    }
    // When the identity is not the owner's active document there is no live
    // dirty session to guard, so the tab is torn down directly.
    guard owner.appState.windowModel.documentIdentity == identity.standardized else {
      documentWindowRegistry.closeDocument(identity)
      completion?(true)
      return true
    }
    owner.closeActiveDocument { [weak self] didClose in
      guard let self else {
        completion?(false)
        return
      }
      if didClose { self.documentWindowRegistry.closeDocument(identity) }
      completion?(didClose)
    }
    return true
  }

  /// Resolves the window that OWNS `identity` for a cross-window close.
  ///
  /// `self` is a valid answer ONLY when this window actually shows that
  /// document. Falling back to `self` unconditionally was unsafe: the
  /// registry's identity→window map is written from the COALESCED, async
  /// window accessor, so there is a real window in which a live tab has no
  /// registered controller yet. In that window the fallback handed the guard to
  /// a session that does not hold the document —
  /// `confirmDirtySession…` sees a mismatched identity, answers "nothing to
  /// guard", and the close proceeds with NO prompt against the window that did
  /// hold unsaved work. Refusing is the safe answer: nothing closes, nothing is
  /// discarded, and the caller can retry once the registration lands.
  private func closeOwner(for identity: DocumentIdentity) -> AppController? {
    if let owner = documentWindowRegistry.controller(for: identity) { return owner }
    guard appState.windowModel.documentIdentity == identity.standardized else {
      DebugTrace.log("close -> refused: no registered owner for \(identity)")
      return nil
    }
    return self
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
  /// chose to Discard and marking it clean. `.settled` is a no-op. Returns false
  /// if the recovery payload could not be retired, which vetoes the teardown.
  func applyDeferredDirtySessionResolution(
    _ resolution: DocumentStore.DirtySessionResolution,
    onRecoveryRetirementFailure: @MainActor () -> Bool = { false }
  ) -> Bool {
    documentStore.applyDeferredDirtySessionResolution(
      resolution,
      appState: appState,
      onRecoveryRetirementFailure: onRecoveryRetirementFailure)
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
    //   Recovery retirement is the remaining fallible apply step. If it fails,
    //   stop before closing any window; choices already applied earlier in this
    //   phase remain conscious Discards, while the failed owner stays dirty and
    //   recoverable rather than disappearing behind a false success.
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
    // Phase 1 can CHANGE a window's identity: Save on a dirty untitled draft
    // runs `saveAs`, which appends a NEW `.file` ref to `openFiles` and persists
    // a bookmark for it. The snapshot still holds that window's OLD
    // `.untitled(UUID)`, and the retire sweep below skips anything that is not
    // `.file` — so the file the user had just saved survived both the Open Files
    // list and the `fileBookmarks` default, and the next launch reopened it.
    // Retire by each owner's identity as it stands AFTER its resolution.
    var retiredIdentities = identities
    for identity in identities {
      // An unresolvable owner aborts the WHOLE sweep, exactly like a Cancel:
      // closing the rest while one window's session was never guarded is the
      // data loss this pass exists to prevent.
      guard let owner = closeOwner(for: identity) else { return }
      guard let resolution = owner.confirmDirtySessionForExternalClose(identity: identity) else {
        return
      }
      deferred.append((owner, resolution))
      if let settledIdentity = owner.currentDocumentIdentity,
        !retiredIdentities.contains(settledIdentity)
      {
        retiredIdentities.append(settledIdentity)
      }
    }

    for (owner, resolution) in deferred {
      guard owner.applyDeferredDirtySessionResolution(resolution) else {
        // A recorded Discard still has one fallible step: retiring its durable
        // recovery payload. If that fails, keep every window alive rather than
        // turning a failed cleanup into an apparent successful close.
        return
      }
    }
    // Phase 2 also retires the FILES from the working set, for the same reason
    // the single-row close does: this affordance empties the Open Files list,
    // and a list the next launch refills was never emptied. Inside phase 2, so
    // a Cancel in phase 1 still forgets nothing.
    for identity in retiredIdentities {
      guard case .file(let url) = identity else { continue }
      documentStore.forgetOpenFile(url, into: appState)
    }
    documentWindowRegistry.closeAllDocumentWindows()
  }

  /// ⌘N / "New File".
  ///
  /// A window holding LIVE WORK is spoken for — the first term of
  /// `routesToOwnTab`, and the reason ⌘O on such a window opens a tab instead of
  /// loading in place. ⌘N never asked, so it replaced the buffer where it fired:
  /// the file-backed session was overwritten by the new draft, the window's
  /// registry identity flipped from `.file(url)` to `.untitled(uuid)`, and the
  /// document's row in the sidebar's Open Files list — which mirrors the tab
  /// chain — was REPLACED rather than joined. One document open, ⌘N, and the
  /// document was gone from the list.
  ///
  /// An occupied window never enters the save/switch path. New is deterministic
  /// in Pensieve v1: the factory-built document joins the source window's native
  /// tab group, regardless of macOS's "Prefer tabs when opening documents"
  /// setting. Reuse is restricted to a window the registry still classifies as
  /// the idle launcher. A user-created untitled tab may briefly have no buffer
  /// while SwiftUI attaches its controller, but its native role already makes a
  /// second New another tab. Clean headless tests retain their in-place fallback.
  @discardableResult
  func createUntitledDocument() -> Bool {
    let sourceWindow =
      documentWindowRegistry.window(hosting: self) ?? hostWindowProvider?()
    let sourceRequiresNewTab =
      sourceWindow.map {
        !documentWindowRegistry.isReusableLauncherWindow($0)
      } ?? false

    if holdsLiveDocumentWork || sourceRequiresNewTab {
      if documentWindowRegistry.canOpenUntitledTab {
        guard let sourceWindow else { return false }
        return documentWindowRegistry.newUntitledTab(from: sourceWindow)
      }

      // A headless controller has no factory with which to preserve a dirty or
      // in-flight session. Fail closed: New must neither ask to save nor replace
      // work it cannot place elsewhere. Clean editable buffers retain the legacy
      // in-place renumbering used by focused command tests.
      guard !appState.documentSession.isDirty,
        !hasPendingImportWork,
        !hasPendingDocumentLoad
      else {
        return false
      }
    }

    return beginUntitledSession()
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

  /// The custom "Quit Pensieve" menu item's guard: settle THIS window's dirty session and report
  /// whether the quit may proceed. Storage hygiene is deliberately NOT here any more — this item is
  /// one of several quit paths, and the one it shares with all the others
  /// (`applicationWillTerminate` → `TerminationSequence`) owns the save → index drain → checkpoint
  /// ordering for every one of them. A second checkpoint fired from here would run BEFORE the final
  /// window saves, which is precisely the ordering the sequence exists to prevent.
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
    // Filesystem cleanup in phase 2 is deliberately sequential, not described
    // as atomic: a recovery draft successfully deleted for an earlier explicit
    // Discard cannot be rolled back if a later deletion fails. Keeping Pensieve
    // open preserves the failing and not-yet-applied sessions; earlier conscious
    // Discards remain applied.
    //
    // Self is asked LAST so the firing window's own prompt is the final word,
    // exactly as before.
    var deferred: [(controller: AppController, resolution: DocumentStore.DirtySessionResolution)] =
      []
    let others = documentWindowRegistry.liveDocumentControllers().filter { $0 !== self }
    for controller in others {
      guard let resolution = controller.confirmDirtySessionForDeferredClose() else { return false }
      deferred.append((controller, resolution))
    }
    guard let ownResolution = confirmDirtySessionForDeferredClose() else { return false }
    deferred.append((self, ownResolution))

    var didAuthorizeRetainedRecoveryForThisQuit = false
    for (controller, resolution) in deferred {
      guard
        controller.applyDeferredDirtySessionResolution(
          resolution,
          onRecoveryRetirementFailure: {
            if didAuthorizeRetainedRecoveryForThisQuit {
              return true
            }
            guard
              self.confirmQuitAfterRecoveryRetirementFailure(
                controller.appState.documentSession.displayTitle)
            else {
              return false
            }
            didAuthorizeRetainedRecoveryForThisQuit = true
            return true
          })
      else {
        return false
      }
    }
    // This pass has SETTLED, so the AppKit terminate hook must not run a second
    // one. ⌘Q reaches that hook through its own `NSApplication.terminate(_:)`
    // moments from now; the latch is one-shot and covers only that request.
    // Reached only on consent — a Cancel returned above and left it disarmed, so
    // the next terminate request still asks.
    documentWindowRegistry.armTerminationPassLatch()
    return true
  }

  /// Save-on-close guard for THIS window's session. Routed from the shared
  /// document-window root on `NSWindow.willCloseNotification`, it flushes a
  /// pending (debounced) edit synchronously before the window/tab tears down,
  /// closing the ≤1.5s data-loss window on every close trigger (red button,
  /// tab "×", sidebar close, ⌘W). No-op for a clean buffer.
  @discardableResult
  func savePendingChangesOnClose() -> Bool {
    // The window is going away, so whatever it was still reading is no longer
    // owed to anyone. Cancelling here is belt to the apply's own claim check and
    // weak session reference — those already make a late result a no-op; this
    // stops the read from continuing at all.
    appState.cancelPendingDocumentLoad()
    return documentStore.savePendingChangesOnClose(appState: appState)
  }

  /// When this window's session was last edited, on the process-wide `EditRecency` scale. Read by
  /// `TerminationSequence.flushPendingWindowSaves` to decide which of two windows over the SAME file
  /// writes its bytes LAST.
  var lastEditGeneration: UInt64 {
    appState.lastEditGeneration
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
  ///
  /// This is the SINGLE-DOCUMENT close (⌘W / File ▸ Close, and the owning
  /// window's half of "Close from Open Files"), so a close that goes through
  /// also retires the file from the Open Files working set — operator decision
  /// 2026-08-03. The window stays alive and reverts to the launcher; the file
  /// is out of the session and does not come back on the next launch. A Cancel
  /// (or a failed save) never reaches the retirement: `finishClose` returns
  /// before it.
  func closeActiveDocument(completion: (@MainActor (Bool) -> Void)? = nil) {
    let decision = documentStore.closeDecision(appState: appState)

    guard let prompt = decision.prompt else {
      // Bind the result FIRST: `completion?(finishClose(…))` would skip the
      // close entirely whenever the caller passed no completion, because
      // optional chaining never evaluates the argument of a nil call.
      let didClose = documentStore.finishClose(
        decision: decision, response: nil, appState: appState, retiring: .now)
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
        decision: decision, response: response, appState: self.appState, retiring: .now)
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
  ///
  /// `gesture` says which affordance is asking. It defaults to `.unreadable`,
  /// which is the behaviour every caller had before the gesture could be read at
  /// all, so a close that arrives without one is never treated as a document
  /// decision.
  @discardableResult
  func windowShouldClose(
    _ window: NSWindow,
    gesture: WindowCloseGesture = .unreadable
  ) -> Bool {
    // A tab's "×" means "retire this document" whatever the window's current
    // layout is — operator decision 2026-08-14, and the reason the gesture is
    // read at all. On the LAST tab there is no window left to leave the
    // document behind in, so the gesture is served by the ⌘W path itself:
    // `closeActiveDocument` runs the identical close-decision matrix (Save /
    // Don't Save / Cancel, recovery stash), retires the file from Open Files
    // and the session on a close that goes through, and leaves the window alive
    // on its empty state. The window teardown is therefore VETOED here — the
    // "×" closed the document, not the window.
    //
    // Windows that still have tab siblings keep the old route: the tab really
    // does go away there, and the retirement rides the settled close exactly as
    // before. A window with no document showing keeps it too — a launcher tab's
    // "×" has nothing to retire, so it must still mean "this window goes away".
    if gesture == .tab, hasEditableBuffer, documentWindowRegistry.isLoneTab(window) {
      closeActiveDocument()
      return false
    }

    let decision = documentStore.closeDecision(appState: appState)
    guard let prompt = decision.prompt else {
      if decision == .saveWithoutPrompting {
        // This is still a VETO point. Persist now instead of trusting the later
        // willClose notification, where both original and recovery writes could
        // fail after AppKit had already committed to tearing the window down.
        let didClose = documentStore.finishClose(
          decision: decision,
          response: nil,
          appState: appState,
          retiring: .deferred { [weak self, weak window] closedURL in
            guard let self, let window else { return }
            self.retireDocumentIfThisIsATabClose(
              url: closedURL, window: window, gesture: gesture)
          })
        refreshRecoveredDrafts()
        return didClose
      }

      // A clean session has nothing to persist. The document this close settles
      // is read now and retired only if the close turns out to be a TAB close.
      if let closingURL = appState.documentSession.url {
        retireDocumentIfThisIsATabClose(url: closingURL, window: window, gesture: gesture)
      }
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
        decision: decision, response: response, appState: self.appState,
        // Reported only by a close that went through, and only after the save
        // branches — a draft that earned its path through "Save As…" is retired
        // under that new location, exactly like the ⌘W route.
        retiring: .deferred { [weak self, weak window] closedURL in
          guard let self, let window else { return }
          self.retireDocumentIfThisIsATabClose(url: closedURL, window: window, gesture: gesture)
        })
      self.refreshRecoveredDrafts()
      // Only a settled close (saved or discarded) tears the window down; its
      // `willCloseNotification` guard is a no-op on the now-clean session. Cancel
      // or a failed save leaves the window — and its buffer — intact.
      guard didClose else { return }
      if let window {
        ConsciousCloseHook.closeAfterConsent(window)
      }
    }
    return false
  }

  /// Retires the document from the Open Files working set, but ONLY when this
  /// close was a TAB close.
  ///
  /// The operator's 2026-08-03 rule is about closing a DOCUMENT: ⌘W and a tab's
  /// "×" take the file out of the session for good. Closing a WINDOW is not
  /// that decision — it takes every tab in it down at once, and the files it
  /// held must still be there on the next launch (the same reason termination
  /// never retires). AppKit hands both gestures to the same close primitive, so
  /// the registry settles the question: the READ GESTURE first, and the
  /// surviving-sibling heuristic when there is no gesture to read — see
  /// `DocumentWindowRegistry.resolveCloseScope`.
  private func retireDocumentIfThisIsATabClose(
    url: URL, window: NSWindow, gesture: WindowCloseGesture
  ) {
    documentWindowRegistry.resolveCloseScope(for: window, gesture: gesture) { [weak self] scope in
      guard let self, scope == .tab else { return }
      self.documentStore.forgetOpenFile(url, into: self.appState)
    }
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
    if didOpen {
      // This window now holds unsaved work with no URL behind it, so the
      // registry cannot classify it from the document identity the accessor
      // publishes — it would stay a "launcher" and the sweep would reap the
      // user's recovered work moments after they asked for it. Promote it
      // explicitly, at the moment of adoption. This is the ONLY adoption route
      // left: nothing claims a draft at launch any more.
      requestPromoteWindowToContent?()
    }
    refreshRecoveredDrafts()
    return didOpen
  }

  /// `Save As…`: pick a location, write the draft there, retire it. A cancelled
  /// panel leaves everything untouched.
  @discardableResult
  func saveRecoveredDraftAs(_ draft: RecoveryDraft) -> Bool {
    let savedURL = documentStore.saveRecoveredDraftAs(draft, into: appState)
    if let savedURL {
      recentDocuments.noteOpened(savedURL)
      if appState.workspaceRoots.contains(where: {
        WorkspaceScanner.contains(savedURL, in: $0.url)
      }) {
        folderManager.refresh(into: appState)
      }
    }
    refreshRecoveredDrafts()
    return savedURL != nil
  }

  /// `Discard`: drop the draft after the user confirms. Returns whether it was
  /// actually discarded.
  @discardableResult
  func discardRecoveredDraft(_ draft: RecoveryDraft) -> Bool {
    guard confirmDiscardDraft(draft) else { return false }
    switch documentStore.discardRecoveredDraft(draft, into: appState) {
    case .discarded:
      refreshRecoveredDrafts()
      return true
    case .claimedByAnotherWindow:
      appState.lastError = "This recovered draft is already open in another window."
    case .storageFailure:
      appState.lastError =
        "Could not discard \(draft.displayTitle). The recovery copy is still on disk; resolve the storage error and try again."
    }
    refreshRecoveredDrafts()
    return false
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

  /// Every click that means "open this file" — the workspace tree, a search
  /// result, the context-menu "Open" — lands exactly where ⌘O and a Finder
  /// "Open with Pensieve" land: as a native window tab. `click = tab`
  /// (`docs/keyboard-shortcuts-and-file-lifecycle-contract.md`, decision
  /// 26.07). A click is an explicit open, so it must not replace the document
  /// this window is reading: files stay visible in parallel and switching
  /// between them is switching tabs.
  ///
  /// Destination is `openFile`'s policy, not a second one — literally, through
  /// the shared `routesToOwnTab`: an empty, idle window is reused in place — the
  /// launcher the user clicked from becomes the file's window instead of
  /// spawning a tab beside itself and being reaped a moment later — and a window
  /// holding live work hands the document to the registry. The registry
  /// activates the tab already showing the document rather than opening a twin,
  /// which is also why a document open SOMEWHERE ELSE routes even from an idle
  /// window: loading it in place would leave the same file rendered in two tabs.
  ///
  /// Clicking the document this window already shows is a no-op. Falls back to
  /// in-window selection when no routing is wired (tests, headless).
  func openDocumentWindow(id: DocumentRef.ID?) {
    guard let id, let ref = resolveDocumentRef(for: id) else { return }

    let documentID = ref.id.standardizedFileURL
    if appState.selectedDocumentID?.standardizedFileURL == documentID {
      return
    }

    guard routesToOwnTab(documentID), let requestOpenDocumentWindow else {
      DebugTrace.log(
        "openDocumentWindow -> load in this window: \(ref.id.lastPathComponent)")
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
    switch metadata.launchVerification {
    case .workerSpawnRecorded:
      onSuccess?()
      appState.lastError = nil
      transcriptionService.updateDispatchStatus(metadata.statusLine)

    case .acceptedUnconfirmed:
      // The detached run may already be alive. Keep the dictated prompt so a
      // bounded proof timeout cannot erase the user's only editable copy, but
      // do not present the accepted receipt as an application error either.
      appState.lastError = nil
      // The tafla has no orange receipt chrome to carry the uncertainty the way
      // the dispatch sheet does, and its status line renders in exactly the same
      // secondary caption a started run gets. So the line itself has to say what
      // is unconfirmed — the sheet's own sentence, from the one copy.
      transcriptionService.updateDispatchStatus(
        "\(metadata.statusLine) — \(AgentDispatchMetadata.unconfirmedLaunchExplanation)")

    case .rejected:
      appState.lastError = metadata.statusLine
      transcriptionService.updateDispatchStatus(metadata.statusLine)
    }
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
  /// explicit, unmissable in-app launch receipt. A spawn record proves that
  /// the detached launcher created a worker, not that the worker is still
  /// alive. A successful launcher receipt without that bounded proof remains
  /// inspectable and must never be rewritten as a failed launch.
  enum DocumentDispatchOutcome: Sendable {
    case success(
      runID: String?, reportPath: String?, observeAgent: String?, statusLine: String)
    case acceptedUnconfirmed(
      runID: String, reportPath: String?, observeAgent: String?, statusLine: String)
    case rejected(
      message: String, runID: String?, reportPath: String?, observeAgent: String?)
    case failure(message: String)
  }

  /// The canonical document-sheet → launch path: headless dispatch of a
  /// confirmed intent via the canonical uv-core entry, which prints a parseable
  /// launch receipt (run_id / agent / report path) and detaches. Called by the gateway
  /// sheet's Dispatch button; the sheet shows "Run started" from the returned
  /// outcome. `workflow`/`agent`/`rootURL` are the sheet's edited
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
      // The receipt's `agent:` token is authoritative. Older/trimmed receipts
      // may omit it; only an explicitly dispatched positional agent is a safe
      // fallback. A default swarm has no positional authority, so it gets no
      // guessed Terminal observer action.
      let observeAgent = metadata.observeAgent ?? agents.first
      switch metadata.launchVerification {
      case .rejected:
        appState.lastError = metadata.statusLine
        transcriptionService.updateDispatchStatus(metadata.statusLine)
        return .rejected(
          message: metadata.statusLine,
          runID: metadata.runID,
          reportPath: metadata.reportPath,
          observeAgent: metadata.observeAgent)

      case .acceptedUnconfirmed:
        guard let runID = metadata.runID else {
          let message = "Dispatch rejected: Vibecrafted returned no run ID."
          appState.lastError = message
          transcriptionService.updateDispatchStatus(message)
          return .rejected(
            message: message,
            runID: nil,
            reportPath: metadata.reportPath,
            observeAgent: observeAgent)
        }
        appState.lastError = nil
        let line =
          "Accepted \(title) → \(workflow) (\(agentLabel)) in \(rootURL.lastPathComponent); "
          + "worker launch unconfirmed"
        transcriptionService.updateDispatchStatus("\(line) · run: \(runID)")
        return .acceptedUnconfirmed(
          runID: runID,
          reportPath: metadata.reportPath,
          observeAgent: observeAgent,
          statusLine: line)

      case .workerSpawnRecorded:
        appState.lastError = nil
        let line =
          "Started \(title) → \(workflow) (\(agentLabel)) in \(rootURL.lastPathComponent)"
        transcriptionService.updateDispatchStatus(
          metadata.runID.map { "\(line) · run: \($0)" } ?? line)
        return .success(
          runID: metadata.runID,
          reportPath: metadata.reportPath,
          observeAgent: observeAgent,
          statusLine: line)
      }
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

  /// The empty draft a "+" / ⌘T / ⌘N tab owes its FIRST render — see
  /// `NewTabSessionSeed` for why it cannot wait for `start(intent:)`.
  ///
  /// One draft per window, whichever caller gets here first. A second call is a
  /// no-op rather than a second `beginUntitledSession`: repeating it would
  /// renumber the tab ("Untitled 2.md") and, worse, throw away whatever the user
  /// had already typed into the tab that was on screen the whole time.
  @discardableResult
  func seedUntitledDraftForNewTab() -> Bool {
    guard !didSeedUntitledDraftForNewTab else { return false }
    didSeedUntitledDraftForNewTab = true
    return beginUntitledSession()
  }

  @discardableResult
  private func beginUntitledSession() -> Bool {
    guard documentStore.prepareForDocumentSwitch(appState: appState) else { return false }
    documentStore.releaseRecoveryClaimBeforeReplacingSession(appState: appState)
    appState.documentSession.createUntitled(title: nextUntitledTitle())
    appState.selectedDocumentID = nil
    appState.lastError = nil
    return true
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

  /// Handed over through `scheduleIndexWrite` rather than a bare `Task`, for the same reason the save
  /// tail is: a bare task joins the index's supersede chain only several suspensions later, so
  /// between "the document was created" and "the write reached the chain" it is invisible to
  /// `drainPendingIndexWrites()`. This was the ONE index writer in the app with no handle at all —
  /// create a document, quit immediately, and the quit could neither wait for it nor know it existed.
  /// Now it is visible from the moment it is created; the termination latch still backs it up.
  private func reindexCreatedDocument(at url: URL) {
    let ref = appState.documentRef(for: url.standardizedFileURL)
    let indexDatabase = indexDatabase
    let appState = appState
    indexDatabase.scheduleIndexWrite {
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
