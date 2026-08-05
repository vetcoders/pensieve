import Observation
import SwiftUI

enum EditorMode: Int, CaseIterable, Identifiable {
  case source = 1
  case split = 2
  case preview = 3
  case focus = 4

  var id: Int { rawValue }

  var label: String {
    switch self {
    case .source: return "Source"
    case .split: return "Split"
    case .preview: return "Preview"
    case .focus: return "Focus"
    }
  }
}

enum SidebarSortOrder: String, CaseIterable, Identifiable {
  case manual
  case nameAscending
  case nameDescending
  case modifiedNewest
  case type

  var id: String { rawValue }

  var label: String {
    switch self {
    case .manual: return "Manual"
    case .nameAscending: return "Name A-Z"
    case .nameDescending: return "Name Z-A"
    case .modifiedNewest: return "Modified"
    case .type: return "Type"
    }
  }
}

struct FindBarCommand: Equatable, Identifiable {
  enum Action: Equatable {
    case next
    case previous
    case replace
    case replaceAll
    case useSelection
    case clear
  }

  let id = UUID()
  let action: Action
}

/// Hands every edit a value no earlier edit in this process has held, so "which window did the user
/// touch most recently?" can be answered by comparing two integers.
///
/// Round 21, finding 3 (operator decision, 2026-07-30). A wall-clock timestamp would answer the same
/// question worse: two edits inside one clock tick compare equal, and the clock can go backwards.
/// The precedent is `Autosaver.generationCounter`, which round 19 used as the ordering source for
/// the quit's index flush — the same shape, one layer up, because the SAVE order needs a marker that
/// exists even when nothing is armed (auto-save off arms no debounce at all).
@MainActor
enum EditRecency {
  private static var counter: UInt64 = 0

  /// Strictly increasing, single mutator, never reused — the three properties the ordering rests on.
  static func next() -> UInt64 {
    counter &+= 1
    return counter
  }
}

@Observable
@MainActor
final class AppState {
  let workspaceStore: WorkspaceStore
  let windowModel: DocumentWindowModel

  /// When this window's session was last EDITED, on `EditRecency`'s process-wide scale. `0` means
  /// "never edited in this process", which is where every window starts and where a window that only
  /// ever displayed a document stays.
  ///
  /// Observation-ignored on purpose: it is bumped on every keystroke and read by nothing on the view
  /// side, so tracking it would put a per-keystroke invalidation into `@Observable` for no reader.
  @ObservationIgnored private(set) var lastEditGeneration: UInt64 = 0

  /// Recorded by the ONE edit funnel, `DocumentStore.documentDidChange(appState:)`.
  func noteEdit() {
    lastEditGeneration = EditRecency.next()
  }

  init(
    workspaceStore: WorkspaceStore? = nil,
    windowModel: DocumentWindowModel? = nil,
    defaults: UserDefaults = .standard
  ) {
    self.workspaceStore = workspaceStore ?? WorkspaceStore(defaults: defaults)
    self.windowModel = windowModel ?? DocumentWindowModel(defaults: defaults)
  }

  // Forwarded straight to the workspace store; with `@Observable`, reading this
  // in a view tracks `workspaceStore.workspaceActivity` directly — no manual
  // objectWillChange fan-in needed (that was the per-keystroke storm source).
  var workspaceActivity: WorkspaceActivity? {
    get { workspaceStore.workspaceActivity }
    set { workspaceStore.workspaceActivity = newValue }
  }

  var folderURL: URL? {
    get { workspaceStore.folderURL }
    set { workspaceStore.folderURL = newValue }
  }

  var workspaceRoots: [WorkspaceRoot] {
    get { workspaceStore.workspaceRoots }
    set { workspaceStore.workspaceRoots = newValue }
  }

  var workspaceTree: [WorkspaceNode] {
    get { workspaceStore.workspaceTree }
    set { workspaceStore.workspaceTree = newValue }
  }

  var documents: [DocumentRef] {
    get { workspaceStore.documents }
    set { workspaceStore.documents = newValue }
  }

  var openFiles: [DocumentRef] {
    get { workspaceStore.openFiles }
    set { workspaceStore.openFiles = newValue }
  }

  var excludedWorkspacePaths: Set<String> {
    get { workspaceStore.excludedWorkspacePaths }
    set { workspaceStore.excludedWorkspacePaths = newValue }
  }

  var workspaceSearchQuery: String {
    get { workspaceStore.workspaceSearchQuery }
    set { workspaceStore.workspaceSearchQuery = newValue }
  }

  var workspaceSearchResults: [WorkspaceSearchResult] {
    get { workspaceStore.workspaceSearchResults }
    set { workspaceStore.workspaceSearchResults = newValue }
  }

