import Combine
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

@MainActor
final class AppState: ObservableObject {
  private static let previewAutoReloadKey = "Pensieve.previewAutoReload"
  private static let tableTidyOnPasteKey = "Pensieve.tableTidyOnPaste"
  private static let asciiSafeTablesKey = "Pensieve.asciiSafeTables"
  private static let sidebarSortOrderKey = "Pensieve.sidebarSortOrder"
  private let defaults: UserDefaults

  // Workspace + document selection
  @Published var folderURL: URL?
  @Published var workspaceRoots: [WorkspaceRoot] = []
  @Published var workspaceTree: [WorkspaceNode] = []
  @Published var documents: [DocumentRef] = [] {
    didSet { rebuildAllDocumentsCache() }
  }
  @Published var openFiles: [DocumentRef] = [] {
    didSet { rebuildAllDocumentsCache() }
  }
  @Published var documentTabs: [DocumentRef] = []
  @Published var excludedWorkspacePaths: Set<String> = []
  @Published var selectedDocumentID: DocumentRef.ID?
  @Published var workspaceSearchQuery: String = ""
  @Published var workspaceSearchResults: [WorkspaceSearchResult] = []
  @Published var sidebarFocusedURL: URL?
  @Published var pendingSidebarRenameURL: URL?
  @Published var sidebarSortOrder: SidebarSortOrder {
    didSet {
      defaults.set(sidebarSortOrder.rawValue, forKey: Self.sidebarSortOrderKey)
    }
  }

  // Active document
  @Published var documentSession: DocumentSession = .empty

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

  // Editor preferences
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

  // Preview behaviour. `previewAutoReload` mirrors the legacy
  // "Automatically reload page" checkbox; `previewRefreshToken` is bumped
  // by the toolbar refresh button to force a re-render even when
  // auto-reload is paused or the markdown text is identical.
  @Published var previewAutoReload: Bool {
    didSet {
      defaults.set(previewAutoReload, forKey: Self.previewAutoReloadKey)
    }
  }
  @Published var previewRefreshToken: Int = 0

  // Sidebar visibility
  @Published var sidebarVisible: Bool = true

