import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class FolderManager {
  typealias RecycleItems = ([URL], @escaping @Sendable ([URL: URL], Error?) -> Void) -> Void
  typealias StandardizeFileURL = (URL) -> URL

  static let shared = FolderManager()
  private let watcher: FileWatcher
  private let metadataStore: WorkspaceMetadataStore
  private let indexDatabase: IndexDatabase
  private let bookmarkStore: BookmarkStore
  private let workspaceBuilder: WorkspaceScanner.Builder
  private let workspaceSubstrate: WorkspaceSubstrate
  private let workspaceValidationProbe: WorkspaceSubstrate.ValidationProbe
  private let standardizeFileURL: StandardizeFileURL
  private let recycleItems: RecycleItems
  /// Shares the substrate's cache store so the persisted `.md` signature lands in the SAME
  /// identity-keyed cache directory (`Workspaces/<workspaceID>/`) as the manifest/fingerprint.
  /// Keeping a single store keeps the signature, manifest, and fingerprint co-located and keyed
  /// identically — critical for the cold-open skip/incremental decision to read its own writes.
  private var cacheStore: WorkspaceCacheStore { workspaceSubstrate.store }
  private let selfWriteSuppressionInterval: TimeInterval
  private let watcherDebounceNanoseconds: UInt64
  private var workspaceBuildTask: Task<Void, Never>?
  private var workspaceValidationTask: Task<WorkspaceValidationResult, Error>?
  /// Ownership token for the open-flow activity presentation. Each open flow (and
  /// `closeWorkspace`) bumps it; an in-flight background build that exits on ANY path —
  /// cancellation, workspace mismatch, or normal completion — clears `workspaceActivity`
  /// only while its own generation is still current. Without this, a build cancelled by
  /// `applyRefresh` or superseded by an ad-hoc file open left `.opening` on screen forever.
  private var openFlowGeneration: UInt64 = 0
  private var watcherRefreshTask: Task<Void, Never>?
  /// Bumped on every `scheduleWatcherRefresh` so `waitForPendingWatcherRefresh` can tell a
  /// completed refresh from one that was cancel-replaced by a newer event mid-await.
  private var watcherRefreshGeneration: UInt64 = 0
  /// Explicit refreshes and workspace-configuration changes use their own off-main reconcile
  /// task so a filesystem event cannot cancel a user-requested refresh.
  private var forcedRefreshTask: Task<Void, Never>?
  /// Tracks the off-main FTS index write launched by live refresh or cold indexing (incremental
  /// delta OR full fallback). Held so `closeWorkspace` can cancel a still-awaiting update and so
  /// callers can await it. The underlying `pool.write` is a single transaction inside
  /// `IndexDatabase`, so cancelling here only abandons the await — it never half-writes the
  /// index. The actual writes are serialized by `IndexDatabase.pendingIndexUpdateTask`.
  private var indexUpdateTask: Task<Void, Never>?
  /// Tracks the manifest-side workspace/document/stat writes separately from the FTS delta.
  /// Synchronous open and forced-refresh paths previously launched this work unowned, which
  /// made close and deterministic tests race an otherwise valid database transaction.
  private var workspaceIndexWriteTask: Task<Void, Never>?
  /// Tracks the off-main index housekeeping (WAL truncate + page compaction) fired on close. Held
  /// separately from `indexUpdateTask` on purpose: close CANCELS the pending index write, and the
  /// whole point of this task is to run right after that, not to be cancelled with it.
  private var indexMaintenanceTask: Task<Void, Never>?
  private var recentSelfWritePaths: [String: Date] = [:]
  /// Last applied `.md` signature (structured `path -> FileSignature` map). The
  /// baseline the next watcher/refresh diffs against. `nil` means "no baseline"
  /// (cold open, or after `closeWorkspace`) — the next rebuild full-indexes.
  private var lastWorkspaceSignature: WorkspaceSignature?
  /// Last published sidebar identity. Unlike the search signature, this includes every visible
  /// root, folder, and supported document by standardized path + node kind, but no file stats.
  private var lastWorkspacePresentationSignature: WorkspacePresentationSignature?

  init(
    metadataStore: WorkspaceMetadataStore = .shared,
    indexDatabase: IndexDatabase? = nil,
    bookmarkStore: BookmarkStore? = nil,
    workspaceBuilder: WorkspaceScanner.Builder? = nil,
    workspaceSubstrate: WorkspaceSubstrate = .shared,
    workspaceValidationProbe: @escaping WorkspaceSubstrate.ValidationProbe = { _ in },
    watcher: FileWatcher = FileWatcher(),
    selfWriteSuppressionInterval: TimeInterval = 1.2,
    watcherDebounceMilliseconds: UInt64 = 300,
    standardizeFileURL: @escaping StandardizeFileURL = { $0.standardizedFileURL },
    recycleItems: @escaping RecycleItems = { urls, completion in
      NSWorkspace.shared.recycle(urls, completionHandler: completion)
    }
  ) {
    self.metadataStore = metadataStore
    self.indexDatabase = indexDatabase ?? .shared
    self.bookmarkStore = bookmarkStore ?? .shared
    self.workspaceBuilder = workspaceBuilder ?? WorkspaceScanner.cancellableBuilder
    self.workspaceSubstrate = workspaceSubstrate
    self.workspaceValidationProbe = workspaceValidationProbe
    self.watcher = watcher
    self.selfWriteSuppressionInterval = selfWriteSuppressionInterval
    self.watcherDebounceNanoseconds = watcherDebounceMilliseconds * 1_000_000
    self.standardizeFileURL = standardizeFileURL
    self.recycleItems = recycleItems
  }

  /// Single choke-point for open-flow activity transitions so `PENSIEVE_TRACE=1`
  /// exposes the honest presentation sequence (`open activity=<case>`), and so the
  /// choreography stays auditable in one place. Presentation only — every set-point
  /// keeps its position relative to the skip/fingerprint/identity decisions.
  private func setOpenActivity(_ activity: WorkspaceActivity?, into appState: AppState) {
    DebugTrace.log("open activity=\(activity?.kind.rawValue ?? "nil")")
    appState.workspaceActivity = activity
  }

  /// Terminal clear for a background open flow. No-op when a NEWER open flow has taken
  /// ownership of the activity display (it bumped the generation before cancelling this
  /// task), and when there is nothing to clear. This is the ONLY clear point for the
  /// background path, so every early `return` in the build task tears the spinner down.
  private func finishOpenFlow(generation: UInt64, into appState: AppState) {
    guard generation == openFlowGeneration else { return }
    guard appState.workspaceActivity != nil else { return }
    setOpenActivity(nil, into: appState)
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
      setOpenActivity(nil, into: appState)
      appState.lastError = "Could not open folder: \(error.localizedDescription)"
    }
  }

  func openFile(url: URL, into appState: AppState) {
    guard let ref = registerOpenFile(url: url, into: appState) else {
      return
    }

    DocumentStore.shared.load(ref: ref, into: appState)
  }

  func registerOpenFile(url: URL, into appState: AppState) -> DocumentRef? {
    guard WorkspaceScanner.isMarkdownFile(url) else {
      appState.lastError = WorkspaceScanner.unsupportedOpenMessage
      return nil
    }

    let standardizedURL = standardizeFileURL(url)
    let standardizedPath = standardizedURL.path
    if let ref = appState.allDocuments.first(where: {
      $0.url.path == standardizedPath
    }) {
      appState.lastError = nil
      return ref
    }

    do {
      try bookmarkStore.persistFile(url: url, into: appState)
    } catch {
      appState.lastError = "Could not open file: \(error.localizedDescription)"
      return nil
    }

    let ref = DocumentRef(id: standardizedURL, isAdHoc: true)
    appState.openFiles.removeAll { $0.id.path == standardizedPath }
    appState.openFiles.append(ref)
    pruneOpenFiles(into: appState, protecting: standardizedURL)
    appState.lastError = nil
    return ref
  }

  @discardableResult
  func createMarkdownFile(at url: URL, into appState: AppState) -> Bool {
    let targetURL = WorkspaceScanner.normalizedMarkdownFileURL(for: url)

    guard !FileManager.default.fileExists(atPath: targetURL.path) else {
      appState.lastError = "A file named \(targetURL.lastPathComponent) already exists."
      return false
    }

    do {
      try FileManager.default.createDirectory(
        at: targetURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try "".write(to: targetURL, atomically: true, encoding: .utf8)
      noteSelfWrite(at: targetURL)
    } catch {
      appState.lastError =
        "Could not create \(targetURL.lastPathComponent): \(error.localizedDescription)"
      return false
    }

    let standardizedURL = targetURL.standardizedFileURL
    if appState.workspaceRoots.contains(where: {
      WorkspaceScanner.contains(standardizedURL, in: $0.url)
    }) {
      publishKnownWorkspaceItem(at: standardizedURL, kind: .document, into: appState)
      refresh(into: appState)
      if let ref = appState.documents.first(where: { $0.url.standardizedFileURL == standardizedURL }
      ) {
        return DocumentStore.shared.select(ref: ref, into: appState)
      }
    }

    openFile(url: standardizedURL, into: appState)
    return appState.selectedDocumentID?.standardizedFileURL == standardizedURL
  }

  @discardableResult
  func createFolder(at url: URL, into appState: AppState) -> Bool {
    let targetURL = availableSiblingURL(for: url.standardizedFileURL)
    do {
      try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
      noteSelfWrite(at: targetURL)
      publishKnownWorkspaceItem(at: targetURL, kind: .folder, into: appState)
      refresh(into: appState, force: true)
      appState.lastError = nil
      return true
    } catch {
      appState.lastError = "Could not create folder: \(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  func rename(url: URL, to name: String, into appState: AppState) -> Bool {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    let source = url.standardizedFileURL
    let target =
      source.deletingLastPathComponent()
      .appendingPathComponent(trimmed)
      .standardizedFileURL
    guard source != target else { return true }
    guard !FileManager.default.fileExists(atPath: target.path) else {
      appState.lastError = "A file or folder named \(trimmed) already exists."
      return false
    }

    do {
      try FileManager.default.moveItem(at: source, to: target)
      noteSelfWrite(at: source)
      noteSelfWrite(at: target)
      replaceReferences(from: source, to: target, into: appState)
      refresh(into: appState)
      appState.lastError = nil
      return true
    } catch {
      appState.lastError =
        "Could not rename \(source.lastPathComponent): \(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  func duplicate(url: URL, into appState: AppState) -> Bool {
    let source = url.standardizedFileURL
    let target = availableDuplicateURL(for: source)
    do {
      try FileManager.default.copyItem(at: source, to: target)
      noteSelfWrite(at: target)
      refresh(into: appState)
      if WorkspaceScanner.isMarkdownFile(target) {
        openFile(url: target, into: appState)
      }
      appState.lastError = nil
      return true
    } catch {
      appState.lastError =
        "Could not duplicate \(source.lastPathComponent): \(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  func moveToTrash(url: URL, into appState: AppState) async -> Bool {
    let source = url.standardizedFileURL
    let recycleStartedAt = DispatchTime.now().uptimeNanoseconds
    let recycleResult: (errorDescription: String?, completedAt: UInt64) =
      await withCheckedContinuation { continuation in
        recycleItems([source]) { _, error in
          continuation.resume(
            returning: (error?.localizedDescription, DispatchTime.now().uptimeNanoseconds)
          )
        }
      }
    let finderMilliseconds = Self.elapsedMilliseconds(
      from: recycleStartedAt,
      to: recycleResult.completedAt
    )
    DebugTrace.log(
      "trash recycle completed path=\(source.path) finder_ms=\(Self.traceMilliseconds(finderMilliseconds)) outcome=\(recycleResult.errorDescription == nil ? "success" : "failure")"
    )

    if let errorDescription = recycleResult.errorDescription {
      appState.lastError =
        "Could not move \(source.lastPathComponent) to Trash: \(errorDescription)"
      return false
    }

    let pruneStartedAt = DispatchTime.now().uptimeNanoseconds
    appState.workspaceTree = Self.prunedWorkspaceTree(
      appState.workspaceTree,
      removing: source
    )
    let pruneCompletedAt = DispatchTime.now().uptimeNanoseconds
    DebugTrace.log(
      "trash tree pruned path=\(source.path) completion_to_prune_ms=\(Self.traceMilliseconds(Self.elapsedMilliseconds(from: recycleResult.completedAt, to: pruneCompletedAt))) prune_ms=\(Self.traceMilliseconds(Self.elapsedMilliseconds(from: pruneStartedAt, to: pruneCompletedAt)))"
    )

    removeReferences(for: source, into: appState)
    noteSelfWrite(at: source)
    appState.lastError = nil

    let reconcileStartedAt = DispatchTime.now().uptimeNanoseconds
    let reconcileTask = scheduleExplicitRefresh(
      into: appState,
      forcePresentation: true
    )
    await reconcileTask?.value
    let indexTask = indexUpdateTask
    await indexTask?.value
    let reconcileCompletedAt = DispatchTime.now().uptimeNanoseconds
    DebugTrace.log(
      "trash reconcile completed path=\(source.path) reconcile_ms=\(Self.traceMilliseconds(Self.elapsedMilliseconds(from: reconcileStartedAt, to: reconcileCompletedAt))) finder_ms=\(Self.traceMilliseconds(finderMilliseconds))"
    )
    return true
  }

  @discardableResult
  func move(url: URL, toFolder folderURL: URL, into appState: AppState) -> Bool {
    let source = url.standardizedFileURL
    let target = availableSiblingURL(
      for: folderURL.standardizedFileURL.appendingPathComponent(source.lastPathComponent)
    )
    guard source != target else { return true }

    do {
      try FileManager.default.moveItem(at: source, to: target)
      noteSelfWrite(at: source)
      noteSelfWrite(at: target)
      replaceReferences(from: source, to: target, into: appState)
      refresh(into: appState)
      appState.lastError = nil
      return true
    } catch {
      appState.lastError =
        "Could not move \(source.lastPathComponent): \(error.localizedDescription)"
      return false
    }
  }

  private func replaceReferences(from source: URL, to target: URL, into appState: AppState) {
    let sourceURL = source.standardizedFileURL
    let targetURL = target.standardizedFileURL
    let sourcePath = sourceURL.path

    appState.openFiles = appState.openFiles.map { ref in
      ref.url.path == sourcePath ? appState.makeDocumentRef(for: targetURL) : ref
    }
    if appState.selectedDocumentID?.path == sourcePath {
      appState.selectedDocumentID = targetURL
      appState.documentSession.document = appState.makeDocumentRef(for: targetURL)
    }
  }

  private func removeReferences(for source: URL, into appState: AppState) {
    let sourceURL = source.standardizedFileURL
    let sourcePath = sourceURL.path
    appState.documents.removeAll { isSameOrDescendant($0.url.path, of: sourcePath) }
    appState.openFiles.removeAll { isSameOrDescendant($0.url.path, of: sourcePath) }
    appState.workspaceSearchResults.removeAll {
      isSameOrDescendant($0.document.url.path, of: sourcePath)
    }
    if let selected = appState.selectedDocumentID,
      isSameOrDescendant(selected.path, of: sourcePath)
    {
      appState.selectedDocumentID = nil
      appState.documentSession.clear()
    }
  }

  private func isSameOrDescendant(_ path: String, of ancestorPath: String) -> Bool {
    return path == ancestorPath || path.hasPrefix(ancestorPath + "/")
  }

  /// Pure presentation mutation used only after Finder confirms the recycle. It removes the
  /// target node as one subtree, so empty and unsupported-only folders disappear without waiting
  /// for FSEvents or walking the filesystem on the main actor. Node URLs are compared by raw
  /// path: WorkspaceScanner standardizes every node URL at construction, and re-standardizing
  /// per node here is what would push a large-tree prune past its latency budget.
  nonisolated static func prunedWorkspaceTree(
    _ nodes: [WorkspaceNode],
    removing source: URL
  ) -> [WorkspaceNode] {
    let sourcePath = source.standardizedFileURL.path
    return nodes.compactMap { prunedWorkspaceNode($0, removingPath: sourcePath) }
  }

  private nonisolated static func prunedWorkspaceNode(
    _ node: WorkspaceNode,
    removingPath sourcePath: String
  ) -> WorkspaceNode? {
    if let nodePath = node.url?.path {
      if nodePath == sourcePath || nodePath.hasPrefix(sourcePath + "/") {
        return nil
      }
      // Only an ancestor of the source can hold it in its subtree; every other
      // sibling subtree survives unchanged, without a per-node copy walk.
      guard sourcePath.hasPrefix(nodePath + "/") else { return node }
    }

    var prunedNode = node
    if let children = node.children {
      prunedNode.children = children.compactMap {
        prunedWorkspaceNode($0, removingPath: sourcePath)
      }
    }
    return prunedNode
  }

  private nonisolated static func elapsedMilliseconds(
    from start: UInt64, to end: UInt64
  ) -> Double {
    guard end >= start else { return 0 }
    return Double(end - start) / 1_000_000
  }

  private nonisolated static func traceMilliseconds(_ value: Double) -> String {
    String(format: "%.3f", value)
  }

  private func availableDuplicateURL(for source: URL) -> URL {
    let directory = source.deletingLastPathComponent()
    let ext = source.pathExtension
    let base =
      ext.isEmpty
      ? source.lastPathComponent
      : source.deletingPathExtension().lastPathComponent
    return availableSiblingURL(
      for: directory.appendingPathComponent("\(base) Copy").appendingPathExtension(ext)
    )
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

  func restoreLastFolder(into appState: AppState) {
    let restored = bookmarkStore.restoreWorkspace(into: appState)
    guard !restored.rootURLs.isEmpty || !restored.fileURLs.isEmpty else {
      return
    }

    openResolvedWorkspace(rootURLs: restored.rootURLs, fileURLs: restored.fileURLs, into: appState)
  }

  func restoreLastFolderInBackground(into appState: AppState) {
    let restored = bookmarkStore.restoreWorkspace(into: appState)
    DebugTrace.log(
      "open restore roots=\(restored.rootURLs.count) files=\(restored.fileURLs.count)")
    guard !restored.rootURLs.isEmpty || !restored.fileURLs.isEmpty else {
      return
    }

    openResolvedWorkspaceInBackground(
      rootURLs: restored.rootURLs, fileURLs: restored.fileURLs, into: appState)
  }

  func waitForPendingWorkspaceBuild() async {
    await workspaceBuildTask?.value
  }

  /// Awaits the in-flight debounced watcher refresh (debounce sleep + off-main scan + rebuild)
  /// so tests can drive `scheduleWatcherRefresh` deterministically instead of sleeping. A live
  /// FSEvents delivery can cancel-replace the awaited task mid-wait, so drain until the awaited
  /// generation is the one that actually ran.
  func waitForPendingWatcherRefresh() async {
    while let task = watcherRefreshTask {
      let generation = watcherRefreshGeneration
      await task.value
      if watcherRefreshGeneration == generation { return }
    }
  }

  /// Deterministic sync point for exclusion/root-removal tests and callers that need the forced
  /// off-main scan, in-memory rebuild, and presentation-cache write to have completed.
  func waitForPendingForcedRefresh() async {
    await forcedRefreshTask?.value
  }

  /// Awaits the off-main FTS index write launched by the most recent refresh/cold index so
  /// tests can assert on the index deterministically. This awaits the FolderManager-side
  /// handle; the canonical write-completion sync point is `IndexDatabase.waitForPendingReindex()`
  /// (which both background variants chain on and await internally).
  func waitForPendingIndexUpdate() async {
    // `refresh(into:)` is intentionally synchronous at the API boundary but schedules its one
    // filesystem walk off-main. Await that reconcile first so legacy callers that already use
    // this index completion point cannot race the task that creates `indexUpdateTask`.
    await forcedRefreshTask?.value
    await indexUpdateTask?.value
  }

  func waitForPendingWorkspaceIndexWrite() async {
    await forcedRefreshTask?.value
    await workspaceIndexWriteTask?.value
  }

  func noteSelfWrite(at url: URL) {
    recentSelfWritePaths[FileWatcherEvent.canonicalPath(for: url.path)] = Date()
  }

  /// Starts one off-main reconcile for explicit one-shot callers (create, save, move, trash).
  /// The public API stays synchronous, but no directory enumeration or per-document stat walk
  /// runs on the main actor. Callers that need completion can await `waitForPendingForcedRefresh`.
  func refresh(into appState: AppState, force: Bool = false) {
    if let activeURL = appState.documentSession.url,
      WorkspaceScanner.isMarkdownFile(activeURL),
      !appState.documents.contains(where: {
        $0.url.standardizedFileURL == activeURL.standardizedFileURL
      })
    {
      // Save As can create a supported workspace document before the off-main reconcile runs.
      // Publish that one already-known path immediately so selection/rename UX stays coherent;
      // the scheduled snapshot remains authoritative and still updates both signatures/cache.
      publishKnownWorkspaceItem(at: activeURL, kind: .document, into: appState)
    }
    scheduleExplicitRefresh(into: appState, forcePresentation: force)
  }

  /// Publishes a path that this process just created without enumerating or stat-walking the
  /// workspace. The subsequent off-main snapshot remains authoritative and repairs ordering,
  /// signatures, search, and cache; this narrow optimistic insertion preserves synchronous
  /// create/save-as UI behavior while that reconcile is in flight.
  private func publishKnownWorkspaceItem(
    at url: URL,
    kind: WorkspaceNode.Kind,
    into appState: AppState
  ) {
    let standardizedURL = url.standardizedFileURL
    let matchingRoot = appState.workspaceRoots
      .map(\.url)
      .filter { WorkspaceScanner.contains(standardizedURL, in: $0) }
      .max(by: { $0.standardizedFileURL.path.count < $1.standardizedFileURL.path.count })
    guard let root = matchingRoot?.standardizedFileURL else { return }

    let relativePath = WorkspaceScanner.relativePath(for: standardizedURL, root: root)
    let exclusions = WorkspaceExclusion.relativePaths(
      for: root,
      from: appState.excludedWorkspacePaths
    )
    guard
      !exclusions.contains(where: { exclusion in
        relativePath == exclusion || relativePath.hasPrefix(exclusion + "/")
      })
    else { return }

    let node = WorkspaceNode(
      id: "\(kind.rawValue):\(standardizedURL.path)",
      name: kind == .document
        ? standardizedURL.deletingPathExtension().lastPathComponent
        : standardizedURL.lastPathComponent,
      kind: kind,
      url: standardizedURL,
      children: kind == .folder ? [] : nil
    )
    let parentURL = standardizedURL.deletingLastPathComponent()
    guard
      let rootIndex = appState.workspaceTree.firstIndex(where: {
        $0.url?.standardizedFileURL == root
      })
    else { return }

    var rootNode = appState.workspaceTree[rootIndex]
    guard insertKnownWorkspaceNode(node, under: parentURL, into: &rootNode) else { return }
    appState.workspaceTree[rootIndex] = rootNode

    if kind == .document {
      let standardizedPath = standardizedURL.path
      appState.documents.removeAll { $0.url.path == standardizedPath }
      appState.documents.append(
        DocumentRef(
          id: standardizedURL,
          rootURL: root,
          relativePath: relativePath,
          isAdHoc: false
        )
      )
      appState.openFiles.removeAll { $0.url.path == standardizedPath }
    }
  }

  private func insertKnownWorkspaceNode(
    _ insertedNode: WorkspaceNode,
    under parentURL: URL,
    into node: inout WorkspaceNode
  ) -> Bool {
    if node.url?.standardizedFileURL == parentURL.standardizedFileURL {
      var children = node.children ?? []
      children.removeAll { $0.id == insertedNode.id }
      children.append(insertedNode)
      children.sort(by: FolderManager.workspaceNodeSort)
      node.children = children
      return true
    }

    guard var children = node.children else { return false }
    for index in children.indices {
      if insertKnownWorkspaceNode(insertedNode, under: parentURL, into: &children[index]) {
        node.children = children
        return true
      }
    }
    return false
  }

  private nonisolated static func workspaceNodeSort(
    _ lhs: WorkspaceNode,
    _ rhs: WorkspaceNode
  ) -> Bool {
    if lhs.kind != rhs.kind { return lhs.kind == .folder }
    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
  }

  /// Debounced, off-main watcher refresh (RC-2). Coalesces a burst of watcher events into a
  /// single refresh after a short quiet period, then builds one presentation + search snapshot
  /// on a background task so foreign filesystem churn never blocks the main actor. Only the
  /// independent signature comparisons and required publications hop back to the main actor.
  /// A new event cancels the in-flight debounce/scan, so overlapping scans cannot pile up.
  func scheduleWatcherRefresh(into appState: AppState) {
    watcherRefreshGeneration &+= 1
    watcherRefreshTask?.cancel()
    watcherRefreshTask = Task { [weak self, weak appState, watcherDebounceNanoseconds] in
      try? await Task.sleep(nanoseconds: watcherDebounceNanoseconds)
      guard !Task.isCancelled else { return }
      guard let self, let appState else { return }
      await self.performWatcherRefresh(into: appState)
    }
  }

  /// Filters only events whose path is the exact path (or a descendant) this process recently
  /// wrote. A mixed FSEvents batch therefore keeps unrelated external mutations, and stream-loss
  /// or root-change markers always run the full safe reconcile regardless of self-write history.
  func actionableWatcherEvents(_ events: [FileWatcher.Event]) -> [FileWatcher.Event] {
    pruneExpiredSelfWrites()
    guard !recentSelfWritePaths.isEmpty else { return events }

    return events.filter { event in
      guard !event.requiresFullReconcile else { return true }
      return !recentSelfWritePaths.keys.contains { selfWritePath in
        event.path == selfWritePath || event.path.hasPrefix(selfWritePath + "/")
      }
    }
  }

  /// Drops events the workspace scanner can never surface, mirroring `shouldInclude` plus the
  /// W1-A signature truth that only folders and supported documents carry freshness weight:
  /// hidden or `WorkspaceDefaults.excludedNames` components below a root, and flagged-as-file
  /// events on unsupported names (atomic-save `<name>.sb-*` temp siblings, logs, images). The
  /// exceptions are load-bearing: `.gitignore` content drives ignore rules so its change must
  /// rescan, events without an is-file flag are kept (no negative evidence), and stream-loss or
  /// root-changed markers always survive. Self-write suppression stays a separate, noted-paths
  /// concern.
  func scannerVisibleWatcherEvents(
    _ events: [FileWatcher.Event],
    rootPaths: [String]
  ) -> [FileWatcher.Event] {
    events.filter { event in
      guard !event.requiresFullReconcile else { return true }
      guard
        let root = rootPaths.first(where: {
          event.path == $0 || event.path.hasPrefix($0 + "/")
        })
      else { return true }
      let components = event.path.dropFirst(root.count).split(separator: "/").map(String.init)
      guard let name = components.last else { return true }
      func invisible(_ component: String) -> Bool {
        component.hasPrefix(".") || WorkspaceDefaults.excludedNames.contains(component)
      }
      if components.dropLast().contains(where: invisible) { return false }
      if name == ".gitignore" { return true }
      if invisible(name) { return false }
      if event.flags.contains(.itemIsFile),
        !WorkspaceScanner.isMarkdownFile(URL(fileURLWithPath: event.path))
      {
        return false
      }
      return true
    }
  }

  /// Exclusions can change the visible folder tree without changing a single markdown file.
  /// Always rebuild for those explicit user actions, but reuse the cancellable scanner off the
  /// main actor and feed its result into `applyRefresh` so this path never reintroduces the
  /// main-thread workspace walks removed by W0-A.
  private func scheduleForcedRefresh(into appState: AppState) {
    scheduleExplicitRefresh(into: appState, forcePresentation: true)
  }

  @discardableResult
  private func scheduleExplicitRefresh(
    into appState: AppState,
    forcePresentation: Bool
  ) -> Task<Void, Never>? {
    guard appState.hasWorkspaceContent else { return nil }
    watcherRefreshTask?.cancel()
    forcedRefreshTask?.cancel()
    let task = Task { [weak self, weak appState] in
      guard let self, let appState, appState.hasWorkspaceContent else { return }
      let roots = appState.workspaceRoots.map(\.url)
      let rootPaths = roots.map { $0.standardizedFileURL.path }
      let exclusions = appState.excludedWorkspacePaths
      let workspaceBuilder = self.workspaceBuilder

      let snapshot = await Task.detached(priority: .userInitiated) {
        FolderManager.refreshSnapshot(
          roots: roots,
          exclusions: exclusions,
          builder: workspaceBuilder
        )
      }.value
      guard !Task.isCancelled else { return }
      guard appState.workspaceRoots.map({ $0.url.standardizedFileURL.path }) == rootPaths,
        appState.excludedWorkspacePaths == exclusions
      else { return }

      self.applyRefresh(
        into: appState,
        snapshot: snapshot,
        roots: roots,
        exclusions: exclusions,
        forcePresentation: forcePresentation
      )
    }
    forcedRefreshTask = task
    return task
  }

  /// Body of the debounced watcher refresh. One injected scanner walk plus both signatures run
  /// off-main; only delta decisions and publication touch main-actor state.
  private func performWatcherRefresh(into appState: AppState) async {
    guard appState.hasWorkspaceContent else { return }
    let roots = appState.workspaceRoots.map(\.url)
    let rootPaths = roots.map { $0.standardizedFileURL.path }
    let exclusions = appState.excludedWorkspacePaths
    let workspaceBuilder = workspaceBuilder

    let snapshot = await Task.detached(priority: .utility) {
      FolderManager.refreshSnapshot(
        roots: roots,
        exclusions: exclusions,
        builder: workspaceBuilder
      )
    }.value
    guard !Task.isCancelled else { return }
    guard appState.workspaceRoots.map({ $0.url.standardizedFileURL.path }) == rootPaths,
      appState.excludedWorkspacePaths == exclusions
    else { return }
    applyRefresh(
      into: appState,
      snapshot: snapshot,
      roots: roots,
      exclusions: exclusions
    )
  }

  /// Independently authorizes sidebar/cache publication and FTS publication from the two
  /// signatures derived by the same off-main scan. Folder-only changes never write search;
  /// content-only changes never republish the tree. Selection and dirty-buffer protection apply
  /// whenever either visible universe changes.
  private func applyRefresh(
    into appState: AppState,
    snapshot: WorkspaceRefreshSnapshot,
    roots: [URL],
    exclusions: Set<String>,
    forcePresentation: Bool = false
  ) {
    let presentationChanged =
      forcePresentation
      || lastWorkspacePresentationSignature != snapshot.presentationSignature
    let searchChanged: Bool
    if let baseline = lastWorkspaceSignature, let signature = snapshot.searchSignature {
      searchChanged = !WorkspaceSignature.delta(from: baseline, to: signature).isEmpty
    } else {
      // Missing evidence is fail-open for search: never bless an uncertain FTS baseline.
      searchChanged = true
    }

    let presentationState = presentationChanged ? "changed" : "stable"
    let searchState = searchChanged ? "changed" : "stable"
    DebugTrace.log("freshness presentation=\(presentationState) search=\(searchState)")
    guard presentationChanged || searchChanged else { return }

    workspaceBuildTask?.cancel()
    workspaceValidationTask?.cancel()
    let previousSelection = appState.selectedDocumentID
    let protectsDirtySession = appState.documentSession.isDirty

    if presentationChanged {
      applyWorkspaceScans(snapshot.scans, into: appState)
      if let fingerprint = snapshot.fingerprint {
        workspaceIndexWriteTask = commitWorkspaceManifest(
          rootURLs: roots,
          exclusions: exclusions,
          precomputedFingerprint: fingerprint,
          cachedScans: snapshot.scans,
          into: appState
        )
      }
    }

    if searchChanged {
      updateWorkspaceSearchIndex(
        signature: snapshot.searchSignature,
        into: appState
      )
    }
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

    // Excluding/removing the selected subtree must mirror close-workspace protection: the
    // workspace collection may no longer contain this document, but its dirty editor session is
    // still the user's unsaved work and must not be replaced by another document or cleared.
    if protectsDirtySession {
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
        let scopedPath = WorkspaceExclusion.scopedKey(
          for: url,
          roots: appState.workspaceRoots.map(\.url)
        )
      else {
        continue
      }
      excluded.insert(scopedPath)
    }
    guard excluded != appState.excludedWorkspacePaths else { return }
    persistExcludedPaths(excluded, into: appState)
    appState.workspaceSearchResults = []
    scheduleForcedRefresh(into: appState)
  }

  func clearExclusions(into appState: AppState) {
    guard !appState.excludedWorkspacePaths.isEmpty else { return }
    persistExcludedPaths([], into: appState)
    appState.workspaceSearchResults = []
    scheduleForcedRefresh(into: appState)
  }

  /// Removes one directory root from a multi-root workspace without touching its contents.
  /// The surviving root/file bookmarks are rebuilt through the same persistence APIs used by
  /// open-folder, the watcher is narrowed immediately, and the forced refresh drops the root
  /// from the tree, document collection, FTS delta, and presentation cache.
  func removeRoot(_ url: URL, into appState: AppState) {
    let standardizedURL = url.standardizedFileURL
    guard
      let targetRoot = appState.workspaceRoots.first(where: {
        $0.url.standardizedFileURL == standardizedURL
      })
    else { return }

    if appState.workspaceRoots.count == 1 {
      let indexedPaths = appState.allDocuments.map { $0.url.standardizedFileURL.path }
      closeWorkspace(into: appState)
      if !indexedPaths.isEmpty {
        let indexDatabase = indexDatabase
        indexUpdateTask = Task { [weak appState] in
          _ = await indexDatabase.updateSearchIndexInBackground(
            upserting: [],
            deletingPaths: indexedPaths,
            appState: appState
          )
        }
      }
      return
    }

    let survivingRoots = appState.workspaceRoots.filter {
      $0.url.standardizedFileURL != targetRoot.url.standardizedFileURL
    }
    let survivingRootURLs = survivingRoots.map(\.url)
    let openFileURLs = appState.openFiles.map(\.url)
    let retainedExclusions = appState.excludedWorkspacePaths.filter {
      !WorkspaceExclusion.isScoped($0, to: standardizedURL)
    }
    let bookmarkError = rewriteWorkspaceBookmarks(
      rootURLs: survivingRootURLs,
      fileURLs: openFileURLs,
      into: appState
    )

    persistExcludedPaths(Set(retainedExclusions), into: appState)
    appState.workspaceRoots = survivingRoots
    appState.folderURL = survivingRootURLs.first?.standardizedFileURL
    appState.workspaceSearchResults.removeAll {
      WorkspaceScanner.contains($0.document.url, in: standardizedURL)
    }
    startWatching(urls: survivingRootURLs, appState: appState)
    scheduleForcedRefresh(into: appState)

    if let bookmarkError {
      appState.lastError = bookmarkError
    }
  }

  /// Closes the workspace: cancels any in-flight build, stops the file watcher, clears the
  /// persisted bookmarks and all workspace state, returning to the "No folder open" state.
  /// Protects unsaved work — if the active document has unsaved edits it stays open in the
  /// editor; otherwise the editor is cleared too.
  func closeWorkspace(into appState: AppState) {
    workspaceBuildTask?.cancel()
    workspaceValidationTask?.cancel()
    // Take ownership of the activity display so the cancelled build's terminal clear
    // cannot race the direct `workspaceActivity = nil` below.
    openFlowGeneration &+= 1
    watcherRefreshTask?.cancel()
    forcedRefreshTask?.cancel()
    // Cancel any still-awaiting off-main index update. The underlying single-transaction
    // `pool.write` commits wholly or not at all, so this never leaves the index half-written.
    indexUpdateTask?.cancel()
    workspaceIndexWriteTask?.cancel()
    // Closing a workspace is the quietest moment the index ever gets: no watcher, no pending write.
    // Bound the WAL and reclaim freed pages here so the storm of a workspace's lifetime does not
    // survive into the next one.
    let indexDatabase = indexDatabase
    indexMaintenanceTask = Task {
      await indexDatabase.performMaintenanceInBackground(reason: .workspaceClose)
    }
    watcher.stop()
    bookmarkStore.clear(into: appState)
    // Clearing the baseline means the next open of any workspace cold-starts with a FULL
    // reindex (no stale delta against a foreign workspace's signature).
    lastWorkspaceSignature = nil
    lastWorkspacePresentationSignature = nil
    recentSelfWritePaths.removeAll()
    appState.workspaceRoots = []
    appState.workspaceTree = []
    appState.documents = []
    appState.openFiles = []
    appState.excludedWorkspacePaths = []
    appState.workspaceSearchQuery = ""
    appState.workspaceSearchResults = []
    appState.workspaceActivity = nil
    appState.folderURL = nil
    if !appState.documentSession.isDirty {
      appState.selectedDocumentID = nil
      appState.documentSession.clear()
    }
    appState.lastError = nil
  }

  private func openResolvedWorkspace(rootURLs: [URL], fileURLs: [URL], into appState: AppState) {
    workspaceBuildTask?.cancel()
    workspaceValidationTask?.cancel()
    openFlowGeneration &+= 1
    let label = workspaceLabel(rootURLs: rootURLs, fileURLs: fileURLs)
    let metadata = metadataStore.load()
    let exclusions = Set(metadata.excludedPaths)
    if attemptHotReopen(rootURLs: rootURLs, exclusions: exclusions, into: appState) {
      return
    }

    // Honest open state: at this point we do NOT know whether an import is coming —
    // the walk below is what decides. `.opening` (subtle) instead of an import claim.
    setOpenActivity(.opening(label), into: appState)
    indexDatabase.open(into: appState)
    let previousSelection = appState.selectedDocumentID
    prepareWorkspaceShell(rootURLs: rootURLs, fileURLs: fileURLs, into: appState)

    // ONE tree walk for the whole cold open. Build the sidebar from it, then decide skip vs full.
    let roots = appState.workspaceRoots.map(\.url)
    let scanExclusions = appState.excludedWorkspacePaths
    let scans = workspaceBuilder(roots, scanExclusions)
    applyWorkspaceScans(scans, into: appState)

    if attemptColdStartValidSkip(
      scans: scans, rootURLs: rootURLs, exclusions: scanExclusions, into: appState)
    {
      selectRestoredDocument(previousSelection: previousSelection, into: appState)
      startWatching(urls: appState.workspaceRoots.map(\.url), appState: appState)
      setOpenActivity(nil, into: appState)
      return
    }

    DebugTrace.log("cold reindex roots=\(rootURLs.count)")
    // The skip-gate said no: index writes are genuinely ahead — NOW the import claim is honest.
    setOpenActivity(.indexing(documentCount: appState.allDocuments.count), into: appState)
    coldRebuildWorkspace(scans: scans, into: appState)
    // Hand the manifest commit the fingerprint derived from THIS walk so it does not re-walk.
    // Multi-root delegates to the single-root v1 fingerprint byte-for-byte when count == 1, so
    // single-root manifests are unchanged; N>1 gets the root-qualified v2 fingerprint.
    let coldFingerprint = try? TreeFingerprint.compute(from: scans, roots: rootURLs)
    workspaceIndexWriteTask = commitWorkspaceManifest(
      rootURLs: rootURLs,
      exclusions: appState.excludedWorkspacePaths,
      precomputedFingerprint: coldFingerprint,
      cachedScans: scans,
      into: appState
    )
    selectRestoredDocument(previousSelection: previousSelection, into: appState)
    startWatching(urls: appState.workspaceRoots.map(\.url), appState: appState)
    setOpenActivity(nil, into: appState)
  }

  /// Persisted-signature-aware index decision for the cold-open path, given the tree the SINGLE
  /// cold-open walk already produced (`scans` — its tree was already applied to `appState`).
  /// Computes the current `.md` signature, then defers the skip/incremental/full FTS decision to
  /// `performColdIndex` (which reads the PERSISTED signature + the index-content guard). Unlike
  /// the live refresh search tail keyed on the IN-MEMORY baseline, this honors the on-disk
  /// baseline so a relaunch with no `.md` changes
  /// SKIPS the reindex entirely. The caller owns the one walk; this never re-walks.
  private func coldRebuildWorkspace(scans: [WorkspaceScan], into appState: AppState) {
    let roots = appState.workspaceRoots.map(\.url)
    let currentSignature = FolderManager.signature(from: scans)
    indexUpdateTask = performColdIndex(
      rootURLs: roots, currentSignature: currentSignature, into: appState)
  }

  /// Cold-start skip-gate. On a fresh launch the in-memory tree is empty, so `attemptHotReopen`'s
  /// cold-start short-circuit (STAB-R01 / B-01) hands off to the cold-scan path; this gate then
  /// consults the EXISTING substrate verdict against the persisted `tree-fingerprint.json` so an
  /// UNCHANGED workspace is opened WITHOUT re-committing every document, re-running the FTS
  /// reindex, or flashing "Indexing N files". It reuses the single cold-open walk (`scans`) —
  /// it computes the substrate fingerprint FROM that walk (no second walk) and asks the substrate
  /// for the SAME `.valid` verdict the in-session hot-reopen uses.
  ///
  /// Returns `true` ONLY when ALL of the following hold (else `false` → caller does the full
  /// cold path unchanged, preserving every existing behavior):
  /// - the workspace identity + fingerprint key on the FULL root set (N≥1; single-root reduces to
  ///   the byte-identical legacy key, so single-root caches stay warm — multi-root is now keyed
  ///   too, in lockstep with `attemptHotReopen`/`cacheIdentity`/`commitWorkspaceManifest`);
  /// - the substrate verdict is genuinely `.valid` (tree-fingerprint match + schema/scanner/
  ///   exclusions/roots/bookmark checks) — NOT a new validity notion;
  /// - the FTS index already has rows for this workspace (empty-index guard, invariant 2): a
  ///   matching fingerprint over an empty index must still FULL-reindex, never skip.
  ///
  /// On a valid skip it opens the index, restores the in-memory `.md` baseline from the persisted
  /// signature (so the first in-session edit goes INCREMENTAL, not full) — falling back to the
  /// current scan's signature if none is persisted — and issues NO index write and NO manifest
  /// re-commit. No `.indexing` activity is set: the caller clears `workspaceActivity` directly.
  private func attemptColdStartValidSkip(
    scans: [WorkspaceScan],
    rootURLs: [URL],
    exclusions: Set<String>,
    precomputedFingerprint: TreeFingerprint? = nil,
    precomputedIndexedDocumentCount: Int? = nil,
    persistPresentationCache: Bool = true,
    into appState: AppState
  ) -> Bool {
    guard !rootURLs.isEmpty else { return false }

    let identity = WorkspaceIdentity.make(
      roots: rootURLs,
      bookmarkData: appState.bookmarkData ?? bookmarkStore.bookmarkData
    )

    do {
      // Fingerprint from the SINGLE cold-open walk — no second tree walk. The background path
      // pre-computes it off the main actor and passes it in; the sync path computes it here.
      // Keyed on the full root set: N==1 reduces to the legacy v1 hash; N>1 is root-qualified v2.
      let fingerprint =
        try precomputedFingerprint ?? TreeFingerprint.compute(from: scans, roots: rootURLs)
      let verdict = try workspaceSubstrate.open(
        identity: identity,
        currentRoots: rootURLs,
        currentExclusions: exclusions,
        precomputedFingerprint: fingerprint
      )
      guard case .valid = verdict else { return false }

      // Empty/missing index guard (invariant 2): a matching fingerprint over an index with no
      // rows for this workspace must NOT skip — the operator may have nuked the index. The background
      // path pre-computes the count OFF the main actor and passes it in; the sync path computes here.
      let rootPaths = rootURLs.map { $0.standardizedFileURL.path }
      let indexedCount =
        precomputedIndexedDocumentCount
        ?? indexDatabase.indexedDocumentCount(forRootPaths: rootPaths, appState: appState)
      guard indexedCount > 0 else {
        return false
      }

      // Restore the in-memory `.md` baseline so the FIRST in-session edit goes INCREMENTAL. Prefer
      // the persisted signature (matches the live index); fall back to a signature derived from
      // the walk we already have (re-uses the scan's documents — no extra enumeration). Either way
      // no index write is issued: the verdict is `.valid`, so the on-disk index already matches.
      lastWorkspaceSignature =
        cacheStore.readSearchSignature(for: identity)
        ?? FolderManager.signature(from: scans)
      if persistPresentationCache {
        do {
          try cacheStore.writeWorkspaceScans(scans, for: identity)
        } catch {
          // The manifest/index verdict remains valid even if this optional acceleration artifact
          // cannot be written. Keep the correct no-reindex result and retry migration next launch.
          NSLog("%@", "Presentation cache migration failed: \(error)")
        }
      }
      appState.lastError = nil
      DebugTrace.log("coldStartValidSkip taken roots=\(rootURLs.count)")
      return true
    } catch {
      NSLog("%@", "Cold-start valid-skip check failed, falling back to cold open: \(error)")
      return false
    }
  }

  private func openResolvedWorkspaceInBackground(
    rootURLs: [URL], fileURLs: [URL], into appState: AppState
  ) {
    workspaceBuildTask?.cancel()
    workspaceValidationTask?.cancel()
    openFlowGeneration &+= 1
    let generation = openFlowGeneration
    let label = workspaceLabel(rootURLs: rootURLs, fileURLs: fileURLs)
    let requestedRootPaths = rootURLs.map { $0.standardizedFileURL.path }
    let requestedOpenFilePaths =
      fileURLs
      .filter(WorkspaceScanner.isMarkdownFile)
      .map { $0.standardizedFileURL.path }
    let isHotReopen =
      !rootURLs.isEmpty && !appState.workspaceTree.isEmpty
      && matchesCurrentWorkspace(
        rootPaths: requestedRootPaths,
        openFilePaths: requestedOpenFilePaths,
        in: appState
      )

    // Preserve the existing/cached tree while ONE detached validation job walks + fingerprints.
    // No substrate validation, scanner build, fingerprint, or signature fallback runs before this
    // method returns to the main actor.
    let previousSelection = appState.selectedDocumentID
    prepareWorkspaceShell(rootURLs: rootURLs, fileURLs: fileURLs, into: appState)
    let restoredPresentationCache =
      !isHotReopen
      && restoreCachedWorkspace(
        rootURLs: rootURLs,
        previousSelection: previousSelection,
        into: appState
      )
    let hasStalePresentation = isHotReopen || restoredPresentationCache
    if hasStalePresentation {
      // Stale-while-revalidate: the last committed tree is already usable. The walk below still
      // proves freshness, but it is background maintenance rather than a loading state.
      setOpenActivity(nil, into: appState)
    } else {
      // First open has no presentation cache yet. Keep the activity honest while the initial
      // off-main walk builds it; subsequent opens take the instant path above.
      setOpenActivity(.opening(label), into: appState)
    }

    let expectedRootPaths = appState.workspaceRoots.map { $0.url.standardizedFileURL.path }
    let expectedOpenFilePaths = appState.openFiles.map { $0.url.standardizedFileURL.path }
    let roots = appState.workspaceRoots.map(\.url)
    let scanExclusions = appState.excludedWorkspacePaths
    guard !roots.isEmpty else {
      applyWorkspaceScans([], into: appState)
      selectRestoredDocument(previousSelection: previousSelection, into: appState)
      setOpenActivity(nil, into: appState)
      return
    }

    let identity = WorkspaceIdentity.make(
      roots: roots,
      bookmarkData: appState.bookmarkData ?? bookmarkStore.bookmarkData
    )
    let workspaceBuilder = workspaceBuilder
    let workspaceSubstrate = workspaceSubstrate
    let workspaceValidationProbe = workspaceValidationProbe
    let validationTask = workspaceSubstrate.startValidation(
      identity: identity,
      currentRoots: roots,
      currentExclusions: scanExclusions,
      workspaceBuilder: workspaceBuilder,
      persistPresentationCache: !hasStalePresentation,
      probe: workspaceValidationProbe
    )
    workspaceValidationTask = validationTask

    workspaceBuildTask = Task { [weak self, weak appState] in
      guard let self, let appState else { return }
      // EVERY exit from this task — cancellation guard, workspace mismatch, or the
      // normal tail — must tear the `.opening`/`.indexing` presentation down, unless a
      // newer open flow already owns the display. A bare `return` here used to leave
      // the "Opening Workspace" spinner on screen forever (e.g. an ad-hoc file opened
      // mid-walk fails the workspace match; `applyRefresh` cancels the build outright).
      defer { self.finishOpenFlow(generation: generation, into: appState) }
      let validation: WorkspaceValidationResult
      do {
        validation = try await withTaskCancellationHandler {
          try await validationTask.value
        } onCancel: {
          validationTask.cancel()
        }
      } catch is CancellationError {
        return
      } catch {
        guard generation == self.openFlowGeneration else { return }
        appState.lastError = "Could not validate workspace: \(error.localizedDescription)"
        return
      }

      guard !Task.isCancelled, generation == self.openFlowGeneration,
        self.matchesCurrentWorkspace(
          rootPaths: expectedRootPaths,
          openFilePaths: expectedOpenFilePaths,
          in: appState
        )
      else {
        return
      }

      if case .some(.accessDenied(let reason)) = validation.verdict {
        appState.lastError = "Could not open cached workspace: \(reason)"
        return
      }

      // Publication happens only after cancellation, generation, roots, and open-file guards.
      self.applyWorkspaceScans(validation.scans, into: appState)

      // Open the index OFF the main thread (coalesced — subsequent DB consumers reuse this pool).
      await self.indexDatabase.openInBackground(into: appState)
      guard !Task.isCancelled, generation == self.openFlowGeneration,
        self.matchesCurrentWorkspace(
          rootPaths: expectedRootPaths,
          openFilePaths: expectedOpenFilePaths,
          in: appState
        )
      else { return }

      let cacheIsValid: Bool
      if case .some(.valid) = validation.verdict {
        cacheIsValid = true
      } else {
        cacheIsValid = false
      }

      // In-session hot reopen preserves its prior index-content invariant. Cold launch additionally
      // proves the index has rows before taking the valid-skip route.
      if cacheIsValid, isHotReopen {
        self.setOpenActivity(.cacheHit(label), into: appState)
        self.lastWorkspaceSignature = validation.searchSignature
        appState.lastError = nil
        self.selectRestoredDocument(previousSelection: previousSelection, into: appState)
        self.startWatching(urls: appState.workspaceRoots.map(\.url), appState: appState)
        return
      }

      let indexedCount = await self.indexDatabase.indexedDocumentCountInBackground(
        forRootPaths: roots.map { $0.standardizedFileURL.path }, appState: appState)
      guard !Task.isCancelled, generation == self.openFlowGeneration,
        self.matchesCurrentWorkspace(
          rootPaths: expectedRootPaths,
          openFilePaths: expectedOpenFilePaths,
          in: appState
        )
      else { return }

      if cacheIsValid, indexedCount > 0 {
        self.setOpenActivity(.cacheHit(label), into: appState)
        self.lastWorkspaceSignature = validation.searchSignature
        appState.lastError = nil
        DebugTrace.log("coldStartValidSkip taken roots=\(roots.count)")
        self.selectRestoredDocument(previousSelection: previousSelection, into: appState)
        self.startWatching(urls: appState.workspaceRoots.map(\.url), appState: appState)
        return
      }

      if validation.verdict != nil {
        self.setOpenActivity(.cacheMiss(label), into: appState)
      }
      DebugTrace.log("cold reindex roots=\(roots.count)")
      // The skip-gate said no: manifest commit + index writes are genuinely ahead — the
      // "Importing Workspace" claim becomes honest exactly here, never during the walk.
      self.setOpenActivity(
        .indexing(documentCount: appState.allDocuments.count), into: appState)
      let workspaceIndexWriteTask: Task<Void, Never>?
      if let fingerprint = validation.fingerprint {
        workspaceIndexWriteTask = self.commitWorkspaceManifest(
          rootURLs: roots,
          exclusions: scanExclusions,
          precomputedFingerprint: fingerprint,
          cachedScans: validation.scans,
          into: appState
        )
      } else {
        workspaceIndexWriteTask = nil
      }
      self.workspaceIndexWriteTask = workspaceIndexWriteTask
      self.selectRestoredDocument(previousSelection: previousSelection, into: appState)
      self.startWatching(urls: appState.workspaceRoots.map(\.url), appState: appState)
      await workspaceIndexWriteTask?.value
      guard !Task.isCancelled, generation == self.openFlowGeneration else { return }
      let indexTask = self.performColdIndex(
        rootURLs: roots,
        currentSignature: validation.searchSignature,
        precomputedIndexHasContent: indexedCount > 0,
        into: appState
      )
      self.indexUpdateTask = indexTask
      await indexTask?.value
      // The defer clears the `.indexing` activity (generation-guarded, so a superseding
      // open that cancelled this await keeps its own presentation).
    }
  }

  private func attemptHotReopen(
    rootURLs: [URL], exclusions: Set<String>, into appState: AppState
  ) -> Bool {
    let label = workspaceLabel(rootURLs: rootURLs, fileURLs: appState.openFiles.map(\.url))

    // Cache fast-path keys on the FULL root set (N≥1). The real guard against silently dropping
    // an ADDED folder is `matchesCurrentWorkspace` below: when `open` merged a new root the
    // in-memory roots no longer equal the requested set, so the match fails and we fall to the
    // cold scan path (WorkspaceScanner.build owns the multi-root walk). A `.valid` fast-return
    // only happens when the in-memory workspace already holds EXACTLY these roots.
    // No `.cacheMiss` here: nothing was validated yet, so a miss claim (titled as an
    // import) would be dishonest. The caller immediately sets `.opening` on the false
    // return; `.cacheMiss` is reserved for a REAL substrate verdict below.
    guard !rootURLs.isEmpty else {
      return false
    }

    // Cold-start short-circuit (STAB-R01 / B-01): if there is no in-memory
    // workspace yet (empty tree) or the requested workspace does not match the
    // one already loaded, skip the substrate validate-walk and hand off to the
    // cold-scan path so the scanner owns the single tree walk. Without this,
    // cold start with an existing manifest pays for the validate-walk only to
    // fall through to the cold scan anyway.
    let rootPaths = rootURLs.map { $0.standardizedFileURL.path }
    let openFilePaths = appState.openFiles.map { $0.url.standardizedFileURL.path }
    guard
      matchesCurrentWorkspace(
        rootPaths: rootPaths,
        openFilePaths: openFilePaths,
        in: appState
      ),
      !appState.workspaceTree.isEmpty
    else {
      // Cold-start short-circuit: the substrate was never consulted, so do not publish a
      // synthetic cache-checking state. The background path can restore its presentation cache
      // immediately before the validation walk begins.
      return false
    }

    setOpenActivity(.checkingCache(label), into: appState)

    let identity = WorkspaceIdentity.make(
      roots: rootURLs,
      bookmarkData: appState.bookmarkData ?? bookmarkStore.bookmarkData
    )

    do {
      let verdict = try workspaceSubstrate.open(
        identity: identity,
        currentRoots: rootURLs,
        currentExclusions: exclusions
      )
      switch verdict {
      case .valid:
        setOpenActivity(.cacheHit(label), into: appState)
        // In-session hot-reopen: the pool is already open from the initial cold open, so this is a
        // no-op fast return; the rare first-open runs OFF the main thread rather than blocking it.
        let indexDatabase = indexDatabase
        Task { await indexDatabase.openInBackground(into: appState) }
        startWatching(urls: appState.workspaceRoots.map(\.url), appState: appState)
        // Restore the in-memory `.md` baseline so the FIRST edit after this in-session hot-reopen
        // goes INCREMENTAL (fixes the prior "hot-reopen leaves baseline nil → first change
        // full-reindexes" caveat). Prefer the persisted signature (matches the live index); fall
        // back to a fresh scan if none is persisted. Either way no index write is issued here —
        // the cache verdict is `.valid`, so the on-disk index already matches.
        lastWorkspaceSignature =
          cacheStore.readSearchSignature(for: identity)
          ?? FolderManager.currentWorkspaceSignature(
            roots: rootURLs, exclusions: exclusions)
        appState.lastError = nil
        setOpenActivity(nil, into: appState)
        return true
      case .accessDenied(let reason):
        appState.lastError = "Could not open cached workspace: \(reason)"
        setOpenActivity(nil, into: appState)
        return true
      case .missing, .stale, .incompatibleSchema, .corrupted:
        setOpenActivity(.cacheMiss(label), into: appState)
        return false
      }
    } catch {
      NSLog("%@", "Hot-reopen cache validation failed, falling back to cold open: \(error)")
      setOpenActivity(.cacheMiss(label), into: appState)
      return false
    }
  }

  private func prepareWorkspaceShell(rootURLs: [URL], fileURLs: [URL], into appState: AppState) {
    let metadata = metadataStore.load()
    appState.excludedWorkspacePaths = Set(metadata.excludedPaths)
    appState.workspaceRoots = rootURLs.map { WorkspaceRoot(id: $0.standardizedFileURL) }
    appState.folderURL = appState.workspaceRoots.first?.url
    var seenOpenFileURLs = Set<URL>()
    appState.openFiles =
      fileURLs
      .filter(WorkspaceScanner.isMarkdownFile)
      .map { $0.standardizedFileURL }
      .filter { seenOpenFileURLs.insert($0).inserted }
      .map { DocumentRef(id: $0, isAdHoc: true) }
    appState.lastError = nil
  }

  /// Publishes the last committed workspace tree before the validation walk completes. The cache
  /// is identity-keyed by the full standardized root set + bookmark, and the root list is checked
  /// again before use. Fresh scans always replace this state later in the same open flow.
  private func restoreCachedWorkspace(
    rootURLs: [URL],
    previousSelection: DocumentRef.ID?,
    into appState: AppState
  ) -> Bool {
    guard !rootURLs.isEmpty else { return false }
    let standardizedRoots = rootURLs.map(\.standardizedFileURL).sorted { $0.path < $1.path }
    let identity = WorkspaceIdentity.make(
      roots: standardizedRoots,
      bookmarkData: appState.bookmarkData ?? bookmarkStore.bookmarkData
    )
    guard let scans = try? cacheStore.readWorkspaceScans(for: identity) else {
      return false
    }
    let cachedRoots = scans.compactMap { $0.rootNode.url?.standardizedFileURL }
      .sorted { $0.path < $1.path }
    guard cachedRoots == standardizedRoots else { return false }

    applyWorkspaceScans(scans, into: appState)
    lastWorkspaceSignature = cacheStore.readSearchSignature(for: identity)
    selectRestoredDocument(previousSelection: previousSelection, into: appState)
    DebugTrace.log(
      "presentation cache restored roots=\(rootURLs.count) documents=\(appState.documents.count)")
    return true
  }

  /// Applies only the search side of a freshness snapshot. Presentation is independently
  /// published when its signature changes; this method never walks or republishes the tree.
  /// A known baseline uses an incremental delta, while missing stat evidence fails open to a
  /// full background reindex without blessing a new baseline.
  private func updateWorkspaceSearchIndex(
    signature newSignature: WorkspaceSignature?,
    into appState: AppState
  ) {
    let roots = appState.workspaceRoots.map(\.url)
    let baseline = lastWorkspaceSignature

    // The FTS index write runs OFF the main actor on a tracked Task. FolderManager is
    // @MainActor and this method is sync, so the body of either background variant — which
    // performs the body reads + the single `pool.write` transaction on a detached `.utility`
    // task — never blocks the main actor regardless of delta size. A LARGE delta (a batch of
    // dropped `.md` files) and the cold/fallback FULL reindex both go through the same off-main
    // path. The in-memory tree (`applyWorkspaceScans` above) already updated synchronously, so
    // the sidebar + selection see the change immediately; only the searchable index lags.
    //
    // Snapshot the Sendable inputs BEFORE launching the Task. Both background variants chain on
    // `IndexDatabase.pendingIndexUpdateTask` (serialized in submission order) and are awaitable
    // via `IndexDatabase.waitForPendingReindex()` — tests sync on that. The FolderManager-side
    // `indexUpdateTask` handle exists so `closeWorkspace` can cancel a still-awaiting update and
    // so callers can await it (`waitForPendingIndexUpdate`).
    let indexDatabase = indexDatabase
    // Persist the just-applied signature AFTER the index write so a relaunch sees a signature
    // that matches the live index (single-root only — multi-root cache is not keyed). Captured
    // for the Task tails; nil identity / nil signature ⇒ no persistence (next launch full-
    // reindexes, which is correct, just not optimal).
    let cacheStore = cacheStore
    let persistIdentity = cacheIdentity(rootURLs: roots, appState: appState)
    // Pre-set the in-memory baseline so the synchronous return contract + the watcher see the
    // just-applied tree immediately; the Task tails RESET it to the prior baseline if the FTS
    // write FAILS, so the next in-session edit never diffs against a baseline the index does not
    // actually reflect (the persisted on-disk signature is likewise gated on success below).
    let priorBaseline = lastWorkspaceSignature
    if let baseline, let newSignature {
      // Incremental: touch only what changed. The tree already reflects the new set; map the
      // changed paths back to DocumentRefs for the upsert.
      let delta = WorkspaceSignature.delta(from: baseline, to: newSignature)
      let documentsByPath = Dictionary(
        appState.allDocuments.map { ($0.url.standardizedFileURL.path, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      let upserts = delta.upsertedPaths.compactMap { documentsByPath[$0] }
      let deletingPaths = delta.removed
      indexUpdateTask = Task { [weak self, weak appState] in
        let didWrite = await indexDatabase.updateSearchIndexInBackground(
          upserting: upserts, deletingPaths: deletingPaths, appState: appState)
        guard didWrite else {
          self?.revertBaselineOnFailedWrite(to: priorBaseline, ifAdvancedTo: newSignature)
          return
        }
        if let persistIdentity {
          Self.persistSearchSignature(newSignature, for: persistIdentity, using: cacheStore)
        }
      }
    } else {
      // Cold open (no baseline) or signature uncertainty (fail open): full reindex, off-main.
      let documents = appState.allDocuments
      let persistSignature = newSignature
      indexUpdateTask = Task { [weak self, weak appState] in
        let didWrite = await indexDatabase.reindexInBackground(
          documents: documents, appState: appState)
        guard didWrite else {
          self?.revertBaselineOnFailedWrite(to: priorBaseline, ifAdvancedTo: persistSignature)
          return
        }
        if let persistIdentity, let persistSignature {
          Self.persistSearchSignature(persistSignature, for: persistIdentity, using: cacheStore)
        }
      }
    }

    lastWorkspaceSignature = newSignature
  }

  /// Restores the in-memory `.md` baseline to `priorBaseline` after a FAILED FTS write, but ONLY
  /// if no later rebuild has already advanced it past `advancedSignature` (the value this write
  /// optimistically set). This keeps the in-memory baseline consistent with what the index
  /// actually reflects: a failed write means the index is stale/empty for the changed set, so the
  /// next in-session edit must NOT diff against the would-be-current baseline (it would miss the
  /// files the failed write never wrote). The guard avoids clobbering a newer, successful rebuild
  /// that landed while this failure was in flight. Runs on the main actor (mutates `self`).
  private func revertBaselineOnFailedWrite(
    to priorBaseline: WorkspaceSignature?, ifAdvancedTo advancedSignature: WorkspaceSignature?
  ) {
    guard lastWorkspaceSignature == advancedSignature else { return }
    lastWorkspaceSignature = priorBaseline
  }

  /// Produces every refresh artifact from one injected scanner walk. Presentation identity is
  /// pure path/kind data; search identity stats only the supported documents from those scans;
  /// the cache fingerprint is also derived from the scans without re-enumerating the workspace.
  nonisolated static func refreshSnapshot(
    roots: [URL],
    exclusions: Set<String>,
    builder: WorkspaceScanner.Builder
  ) -> WorkspaceRefreshSnapshot {
    let scans = builder(roots, exclusions)
    return WorkspaceRefreshSnapshot(
      scans: scans,
      presentationSignature: WorkspacePresentationSignature(scans: scans),
      searchSignature: signature(from: scans),
      fingerprint: try? TreeFingerprint.compute(from: scans, roots: roots)
    )
  }

  /// Precise structured `.md`-tree signature (`standardizedPath -> FileSignature{mtime,size}`)
  /// across all workspace roots. Replaces the opaque joined-String fingerprint: the same
  /// `path | full-precision mtime | size` evidence, now keyed by path so the watcher/refresh
  /// path can DIFF it (added/modified/removed) and update the FTS index proportionally to the
  /// change rather than full-replacing it. Equality still gates the skip-when-unchanged path,
  /// so non-`.md` churn (screenshots, `.DS_Store`) leaves the signature unchanged and the
  /// rebuild is skipped. Unlike `TreeFingerprint` (whole-second mtime), this keeps the
  /// sub-second modification time, so a same-second, same-length external edit is still
  /// detected. Uses the STATIC scanner (not the injected builder) so the gate never counts as
  /// a rebuild. Returns nil when there are no roots or a file cannot be stat'd — callers then
  /// full-rebuild (fail open; never skip / never delta on uncertainty).
  ///
  /// `nonisolated static` so the legacy hot-reopen fallback can also be moved across an actor
  /// boundary when that call path becomes asynchronous. Live refreshes do not call this helper;
  /// they derive both freshness signatures from `refreshSnapshot` and its one injected walk.
  nonisolated static func currentWorkspaceSignature(roots: [URL], exclusions: Set<String>)
    -> WorkspaceSignature?
  {
    guard !roots.isEmpty else { return nil }
    guard
      let scans = try? WorkspaceScanner.buildCancellable(
        rootURLs: roots, exclusions: exclusions)
    else { return nil }
    return signature(from: scans)
  }

  /// Builds a `WorkspaceSignature` from ALREADY-WALKED scans, statting each `.md` document but
  /// NOT re-enumerating the directory. The cold-start skip-gate reuses this with the single
  /// cold-open walk so its baseline fallback costs no extra tree walk. Returns nil on a stat
  /// failure (caller treats it as "no baseline" → first edit full-reindexes; fail open). `mtime`
  /// is full-precision (matches `currentWorkspaceSignature`); used only as the IN-MEMORY baseline.
  nonisolated static func signature(from scans: [WorkspaceScan]) -> WorkspaceSignature? {
    let documents = scans.flatMap(\.documents)
    var entries: [String: FileSignature] = [:]
    entries.reserveCapacity(documents.count)
    for document in documents {
      guard !Task.isCancelled else { return nil }
      guard
        let values = try? document.url.resourceValues(forKeys: [
          .contentModificationDateKey, .fileSizeKey,
        ])
      else { return nil }
      let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
      let size = values.fileSize ?? 0
      entries[document.url.standardizedFileURL.path] = FileSignature(mtime: mtime, size: size)
    }
    return WorkspaceSignature(entries: entries)
  }

  /// Workspace identity for cache keying (signature, fingerprint, manifest), keyed on the FULL
  /// root set (N≥1). Single-root reduces to the byte-identical legacy key so existing single-root
  /// signature caches stay warm; multi-root is keyed in lockstep with `attemptHotReopen` /
  /// `attemptColdStartValidSkip` / `commitWorkspaceManifest`, so the persisted `.md` signature
  /// survives across launches for a multi-root workspace too. Returns nil only for an empty root
  /// set (caller full-reindexes, persists nothing — there is nothing to key on).
  private func cacheIdentity(rootURLs: [URL], appState: AppState) -> WorkspaceIdentity? {
    guard !rootURLs.isEmpty else { return nil }
    return WorkspaceIdentity.make(
      roots: rootURLs,
      bookmarkData: appState.bookmarkData ?? bookmarkStore.bookmarkData
    )
  }

  /// Decides the cold-open FTS work using the PERSISTED `.md` signature (survives across
  /// launches, unlike the in-memory `lastWorkspaceSignature`) and an index-content guard:
  ///
  /// - persisted == current AND index already has rows for this workspace → SKIP the reindex
  ///   entirely (the common relaunch-with-no-changes case; kills the per-launch reindex storm);
  /// - persisted exists, differs, index has rows → INCREMENTAL delta: upsert only added/modified
  ///   docs, delete removed paths (the live-folder case: operator edited a few files);
  /// - no persisted signature, OR the index is empty/missing for this workspace (true first run
  ///   / post-reset / operator nuked Application Support) → FULL reindex.
  ///
  /// In all three branches the in-memory baseline is set to `current` so the first subsequent
  /// edit goes incremental. The persisted signature is (re)written ONLY after the index write
  /// succeeds (skip needs no write — the prior signature already matches the live index). Returns
  /// the launched index-write Task (nil on skip) so the caller can await it.
  ///
  /// Multi-root (identity == nil) or a failed current-signature scan (current == nil) falls back
  /// to a FULL reindex with NO persistence — never skip / never delta on uncertainty (fail open).
  @discardableResult
  private func performColdIndex(
    rootURLs: [URL],
    currentSignature: WorkspaceSignature?,
    precomputedIndexHasContent: Bool? = nil,
    into appState: AppState
  ) -> Task<Void, Never>? {
    let documents = appState.allDocuments
    let indexDatabase = indexDatabase
    let identity = cacheIdentity(rootURLs: rootURLs, appState: appState)
    let rootPaths = rootURLs.map { $0.standardizedFileURL.path }
    // Prior in-memory baseline; the Task tails reset to it if the FTS write fails (see
    // `revertBaselineOnFailedWrite`). At true cold open this is nil — a failed write then leaves
    // the baseline nil so the first edit FULL-reindexes (fail open), which is correct.
    let priorBaseline = lastWorkspaceSignature

    guard let identity, let currentSignature else {
      // Multi-root or signature scan failure: full reindex, persist nothing.
      lastWorkspaceSignature = currentSignature
      return Task { [weak self, weak appState] in
        let didWrite = await indexDatabase.reindexInBackground(
          documents: documents, appState: appState)
        if !didWrite {
          self?.revertBaselineOnFailedWrite(to: priorBaseline, ifAdvancedTo: currentSignature)
        }
      }
    }

    let persisted = cacheStore.readSearchSignature(for: identity)
    // The background import path pre-computes this content guard OFF the main actor and passes it in;
    // the legacy synchronous path computes it here (its `pool.read` then runs on the caller's thread).
    let indexHasContent =
      precomputedIndexHasContent
      ?? (indexDatabase.indexedDocumentCount(forRootPaths: rootPaths, appState: appState) > 0)

    // SKIP: nothing changed and the index is already populated for this workspace.
    if let persisted, indexHasContent,
      WorkspaceSignature.delta(from: persisted, to: currentSignature).isEmpty
    {
      lastWorkspaceSignature = currentSignature
      return nil
    }

    // INCREMENTAL: a persisted baseline exists, it differs, and the index has rows to delta.
    if let persisted, indexHasContent {
      let delta = WorkspaceSignature.delta(from: persisted, to: currentSignature)
      let documentsByPath = Dictionary(
        documents.map { ($0.url.standardizedFileURL.path, $0) },
        uniquingKeysWith: { first, _ in first }
      )
      let upserts = delta.upsertedPaths.compactMap { documentsByPath[$0] }
      let deletingPaths = delta.removed
      let cacheStore = cacheStore
      lastWorkspaceSignature = currentSignature
      return Task { [weak self, weak appState] in
        let didWrite = await indexDatabase.updateSearchIndexInBackground(
          upserting: upserts, deletingPaths: deletingPaths, appState: appState)
        guard didWrite else {
          self?.revertBaselineOnFailedWrite(to: priorBaseline, ifAdvancedTo: currentSignature)
          return
        }
        Self.persistSearchSignature(currentSignature, for: identity, using: cacheStore)
      }
    }

    // FULL: no persisted signature, or the index is empty/missing for this workspace.
    let cacheStore = cacheStore
    lastWorkspaceSignature = currentSignature
    return Task { [weak self, weak appState] in
      let didWrite = await indexDatabase.reindexInBackground(
        documents: documents, appState: appState)
      guard didWrite else {
        self?.revertBaselineOnFailedWrite(to: priorBaseline, ifAdvancedTo: currentSignature)
        return
      }
      Self.persistSearchSignature(currentSignature, for: identity, using: cacheStore)
    }
  }

  /// Persists the signature off the main actor AFTER the matching index write completed, so a
  /// crash between "index written" and "signature written" only costs an extra reindex next
  /// launch (the signature is conservatively absent), never a stale signature pointing at an
  /// index that does not match. Best-effort: a write failure is swallowed (next launch
  /// full-reindexes — correct, just not optimal).
  private nonisolated static func persistSearchSignature(
    _ signature: WorkspaceSignature,
    for identity: WorkspaceIdentity,
    using cacheStore: WorkspaceCacheStore
  ) {
    try? cacheStore.writeSearchSignature(signature, for: identity)
  }

  private func commitWorkspaceManifest(
    rootURLs: [URL], exclusions: Set<String>,
    precomputedFingerprint: TreeFingerprint? = nil,
    cachedScans: [WorkspaceScan]? = nil,
    into appState: AppState
  ) -> Task<Void, Never>? {
    guard !rootURLs.isEmpty else { return nil }
    let startedAt = Date()
    let identity = WorkspaceIdentity.make(
      roots: rootURLs,
      bookmarkData: appState.bookmarkData ?? bookmarkStore.bookmarkData
    )
    do {
      // Reuse the fingerprint the single cold-open walk already produced instead of walking the
      // tree a SECOND time. `compute(from:scans:roots:)` is byte-for-byte identical to
      // `compute(roots:exclusions:)` for the same tree (and to the legacy single-root path when
      // count == 1), so the persisted manifest/fingerprint are unchanged for single-root and
      // root-qualified for multi-root (no STAB-R01 regression — the scanner still owns the only
      // walk). Falls back to a fresh walk only when no precomputed fingerprint is supplied.
      let fingerprint =
        try precomputedFingerprint
        ?? TreeFingerprint.compute(roots: rootURLs, exclusions: exclusions)
      let manifest = try workspaceSubstrate.commit(
        identity: identity,
        roots: rootURLs,
        exclusions: exclusions,
        fingerprint: fingerprint
      )
      if let cachedScans {
        try cacheStore.writeWorkspaceScans(cachedScans, for: identity)
      }
      let documents = appState.documents
      return Task {
        await indexDatabase.upsertWorkspace(
          identity: identity,
          roots: rootURLs,
          documents: documents,
          appState: appState
        )

        let finishedAt = Date()
        let durationMs = Int(finishedAt.timeIntervalSince(startedAt) * 1000)

        await indexDatabase.appendScanSession(
          workspaceID: identity.workspaceID,
          trigger: "cold_scan",
          startedAt: startedAt,
          finishedAt: finishedAt,
          scannerVersion: manifest.scannerVersion,
          fingerprintHash: manifest.treeFingerprint.treeHash,
          fileCount: manifest.fileCount,
          folderCount: manifest.folderCount,
          durationMs: durationMs,
          appState: appState
        )

        await indexDatabase.refreshWorkspaceStats(
          workspaceID: identity.workspaceID,
          fileCount: manifest.fileCount,
          folderCount: manifest.folderCount,
          fingerprintMatches: true,
          appState: appState
        )
      }
    } catch {
      try? workspaceSubstrate.markFailure(identity: identity, kind: "manifestCommitFailed")
      appState.lastError = "Could not update workspace cache: \(error.localizedDescription)"
      return nil
    }
  }

  private func applyWorkspaceScans(_ scans: [WorkspaceScan], into appState: AppState) {
    appState.documents = scans.flatMap(\.documents)
    appState.workspaceTree = scans.map(\.rootNode)
    lastWorkspacePresentationSignature = WorkspacePresentationSignature(scans: scans)

    let workspaceIDs = Set(appState.documents.map(\.id))
    appState.openFiles.removeAll { workspaceIDs.contains($0.id) }
  }

  private func selectRestoredDocument(previousSelection: DocumentRef.ID?, into appState: AppState) {
    guard !appState.documentSession.isDirty else { return }

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
      try watcher.start(watching: urls) { [weak self, weak appState] events in
        let deliveredOffMain = !Thread.isMainThread
        Task { @MainActor in
          guard let self, let appState else { return }
          let rootPaths = appState.workspaceRoots.map {
            FileWatcherEvent.canonicalPath(for: $0.url.path)
          }
          let visibleEvents = self.scannerVisibleWatcherEvents(events, rootPaths: rootPaths)
          let actionableEvents = self.actionableWatcherEvents(visibleEvents)
          let requiresFullReconcile = actionableEvents.contains(where: \.requiresFullReconcile)
          DebugTrace.log(
            "watcher events=\(events.count) visible=\(visibleEvents.count) "
              + "actionable=\(actionableEvents.count) "
              + "full=\(requiresFullReconcile) deliveryOffMain=\(deliveredOffMain) "
              + "paths=\(events.map { "\($0.path):\($0.flags.rawValue)" }.joined(separator: ","))"
          )
          guard !actionableEvents.isEmpty else { return }
          // FolderManager is the sole application-level coalescer. Every surviving path batch
          // feeds W1-A's canonical full snapshot; flags only prevent unsafe path-level trust.
          self.scheduleWatcherRefresh(into: appState)
        }
      }
    } catch {
      appState.lastError = "Could not watch folder: \(error.localizedDescription)"
    }
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

  /// Rebuilds both root and ad-hoc file bookmark sets through BookmarkStore's prepare-then-replace
  /// path. A removed root cannot return on relaunch, while failure to create a new bookmark leaves
  /// the previously valid persisted workspace intact instead of clearing it partially.
  private func rewriteWorkspaceBookmarks(
    rootURLs: [URL],
    fileURLs: [URL],
    into appState: AppState
  ) -> String? {
    do {
      try bookmarkStore.replaceWorkspace(
        rootURLs: rootURLs,
        fileURLs: fileURLs,
        into: appState
      )
      return nil
    } catch {
      return "Could not update workspace bookmarks: \(error.localizedDescription)"
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

  private func pruneExpiredSelfWrites() {
    let now = Date()
    recentSelfWritePaths = recentSelfWritePaths.filter { _, writeDate in
      now.timeIntervalSince(writeDate) <= selfWriteSuppressionInterval
    }
  }

  private func pruneOpenFiles(into appState: AppState, protecting protectedID: URL? = nil) {
    pruneOpenFilesWorkingSet(into: appState, protecting: protectedID)
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

struct WorkspaceScan: Codable, Sendable {
  var documents: [DocumentRef]
  var rootNode: WorkspaceNode
}

/// Deterministic identity of the sidebar's visible universe. Every root, folder, and supported
/// document contributes its standardized path and semantic kind; unsupported files never enter
/// the scanner tree and therefore cannot perturb presentation freshness.
struct WorkspacePresentationSignature: Equatable, Sendable {
  struct Entry: Equatable, Sendable {
    var path: String
    var kind: WorkspaceNode.Kind
  }

  var entries: [Entry]

  init(scans: [WorkspaceScan]) {
    var collected: [Entry] = []

    func collect(_ node: WorkspaceNode) {
      if let url = node.url {
        collected.append(
          Entry(path: url.standardizedFileURL.path, kind: node.kind)
        )
      }
      for child in node.children ?? [] {
        collect(child)
      }
    }

    for scan in scans {
      collect(scan.rootNode)
    }
    entries = collected.sorted {
      if $0.path != $1.path { return $0.path < $1.path }
      return $0.kind.rawValue < $1.kind.rawValue
    }
  }
}

/// One off-main filesystem walk and every artifact derived from it. `TreeFingerprint` remains a
/// cache-validation artifact; it is carried beside, not reused as, either live freshness gate.
struct WorkspaceRefreshSnapshot: @unchecked Sendable {
  var scans: [WorkspaceScan]
  var presentationSignature: WorkspacePresentationSignature
  var searchSignature: WorkspaceSignature?
  var fingerprint: TreeFingerprint?
}

/// Per-file `.md` signature: full-precision modification time + byte size. Two
/// files with the same path are considered "modified" when EITHER differs, so a
/// same-second content edit that changes the size, OR a same-size edit that
/// bumps the mtime, is detected. Full-precision `mtime` (not whole-second, as
/// `TreeFingerprint` uses) preserves sub-second edits.
struct FileSignature: Codable, Equatable, Sendable {
  var mtime: TimeInterval
  var size: Int
}

/// Structured workspace `.md` signature: `standardizedPath -> FileSignature`
/// across all roots. Replaces the opaque joined-String fingerprint as the
/// baseline the watcher/refresh path diffs against. Equality of two signatures
/// is the skip-when-unchanged gate; the delta between two signatures drives the
/// incremental FTS update. Computed off the main actor (RC-2) — all members are
/// `Sendable`, so it crosses the actor boundary cleanly.
struct WorkspaceSignature: Codable, Equatable, Sendable {
  var entries: [String: FileSignature]

  init(entries: [String: FileSignature] = [:]) {
    self.entries = entries
  }

  /// Files in `new` but not in `old` (added), in both but with a changed
  /// signature (modified), and in `old` but not in `new` (removed). Pure and
  /// deterministic — the unit-testable core of the scan-diff. The FSEvents
  /// stage will produce the same `Delta` shape from event paths and feed it to
  /// the SAME apply step, so the apply path is reused unchanged.
  struct Delta: Equatable, Sendable {
    var added: [String]
    var modified: [String]
    var removed: [String]

    var isEmpty: Bool { added.isEmpty && modified.isEmpty && removed.isEmpty }

    /// Paths whose FTS row must be (re)written: added + modified.
    var upsertedPaths: [String] { added + modified }
  }

  static func delta(from old: WorkspaceSignature, to new: WorkspaceSignature) -> Delta {
    var added: [String] = []
    var modified: [String] = []
    for (path, signature) in new.entries {
      if let previous = old.entries[path] {
        if previous != signature {
          modified.append(path)
        }
      } else {
        added.append(path)
      }
    }
    let removed = old.entries.keys.filter { new.entries[$0] == nil }
    return Delta(
      added: added.sorted(),
      modified: modified.sorted(),
      removed: removed.sorted()
    )
  }
}

/// Persisted exclusion identity. New entries are scoped to one standardized root so `docs`
/// under root A never hides `docs` under root B. Bare legacy entries remain readable and apply
/// to every root exactly as they did before this migration.
enum WorkspaceExclusion {
  private static let separator = "::"

  static func scopedKey(for url: URL, roots: [URL]) -> String? {
    let standardizedURL = url.standardizedFileURL
    let matchingRoot =
      roots
      .map(\.standardizedFileURL)
      .filter { WorkspaceScanner.contains(standardizedURL, in: $0) }
      .sorted { $0.path.count > $1.path.count }
      .first
    guard let matchingRoot else { return nil }
    let relativePath = WorkspaceScanner.relativePath(for: standardizedURL, root: matchingRoot)
    guard !relativePath.isEmpty else { return nil }
    return matchingRoot.path + separator + relativePath
  }

  static func relativePaths(for root: URL, from exclusions: Set<String>) -> Set<String> {
    let rootPath = root.standardizedFileURL.path
    return Set(
      exclusions.compactMap { exclusion in
        guard let scoped = split(exclusion) else {
          return exclusion
        }
        return scoped.rootPath == rootPath ? scoped.relativePath : nil
      }
    )
  }

  static func isScoped(_ exclusion: String, to root: URL) -> Bool {
    guard let scoped = split(exclusion) else { return false }
    return scoped.rootPath == root.standardizedFileURL.path
  }

  private static func split(_ exclusion: String) -> (rootPath: String, relativePath: String)? {
    // Root-scoped keys always start with an absolute path. This preserves a legacy relative path
    // that happens to contain `::` instead of misclassifying it as a scoped key.
    guard exclusion.hasPrefix("/"), let range = exclusion.range(of: separator) else {
      return nil
    }
    let rootPath = String(exclusion[..<range.lowerBound])
    let relativePath = String(exclusion[range.upperBound...])
    guard !rootPath.isEmpty, !relativePath.isEmpty else { return nil }
    return (rootPath, relativePath)
  }
}

enum WorkspaceScanner {
  typealias Builder = @Sendable (_ rootURLs: [URL], _ exclusions: Set<String>) -> [WorkspaceScan]

  static let defaultBuilder: Builder = { rootURLs, exclusions in
    build(rootURLs: rootURLs, exclusions: exclusions)
  }

  /// Runtime builder: cancellation may surface only as an empty compatibility value here, but
  /// every production caller checks task cancellation immediately after the call and therefore
  /// never publishes it as a complete scan.
  static let cancellableBuilder: Builder = { rootURLs, exclusions in
    (try? buildCancellable(rootURLs: rootURLs, exclusions: exclusions)) ?? []
  }

  /// Compatibility entry point for synchronous callers and fixture construction. Production
  /// background opens use `buildCancellable`; this wrapper never exposes a partial traversal.
  static func build(rootURLs: [URL], exclusions: Set<String>) -> [WorkspaceScan] {
    (try? build(rootURLs: rootURLs, exclusions: exclusions, cancellationCheck: {})) ?? []
  }

  /// Cooperative scanner used by runtime background work. Cancellation is checked before each
  /// root, directory enumeration, entry classification, and recursive descent. It throws instead
  /// of returning a partial tree, so cancellation can never be mistaken for a complete scan.
  static func buildCancellable(rootURLs: [URL], exclusions: Set<String>) throws -> [WorkspaceScan] {
    try build(
      rootURLs: rootURLs,
      exclusions: exclusions,
      cancellationCheck: { try Task.checkCancellation() }
    )
  }

  private static func build(
    rootURLs: [URL],
    exclusions: Set<String>,
    cancellationCheck: () throws -> Void
  ) throws -> [WorkspaceScan] {
    var scans: [WorkspaceScan] = []
    scans.reserveCapacity(rootURLs.count)
    for rootURL in rootURLs {
      try cancellationCheck()
      let rootExclusions = WorkspaceExclusion.relativePaths(for: rootURL, from: exclusions)
      scans.append(
        try scan(
          folder: rootURL,
          exclusions: rootExclusions,
          cancellationCheck: cancellationCheck
        ))
    }
    return scans
  }

  static let unsupportedOpenMessage =
    "Pensieve can open Markdown or plain text files with .md, .markdown, or .txt extensions."

  static func isMarkdownFile(_ url: URL) -> Bool {
    ["md", "markdown", "txt"].contains(url.pathExtension.lowercased())
  }

  static func normalizedMarkdownFileURL(for url: URL) -> URL {
    let ext = url.pathExtension.lowercased()
    if ext == "md" || ext == "markdown" || ext == "txt" {
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

  private static func scan(
    folder url: URL,
    exclusions: Set<String>,
    cancellationCheck: () throws -> Void
  ) throws -> WorkspaceScan {
    try cancellationCheck()
    let root = url.standardizedFileURL
    var visitedDirectories = Set<String>()
    let scan = try scanChildren(
      folder: root,
      root: root,
      exclusions: exclusions,
      gitIgnoreRules: [],
      visitedDirectories: &visitedDirectories,
      cancellationCheck: cancellationCheck
    )
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
    exclusions: Set<String>,
    gitIgnoreRules inheritedGitIgnoreRules: [GitIgnoreRule],
    visitedDirectories: inout Set<String>,
    cancellationCheck: () throws -> Void
  ) throws -> (documents: [DocumentRef], nodes: [WorkspaceNode]) {
    try cancellationCheck()
    let standardizedDirectory = url.standardizedFileURL
    guard contains(standardizedDirectory, in: root),
      visitedDirectories.insert(standardizedDirectory.path).inserted
    else {
      return ([], [])
    }

    let fm = FileManager.default
    guard let childNames = try? fm.contentsOfDirectory(atPath: url.path) else {
      return ([], [])
    }
    // The URL-based directory API rejects a workspace root that is itself a
    // symlink on current macOS. Enumerate names through the path API, then
    // anchor each child to the logical workspace URL. Entry classification
    // below reads link identity before directory/file target type.
    let urls = childNames.map { url.appendingPathComponent($0) }

    var documents: [DocumentRef] = []
    var nodes: [WorkspaceNode] = []
    let gitIgnoreRules =
      inheritedGitIgnoreRules + loadGitIgnoreRules(folder: url, root: root)
    var entries: [WorkspaceDirectoryEntry] = []
    entries.reserveCapacity(urls.count)
    for childURL in urls {
      try cancellationCheck()
      if let entry = entry(
        for: childURL,
        root: root,
        exclusions: exclusions,
        gitIgnoreRules: gitIgnoreRules
      ) {
        entries.append(entry)
      }
    }
    entries.sort(by: workspaceSort)

    for entry in entries {
      try cancellationCheck()
      if entry.isDirectory {
        let childScan = try scanChildren(
          folder: entry.url,
          root: root,
          exclusions: exclusions,
          gitIgnoreRules: gitIgnoreRules,
          visitedDirectories: &visitedDirectories,
          cancellationCheck: cancellationCheck
        )
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

  private static func entry(
    for url: URL,
    root: URL,
    exclusions: Set<String>,
    gitIgnoreRules: [GitIgnoreRule]
  )
    -> WorkspaceDirectoryEntry?
  {
    let standardizedURL = url.standardizedFileURL
    guard contains(standardizedURL, in: root) else { return nil }

    // Classify the link itself before asking Foundation whether its target is a directory/file.
    // Symlinked folders/files are excluded wholesale: no external targets, no self-cycle edges.
    guard
      let linkValues = try? standardizedURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
      linkValues.isSymbolicLink != true
    else { return nil }

    let values = try? standardizedURL.resourceValues(forKeys: [
      .isDirectoryKey, .isRegularFileKey,
    ])
    let relativePath = relativePath(for: url, root: root)
    let isDirectory = values?.isDirectory == true
    let isRegularFile = values?.isRegularFile == true
    guard
      shouldInclude(
        url,
        relativePath: relativePath,
        isDirectory: isDirectory,
        exclusions: exclusions,
        gitIgnoreRules: gitIgnoreRules
      )
    else {
      return nil
    }

    return WorkspaceDirectoryEntry(
      url: standardizedURL,
      relativePath: relativePath,
      isDirectory: isDirectory,
      isRegularFile: isRegularFile
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

  private static func shouldInclude(
    _ url: URL,
    relativePath: String,
    isDirectory: Bool,
    exclusions: Set<String>,
    gitIgnoreRules: [GitIgnoreRule]
  )
    -> Bool
  {
    let name = url.lastPathComponent
    if name.hasPrefix(".") || WorkspaceDefaults.excludedNames.contains(name) {
      return false
    }
    return !exclusions.contains { excluded in
      relativePath == excluded || relativePath.hasPrefix("\(excluded)/")
    }
      && !isIgnored(
        relativePath: relativePath,
        name: name,
        isDirectory: isDirectory,
        rules: gitIgnoreRules
      )
  }

  private static func loadGitIgnoreRules(folder: URL, root: URL) -> [GitIgnoreRule] {
    let ignoreURL = folder.appendingPathComponent(".gitignore")
    guard let text = try? String(contentsOf: ignoreURL, encoding: .utf8) else { return [] }
    let baseRelativePath = relativePath(for: folder, root: root)
    return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap {
      GitIgnoreRule(line: String($0), baseRelativePath: baseRelativePath)
    }
  }

  private static func isIgnored(
    relativePath: String,
    name: String,
    isDirectory: Bool,
    rules: [GitIgnoreRule]
  ) -> Bool {
    var ignored = false
    for rule in rules
    where rule.matches(relativePath: relativePath, name: name, isDirectory: isDirectory) {
      ignored = !rule.isNegated
    }
    return ignored
  }
}

private struct GitIgnoreRule: Sendable {
  let pattern: String
  let baseRelativePath: String
  let isNegated: Bool
  let isDirectoryOnly: Bool
  let isAnchored: Bool
  let containsSlash: Bool

  init?(line rawLine: String, baseRelativePath: String) {
    var line = rawLine.trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty else { return nil }
    if line.hasPrefix("\\#") {
      line.removeFirst()
    } else if line.hasPrefix("#") {
      return nil
    }

    var isNegated = false
    if line.hasPrefix("!") {
      isNegated = true
      line.removeFirst()
    }
    guard !line.isEmpty else { return nil }

    let isDirectoryOnly = line.hasSuffix("/")
    if isDirectoryOnly {
      line.removeLast()
    }
    let isAnchored = line.hasPrefix("/")
    if isAnchored {
      line.removeFirst()
    }
    guard !line.isEmpty else { return nil }

    self.pattern = line
    self.baseRelativePath = baseRelativePath
    self.isNegated = isNegated
    self.isDirectoryOnly = isDirectoryOnly
    self.isAnchored = isAnchored
    self.containsSlash = line.contains("/")
  }

  func matches(relativePath: String, name: String, isDirectory: Bool) -> Bool {
    if isDirectoryOnly, !isDirectory {
      return false
    }
    guard let candidate = candidatePath(for: relativePath) else {
      return false
    }

    if isAnchored || containsSlash {
      return Self.glob(pattern, matches: candidate)
    }
    return Self.glob(pattern, matches: name)
  }

  private func candidatePath(for relativePath: String) -> String? {
    guard !baseRelativePath.isEmpty else { return relativePath }
    if relativePath == baseRelativePath {
      return ""
    }
    guard relativePath.hasPrefix(baseRelativePath + "/") else {
      return nil
    }
    return String(relativePath.dropFirst(baseRelativePath.count + 1))
  }

  private static func glob(_ pattern: String, matches value: String) -> Bool {
    let regex =
      "^"
      + pattern.reduce(into: "") { result, character in
        switch character {
        case "*":
          result += "[^/]*"
        case "?":
          result += "[^/]"
        case ".", "+", "(", ")", "{", "}", "[", "]", "^", "$", "|", "\\":
          result += "\\\(character)"
        default:
          result.append(character)
        }
      } + "$"
    return value.range(of: regex, options: .regularExpression) != nil
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
  static let shared = DocumentStore(recoveryStore: .shared)
  private let autosaver: Autosaver
  private let indexDatabase: IndexDatabase
  private let bookmarkStore: BookmarkStore
  private let recoveryStore: RecoveryStore
  private let writeDocument: (String, URL) throws -> Void
  private let indexDocument: @MainActor (DocumentRef, String, AppState?) -> Void
  private let dirtyUntitledPrompt: @MainActor (DocumentSession) -> SaveChangesResponse
  private let savePanelURLProvider: @MainActor (AppState) -> URL?
  private var selfWriteObserver: @MainActor (URL) -> Void
  private weak var appState: AppState?

  init(
    autosaver: Autosaver? = nil,
    indexDatabase: IndexDatabase? = nil,
    bookmarkStore: BookmarkStore? = nil,
    recoveryStore: RecoveryStore,
    writeDocument: ((String, URL) throws -> Void)? = nil,
    indexDocument: (@MainActor (DocumentRef, String, AppState?) -> Void)? = nil,
    dirtyUntitledPrompt: (@MainActor (DocumentSession) -> SaveChangesResponse)? = nil,
    savePanelURLProvider: (@MainActor (AppState) -> URL?)? = nil,
    selfWriteObserver: (@MainActor (URL) -> Void)? = nil
  ) {
    let resolvedIndexDatabase = indexDatabase ?? .shared
    self.autosaver = autosaver ?? .shared
    self.indexDatabase = resolvedIndexDatabase
    self.bookmarkStore = bookmarkStore ?? .shared
    self.recoveryStore = recoveryStore
    self.writeDocument =
      writeDocument ?? { text, url in
        try text.write(to: url, atomically: true, encoding: .utf8)
      }
    self.indexDocument =
      indexDocument
      ?? { ref, body, appState in
        // Off-main autosave/save index tail: the single-doc `pool.write` + search refresh used to run
        // synchronously on the main actor on every persisted edit (a per-save SQLite stall). Routing
        // it through the off-main `indexInBackground` twin keeps the file write synchronous while the
        // FTS update commits in the background; tests sync on it via `waitForPendingReindex()`.
        Task {
          await resolvedIndexDatabase.indexInBackground(
            document: ref, body: body, appState: appState)
        }
      }
    self.dirtyUntitledPrompt = dirtyUntitledPrompt ?? Self.promptForDirtyUntitledSession
    self.savePanelURLProvider = savePanelURLProvider ?? Self.promptForSaveURL
    self.selfWriteObserver = selfWriteObserver ?? { _ in }
  }

  func observeSelfWrites(_ observer: @escaping @MainActor (URL) -> Void) {
    selfWriteObserver = observer
  }

  @discardableResult
  func restoreRecoveredDraft(into appState: AppState) -> Bool {
    guard !appState.documentSession.hasEditableBuffer else { return false }
    guard let draft = recoveryStore.claimDraftForRestore() else { return false }

    self.appState = appState
    autosaver.cancel()
    appState.selectedDocumentID = nil
    appState.documentSession.restoreUntitled(
      title: draft.title,
      text: draft.text,
      recoveryID: draft.id
    )
    appState.lastError = nil
    return true
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

  /// What `File > Close` must do with this window's session. Pure — call it
  /// before showing anything, then feed the user's answer to `finishClose`.
  ///
  /// W2-E seam: when the auto-save setting lands it feeds
  /// `autoSavesPathedDocuments` here, and file-backed documents stop asking.
  func closeDecision(appState: AppState) -> DocumentCloseDecision {
    DocumentCloseDecision.resolve(for: appState.documentSession)
  }

  /// Second half of the conscious close: applies the user's answer (`nil` when
  /// `decision` needed no prompt) and clears the session when the answer
  /// allows it. Returns whether the document actually closed — `false` means
  /// the close was cancelled or its save failed, and the session stays exactly
  /// as it was so the user can retry.
  ///
  /// Unlike `savePendingChangesOnClose` (the window/tab teardown guard, which
  /// has no veto point left and therefore persists silently), this path is
  /// allowed to refuse: nothing has been torn down yet.
  @discardableResult
  func finishClose(
    decision: DocumentCloseDecision,
    response: SaveChangesResponse?,
    appState: AppState
  ) -> Bool {
    self.appState = appState

    switch (decision, response) {
    case (.closeWithoutPrompting, _):
      break

    case (.saveWithoutPrompting, _), (.confirm(.savePathed), .save):
      let openSessionID = appState.documentSession.id
      guard saveExisting(appState: appState, indexNow: true) else {
        appState.selectedDocumentID = openSessionID
        return false
      }

    case (.confirm(.saveAsUntitled), .save):
      guard let url = savePanelURLProvider(appState) else { return false }
      guard saveAs(appState: appState, to: url) else { return false }

    case (.confirm(.saveAsUntitled), .discard):
      // "Don't Save" on a draft is a conscious throw-away, so the crash-recovery
      // copy goes with it — leaving it behind would resurrect the very text the
      // user just declined to keep.
      recoveryStore.deleteDraft(id: appState.documentSession.recoveryID)

    case (.confirm(.savePathed), .discard):
      // The buffer is dropped; whatever is already on disk stays as it is.
      break

    case (.confirm, .cancel), (.confirm, nil):
      return false
    }

    // Read the URL AFTER the save branches: a draft that went through
    // "Save As…" only earns its location there, and it is that final location
    // that leaves the working set.
    let closedURL = appState.documentSession.url

    autosaver.cancel()
    appState.selectedDocumentID = nil
    appState.documentSession.clear()
    if let closedURL {
      forgetOpenFile(url: closedURL, appState: appState)
    }
    return true
  }

  /// Drops `url` from the Open Files working set.
  ///
  /// Open Files means "open right now", not "opened at some point": a closed
  /// document leaves the list and comes back only when it is opened again.
  /// Nothing about the file itself changes — it keeps its place in the
  /// workspace tree and can be reopened from there. Idempotent, so every close
  /// route may call it without checking whether some other route got there
  /// first.
  func forgetOpenFile(url: URL, appState: AppState) {
    let standardizedPath = url.standardizedFileURL.path
    appState.openFiles.removeAll { $0.id.standardizedFileURL.path == standardizedPath }
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
    let recoveryID = appState.documentSession.recoveryID

    do {
      try FileManager.default.createDirectory(
        at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try writeDocument(appState.documentSession.text, targetURL)
      selfWriteObserver(targetURL)
      let ref = documentRef(for: targetURL, appState: appState)
      registerSavedDocument(ref, previousID: previousID, appState: appState)
      appState.documentSession.document = ref
      appState.documentSession.isDirty = false
      recoveryStore.deleteDraft(id: recoveryID)
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

  /// Save-on-close guard (app-wide). The autosave write is debounced 1.5s after
  /// the last edit; closing a window/tab inside that window — red close button,
  /// the tab's "×", the sidebar "Close from Open Files", or ⌘W falling through
  /// to a native window close — used to tear the window (and its `AppState`)
  /// down before the scheduled save fired, silently dropping the edit. This
  /// flushes the pending change SYNCHRONOUSLY so the close never races the
  /// debounce. It mirrors the autosave closure exactly — titled buffers write
  /// to disk, untitled buffers persist a recovery draft — but runs NOW and
  /// cancels the still-pending timer. No blocking prompt: the window is already
  /// committed to closing, so there is nothing to cancel. A clean (non-dirty)
  /// buffer is a no-op. Returns whether anything was persisted.
  @discardableResult
  func savePendingChangesOnClose(appState: AppState) -> Bool {
    self.appState = appState
    guard appState.documentSession.hasEditableBuffer,
      appState.documentSession.isDirty
    else {
      return false
    }

    autosaver.cancel()
    if appState.documentSession.isUntitled {
      saveRecoveryDraft(appState: appState)
      return true
    }
    return saveExisting(appState: appState, indexNow: true)
  }

  /// Single-window "settle the dirty session, report whether the user
  /// cancelled" primitive: decides AND immediately applies the dirty-session
  /// guard — force-save a pathed doc, or Save/Discard/Cancel an untitled draft —
  /// without clearing the session, returning `false` only when the untitled
  /// prompt was cancelled. Correct for switching the document within one window,
  /// where there is no later step that could still abort. A multi-window close
  /// that CAN be cancelled late must instead split decide from apply via
  /// `confirmDirtySessionForExternalClose` / `applyDeferredDirtySessionResolution`.
  @discardableResult
  func prepareForDocumentSwitch(appState: AppState) -> Bool {
    self.appState = appState
    return saveDirtySessionIfNeeded(appState: appState)
  }

  private func scheduleAutosave(appState: AppState) {
    guard appState.documentSession.isDirty else {
      return
    }

    autosaver.scheduleSave { [weak self, weak appState] in
      guard let self, let appState else { return }
      if appState.documentSession.isUntitled {
        self.saveRecoveryDraft(appState: appState)
      } else {
        self.saveExisting(appState: appState, indexNow: false)
      }
    }
  }

  private func saveRecoveryDraft(appState: AppState) {
    guard appState.documentSession.isUntitled, appState.documentSession.isDirty else { return }

    do {
      let draft = try recoveryStore.saveDraft(
        id: appState.documentSession.recoveryID,
        title: appState.documentSession.displayTitle,
        text: appState.documentSession.text
      )
      appState.documentSession.recoveryID = draft.id
      appState.lastError = nil
    } catch {
      appState.lastError = "Could not write recovery draft: \(error.localizedDescription)"
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

  /// The user's resolution of a dirty session, split so a multi-window pass can
  /// DECIDE without yet performing the irreversible part.
  enum DirtySessionResolution {
    /// Nothing remains to apply: the session was clean, or a Save / force-save
    /// already wrote its bytes in the decide step. A write is not a loss — the
    /// content is on disk and the buffer lives on — so it stays in decide.
    case settled
    /// The user chose Discard on an untitled draft. The DESTRUCTIVE part —
    /// dropping the recovery draft and marking the buffer clean — is deferred to
    /// `applyDirtySessionResolution`, so a Cancel later in a multi-window pass
    /// leaves the draft recoverable.
    case discardUntitled
  }

  /// Non-destructive DECIDE half of the dirty-session guard. Force-saves a
  /// pathed doc, or prompts Save/Discard/Cancel for an untitled draft, but
  /// performs NO irreversible drop: a Discard is only RECORDED as
  /// `.discardUntitled`. Returns `nil` when the user cancelled (or a forced save
  /// failed). A Save DOES write bytes here — that write is the only step where a
  /// failed I/O can still abort the pass, so it must stay in decide, never move
  /// to apply.
  private func decideDirtySessionResolution(appState: AppState) -> DirtySessionResolution? {
    guard appState.documentSession.isDirty else {
      return .settled
    }

    if appState.documentSession.isUntitled {
      switch dirtyUntitledPrompt(appState.documentSession) {
      case .save:
        guard let url = savePanelURLProvider(appState) else { return nil }
        return saveAs(appState: appState, to: url) ? .settled : nil
      case .discard:
        return .discardUntitled
      case .cancel:
        return nil
      }
    }

    let openSessionID = appState.documentSession.id
    _ = saveExisting(appState: appState, indexNow: true)
    guard !appState.documentSession.isDirty else {
      appState.selectedDocumentID = openSessionID
      return nil
    }
    return .settled
  }

  /// APPLY half: performs the deferred destructive step recorded by decide. Only
  /// `.discardUntitled` carries one — drop the untitled recovery draft and mark
  /// the buffer clean. `.settled` is a no-op.
  private func applyDirtySessionResolution(
    _ resolution: DirtySessionResolution, appState: AppState
  ) {
    switch resolution {
    case .settled:
      break
    case .discardUntitled:
      recoveryStore.deleteDraft(id: appState.documentSession.recoveryID)
      appState.documentSession.isDirty = false
    }
  }

  /// Phase-1 confirm for a multi-window external close ("Clear Open Files").
  /// Runs the non-destructive DECIDE half and hands back the resolution so the
  /// caller can defer the destructive part until every window has confirmed.
  /// Returns `nil` when the user cancelled — the caller must then apply nothing
  /// and close nothing.
  func confirmDirtySessionForExternalClose(appState: AppState) -> DirtySessionResolution? {
    self.appState = appState
    return decideDirtySessionResolution(appState: appState)
  }

  /// Phase-2 apply for a multi-window external close: performs the destructive
  /// step deferred in phase 1. Called only once every window confirmed without a
  /// Cancel, and BEFORE the windows are torn down, so a dropped draft can't
  /// resurrect and a stale `isDirty` can't trip the teardown save hook.
  func applyDeferredDirtySessionResolution(
    _ resolution: DirtySessionResolution, appState: AppState
  ) {
    self.appState = appState
    applyDirtySessionResolution(resolution, appState: appState)
  }

  private func saveDirtySessionIfNeeded(appState: AppState) -> Bool {
    guard let resolution = decideDirtySessionResolution(appState: appState) else {
      return false
    }
    applyDirtySessionResolution(resolution, appState: appState)
    return true
  }

  private func documentRef(for url: URL, appState: AppState) -> DocumentRef {
    let standardizedURL = url.standardizedFileURL
    let standardizedPath = standardizedURL.path
    if let existing = appState.allDocuments.first(where: {
      $0.url.path == standardizedPath
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
      selfWriteObserver(url)
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
    let refPath = ref.id.path
    let isNewSessionURL = previousID?.path != refPath

    if ref.isAdHoc {
      if !appState.openFiles.contains(where: {
        $0.id.path == refPath
      }
      ) {
        appState.openFiles.append(ref)
        pruneOpenFiles(into: appState, protecting: ref.id)
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
      $0.id.path == refPath
    }) {
      appState.documents.append(ref)
    }

    appState.selectedDocumentID = ref.id
  }

  private func pruneOpenFiles(into appState: AppState, protecting protectedID: URL? = nil) {
    pruneOpenFilesWorkingSet(into: appState, protecting: protectedID)
  }

  private static func promptForDirtyUntitledSession(
    _ session: DocumentSession
  ) -> SaveChangesResponse {
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
      .plainText,
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

@MainActor
private func pruneOpenFilesWorkingSet(into appState: AppState, protecting protectedID: URL? = nil) {
  guard appState.openFiles.count > WorkspaceStore.maxOpenFiles else { return }

  let activePath = (protectedID ?? appState.selectedDocumentID)?.path
  var protected: DocumentRef?
  var candidates = appState.openFiles
  if let activePath,
    let index = candidates.firstIndex(where: { $0.id.path == activePath })
  {
    protected = candidates.remove(at: index)
  }

  let allowedCount = WorkspaceStore.maxOpenFiles - (protected == nil ? 0 : 1)
  candidates = Array(candidates.suffix(max(allowedCount, 0)))
  if let protected {
    candidates.append(protected)
  }
  appState.openFiles = candidates
}