  var sidebarFocusedURL: URL? {
    get { workspaceStore.sidebarFocusedURL }
    set { workspaceStore.sidebarFocusedURL = newValue }
  }

  var pendingSidebarRenameURL: URL? {
    get { workspaceStore.pendingSidebarRenameURL }
    set { workspaceStore.pendingSidebarRenameURL = newValue }
  }

  var sidebarSortOrder: SidebarSortOrder {
    get { workspaceStore.sidebarSortOrder }
    set { workspaceStore.sidebarSortOrder = newValue }
  }

  var bookmarkData: Data? {
    get { workspaceStore.bookmarkData }
    set { workspaceStore.bookmarkData = newValue }
  }

  @discardableResult
  func rememberDispatchRoot(_ url: URL) -> Bool {
    workspaceStore.rememberDispatchRoot(url)
  }

  func resolveDispatchRoot(
    explicitOverride: URL? = nil,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    workspaceStore.resolveDispatchRoot(
      explicitOverride: explicitOverride,
      workspaceRoot: folderURL ?? workspaceRoots.first?.url,
      documentURL: documentURL,
      homeDirectory: homeDirectory
    )
  }

  var selectedDocumentID: DocumentRef.ID? {
    get { windowModel.selectedDocumentID }
    set { windowModel.selectedDocumentID = newValue }
  }

  var documentSession: DocumentSession {
    get { windowModel.documentSession }
    set { windowModel.documentSession = newValue }
  }

  // Discrete metadata mirrors (see DocumentWindowModel). Window chrome reads
  // these so a text-only edit never invalidates it.
  var documentTitle: String { windowModel.documentTitle }
  var documentHasEditableBuffer: Bool { windowModel.documentHasEditableBuffer }
  var documentURL: URL? { windowModel.documentURL }
  var documentIsDirty: Bool { windowModel.documentIsDirty }
  var aiDocumentID: String { windowModel.aiDocumentID }
  /// True while this window has claimed a file whose bytes are still being read
  /// off the main actor. See `DocumentSession.Kind.loading`.
  var documentIsLoading: Bool { windowModel.documentIsLoading }

  // Staged-open claim, forwarded so `DocumentStore` drives it through the same
  // façade every other per-window value goes through. See
  // `DocumentWindowModel.documentLoadClaim`.
  @discardableResult
  func beginDocumentLoad() -> UInt64 { windowModel.beginDocumentLoad() }
  func trackPendingDocumentLoad(_ task: Task<Void, Never>) {
    windowModel.trackPendingDocumentLoad(task)
  }
  func isCurrentDocumentLoad(_ claim: UInt64) -> Bool { windowModel.isCurrentDocumentLoad(claim) }
  func finishDocumentLoad(_ claim: UInt64) { windowModel.finishDocumentLoad(claim) }
  func cancelPendingDocumentLoad() { windowModel.cancelPendingDocumentLoad() }

  var mode: EditorMode {
    get { windowModel.mode }
    set { windowModel.mode = newValue }
  }

  var fontSize: CGFloat {
    get { windowModel.fontSize }
    set { windowModel.fontSize = newValue }
  }

  var richMarkdownEnabled: Bool {
    get { windowModel.richMarkdownEnabled }
    set { windowModel.richMarkdownEnabled = newValue }
  }

  var pendingMarkdownFormatCommand: MarkdownFormatCommand? {
    get { windowModel.pendingMarkdownFormatCommand }
    set { windowModel.pendingMarkdownFormatCommand = newValue }
  }

  var pendingAIRewriteCommand: AIRewriteCommand? {
    get { windowModel.pendingAIRewriteCommand }
    set { windowModel.pendingAIRewriteCommand = newValue }
  }

  var aiRewritePreview: AIRewritePreview? {
    get { windowModel.aiRewritePreview }
    set { windowModel.aiRewritePreview = newValue }
  }

  var findBarVisible: Bool {
    get { windowModel.findBarVisible }
    set { windowModel.findBarVisible = newValue }
  }

  var findReplaceMode: Bool {
    get { windowModel.findReplaceMode }
    set { windowModel.findReplaceMode = newValue }
  }

  var findQuery: String {
    get { windowModel.findQuery }
    set { windowModel.findQuery = newValue }
  }

  var findReplaceQuery: String {
    get { windowModel.findReplaceQuery }
    set { windowModel.findReplaceQuery = newValue }
  }

  var findFocusToken: Int {
    get { windowModel.findFocusToken }
    set { windowModel.findFocusToken = newValue }
  }

