import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FolderManager {
  static let shared = FolderManager()
  private let watcher = FileWatcher()
  private let metadataStore: WorkspaceMetadataStore
  private let indexDatabase: IndexDatabase
  private let bookmarkStore: BookmarkStore
  private let workspaceBuilder: WorkspaceScanner.Builder
  private var workspaceBuildTask: Task<Void, Never>?

  init(
    metadataStore: WorkspaceMetadataStore = .shared,
    indexDatabase: IndexDatabase? = nil,
    bookmarkStore: BookmarkStore? = nil,
    workspaceBuilder: WorkspaceScanner.Builder? = nil
  ) {
    self.metadataStore = metadataStore
    self.indexDatabase = indexDatabase ?? .shared
    self.bookmarkStore = bookmarkStore ?? .shared
    self.workspaceBuilder = workspaceBuilder ?? WorkspaceScanner.defaultBuilder
  }

  func open(url: URL, into appState: AppState) {
    do {
      try bookmarkStore.persistRoot(url: url, into: appState)
      let roots = mergedRoots(current: appState.workspaceRoots.map(\.url), adding: [url])
      openResolvedWorkspace(
        rootURLs: roots, fileURLs: appState.openFiles.map(\.url), into: appState)
    } catch {
      appState.lastError = "Could not open folder: \(error.localizedDescription)"
    }
  }

  func openInBackground(url: URL, into appState: AppState) {
    do {
      try bookmarkStore.persistRoot(url: url, into: appState)
      let roots = mergedRoots(current: appState.workspaceRoots.map(\.url), adding: [url])
      openResolvedWorkspaceInBackground(
        rootURLs: roots, fileURLs: appState.openFiles.map(\.url), into: appState)
    } catch {
      appState.workspaceActivity = nil
      appState.lastError = "Could not open folder: \(error.localizedDescription)"
    }
  }

  func openFile(url: URL, into appState: AppState) {
    guard WorkspaceScanner.isMarkdownFile(url) else {
      appState.lastError = "Pensieve can open Markdown files with .md or .markdown extensions."
      return
    }

    let standardizedURL = url.standardizedFileURL
    if let ref = appState.allDocuments.first(where: {
      $0.url.standardizedFileURL == url.standardizedFileURL
    }) {
      DocumentStore.shared.select(ref: ref, into: appState)
      return
    }

    do {
      try bookmarkStore.persistFile(url: url, into: appState)
      let ref = DocumentRef(id: standardizedURL, isAdHoc: true)
      appState.openFiles.removeAll { $0.id.standardizedFileURL == standardizedURL }
      appState.openFiles.append(ref)
      DocumentStore.shared.load(ref: ref, into: appState)
    } catch {
      appState.lastError = "Could not open file: \(error.localizedDescription)"
    }
  }

  @discardableResult
  func createMarkdownFile(at url: URL, into appState: AppState) -> Bool {
    let targetURL = WorkspaceScanner.normalizedMarkdownFileURL(for: url)
    let fm = FileManager.default

    guard !fm.fileExists(atPath: targetURL.path) else {
      appState.lastError = "A file named \(targetURL.lastPathComponent) already exists."
      return false
    }

    do {
      try fm.createDirectory(
        at: targetURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try "".write(to: targetURL, atomically: true, encoding: .utf8)
    } catch {
      appState.lastError =
        "Could not create \(targetURL.lastPathComponent): \(error.localizedDescription)"
      return false
    }

    let standardizedURL = targetURL.standardizedFileURL
    if appState.workspaceRoots.contains(where: {
      WorkspaceScanner.contains(standardizedURL, in: $0.url)
    }) {
      refresh(into: appState)
      if let ref = appState.documents.first(where: { $0.url.standardizedFileURL == standardizedURL }
      ) {
        return DocumentStore.shared.select(ref: ref, into: appState)
      }
    }

    openFile(url: standardizedURL, into: appState)
    return appState.selectedDocumentID?.standardizedFileURL == standardizedURL
  }

  func restoreLastFolder(into appState: AppState) {
    let restored = bookmarkStore.restoreWorkspace(into: appState)
    guard !restored.rootURLs.isEmpty || !restored.fileURLs.isEmpty else {
      return
    }

    openResolvedWorkspace(rootURLs: restored.rootURLs, fileURLs: restored.fileURLs, into: appState)
  }

  func restoreLastFolderInBackground(into appState: AppState) {
    let restored = bookmarkStore.restoreWorkspace(into: appState)
    guard !restored.rootURLs.isEmpty || !restored.fileURLs.isEmpty else {
      return
    }

    openResolvedWorkspaceInBackground(
      rootURLs: restored.rootURLs, fileURLs: restored.fileURLs, into: appState)
  }

  func waitForPendingWorkspaceBuild() async {
    await workspaceBuildTask?.value
  }

  func refresh(into appState: AppState) {
    guard appState.hasWorkspaceContent else { return }

    workspaceBuildTask?.cancel()
    let previousSelection = appState.selectedDocumentID
    rebuildWorkspace(into: appState)
    let documents = appState.allDocuments

    if let previousSelection, documents.contains(where: { $0.id == previousSelection }) {
      appState.selectedDocumentID = previousSelection
      if !appState.activeDocumentDirty,
        let ref = documents.first(where: { $0.id == previousSelection })
      {
        DocumentStore.shared.load(ref: ref, into: appState)
      }
      return
    }

    if let first = documents.first {
      DocumentStore.shared.select(ref: first, into: appState)
    } else {
      appState.selectedDocumentID = nil
      appState.activeDocumentURL = nil
      appState.activeDocumentText = ""
      appState.activeDocumentDirty = false
    }
  }

  func addExcludedURLs(_ urls: [URL], into appState: AppState) {
    guard !appState.workspaceRoots.isEmpty else { return }

    var excluded = appState.excludedWorkspacePaths
    for url in urls {
      guard
        let relativePath = relativeExcludedPath(for: url, roots: appState.workspaceRoots.map(\.url))
      else {
        continue
      }
      excluded.insert(relativePath)
    }
    persistExcludedPaths(excluded, into: appState)
    refresh(into: appState)
  }

  func clearExclusions(into appState: AppState) {
    persistExcludedPaths([], into: appState)
    refresh(into: appState)
  }

  private func openResolvedWorkspace(rootURLs: [URL], fileURLs: [URL], into appState: AppState) {
    workspaceBuildTask?.cancel()
    appState.workspaceActivity = .scanning(workspaceLabel(rootURLs: rootURLs, fileURLs: fileURLs))
    indexDatabase.open(into: appState)
    let previousSelection = appState.selectedDocumentID
    prepareWorkspaceShell(rootURLs: rootURLs, fileURLs: fileURLs, into: appState)
    rebuildWorkspace(into: appState)
    selectRestoredDocument(previousSelection: previousSelection, into: appState)
    startWatching(urls: appState.workspaceRoots.map(\.url), appState: appState)
    appState.workspaceActivity = nil
  }

  private func openResolvedWorkspaceInBackground(
    rootURLs: [URL], fileURLs: [URL], into appState: AppState
  ) {
    workspaceBuildTask?.cancel()
    indexDatabase.open(into: appState)
    let previousSelection = appState.selectedDocumentID
    prepareWorkspaceShell(rootURLs: rootURLs, fileURLs: fileURLs, into: appState)
    appState.workspaceActivity = .scanning(workspaceLabel(rootURLs: rootURLs, fileURLs: fileURLs))

    let expectedRootPaths = appState.workspaceRoots.map { $0.url.standardizedFileURL.path }
    let expectedOpenFilePaths = appState.openFiles.map { $0.url.standardizedFileURL.path }
    let roots = appState.workspaceRoots.map(\.url)
    let exclusions = appState.excludedWorkspacePaths
    let workspaceBuilder = workspaceBuilder
    let scanTask = Task.detached(priority: .userInitiated) {
      workspaceBuilder(roots, exclusions)
    }

    workspaceBuildTask = Task { [weak self, weak appState] in
      let scans = await scanTask.value
      guard !Task.isCancelled, let self, let appState else { return }
      guard
        self.matchesCurrentWorkspace(
          rootPaths: expectedRootPaths,
          openFilePaths: expectedOpenFilePaths,
          in: appState
        )
      else {
        return
      }

      self.applyWorkspaceScans(scans, into: appState)
      self.selectRestoredDocument(previousSelection: previousSelection, into: appState)
      self.startWatching(urls: appState.workspaceRoots.map(\.url), appState: appState)
      appState.workspaceActivity = .indexing(documentCount: appState.allDocuments.count)
      await self.indexDatabase.reindexInBackground(
        documents: appState.allDocuments, appState: appState)
      guard !Task.isCancelled else { return }
      appState.workspaceActivity = nil
    }
  }

  private func prepareWorkspaceShell(rootURLs: [URL], fileURLs: [URL], into appState: AppState) {
    let metadata = metadataStore.load()
    appState.excludedWorkspacePaths = Set(metadata.excludedPaths)
    appState.workspaceRoots = rootURLs.map { WorkspaceRoot(id: $0.standardizedFileURL) }
    appState.folderURL = appState.workspaceRoots.first?.url
    appState.openFiles =
      fileURLs
      .filter(WorkspaceScanner.isMarkdownFile)
      .map { DocumentRef(id: $0.standardizedFileURL, isAdHoc: true) }
    appState.lastError = nil
  }

  private func rebuildWorkspace(into appState: AppState) {
    let scans = workspaceBuilder(
      appState.workspaceRoots.map(\.url), appState.excludedWorkspacePaths)
    applyWorkspaceScans(scans, into: appState)
    indexDatabase.reindex(documents: appState.allDocuments, appState: appState)
  }

  private func applyWorkspaceScans(_ scans: [WorkspaceScan], into appState: AppState) {
    appState.documents = scans.flatMap(\.documents)
    appState.workspaceTree = scans.map(\.rootNode)

    let workspaceIDs = Set(appState.documents.map(\.id))
    appState.openFiles.removeAll { workspaceIDs.contains($0.id) }
    appState.pruneDocumentTabs()
  }

  private func selectRestoredDocument(previousSelection: DocumentRef.ID?, into appState: AppState) {
    let documents = appState.allDocuments
    if let currentSelection = appState.selectedDocumentID,
      documents.contains(where: { $0.id == currentSelection })
    {
      return
    }

    if let previousSelection,
      let ref = documents.first(where: { $0.id == previousSelection })
    {
      DocumentStore.shared.select(ref: ref, into: appState)
    } else if let first = documents.first {
      DocumentStore.shared.select(ref: first, into: appState)
    } else {
      appState.selectedDocumentID = nil
      appState.activeDocumentURL = nil
      appState.activeDocumentText = ""
      appState.activeDocumentDirty = false
    }
  }

  private func startWatching(urls: [URL], appState: AppState) {
    guard !urls.isEmpty else {
      watcher.stop()
      return
    }

    do {
      try watcher.start(watching: urls) { [weak self, weak appState] in
        Task { @MainActor in
          guard let appState else { return }
          self?.refresh(into: appState)
        }
      }
    } catch {
      appState.lastError = "Could not watch folder: \(error.localizedDescription)"
    }
  }

  private func relativeExcludedPath(for url: URL, roots: [URL]) -> String? {
    let standardizedURL = url.standardizedFileURL
    let matchingRoot =
      roots
      .map(\.standardizedFileURL)
      .filter { standardizedURL.path == $0.path || standardizedURL.path.hasPrefix($0.path + "/") }
      .sorted { $0.path.count > $1.path.count }
      .first
    guard let matchingRoot else { return nil }
    let path = WorkspaceScanner.relativePath(for: standardizedURL, root: matchingRoot)
    return path.isEmpty ? nil : path
  }

  private func matchesCurrentWorkspace(
    rootPaths: [String], openFilePaths: [String], in appState: AppState
  ) -> Bool {
    appState.workspaceRoots.map { $0.url.standardizedFileURL.path } == rootPaths
      && appState.openFiles.map { $0.url.standardizedFileURL.path } == openFilePaths
  }

  private func persistExcludedPaths(_ excluded: Set<String>, into appState: AppState) {
    appState.excludedWorkspacePaths = excluded
    do {
      try metadataStore.save(WorkspaceMetadata(excludedPaths: excluded.sorted()))
      appState.lastError = nil
    } catch {
      appState.lastError = "Could not save workspace exclusions: \(error.localizedDescription)"
    }
  }

  private func mergedRoots(current: [URL], adding urls: [URL]) -> [URL] {
    var seen = Set<String>()
    return (current + urls)
      .map(\.standardizedFileURL)
      .filter { seen.insert($0.path).inserted }
  }

  private func workspaceLabel(rootURLs: [URL], fileURLs: [URL]) -> String {
    if rootURLs.count == 1, fileURLs.isEmpty {
      return rootURLs[0].lastPathComponent
    }
    let rootCount = rootURLs.count
    let fileCount = fileURLs.count
    switch (rootCount, fileCount) {
    case (0, 1):
      return fileURLs[0].lastPathComponent
    case (0, _):
      return "\(fileCount) files"
    case (_, 0):
      return "\(rootCount) folders"
    default:
      return "\(rootCount) folders and \(fileCount) files"
    }
  }
}

private enum WorkspaceDefaults {
  static let excludedNames: Set<String> = [
    ".git",
    ".build",
    ".DS_Store",
    "node_modules",
    "dist",
    "DerivedData",
  ]
}

struct WorkspaceScan: Sendable {
  var documents: [DocumentRef]
  var rootNode: WorkspaceNode
}

enum WorkspaceScanner {
  typealias Builder = @Sendable (_ rootURLs: [URL], _ exclusions: Set<String>) -> [WorkspaceScan]

  static let defaultBuilder: Builder = { rootURLs, exclusions in
    build(rootURLs: rootURLs, exclusions: exclusions)
  }

  static func build(rootURLs: [URL], exclusions: Set<String>) -> [WorkspaceScan] {
    rootURLs.map { scan(folder: $0, exclusions: exclusions) }
  }

  static func isMarkdownFile(_ url: URL) -> Bool {
    ["md", "markdown"].contains(url.pathExtension.lowercased())
  }

  static func normalizedMarkdownFileURL(for url: URL) -> URL {
    let ext = url.pathExtension.lowercased()
    if ext == "md" || ext == "markdown" {
      return url.standardizedFileURL
    }
    if ext.isEmpty {
      return url.appendingPathExtension("md").standardizedFileURL
    }
    return url.deletingPathExtension().appendingPathExtension("md").standardizedFileURL
  }

  static func contains(_ url: URL, in root: URL) -> Bool {
    let standardizedURL = url.standardizedFileURL
    let standardizedRoot = root.standardizedFileURL
    return standardizedURL.path == standardizedRoot.path
      || standardizedURL.path.hasPrefix(standardizedRoot.path + "/")
  }

  static func relativePath(for url: URL, root: URL) -> String {
    let rootComponents = root.standardizedFileURL.pathComponents
    let components = url.standardizedFileURL.pathComponents
    guard components.count >= rootComponents.count else {
      return url.lastPathComponent
    }
    return components.dropFirst(rootComponents.count).joined(separator: "/")
  }

  private static func scan(folder url: URL, exclusions: Set<String>) -> WorkspaceScan {
    let root = url.standardizedFileURL
    let scan = scanChildren(folder: root, root: root, exclusions: exclusions)
    return WorkspaceScan(
      documents: scan.documents,
      rootNode: WorkspaceNode(
        id: "root:\(root.path)",
        name: root.lastPathComponent,
        kind: .folder,
        url: root,
        children: scan.nodes
      )
    )
  }

  private static func scanChildren(
    folder url: URL,
    root: URL,
    exclusions: Set<String>
  ) -> (documents: [DocumentRef], nodes: [WorkspaceNode]) {
    let fm = FileManager.default
    guard
      let urls = try? fm.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
        options: []
      )
    else {
      return ([], [])
    }

    var documents: [DocumentRef] = []
    var nodes: [WorkspaceNode] = []
    let entries = urls.compactMap { entry(for: $0, root: root, exclusions: exclusions) }
      .sorted(by: workspaceSort)

    for entry in entries {
      if entry.isDirectory {
        let childScan = scanChildren(folder: entry.url, root: root, exclusions: exclusions)
        guard !childScan.nodes.isEmpty else { continue }
        documents.append(contentsOf: childScan.documents)
        nodes.append(
          WorkspaceNode(
            id: "folder:\(entry.standardizedURL.path)",
            name: entry.name,
            kind: .folder,
            url: entry.standardizedURL,
            children: childScan.nodes
          )
        )
      } else if entry.isRegularFile, isMarkdownFile(entry.url) {
        let ref = DocumentRef(
          id: entry.standardizedURL,
          rootURL: root,
          relativePath: entry.relativePath,
          isAdHoc: false
        )
        documents.append(ref)
        nodes.append(
          WorkspaceNode(
            id: "document:\(entry.standardizedURL.path)",
            name: entry.url.deletingPathExtension().lastPathComponent,
            kind: .document,
            url: entry.standardizedURL,
            children: nil
          )
        )
      }
    }

    return (documents, nodes)
  }

  private static func entry(for url: URL, root: URL, exclusions: Set<String>)
    -> WorkspaceDirectoryEntry?
  {
    let relativePath = relativePath(for: url, root: root)
    guard shouldInclude(url, relativePath: relativePath, exclusions: exclusions) else {
      return nil
    }

    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
    return WorkspaceDirectoryEntry(
      url: url,
      relativePath: relativePath,
      isDirectory: values?.isDirectory == true,
      isRegularFile: values?.isRegularFile == true
    )
  }

  private static func workspaceSort(_ lhs: WorkspaceDirectoryEntry, _ rhs: WorkspaceDirectoryEntry)
    -> Bool
  {
    if lhs.isDirectory, !rhs.isDirectory {
      return true
    }
    if !lhs.isDirectory, rhs.isDirectory {
      return false
    }
    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
  }

  private static func shouldInclude(_ url: URL, relativePath: String, exclusions: Set<String>)
    -> Bool
  {
    let name = url.lastPathComponent
    if name.hasPrefix(".") || WorkspaceDefaults.excludedNames.contains(name) {
      return false
    }
    return !exclusions.contains { excluded in
      relativePath == excluded || relativePath.hasPrefix("\(excluded)/")
    }
  }
}