  // Storage persistence + user-visible errors
  @Published var bookmarkData: Data?
  @Published var lastError: String?
  @Published var workspaceActivity: WorkspaceActivity?

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
    if let rawSort = defaults.string(forKey: Self.sidebarSortOrderKey),
      let sortOrder = SidebarSortOrder(rawValue: rawSort)
    {
      self.sidebarSortOrder = sortOrder
    } else {
      self.sidebarSortOrder = .nameAscending
    }
  }

  var selectedDocument: DocumentRef? {
    guard let id = selectedDocumentID else { return nil }
    return allDocuments.first(where: { $0.id == id })
  }

  /// Deduplicated union of workspace + open documents. CACHED: it was a computed
  /// property that allocated a Set and rebuilt the dedup on every access — and SwiftUI
  /// evaluates it once per sidebar context-menu row on every layout pass, so a single
  /// keystroke (which re-lays-out the hosting view) cost O(rows × documents). Now rebuilt
  /// only when `documents`/`openFiles` change. Profiler showed ~84% of the per-keystroke
  /// main-thread time in `allDocuments.getter` via `nodeContextMenu`.
  private(set) var allDocuments: [DocumentRef] = []
  private var allDocumentsByID: [DocumentRef.ID: DocumentRef] = [:]

  /// O(1) lookup into `allDocuments` by id, avoiding a per-row linear `first(where:)`.
  func document(id: DocumentRef.ID) -> DocumentRef? {
    allDocumentsByID[id]
  }

  private func rebuildAllDocumentsCache() {
    var seen = Set<DocumentRef.ID>()
    var result: [DocumentRef] = []
    var byID: [DocumentRef.ID: DocumentRef] = [:]
    result.reserveCapacity(documents.count + openFiles.count)
    for ref in documents + openFiles where seen.insert(ref.id).inserted {
      result.append(ref)
      byID[ref.id] = ref
    }
    allDocuments = result
    allDocumentsByID = byID
  }

  var sortedOpenFiles: [DocumentRef] {
    sortDocuments(openFiles)
  }

  var sortedWorkspaceTree: [WorkspaceNode] {
    sortNodes(workspaceTree)
  }

  var hasWorkspaceContent: Bool {
    !workspaceRoots.isEmpty || !openFiles.isEmpty
  }

  var isSearchingWorkspace: Bool {
    !workspaceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func bumpFontSize(by delta: CGFloat) {
    fontSize = max(8, min(48, fontSize + delta))
  }

  func resetFontSize() {
    fontSize = 14
  }

  /// Bumps `previewRefreshToken`, asking the preview pipeline to re-render
  /// even when the markdown payload is identical or auto-reload is off.
  func requestPreviewRefresh() {
    previewRefreshToken &+= 1
  }

  func documentRef(for url: URL) -> DocumentRef {
    let standardizedURL = url.standardizedFileURL
    return allDocuments.first { $0.url.standardizedFileURL == standardizedURL }
      ?? makeDocumentRef(for: standardizedURL)
  }

  func makeDocumentRef(for url: URL) -> DocumentRef {
    let standardizedURL = url.standardizedFileURL
    if let root =
      workspaceRoots
      .map(\.url.standardizedFileURL)
      .filter({ WorkspaceScanner.contains(standardizedURL, in: $0) })
      .sorted(by: { $0.path.count > $1.path.count })
      .first
    {
      return DocumentRef(
        id: standardizedURL,
        rootURL: root,
        relativePath: WorkspaceScanner.relativePath(for: standardizedURL, root: root),
        isAdHoc: false
      )
    }
    return DocumentRef(id: standardizedURL, isAdHoc: true)
  }

  func rememberDocumentTab(_ ref: DocumentRef) {
    documentTabs.removeAll { $0.id.standardizedFileURL == ref.id.standardizedFileURL }
    documentTabs.append(ref)
    if documentTabs.count > 12 {
      documentTabs.removeFirst(documentTabs.count - 12)
    }
  }

  func forgetDocumentTab(id: DocumentRef.ID) {
    documentTabs.removeAll { $0.id.standardizedFileURL == id.standardizedFileURL }
  }

  func pruneDocumentTabs() {
    let liveIDs = Set(allDocuments.map { $0.id.standardizedFileURL })
    documentTabs.removeAll { !liveIDs.contains($0.id.standardizedFileURL) }
  }

  private func sortDocuments(_ documents: [DocumentRef]) -> [DocumentRef] {
    guard sidebarSortOrder != .manual else { return documents }
    return documents.sorted { lhs, rhs in
      compareURLs(lhs.url, rhs.url, lhsTitle: lhs.title, rhsTitle: rhs.title)
    }
  }

  private func sortNodes(_ nodes: [WorkspaceNode]) -> [WorkspaceNode] {
    guard sidebarSortOrder != .manual else { return nodes }

    let sortedChildren =
      nodes
      .map { node in
        var copy = node
        copy.children = node.children.map(sortNodes)
        return copy
      }
    return sortedChildren.sorted { lhs, rhs in
      compareWorkspaceNodes(lhs, rhs)
    }
  }

  private func compareWorkspaceNodes(_ lhs: WorkspaceNode, _ rhs: WorkspaceNode) -> Bool {
    if lhs.kind != rhs.kind {
      return lhs.kind == .folder
    }
    return compareURLs(lhs.url, rhs.url, lhsTitle: lhs.name, rhsTitle: rhs.name)
  }

  private func compareURLs(_ lhs: URL?, _ rhs: URL?, lhsTitle: String, rhsTitle: String) -> Bool {
    switch sidebarSortOrder {
    case .manual:
      return false
    case .nameAscending, .type:
      return lhsTitle.localizedStandardCompare(rhsTitle) == .orderedAscending
    case .nameDescending:
      return lhsTitle.localizedStandardCompare(rhsTitle) == .orderedDescending
    case .modifiedNewest:
      let lhsDate = lhs.flatMap(Self.modifiedDate) ?? .distantPast
      let rhsDate = rhs.flatMap(Self.modifiedDate) ?? .distantPast
      if lhsDate != rhsDate {
        return lhsDate > rhsDate
      }
      return lhsTitle.localizedStandardCompare(rhsTitle) == .orderedAscending
    }
  }

  private static func modifiedDate(for url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }
}

struct DocumentRef: Identifiable, Hashable, Sendable {
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

struct WorkspaceNode: Identifiable, Hashable, Sendable {
  enum Kind: String, Sendable {
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
  var title: String
  var detail: String
  var progress: Double?

  static func scanning(_ label: String) -> WorkspaceActivity {
    WorkspaceActivity(
      title: "Importing Workspace",
      detail: "Scanning \(label)",
      progress: 0.15
    )
  }

  static func indexing(documentCount: Int) -> WorkspaceActivity {
    WorkspaceActivity(
      title: "Importing Workspace",
      detail: "Indexing \(documentCount) Markdown file\(documentCount == 1 ? "" : "s")",
      progress: 0.68
    )
  }

  static func checkingCache(_ label: String) -> WorkspaceActivity {
    WorkspaceActivity(
      title: "Checking Workspace Cache",
      detail: "Validating \(label)",
      progress: 0.05
    )
  }

  static func cacheHit(_ label: String) -> WorkspaceActivity {
    WorkspaceActivity(
      title: "Opening Cached Workspace",
      detail: "Using cached state for \(label)",
      progress: 0.92
    )
  }

  static func cacheMiss(_ label: String) -> WorkspaceActivity {
    WorkspaceActivity(
      title: "Importing Workspace",
      detail: "Cache miss for \(label)",
      progress: 0.1
    )
  }
}