  var pendingFindCommand: FindBarCommand? {
    get { windowModel.pendingFindCommand }
    set { windowModel.pendingFindCommand = newValue }
  }

  var findMatchCount: Int {
    get { windowModel.findMatchCount }
    set { windowModel.findMatchCount = newValue }
  }

  var findActiveMatchIndex: Int? {
    get { windowModel.findActiveMatchIndex }
    set { windowModel.findActiveMatchIndex = newValue }
  }

  var caretUTF16Offset: Int {
    get { windowModel.caretUTF16Offset }
    set { windowModel.caretUTF16Offset = newValue }
  }

  var selectionUTF16Length: Int {
    get { windowModel.selectionUTF16Length }
    set { windowModel.selectionUTF16Length = newValue }
  }

  var tableTidyOnPaste: Bool {
    get { windowModel.tableTidyOnPaste }
    set { windowModel.tableTidyOnPaste = newValue }
  }

  var asciiSafeTables: Bool {
    get { windowModel.asciiSafeTables }
    set { windowModel.asciiSafeTables = newValue }
  }

  var aiAutocompleteEnabled: Bool {
    get { windowModel.aiAutocompleteEnabled }
    set { windowModel.aiAutocompleteEnabled = newValue }
  }

  var scrollSyncEnabled: Bool {
    get { windowModel.scrollSyncEnabled }
    set { windowModel.scrollSyncEnabled = newValue }
  }

  var previewAutoReload: Bool {
    get { windowModel.previewAutoReload }
    set { windowModel.previewAutoReload = newValue }
  }

  var previewRefreshToken: Int {
    get { windowModel.previewRefreshToken }
    set { windowModel.previewRefreshToken = newValue }
  }

  var sidebarVisible: Bool {
    get { windowModel.sidebarVisible }
    set { windowModel.sidebarVisible = newValue }
  }

  var showAllFilesInSidebar: Bool {
    get { windowModel.showAllFilesInSidebar }
    set { windowModel.showAllFilesInSidebar = newValue }
  }

  /// The plain-message surface every ordinary failure writes to. Assigning here
  /// files the error as `.status`: a refused action, a failed read, a piece of
  /// housekeeping that did not land — nothing the user typed is at risk.
  ///
  /// Kept as `String?` so the ~35 existing call sites read exactly as before;
  /// the severity they get is the safe default. A site that IS losing the user's
  /// only copy has to say so through `reportDataLoss`, which is the point: the
  /// loud class is opt-in and argued for, never inherited.
  var lastError: String? {
    get { windowModel.currentError?.message }
    set { windowModel.currentError = newValue.map(WindowError.status) }
  }

  /// This window's current error with its severity — what the chrome renders.
  var currentError: WindowError? { windowModel.currentError }

  /// Files a failure that leaves the user's content in memory and nowhere else.
  ///
  /// Raises the alert only when this is a NEW data-loss condition. A write that
  /// keeps failing (a full volume, a revoked permission) re-reports the same
  /// message on every retry, and asking again each time would bury the app under
  /// its own modal instead of informing anyone.
  func reportDataLoss(_ message: String) {
    let error = WindowError.dataLoss(message)
    if windowModel.currentError != error {
      windowModel.pendingDataLossAlert = error
    }
    windowModel.currentError = error
  }

  /// The user dismissing the banner. Clears the standing report only — a pending
  /// alert is a separate, already-raised question.
  func clearError() {
    windowModel.currentError = nil
  }

  /// The data-loss question this window still owes the user, if any. Presented
  /// by `ContentView` and cleared when it is answered.
  var pendingDataLossAlert: WindowError? {
    get { windowModel.pendingDataLossAlert }
    set { windowModel.pendingDataLossAlert = newValue }
  }

  /// The dispatch-gateway request for THIS window. Menu/toolbar/sidebar
  /// surfaces set it (via `AppController.request…Dispatch`); this window's
  /// `ContentView` presents the canonical configuration sheet for it and
  /// clears it on dismissal. Stored per window, so a request raised from the
  /// focused window can never surface a sheet in another one.
  var pendingDispatchIntent: DispatchIntent?

  var activeDocumentURL: URL? {
    get {
      documentSession.url
    }
    set {
      guard let newValue else {
        documentSession.clear()
        return
      }

      let standardizedURL = newValue.standardizedFileURL
      documentSession.document = documentRef(for: standardizedURL)
    }
  }

  var activeDocumentText: String {
    get {
      documentSession.text
    }
    set {
      documentSession.text = newValue
    }
  }

  var activeDocumentDirty: Bool {
    get {
      documentSession.isDirty
    }
    set {
      documentSession.isDirty = newValue
    }
  }