private struct WorkspaceDirectoryEntry: Sendable {
  var url: URL
  var relativePath: String
  var isDirectory: Bool
  var isRegularFile: Bool

  var standardizedURL: URL {
    url.standardizedFileURL
  }

  var name: String {
    url.lastPathComponent
  }
}

@MainActor
final class DocumentStore {
  enum DirtyUntitledResponse {
    case save
    case discard
    case cancel
  }

  static let shared = DocumentStore()
  private let autosaver: Autosaver
  private let indexDatabase: IndexDatabase
  private let bookmarkStore: BookmarkStore
  private let writeDocument: (String, URL) throws -> Void
  private let indexDocument: @MainActor (DocumentRef, String, AppState?) -> Void
  private let dirtyUntitledPrompt: @MainActor (DocumentSession) -> DirtyUntitledResponse
  private let savePanelURLProvider: @MainActor (AppState) -> URL?
  private weak var appState: AppState?

  init(
    autosaver: Autosaver? = nil,
    indexDatabase: IndexDatabase? = nil,
    bookmarkStore: BookmarkStore? = nil,
    writeDocument: ((String, URL) throws -> Void)? = nil,
    indexDocument: (@MainActor (DocumentRef, String, AppState?) -> Void)? = nil,
    dirtyUntitledPrompt: (@MainActor (DocumentSession) -> DirtyUntitledResponse)? = nil,
    savePanelURLProvider: (@MainActor (AppState) -> URL?)? = nil
  ) {
    let resolvedIndexDatabase = indexDatabase ?? .shared
    self.autosaver = autosaver ?? .shared
    self.indexDatabase = resolvedIndexDatabase
    self.bookmarkStore = bookmarkStore ?? .shared
    self.writeDocument =
      writeDocument ?? { text, url in
        try text.write(to: url, atomically: true, encoding: .utf8)
      }
    self.indexDocument =
      indexDocument
      ?? { ref, body, appState in
        resolvedIndexDatabase.index(document: ref, body: body, appState: appState)
      }
    self.dirtyUntitledPrompt = dirtyUntitledPrompt ?? Self.promptForDirtyUntitledSession
    self.savePanelURLProvider = savePanelURLProvider ?? Self.promptForSaveURL
  }

