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

@Observable
@MainActor
final class AppState {
  let workspaceStore: WorkspaceStore
  let windowModel: DocumentWindowModel

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

  var lastError: String? {
    get { windowModel.lastError }
    set { windowModel.lastError = newValue }
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