  var allDocuments: [DocumentRef] {
    workspaceStore.allDocuments
  }

  func document(id: DocumentRef.ID) -> DocumentRef? {
    workspaceStore.document(id: id)
  }

  var sortedOpenFiles: [DocumentRef] {
    workspaceStore.sortedOpenFiles
  }

  var sortedWorkspaceTree: [WorkspaceNode] {
    workspaceStore.sortedWorkspaceTree
  }

  var hasWorkspaceContent: Bool {
    workspaceStore.hasWorkspaceContent
  }

  var isSearchingWorkspace: Bool {
    workspaceStore.isSearchingWorkspace
  }

  func bumpFontSize(by delta: CGFloat) {
    windowModel.bumpFontSize(by: delta)
  }

  func resetFontSize() {
    windowModel.resetFontSize()
  }

  func requestPreviewRefresh() {
    windowModel.requestPreviewRefresh()
  }

  func documentRef(for url: URL) -> DocumentRef {
    workspaceStore.documentRef(for: url)
  }

  func makeDocumentRef(for url: URL) -> DocumentRef {
    workspaceStore.makeDocumentRef(for: url)
  }
}

struct DocumentRef: Identifiable, Hashable, Codable, Sendable {
  let id: URL
  var rootURL: URL?
  var relativePath: String?
  var isAdHoc: Bool = false

  var url: URL { id }
  var title: String { url.deletingPathExtension().lastPathComponent }
  var displayPath: String {
    relativePath ?? url.lastPathComponent
  }
}

struct WorkspaceRoot: Identifiable, Hashable, Sendable {
  let id: URL
  var url: URL { id }
  var name: String { url.lastPathComponent }
}

struct WorkspaceNode: Identifiable, Hashable, Codable, Sendable {
  enum Kind: String, Codable, Sendable {
    case folder
    case document
    /// A regular file whose extension falls outside `WorkspaceScanner.isMarkdownFile`'s
    /// allow-list. Sidebar-visible only, by construction: it never enters `documents`,
    /// so FTS indexing, Open Files, and the open-document guards never see it.
    case foreignFile
  }

  let id: String
  var name: String
  var kind: Kind
  var url: URL?
  var children: [WorkspaceNode]?

  var documentID: DocumentRef.ID? {
    kind == .document ? url : nil
  }
}

struct WorkspaceActivity: Equatable, Sendable {
  /// Stable case tag: drives the `open activity=<case>` trace breadcrumb and the
  /// prominent-vs-subtle presentation split. The open flow may not KNOW yet whether
  /// an import is coming — `.opening` is the honest "walking the tree to find out"
  /// state; only import-class kinds may claim "Importing Workspace".
  enum Kind: String, Equatable, Sendable {
    case opening
    case indexing
    case checkingCache
    case cacheHit
    case cacheMiss
  }

  var kind: Kind
  var title: String
  var detail: String
  var progress: Double?

  /// Import-class work (index writes genuinely ahead) earns the center takeover in the
  /// empty document pane; open/validate states stay subtle — sidebar progress only. This
  /// is what keeps a cached, unchanged reopen free of the "Importing Workspace" takeover.
  var isProminent: Bool {
    switch kind {
    case .indexing, .cacheMiss: return true
    case .opening, .checkingCache, .cacheHit: return false
    }
  }

  static func opening(_ label: String) -> WorkspaceActivity {
    WorkspaceActivity(
      kind: .opening,
      title: "Opening Workspace",
      detail: "Reading \(label)",
      progress: 0.15
    )
  }

  static func indexing(documentCount: Int) -> WorkspaceActivity {
    WorkspaceActivity(
      kind: .indexing,
      title: "Importing Workspace",
      detail: "Indexing \(documentCount) Markdown file\(documentCount == 1 ? "" : "s")",
      progress: 0.68
    )
  }

  static func checkingCache(_ label: String) -> WorkspaceActivity {
    WorkspaceActivity(
      kind: .checkingCache,
      title: "Checking Workspace Cache",
      detail: "Validating \(label)",
      progress: 0.05
    )
  }

  static func cacheHit(_ label: String) -> WorkspaceActivity {
    WorkspaceActivity(
      kind: .cacheHit,
      title: "Opening Cached Workspace",
      detail: "Using cached state for \(label)",
      progress: 0.92
    )
  }

  static func cacheMiss(_ label: String) -> WorkspaceActivity {
    WorkspaceActivity(
      kind: .cacheMiss,
      title: "Importing Workspace",
      detail: "Cache miss for \(label)",
      progress: 0.1
    )
  }
}