  func load(ref: DocumentRef, into appState: AppState) {
    self.appState = appState

    guard saveDirtySessionIfNeeded(appState: appState) else {
      return
    }

    loadClean(ref: ref, into: appState)
  }

  private func loadClean(ref: DocumentRef, into appState: AppState) {
    autosaver.cancel()

    do {
      let text = try String(contentsOf: ref.url, encoding: .utf8)
      appState.selectedDocumentID = ref.id
      appState.documentSession.load(document: ref, text: text)
      appState.rememberDocumentTab(ref)
      appState.lastError = nil
    } catch {
      appState.lastError =
        "Could not load \(ref.url.lastPathComponent): \(error.localizedDescription)"
      appState.selectedDocumentID = appState.documentSession.id
    }
  }

  @discardableResult
  func select(ref: DocumentRef?, into appState: AppState) -> Bool {
    self.appState = appState

    guard saveDirtySessionIfNeeded(appState: appState) else {
      return false
    }

    guard let ref else {
      autosaver.cancel()
      appState.selectedDocumentID = nil
      appState.documentSession.clear()
      return true
    }

    loadClean(ref: ref, into: appState)
    return true
  }

  func save(appState: AppState) {
    _ = saveExisting(appState: appState, indexNow: true)
  }

  @discardableResult
  func saveAs(appState: AppState, to url: URL) -> Bool {
    self.appState = appState
    autosaver.cancel()

    guard appState.documentSession.hasEditableBuffer else { return false }
    let targetURL = WorkspaceScanner.normalizedMarkdownFileURL(for: url)
    let previousID = appState.documentSession.id

    do {
      try FileManager.default.createDirectory(
        at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try writeDocument(appState.documentSession.text, targetURL)
      let ref = documentRef(for: targetURL, appState: appState)
      registerSavedDocument(ref, previousID: previousID, appState: appState)
      appState.documentSession.document = ref
      appState.documentSession.isDirty = false
      appState.lastError = nil
      indexDocument(ref, appState.documentSession.text, appState)
      return true
    } catch {
      let message = "Could not save \(targetURL.lastPathComponent): \(error.localizedDescription)"
      appState.lastError = message
      NSLog(message)
      return false
    }
  }

  func documentDidChange(appState: AppState) {
    self.appState = appState
    guard appState.documentSession.hasEditableBuffer else {
      return
    }
    appState.documentSession.isDirty = true
    scheduleAutosave(appState: appState)
    scheduleIndexUpdate(appState: appState)
  }

  @discardableResult
  func prepareForDocumentSwitch(appState: AppState) -> Bool {
    self.appState = appState
    return saveDirtySessionIfNeeded(appState: appState)
  }

  private func scheduleAutosave(appState: AppState) {
    guard appState.documentSession.document != nil, appState.documentSession.isDirty else {
      return
    }

    autosaver.scheduleSave { [weak self, weak appState] in
      guard let appState else { return }
      self?.saveExisting(appState: appState, indexNow: false)
    }
  }

  private func scheduleIndexUpdate(appState: AppState) {
    guard appState.documentSession.document != nil else {
      autosaver.cancelIndex()
      return
    }

    autosaver.scheduleIndex { [weak self, weak appState] in
      guard let self, let appState, let ref = appState.documentSession.document else { return }
      self.indexDocument(ref, appState.documentSession.text, appState)
    }
  }

  private func saveDirtySessionIfNeeded(appState: AppState) -> Bool {
    guard appState.documentSession.isDirty else {
      return true
    }

    if appState.documentSession.isUntitled {
      switch dirtyUntitledPrompt(appState.documentSession) {
      case .save:
        guard let url = savePanelURLProvider(appState) else { return false }
        return saveAs(appState: appState, to: url)
      case .discard:
        appState.documentSession.isDirty = false
        return true
      case .cancel:
        return false
      }
    }

    let openSessionID = appState.documentSession.id
    _ = saveExisting(appState: appState, indexNow: true)
    guard !appState.documentSession.isDirty else {
      appState.selectedDocumentID = openSessionID
      return false
    }
    return true
  }

  private func documentRef(for url: URL, appState: AppState) -> DocumentRef {
    let standardizedURL = url.standardizedFileURL
    if let existing = appState.allDocuments.first(where: {
      $0.url.standardizedFileURL == standardizedURL
    }) {
      return existing
    }
    return appState.makeDocumentRef(for: standardizedURL)
  }

  @discardableResult
  private func saveExisting(appState: AppState, indexNow: Bool) -> Bool {
    self.appState = appState
    autosaver.cancelSave()

    guard let url = appState.documentSession.url else { return false }
    let ref = documentRef(for: url, appState: appState)

    do {
      try writeDocument(appState.documentSession.text, url)
      registerSavedDocument(ref, previousID: appState.documentSession.id, appState: appState)
      appState.documentSession.document = ref
      appState.documentSession.isDirty = false
      appState.lastError = nil
      if indexNow {
        autosaver.cancelIndex()
        indexDocument(ref, appState.documentSession.text, appState)
      }
      return true
    } catch {
      let message = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
      appState.lastError = message
      NSLog(message)
      return false
    }
  }

  private func registerSavedDocument(
    _ ref: DocumentRef, previousID: DocumentRef.ID?, appState: AppState
  ) {
    let isNewSessionURL = previousID?.standardizedFileURL != ref.id.standardizedFileURL

    if ref.isAdHoc {
      if !appState.openFiles.contains(where: {
        $0.id.standardizedFileURL == ref.id.standardizedFileURL
      }
      ) {
        appState.openFiles.append(ref)
      }
      if isNewSessionURL {
        do {
          try bookmarkStore.persistFile(url: ref.url, into: appState)
        } catch {
          appState.lastError =
            "Could not persist bookmark for \(ref.url.lastPathComponent): \(error.localizedDescription)"
        }
      }
    } else if !appState.documents.contains(where: {
      $0.id.standardizedFileURL == ref.id.standardizedFileURL
    }) {
      appState.documents.append(ref)
    }

    if let previousID, isNewSessionURL {
      appState.forgetDocumentTab(id: previousID)
    }
    appState.selectedDocumentID = ref.id
    appState.rememberDocumentTab(ref)
  }

  private static func promptForDirtyUntitledSession(
    _ session: DocumentSession
  ) -> DirtyUntitledResponse {
    let alert = NSAlert()
    alert.messageText = "Do you want to save changes to \(session.displayTitle)?"
    alert.informativeText = "Your changes will be lost if you don't save them."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Don't Save")
    alert.addButton(withTitle: "Cancel")

    switch alert.runModal() {
    case .alertFirstButtonReturn:
      return .save
    case .alertSecondButtonReturn:
      return .discard
    default:
      return .cancel
    }
  }

  private static func promptForSaveURL(appState: AppState) -> URL? {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [
      UTType(filenameExtension: "md"),
      UTType(filenameExtension: "markdown"),
    ].compactMap { $0 }
    panel.canCreateDirectories = true
    panel.directoryURL = defaultSaveDirectory(appState: appState)
    panel.nameFieldStringValue =
      appState.documentSession.displayTitle.isEmpty
      ? "Untitled.md" : appState.documentSession.displayTitle
    panel.prompt = "Save"
    return panel.runModal() == .OK ? panel.url : nil
  }

  private static func defaultSaveDirectory(appState: AppState) -> URL? {
    if let activeURL = appState.documentSession.url {
      return activeURL.deletingLastPathComponent()
    }
    if let rootURL = appState.workspaceRoots.first?.url {
      return rootURL
    }
    if let openFileURL = appState.openFiles.first?.url {
      return openFileURL.deletingLastPathComponent()
    }
    return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
  }
}
