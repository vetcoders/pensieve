import AppKit
import Foundation
import UniformTypeIdentifiers

/// What an open/restore flow knew about a window's selection at the moment it
/// STARTED. Every selection decision at the end of such a flow is made from
/// this snapshot, never from ambient state — the walk in between runs off the
/// main actor and the window keeps living while it does.
@MainActor
struct WorkspaceSelectionContext {
  /// The document this window showed when the flow started; restored by name if
  /// it is still part of the workspace.
  let previousSelection: DocumentRef.ID?
  /// The window's conscious-close counter at start. A different value at the
  /// end means the user closed the document mid-flow.
  let closeGeneration: Int

  static func capture(from appState: AppState) -> WorkspaceSelectionContext {
    WorkspaceSelectionContext(
      previousSelection: appState.selectedDocumentID,
      closeGeneration: appState.windowModel.documentCloseGeneration)
  }

  /// False once the user consciously closed this window's document after the
  /// flow began — restoration must not put it back.
  func survivesConsciousClose(in appState: AppState) -> Bool {
    appState.windowModel.documentCloseGeneration == closeGeneration
  }
}

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
  /// Bumped by every workspace OPEN, and by nothing else — deliberately not `openFlowGeneration`,
  /// which a close bumps too. `scheduleIndexMaintenance` captures it so a close's housekeeping can
  /// answer one question at the moment it matters: "is the index still as quiet as it was when I
  /// was armed?" See `scheduleIndexMaintenance(after:)`.
  ///
  /// Lock-guarded rather than a plain `UInt64` since round 20: the close pass has to ask that
  /// question a SECOND time, at barrier acquisition, from inside a detached closure that has no main
  /// actor to read this from. Same shape and same reason as `IndexDatabase`'s `TerminationLatch`,
  /// with one difference worth naming — a latch is one-way, a generation is not, so this is a
  /// snapshot/compare rather than a flag.
  private let workspaceOpenGeneration = WorkspaceOpenGeneration()
  private var watcherRefreshTask: Task<Void, Never>?
  /// Bumped on every `scheduleWatcherRefresh` so `waitForPendingWatcherRefresh` can tell a
  /// completed refresh from one that was cancel-replaced by a newer event mid-await.
  ///
  /// Readable from outside for the same reason `IndexDatabase.terminationRejectedEntryPoints` is:
  /// `waitForPendingWatcherRefresh()` answers "has the armed refresh finished", and proving that
  /// NOTHING was armed needs the counter itself — there is no task to await.
  private(set) var watcherRefreshGeneration: UInt64 = 0
  /// Single-flight gate for the watcher refresh: set the moment a pass is ARMED and cleared when
  /// that pass (debounce + walk + apply, plus any coalesced follow-up) has finished. While it is
  /// set, `scheduleWatcherRefresh` records the event instead of starting a second pass.
  private var isWatcherRefreshArmed = false
  /// Set by an event that arrives while a pass is armed or running, and consumed by that pass as
  /// "run exactly once more". A flag rather than a counter is the whole point: a burst of N events
  /// buys ONE follow-up walk, not N.
  private var pendingWatcherRescan = false
  /// One-way switch set by `quiesceForTermination()`, and the successor half of the watcher
  /// quiescence. `watcher.stop()` bumps a generation, so an FSEvents batch still on the watcher
  /// queue is discarded — but the generation is checked on that queue, BEFORE the delivery hops to
  /// the main actor (`FileWatcher.start(watching:onEvents:)`). A batch that passed the check and
  /// enqueued its `Task { @MainActor }` a moment before the quit is therefore not retractable by
  /// `stop()`, and cancelling `watcherRefreshTask` does nothing about it either: cancellation
  /// applies to the task that exists, not to the one the hop is about to arm. The quit then pumps
  /// the run loop (`TerminationSequence.runBlockingMainRunLoop()`), which is exactly what gives that
  /// hop the main actor — after quiescence, after the drain, and in time to arm a fresh 300 ms
  /// refresh whose scan would ask the index to write behind the terminal checkpoint.
  ///
  /// Quit-ONLY, deliberately: `closeWorkspace` also stops the watcher and cancels these tasks, but a
  /// close is followed by opens that must start watching again. A latch set there would make the
  /// first workspace switch the last one with a live watcher.
  private var isQuiescedForTermination = false
  /// Explicit refreshes and workspace-configuration changes use their own off-main reconcile
  /// task so a filesystem event cannot cancel a user-requested refresh.
  private var forcedRefreshTask: Task<Void, Never>?
  /// Bumped by every explicit refresh this manager actually ARMS, and readable from outside for the
  /// same reason `watcherRefreshGeneration` is: proving that nothing was armed needs the counter
  /// itself, because a task that was never created leaves no handle to await. Round 19's trash-route
  /// latch is what made that distinguishable — the refusal happens before the task exists, so a test
  /// that watched only the scanner could not tell the arming site's refusal from the task body's.
  private(set) var forcedRefreshGeneration: UInt64 = 0
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

    var isDirectoryObjC: ObjCBool = false
    let sourceExists = FileManager.default.fileExists(
      atPath: source.path, isDirectory: &isDirectoryObjC)
    let sourceIsDirectory = sourceExists && isDirectoryObjC.boolValue

    // Sidebar inline-rename prefills the field with the full filename,
    // extension included. If the user retypes just the base name and drops
    // the extension, silently reinstate it (Finder-style) so the file
    // doesn't fall out of the workspace scanner's markdown filter and
    // appear to have vanished. `URL.pathExtension` alone is not a reliable
    // "did they type an extension?" signal here: a name like "ver 2.5" reports
    // a pathExtension of "5" (a decimal fragment, not an extension). Requiring
    // at least one letter filters those out while still honoring real,
    // explicit extensions ("b.txt") — in doubt, keep the source extension:
    // a visible file beats an invisible one.
    var resolvedName = trimmed
    if !sourceIsDirectory {
      let sourceExtension = source.pathExtension
      let typedExtensionLooksReal = WorkspaceScanner.hasRealExtension(forTypedName: trimmed)
      if !sourceExtension.isEmpty, !typedExtensionLooksReal {
        resolvedName = "\(trimmed).\(sourceExtension)"
      }
    }

    let target =
      source.deletingLastPathComponent()
      .appendingPathComponent(resolvedName)
      .standardizedFileURL
    guard source != target else { return true }
    guard !FileManager.default.fileExists(atPath: target.path) else {
      appState.lastError = "A file or folder named \(resolvedName) already exists."
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

  /// Rebuilds the persisted workspace (roots, tree, sidebar) for a starting
  /// window. It never picks a document for the user — see
  /// `selectRestoredDocument`.
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
    // Folders always sort first; documents and foreign files share the same non-folder
    // bucket and fall through to the name compare together (three kinds now exist, so
    // "differs" alone no longer implies "one of them is a folder").
    if lhs.kind != rhs.kind, lhs.kind == .folder || rhs.kind == .folder {
      return lhs.kind == .folder
    }
    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
  }

  /// Debounced, single-flight, off-main watcher refresh (RC-2). Coalesces a burst of watcher
  /// events into a single refresh after a short quiet period, then builds one presentation +
  /// search snapshot on a background task so foreign filesystem churn never blocks the main actor.
  /// Only the independent signature comparisons and required publications hop back to the main
  /// actor.
  ///
  /// Events arriving while a pass is still in its quiet period are absorbed by that debounce;
  /// events arriving while its walk is already running buy exactly ONE follow-up pass, however
  /// many of them there are. Cancel-and-re-arm — what this used to do — only looked like
  /// coalescing: `cancel()` cannot reach a walk that is already running (see
  /// `cancellableRefreshSnapshot`), so each surviving event batch added a full-tree walk to the
  /// ones already burning a core, and nothing bounded the pile except the event rate. A workspace
  /// whose event source is faster than one walk — an iCloud Drive root materialising placeholders,
  /// a sync client, a build directory — therefore saturated every core while converging on
  /// nothing, since each superseded pass discarded its own result.
  func scheduleWatcherRefresh(into appState: AppState) {
    // The arming site itself, so "no watcher refresh is armed after the quiescence" holds for every
    // caller rather than for the one hop that is known to reach here today. A cancel covers the task
    // that exists; only refusal covers its successor.
    guard !isQuiescedForTermination else { return }
    watcherRefreshGeneration &+= 1
    guard !isWatcherRefreshArmed else {
      pendingWatcherRescan = true
      return
    }
    isWatcherRefreshArmed = true
    watcherRefreshTask?.cancel()
    watcherRefreshTask = Task { [weak self, weak appState, watcherDebounceNanoseconds] in
      try? await Task.sleep(nanoseconds: watcherDebounceNanoseconds)
      guard let self else { return }
      // A cancelled pass drops the request it absorbed, deliberately: every site that cancels this
      // task either runs an authoritative reconcile straight behind it (`scheduleExplicitRefresh`)
      // or is tearing the workspace down (`closeWorkspace`, `quiesceForTermination`).
      defer {
        self.isWatcherRefreshArmed = false
        self.pendingWatcherRescan = false
      }
      guard !Task.isCancelled, let appState else { return }
      await self.runWatcherRefreshPasses(into: appState)
    }
  }

  /// The walk/apply loop of one armed watcher refresh, entered after the first debounce has
  /// elapsed. `pendingWatcherRescan` is cleared BEFORE each walk and re-read after it, which is
  /// exactly what splits "already covered by this pass" from "needs the next one": an event the
  /// walk could have seen is absorbed, an event that arrived after it started gets one more pass —
  /// and that pass is debounced too, so a burst during a walk still costs a single follow-up.
  private func runWatcherRefreshPasses(into appState: AppState) async {
    while true {
      guard !isQuiescedForTermination else { return }
      pendingWatcherRescan = false
      await performWatcherRefresh(into: appState)
      guard !Task.isCancelled, pendingWatcherRescan else { return }
      try? await Task.sleep(nanoseconds: watcherDebounceNanoseconds)
      guard !Task.isCancelled else { return }
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

  /// The arming site of the explicit reconcile, latched against the quit for the same reason
  /// `scheduleWatcherRefresh` is — and, since round 19, for a reason that is not hypothetical.
  ///
  /// `moveToTrash` genuinely SUSPENDS before it gets here: it parks on a `withCheckedContinuation`
  /// around Finder's `recycleItems`, and only the completion brings it back to prune, remove
  /// references, and ask for this refresh. A quit that begins while it is parked therefore has no
  /// `forcedRefreshTask` to cancel — there is none yet — and `runBlockingMainRunLoop()` is precisely
  /// what resumes the continuation. Without this guard the resumed call armed a full replacement scan
  /// whose `applyRefresh` republishes the tree, commits the workspace manifest and asks the index to
  /// write, all after the drain had already taken its snapshots. A cancel covers the task that exists;
  /// only refusal covers its successor.
  ///
  /// Round 17 said this method was out of scope because a queued WATCHER hop cannot reach it. That
  /// remains true and is not what this closes: the trash continuation is a different route in.
  ///
  /// Checked in the task BODY as well, because the arming site can be passed a moment before the latch
  /// closes while the body only starts afterwards — the same "the two halves must not disagree"
  /// property `quiesceForTermination()` documents. Quit-only, so `moveToTrash` outside termination
  /// reconciles exactly as before.
  @discardableResult
  private func scheduleExplicitRefresh(
    into appState: AppState,
    forcePresentation: Bool
  ) -> Task<Void, Never>? {
    guard !isQuiescedForTermination else { return nil }
    guard appState.hasWorkspaceContent else { return nil }
    forcedRefreshGeneration &+= 1
    watcherRefreshTask?.cancel()
    forcedRefreshTask?.cancel()
    let task = Task { [weak self, weak appState] in
      guard let self, let appState, appState.hasWorkspaceContent else { return }
      guard !self.isQuiescedForTermination else { return }
      let roots = appState.workspaceRoots.map(\.url)
      let rootPaths = roots.map { $0.standardizedFileURL.path }
      let exclusions = appState.excludedWorkspacePaths
      let workspaceBuilder = self.workspaceBuilder

      let snapshot = await FolderManager.cancellableRefreshSnapshot(
        roots: roots,
        exclusions: exclusions,
        builder: workspaceBuilder,
        priority: .userInitiated
      )
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

  /// One workspace walk plus every artifact derived from it, run off the main actor in a way that
  /// cancelling the OWNING task can actually stop.
  ///
  /// `Task.detached` inherits nothing — not the actor, not the priority, and not the cancellation.
  /// Detachment is what keeps the walk off the main actor, but it also put the walk out of reach of
  /// the handle callers cancel, so `WorkspaceScanner.buildCancellable`'s `Task.checkCancellation()`
  /// was interrogating a flag nothing could set. A superseded refresh stopped being AWAITED while
  /// its walk kept a core busy to the end. The cancellation handler is what makes the cancel honest;
  /// the walk then returns the empty compatibility value its callers already discard.
  private nonisolated static func cancellableRefreshSnapshot(
    roots: [URL],
    exclusions: Set<String>,
    builder: @escaping WorkspaceScanner.Builder,
    priority: TaskPriority
  ) async -> WorkspaceRefreshSnapshot {
    let walk = Task.detached(priority: priority) {
      FolderManager.refreshSnapshot(
        roots: roots,
        exclusions: exclusions,
        builder: builder
      )
    }
    return await withTaskCancellationHandler {
      await walk.value
    } onCancel: {
      walk.cancel()
    }
  }

  /// Body of the debounced watcher refresh. One injected scanner walk plus both signatures run
  /// off-main; only delta decisions and publication touch main-actor state.
  private func performWatcherRefresh(into appState: AppState) async {
    guard appState.hasWorkspaceContent else { return }
    let roots = appState.workspaceRoots.map(\.url)
    let rootPaths = roots.map { $0.standardizedFileURL.path }
    let exclusions = appState.excludedWorkspacePaths
    let workspaceBuilder = workspaceBuilder

    let snapshot = await FolderManager.cancellableRefreshSnapshot(
      roots: roots,
      exclusions: exclusions,
      builder: workspaceBuilder,
      priority: .utility
    )
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

    // Nothing to re-select: the empty state, never a substitute document. This
    // used to fall back to `documents.first` — the same fallback the restore
    // path carried, with the same two failure modes. A session with nothing
    // open (which, since a launch stopped picking for the user, is what an
    // untouched session looks like) had a document opened FOR it by the next
    // file event that happened to reach the watcher. And a user whose document
    // left the workspace — trashed, or its folder excluded — got a neighbouring
    // file in the editor they had not asked to change; `removeReferences` has
    // already cleared the selection by then, so this branch was free to fill it.
    //
    // The paths that legitimately move a selection never reach here: rename and
    // move re-point `selectedDocumentID` through `replaceReferences` BEFORE
    // scheduling the refresh, so the document is found by the branch above, and
    // create/duplicate select the new document themselves. Nor does opening a
    // different workspace, which is the cold path.
    appState.selectedDocumentID = nil
    appState.activeDocumentURL = nil
    appState.activeDocumentText = ""
    appState.activeDocumentDirty = false
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
      // The close still has ONE index write coming after it — the delete below. Let it skip its own
      // maintenance arming so the two cannot race; this path re-arms maintenance behind the delete.
      closeWorkspace(into: appState, deferringIndexMaintenance: !indexedPaths.isEmpty)
      if !indexedPaths.isEmpty {
        let indexDatabase = indexDatabase
        let deleteTask = Task { [weak appState] in
          _ = await indexDatabase.updateSearchIndexInBackground(
            upserting: [],
            deletingPaths: indexedPaths,
            appState: appState
          )
        }
        indexUpdateTask = deleteTask
        scheduleIndexMaintenance(after: deleteTask)
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

  /// Arms the off-main index housekeeping (WAL truncate + page compaction) that follows a close.
  ///
  /// Compaction is not order-agnostic — it truncates the WAL and hands free pages back, so running
  /// it BEFORE a still-outstanding index write truncates a log that write immediately grows again,
  /// and the resulting frames and free pages then sit there unclaimed: the workspace is gone, so no
  /// further batch checkpoint is coming to notice them.
  ///
  /// Two things can still be owed at that moment, and BOTH are waited for:
  ///
  /// - `pendingIndexWork` — a final write this close's CALLER owns and has not handed to the index
  ///   yet (only `removeRoot`'s last-root delete does this).
  /// - the index's own queue — `closeWorkspace` cancels `indexUpdateTask`, but that handle is only
  ///   the WAIT: the write underneath belongs to `IndexDatabase`'s supersede chain and survives the
  ///   cancellation, and a save's write may not even have joined that chain yet. Ordinary
  ///   `Close Folder` used to arm this task with nothing to await and compacted straight through
  ///   a queue that was still moving.
  ///
  /// Successive passes CHAIN rather than replace. This handle is the only one there is, so a second
  /// close arriving before the first close's pass has finished — reopen a workspace, close it again
  /// — used to drop the older task on the floor: `waitForPendingIndexMaintenance()` then awaited
  /// only the newest one, while the orphan was still draining and could enter its vacuum + truncate
  /// after the terminal checkpoint had started, recreating WAL frames behind the operation meant to
  /// be final. Awaiting the predecessor at the head makes "await the newest" transitively await them
  /// all, and it preserves the compaction-after-writes ordering above for free: a pass cannot
  /// truncate a log the previous pass's write is still growing. Cancelling the orphan instead would
  /// be the wrong half of the cancel/drain distinction — its `barrierWriteWithoutTransaction` is
  /// accepted work, so cancellation would abandon only the wait, not the vacuum.
  ///
  /// …and everything above assumes the pass still lands in the quiet moment it was armed for. It
  /// need not: `Close Folder` followed by `Open Folder` is an ordinary two-second sequence, no open
  /// path cancels or awaits this handle, and the waits at the head of the task (the predecessor, the
  /// caller's final write, the index drain) are exactly where the seconds go. So the `.workspaceClose`
  /// pass — full-freelist `incremental_vacuum`, a possible one-off `VACUUM`, and a truncate under
  /// `barrierWriteWithoutTransaction` — used to run INSIDE the next workspace's opening searches, and
  /// that barrier excludes the pool's reader checkouts (GRDB 6.29.3, measured in round 12). The new
  /// workspace's first search, backlink and count all wait it out.
  ///
  /// The reason is therefore decided at the LAST moment rather than at arm time, and the answer is a
  /// downgrade rather than a cancellation. Cancelling would drop the WAL bound this pass exists to
  /// provide; delaying the open on it is worse still. `.workspaceCloseIntoOpenWorkspace` keeps the
  /// obligation and drops only the exclusion — plain write, fail-fast truncate, backoff ladder — so
  /// the bound is deferred and still enforced while the new workspace reads freely.
  ///
  /// Deciding it in the task (not at arm time) also keeps the quit honest: the LAST close before a
  /// quit is followed by no open at all, so it still takes the barrier and the WAL→0 promise is
  /// unconditional. Nothing legitimate can contradict that during a quit either: `TerminationSequence`
  /// quiesces this manager before it drains, `quiesceForTermination()` stops the watcher and cancels
  /// every refresh/build task, and the open entry points are main-actor calls the quit's pumped run
  /// loop has nothing left to deliver — so no bump can arrive between the decision and the barrier
  /// while the process is closing.
  ///
  /// Rounds 16 and 20, in that order, are why the decision is taken TWICE. Round 16 read the
  /// generation on the main actor immediately before the call and argued no open could slip in,
  /// because `performMaintenanceInBackground` "only suspends once it reaches its detached work". That
  /// covered decision→call and nothing after it: round 12 had already measured that the pass parks
  /// BEFORE `Task.detached { barrier }`, and on the undowngraded path a one-off `VACUUM` conversion —
  /// seconds of whole-file rewrite — runs inside that detached closure before the lock is taken. An
  /// `Open Folder` landing in that gap kept a `.workspaceClose` pass claiming a quiet index it no
  /// longer had. So the exclusion decision is now REVALIDATED at barrier acquisition, from the
  /// detached closure, through a lock-guarded generation the main actor is not needed to read.
  ///
  /// Round 21 closed the last unbounded stretch of that prologue. Between the first revalidation and
  /// the first byte of the `VACUUM` conversion sits the queue for the pool's SERIALIZED WRITER,
  /// which a save or a reindex already in flight can hold for as long as it likes; a workspace
  /// opened during that wait had its own first index writes queued behind a whole-file rewrite. The
  /// conversion now carries the predicate into its write and reads it with the writer in hand.
  ///
  /// Named residual, re-derived: an open that arrives after the pass has already ENTERED its
  /// barrier, or after the conversion's rewrite has BEGUN, is not retracted — neither is abortable.
  /// Those windows are now exactly the barrier's own duration and the rewrite's own duration
  /// (bounded by `IndexDatabase.autoVacuumConversionByteLimit`, measured at roughly 1.3 s at that
  /// ceiling on an SSD, and paid at most once per database), rather than the whole detached
  /// prologue.
  private func scheduleIndexMaintenance(after pendingIndexWork: Task<Void, Never>? = nil) {
    let indexDatabase = indexDatabase
    let previous = indexMaintenanceTask
    // Captured by value, not through `self`: the generation object outlives a deallocated manager and
    // nothing can bump it once the manager is gone, so "deallocated reads as no open" — the old
    // behaviour, and the safe one — now holds by construction instead of by an optional fallback.
    let openGeneration = workspaceOpenGeneration
    let armedAtOpenGeneration = openGeneration.current
    indexMaintenanceTask = Task {
      await previous?.value
      await pendingIndexWork?.value
      await indexDatabase.drainPendingIndexWrites()
      let reopened = openGeneration.hasChanged(since: armedAtOpenGeneration)
      await indexDatabase.performMaintenanceInBackground(
        reason: reopened ? .workspaceCloseIntoOpenWorkspace : .workspaceClose,
        exclusionRemainsWarranted: {
          !openGeneration.hasChanged(since: armedAtOpenGeneration)
        })
    }
  }

  /// Termination command, issued by `TerminationSequence` in the quiescence phase. Stops every
  /// workspace-side producer this manager owns, so the drain that follows waits for a FINITE set of
  /// work instead of chasing a target the watcher keeps moving.
  ///
  /// The watcher goes first and it is the load-bearing half: `FileWatcher.stop()` bumps a
  /// generation, so an FSEvents batch already in flight on the watcher queue is discarded instead of
  /// being debounced into a fresh refresh during the quit's pumped run loop. The primitive already
  /// existed — until now only `closeWorkspace` called it, so a quit left FSEvents live to the last
  /// instruction of the process.
  ///
  /// Deliberately does NOT await the detached scans those four tasks may already be running. Every
  /// one of them re-checks cancellation AND workspace identity after the walk and before it
  /// publishes or writes (`performWatcherRefresh`, `scheduleExplicitRefresh`, the build task's
  /// guards), so a cancelled scan can no longer produce an index write. Awaiting them would put a
  /// full tree walk inside the quit budget and buy nothing.
  func quiesceForTermination() {
    // Set BEFORE the stop, in the same synchronous step and with no suspension point between them:
    // the two halves of the watcher quiescence must not be able to disagree, and a delivery hopping
    // to the main actor between them would find the latch open. See `isQuiescedForTermination`.
    isQuiescedForTermination = true
    watcher.stop()
    watcherRefreshTask?.cancel()
    forcedRefreshTask?.cancel()
    workspaceBuildTask?.cancel()
    workspaceValidationTask?.cancel()
  }

  /// Deterministic sync point for the post-close index housekeeping, and the quit's only handle on
  /// it. Because the maintenance task chains on whatever final index write it was armed behind,
  /// awaiting this also awaits that write — which is exactly the ordering `removeRoot`'s last-root
  /// path depends on. And because each pass chains on its PREDECESSOR
  /// (`scheduleIndexMaintenance(after:)`), awaiting the newest handle transitively awaits every
  /// older pass still in flight: when this returns, no maintenance is outstanding at all, so the
  /// terminal checkpoint that follows it cannot be overtaken by an orphaned vacuum.
  func waitForPendingIndexMaintenance() async {
    await indexMaintenanceTask?.value
  }

  /// The newest armed housekeeping pass, exposed by IDENTITY rather than as a wait.
  ///
  /// `waitForPendingIndexMaintenance()` answers "is anything owed right now"; the quit's stability
  /// drain also has to answer "did anything get armed WHILE I was waiting", and the two are different
  /// questions for the same reason `drainPendingIndexWrites()` tracks its open and its tail by
  /// identity: a pass armed during a wait is work the waiter accepted and has not waited for yet.
  /// Reading the handle lets `TerminationSequence` tell "already awaited" from "moved".
  var pendingIndexMaintenance: Task<Void, Never>? { indexMaintenanceTask }

  /// Closes the workspace: cancels any in-flight build, stops the file watcher, clears the
  /// persisted bookmarks and all workspace state, returning to the "No folder open" state.
  /// Protects unsaved work — if the active document has unsaved edits it stays open in the
  /// editor; otherwise the editor is cleared too.
  ///
  /// - Parameter deferringIndexMaintenance: pass `true` when the CALLER still owns a final index
  ///   write and will re-arm the housekeeping behind it via `scheduleIndexMaintenance(after:)`.
  ///   Only `removeRoot`'s last-root path does this.
  func closeWorkspace(into appState: AppState, deferringIndexMaintenance: Bool = false) {
    workspaceBuildTask?.cancel()
    workspaceValidationTask?.cancel()
    // Take ownership of the activity display so the cancelled build's terminal clear
    // cannot race the direct `workspaceActivity = nil` below.
    openFlowGeneration &+= 1
    watcherRefreshTask?.cancel()
    forcedRefreshTask?.cancel()
    // Cancel any still-awaiting off-main index update. Only the WAIT is abandoned — the write
    // itself belongs to `IndexDatabase`'s supersede chain and still runs — but the underlying
    // single-transaction `pool.write` commits wholly or not at all, so this never leaves the index
    // half-written. The housekeeping armed below waits for that chain; see
    // `scheduleIndexMaintenance(after:)`.
    indexUpdateTask?.cancel()
    workspaceIndexWriteTask?.cancel()
    // Closing a workspace is the quietest moment the index ever gets: no watcher, and whatever
    // writes are still queued are drained before the compaction runs. Bound the WAL and reclaim
    // freed pages here so the storm of a workspace's lifetime does not survive into the next one.
    if !deferringIndexMaintenance {
      scheduleIndexMaintenance()
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
    // Before the hot-reopen short-circuit below, so BOTH open shapes are covered by one bump.
    workspaceOpenGeneration.bump()
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
    let selection = WorkspaceSelectionContext.capture(from: appState)
    prepareWorkspaceShell(rootURLs: rootURLs, fileURLs: fileURLs, into: appState)

    // ONE tree walk for the whole cold open. Build the sidebar from it, then decide skip vs full.
    let roots = appState.workspaceRoots.map(\.url)
    let scanExclusions = appState.excludedWorkspacePaths
    let scans = workspaceBuilder(roots, scanExclusions)
    applyWorkspaceScans(scans, into: appState)

    if attemptColdStartValidSkip(
      scans: scans, rootURLs: rootURLs, exclusions: scanExclusions, into: appState)
    {
      selectRestoredDocument(selection, into: appState)
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
    selectRestoredDocument(selection, into: appState)
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

  /// Whether the PERSISTED `.md` signature still describes the tree the current walk found — the
  /// corroboration a cold-start valid-skip needs on top of the manifest's tree fingerprint.
  ///
  /// Round 21, finding 1. The two cold-start artifacts are written in OPPOSITE orders relative to
  /// the index write they describe, and only one of them is safe to trust alone:
  ///
  /// - the manifest and its tree fingerprint are committed by `commitWorkspaceManifest` BEFORE the
  ///   paired index write is even handed to `scheduleIndexWrite`, so a quit whose budget closes the
  ///   termination latch in between rolls the documents/FTS transaction back and leaves the
  ///   fingerprint on disk describing a tree the index does not hold;
  /// - the `.md` signature is written by `persistSearchSignature` only AFTER its index write
  ///   reported success, which is why a failed or abandoned write simply leaves the previous one in
  ///   place (see `performColdIndex`).
  ///
  /// The skip gate used to ask only for `.valid` plus "the index has ANY rows for this workspace",
  /// and rows left over from the PREVIOUS launch satisfy that. The next cold start then skipped over
  /// its own repair, and because a skip issues no index write and no manifest re-commit, nothing at
  /// startup ever revisited it: on an unchanged tree the stale FTS state survived indefinitely.
  ///
  /// So the gate now asks the persisted signature the same question `performColdIndex` asks before
  /// taking ITS skip — the two decisions were making different demands of the same substrate, and
  /// this gate is the one that suppresses `performColdIndex` entirely. Disagreement, or no persisted
  /// signature at all, is answered `false`: the caller runs the full cold path, which re-derives the
  /// index and persists the signature, so the cost of the conservative answer is one reindex on the
  /// first launch after an abandoned write (or after an upgrade from a pre-signature workspace) and
  /// warm starts from then on. Fail open, never fail skip.
  static func persistedIndexAgreesWithTree(
    persisted: WorkspaceSignature?,
    current: WorkspaceSignature?
  ) -> Bool {
    guard let persisted, let current else { return false }
    return WorkspaceSignature.delta(from: persisted, to: current).isEmpty
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
  ///   matching fingerprint over an empty index must still FULL-reindex, never skip;
  /// - the PERSISTED `.md` signature still describes this walk (round 21, finding 1) — see
  ///   `persistedIndexAgreesWithTree` for why the fingerprint alone cannot answer this.
  ///
  /// On a valid skip it opens the index, restores the in-memory `.md` baseline from the persisted
  /// signature (so the first in-session edit goes INCREMENTAL, not full) and issues NO index write
  /// and NO manifest re-commit. No `.indexing` activity is set: the caller clears
  /// `workspaceActivity` directly.
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

      // Round 21, finding 1: the persisted `.md` signature has to CORROBORATE the fingerprint before
      // this gate may suppress the whole cold path, because the fingerprint is persisted before its
      // index write and the signature only after it. No persisted signature, or one that no longer
      // describes this walk, means the full cold path — which repairs. See
      // `persistedIndexAgreesWithTree`.
      let persistedSignature = cacheStore.readSearchSignature(for: identity)
      guard
        Self.persistedIndexAgreesWithTree(
          persisted: persistedSignature, current: FolderManager.signature(from: scans)),
        let persistedSignature
      else {
        return false
      }

      // Restore the in-memory `.md` baseline so the FIRST in-session edit goes INCREMENTAL. It is
      // the persisted signature by construction now — the guard above refuses the skip without one —
      // and it matches the live index, which is what the `.valid` verdict plus that agreement mean.
      lastWorkspaceSignature = persistedSignature
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
    // The background sibling of the bump in `openResolvedWorkspace` — same reason, and it covers
    // this path's own hot-reopen branch too.
    workspaceOpenGeneration.bump()
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
    let selection = WorkspaceSelectionContext.capture(from: appState)
    prepareWorkspaceShell(rootURLs: rootURLs, fileURLs: fileURLs, into: appState)
    let restoredPresentationCache =
      !isHotReopen
      && restoreCachedWorkspace(
        rootURLs: rootURLs,
        selection: selection,
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
      selectRestoredDocument(selection, into: appState)
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
        self.selectRestoredDocument(selection, into: appState)
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

      // The background sibling of `attemptColdStartValidSkip`'s gate, and it carries the round-21
      // corroboration for the same reason: this branch suppresses the manifest commit AND
      // `performColdIndex` below, so a fingerprint left describing an index write that never
      // committed would be believed here too. The validation job already read both signatures off
      // the one walk it owns, so this costs no scan.
      if cacheIsValid, indexedCount > 0,
        FolderManager.persistedIndexAgreesWithTree(
          persisted: validation.persistedSearchSignature,
          current: validation.currentSearchSignature)
      {
        self.setOpenActivity(.cacheHit(label), into: appState)
        self.lastWorkspaceSignature = validation.searchSignature
        appState.lastError = nil
        DebugTrace.log("coldStartValidSkip taken roots=\(roots.count)")
        self.selectRestoredDocument(selection, into: appState)
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
      self.selectRestoredDocument(selection, into: appState)
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
    // THE CAP APPLIES TO WHAT A LAUNCH INHERITS, not only to what a session
    // grows. The restored set is every bookmark that survived — for an install
    // that predates the paired prune below, that is every ad-hoc file ever
    // opened and not explicitly closed — and the startup restore now opens the
    // working set for real, one tab per ref. Nothing in-session can repair such
    // a key; only the restore can, so the newest `maxOpenFiles` are kept here
    // and the rest lose their bookmarks with their rows.
    pruneOpenFiles(into: appState)
    appState.lastError = nil
  }

  /// Publishes the last committed workspace tree before the validation walk completes. The cache
  /// is identity-keyed by the full standardized root set + bookmark, and the root list is checked
  /// again before use. Fresh scans always replace this state later in the same open flow.
  private func restoreCachedWorkspace(
    rootURLs: [URL],
    selection: WorkspaceSelectionContext,
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
    selectRestoredDocument(selection, into: appState)
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
      // Handed over through `scheduleIndexWrite` rather than a bare `Task` for the same reason the
      // save tail is: these three calls are `IndexDatabase` WRITES, and a bare task is invisible to
      // `drainPendingIndexWrites()`. It is not enough that the close path cancels this task —
      // cancellation abandons the WAIT, not the record build underneath, so a Close Folder or a quit
      // landing mid-manifest used to drain, checkpoint, and only THEN take these writes' frames,
      // recreating the WAL the maintenance had just truncated. One mechanism for every writer.
      let indexDatabase = self.indexDatabase
      return indexDatabase.scheduleIndexWrite {
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

  /// Decides what an open/restore flow puts on screen once its walk lands,
  /// using only what the flow knew when it STARTED (`selection`).
  ///
  /// Re-selects the document this window was already on — and NOTHING else.
  ///
  /// It used to fall back to `documents.first` when there was no previous
  /// selection, which on a launch is always. That is how a file the operator had
  /// not touched in two weeks became the one open document after a launch, with
  /// no bookmark of its own anywhere in the working set: nothing restored it, the
  /// app picked it. `documents.first` is not "the most recent" — the scan sorts
  /// folders before files and each group alphabetically, then walks depth-first,
  /// so it is the first Markdown file inside the alphabetically-first folder
  /// chain.
  ///
  /// An empty session therefore stays empty. What the user left open comes back
  /// through the store that actually records it — the file bookmarks behind Open
  /// Files — and a launch with none shows the launcher, which is what "nothing
  /// was open" looks like.
  ///
  /// Two further guards protect a session the user is responsible for: a dirty
  /// buffer always wins, and a conscious `Close` that happened while this flow
  /// was in flight wins too. The second one closes the race the old code had no
  /// answer for — the validation tail of a workspace opened seconds earlier
  /// would happily re-select the previous document into a window the user had
  /// just emptied, making ⌘W look like it did nothing.
  private func selectRestoredDocument(
    _ selection: WorkspaceSelectionContext,
    into appState: AppState
  ) {
    guard !appState.documentSession.isDirty else { return }
    guard selection.survivesConsciousClose(in: appState) else {
      DebugTrace.log("selectRestoredDocument skipped: document closed while the open flow ran")
      return
    }

    let documents = appState.allDocuments
    if let currentSelection = appState.selectedDocumentID,
      documents.contains(where: { $0.id == currentSelection })
    {
      return
    }

    if let previousSelection = selection.previousSelection,
      let ref = documents.first(where: { $0.id == previousSelection })
    {
      DocumentStore.shared.select(ref: ref, into: appState)
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
          // The hop's own generation check, and the one `FileWatcher` cannot give it: its token is
          // verified on the watcher queue, one line ABOVE this enqueue, so a batch that beat the
          // quit by a moment arrives here with nothing left to stop it. See
          // `isQuiescedForTermination`.
          guard !self.isQuiescedForTermination else { return }
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

  /// The working-set prune, and the bookmark side of it. `persistFile` only ever
  /// grows the key, and before this the only things that shrank it were an
  /// explicit close and the removal of a root — so an eviction here left a
  /// bookmark the next launch would restore into a row the cap had already
  /// rejected.
  private func pruneOpenFiles(into appState: AppState, protecting protectedID: URL? = nil) {
    let evicted = pruneOpenFilesWorkingSet(into: appState, protecting: protectedID)
    guard !evicted.isEmpty else { return }
    bookmarkStore.removeFiles(urls: evicted.map(\.url))
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

/// Deterministic identity of the sidebar's visible universe. Every root, folder, document,
/// and foreign (non-markdown) file contributes its standardized path and semantic kind, so
/// adding/renaming/removing any of them perturbs presentation freshness and triggers a
/// re-render.
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
    isMarkdownExtension(url.pathExtension)
  }

  static func isMarkdownExtension(_ ext: String) -> Bool {
    ["md", "markdown", "txt"].contains(ext.lowercased())
  }

  static func hasRealExtension(forTypedName name: String) -> Bool {
    let ext = URL(fileURLWithPath: name).pathExtension
    return !ext.isEmpty && ext.count <= 5 && ext.allSatisfy(\.isLetter)
  }

  /// Sidebar inline-rename hint: true when the typed name has a real
  /// extension that falls outside the markdown family (md/markdown/txt).
  /// Folders never warn — this only applies to file renames.
  static func warnsAboutLeavingMarkdownFamily(typedName: String, isFolder: Bool) -> Bool {
    guard !isFolder else { return false }
    guard hasRealExtension(forTypedName: typedName) else { return false }
    return !isMarkdownExtension(URL(fileURLWithPath: typedName).pathExtension)
  }

  /// Sidebar inline-rename prefill (Finder-style): a name with a real extension
  /// prefills without it, so retyping the base name and committing doesn't
  /// silently drop the extension. Names with no extension (directories, or
  /// extensionless files) are returned unchanged.
  static func renamePrefill(for url: URL) -> String {
    guard !url.pathExtension.isEmpty else { return url.lastPathComponent }
    return url.deletingPathExtension().lastPathComponent
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
      } else if entry.isRegularFile {
        // Outside the markdown allow-list, but still on disk: surface it as an inert
        // sidebar node instead of silently dropping it (that silence is how a rename
        // that loses its extension used to look like data loss). It never joins
        // `documents`, so FTS indexing, Open Files, and the open-document guards
        // stay untouched.
        nodes.append(
          WorkspaceNode(
            id: "foreign:\(entry.standardizedURL.path)",
            name: entry.url.lastPathComponent,
            kind: .foreignFile,
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
  /// Why a background document read failed, reduced to the message the session
  /// surfaces.
  ///
  /// Its own type rather than the underlying `Error` because this value crosses
  /// an actor hop and `Error` carries no `Sendable` promise; the message is all
  /// the apply ever used anyway.
  struct ReadFailure: Error, Sendable {
    let localizedMessage: String
  }

  /// Reads a document's text away from the main actor.
  ///
  /// Injected — the precedent is `MarkdownTextStorage.scheduleRethemeChunk` —
  /// so a pin can DRIVE a staged open instead of racing a real file read: an
  /// expectation with a fixed timeout wrapped around "the disk is probably done
  /// by now" is a bet on the machine, not a pin. It is also the only way to hold
  /// a load open long enough to prove the stale-apply and teardown guards.
  typealias BackgroundTextReader = @Sendable (URL) async -> Result<String, ReadFailure>

  /// The production read. `nonisolated` is load-bearing, not decoration: it is
  /// what makes awaiting this from the main actor actually leave it.
  nonisolated static func readTextFromFileSystem(at url: URL) async -> Result<String, ReadFailure> {
    do {
      return .success(try String(contentsOf: url, encoding: .utf8))
    } catch {
      return .failure(ReadFailure(localizedMessage: error.localizedDescription))
    }
  }

  static let shared = DocumentStore(recoveryStore: .shared)
  private let autosaver: Autosaver
  private let indexDatabase: IndexDatabase
  private let bookmarkStore: BookmarkStore
  private let recoveryStore: RecoveryStore
  private let savingSettings: DocumentSavingSettings
  private let writeDocument: (String, URL) throws -> Void
  private let indexDocument: @MainActor (DocumentRef, String, AppState?) -> Void
  private let dirtySessionPrompt: @MainActor (DocumentSession) -> SaveChangesResponse
  private let savePanelURLProvider: @MainActor (AppState) -> URL?
  private let backgroundTextReader: BackgroundTextReader
  private var selfWriteObserver: @MainActor (URL) -> Void
  private weak var appState: AppState?

  init(
    autosaver: Autosaver? = nil,
    indexDatabase: IndexDatabase? = nil,
    bookmarkStore: BookmarkStore? = nil,
    recoveryStore: RecoveryStore,
    savingSettings: DocumentSavingSettings? = nil,
    writeDocument: ((String, URL) throws -> Void)? = nil,
    indexDocument: (@MainActor (DocumentRef, String, AppState?) -> Void)? = nil,
    dirtySessionPrompt: (@MainActor (DocumentSession) -> SaveChangesResponse)? = nil,
    savePanelURLProvider: (@MainActor (AppState) -> URL?)? = nil,
    backgroundTextReader: BackgroundTextReader? = nil,
    selfWriteObserver: (@MainActor (URL) -> Void)? = nil
  ) {
    let resolvedIndexDatabase = indexDatabase ?? .shared
    self.autosaver = autosaver ?? .shared
    self.savingSettings = savingSettings ?? .shared
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
        //
        // Handed over through `scheduleIndexWrite` rather than a bare `Task` so the write stays
        // TRACKABLE. A bare task joins the supersede chain several suspensions later, which is
        // invisible to anyone asking "does the index still owe me anything?" — and the quit
        // sequence has to answer exactly that before it checkpoints the WAL.
        resolvedIndexDatabase.scheduleIndexWrite {
          await resolvedIndexDatabase.indexInBackground(
            document: ref, body: body, appState: appState)
        }
      }
    self.dirtySessionPrompt = dirtySessionPrompt ?? Self.promptForDirtySession
    self.savePanelURLProvider = savePanelURLProvider ?? Self.promptForSaveURL
    self.backgroundTextReader = backgroundTextReader ?? Self.readTextFromFileSystem(at:)
    self.selfWriteObserver = selfWriteObserver ?? { _ in }
  }

  func observeSelfWrites(_ observer: @escaping @MainActor (URL) -> Void) {
    selfWriteObserver = observer
  }

  /// The user closed this DOCUMENT — retires it from the WORKING SET a relaunch
  /// restores from, not just from the window that was showing it.
  ///
  /// CONTRACT REVERSAL, operator decision 2026-08-03. Until now closing a
  /// document deliberately did NOT come here: "a window is a view of a file",
  /// so ⌘W and a tab's "×" left the row in place and the next launch brought
  /// the file back; only "Close from Open Files" retired it. The operator's
  /// call is the opposite one — closing a single document explicitly (⌘W /
  /// File ▸ Close, a tab's "×", "Close from Open Files") takes the file out of
  /// the session for good.
  ///
  /// What still does NOT retire, and must not: closing a whole WINDOW, which
  /// takes every tab in it down at once, and every termination teardown — quit,
  /// logout, crash. Those are the paths the next launch is supposed to restore
  /// from; reading them as "the user closed all of these" would quietly empty
  /// the working set behind the user's back.
  ///
  /// Two stores hold that answer and both have to hear it, or whichever one is
  /// missed reseeds the other on the next launch: the in-memory `openFiles`
  /// working set, shared across windows, and the persisted file bookmarks,
  /// which are what a relaunch actually reads.
  func forgetOpenFile(_ url: URL, into appState: AppState) {
    let standardizedURL = url.standardizedFileURL
    appState.openFiles.removeAll { $0.url.standardizedFileURL == standardizedURL }
    bookmarkStore.removeFile(url: standardizedURL)
  }

  // MARK: - Recovered drafts

  /// Every unhandled crash draft, newest first. The launcher's Recovered Drafts
  /// section is the ONLY route from here into a window — nothing adopts a draft
  /// on its own any more.
  ///
  /// A draft another window is already editing is not "unhandled": it is live
  /// work with a window on it, so it drops off every other launcher surface.
  func recoveredDrafts() -> [RecoveryDraft] {
    recoveryStore.unclaimedDrafts()
  }

  /// Adopts `draft` into an EMPTY window as the untitled document it was.
  ///
  /// The draft file stays on disk: it is retired only by a successful save or
  /// an explicit discard, so a window closed again without deciding leaves the
  /// draft exactly where the user can find it. Refuses a window that already
  /// holds a buffer — the section that offers this is only shown in an empty
  /// one, and silently replacing a document would be the very hijack W2-D
  /// removes.
  ///
  /// Refuses a draft ANOTHER window already adopted too. `recoveredDrafts()`
  /// stops offering a claimed draft, but a launcher rendered before the claim
  /// still holds the stale row: adopting it would put two buffers on one
  /// recovery ID, autosaving over each other, with a Save As… in one undone by
  /// the other's next autosave recreating the file. Refusing is a no-op — the
  /// caller refreshes and the stale row disappears.
  ///
  /// Refuses a window in the middle of a STAGED OPEN as well. It has no buffer
  /// yet, but it is not free: it has already claimed the file the user clicked
  /// and is only waiting for the bytes, so adopting a draft into it would drop
  /// that file and then have the background read land on top of the draft.
  @discardableResult
  func openRecoveredDraft(_ draft: RecoveryDraft, into appState: AppState) -> Bool {
    guard !appState.documentSession.hasEditableBuffer,
      !appState.documentSession.isLoading
    else { return false }
    guard !recoveryStore.isDraftOpen(id: draft.id) else { return false }

    self.appState = appState
    cancelOwnDebouncesOnSessionChange(appState: appState)
    appState.selectedDocumentID = nil
    appState.documentSession.restoreUntitled(
      title: draft.title,
      text: draft.text,
      recoveryID: draft.id
    )
    recoveryStore.markDraftOpen(id: draft.id)
    appState.lastError = nil
    return true
  }

  /// Writes `draft` to a location the user picks and retires it. The draft
  /// survives a cancelled panel and a failed write — it is dropped only once
  /// its content is safely somewhere else.
  @discardableResult
  func saveRecoveredDraftAs(_ draft: RecoveryDraft, into appState: AppState) -> Bool {
    self.appState = appState

    guard let url = savePanelURLProvider(appState) else { return false }

    // A draft this window already adopted is just an unsaved document: the
    // ordinary Save As… path owns it (registration, working set, index) and
    // retires the draft on success.
    if appState.documentSession.recoveryID == draft.id {
      return saveAs(appState: appState, to: url)
    }

    let targetURL = WorkspaceScanner.normalizedMarkdownFileURL(for: url)
    do {
      try FileManager.default.createDirectory(
        at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try writeDocument(draft.text, targetURL)
      selfWriteObserver(targetURL)
      indexDocument(documentRef(for: targetURL, appState: appState), draft.text, appState)
      recoveryStore.deleteDraft(id: draft.id)
      appState.lastError = nil
      return true
    } catch {
      let message = "Could not save \(targetURL.lastPathComponent): \(error.localizedDescription)"
      // STATUS, not data loss: the draft file is still on disk — it is
      // retired only on a SUCCESSFUL save — so the work survives this failure.
      appState.lastError = message
      NSLog(message)
      return false
    }
  }

  /// Drops `draft` for good. The caller owns the confirmation.
  func discardRecoveredDraft(_ draft: RecoveryDraft) {
    recoveryStore.deleteDraft(id: draft.id)
  }

  func load(ref: DocumentRef, into appState: AppState) {
    self.appState = appState

    guard saveDirtySessionIfNeeded(appState: appState) else {
      return
    }

    loadClean(ref: ref, into: appState)
  }

  /// Replaces this window's session with `ref`, synchronously for an ordinary
  /// document and in two stages for one past `LargeDocument.sizeBudget`.
  ///
  /// The dirty guard has ALREADY run by the time anything here executes — every
  /// caller (`load`, `select`) passes through `saveDirtySessionIfNeeded` first,
  /// and it is synchronous. That ordering is the contract, not an accident: a
  /// Save/Discard/Cancel prompt has to be answered before the session it is
  /// asking about is replaced, and a staged open that scheduled its read first
  /// would be racing the user's answer with a background write.
  private func loadClean(ref: DocumentRef, into appState: AppState) {
    cancelOwnDebouncesOnSessionChange(appState: appState)

    // Claim the window on BOTH branches. That is what makes an in-flight staged
    // read lose to whatever the user did next, whether the next thing was another
    // large file, a small one, or closing the document.
    let claim = appState.beginDocumentLoad()

    guard LargeDocument.isLargeFile(at: ref.url) else {
      loadSynchronously(ref: ref, into: appState)
      return
    }
    loadInBackground(ref: ref, claim: claim, into: appState)
  }

  /// The path every ordinary document still takes, byte for byte what
  /// `loadClean` did before the size gate existed.
  private func loadSynchronously(ref: DocumentRef, into appState: AppState) {
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

  /// Stage one of a large open, in THIS run-loop turn: the window claims the
  /// file and starts showing an opening placeholder for it. Stage two — the
  /// bytes — arrives from a background read.
  ///
  /// Everything a synchronous open publishes in its own turn is published here
  /// too: `selectedDocumentID` (which the sidebar highlight, the window
  /// registry's document mapping and `PensieveApp.openInitialDocument`'s
  /// resolved-load contract all read) and `documentSession.url` (which
  /// `AppController.noteRecentDocumentIfOpened` reads to decide whether the open
  /// actually landed). The ONLY thing that arrives late is the text.
  private func loadInBackground(ref: DocumentRef, claim: UInt64, into appState: AppState) {
    appState.selectedDocumentID = ref.id
    appState.documentSession.beginLoading(document: ref)
    appState.lastError = nil

    let reader = backgroundTextReader
    let task = Task { @MainActor [weak appState] in
      // `reader` is `nonisolated`, so awaiting it hops off the main actor: the
      // read and the UTF-8 decode of a multi-megabyte file happen there, and only
      // the apply below comes back.
      let result = await reader(ref.url)

      // Three guards in one line, and each of them is a bug this repo has shipped
      // before. `appState == nil`: the window was torn down mid-read, so there is
      // nothing to apply to and nothing to resurrect — the apply mutates session
      // state only, it never creates a window or touches the registry. Claim
      // mismatch: the user opened something else into this window while the read
      // was in flight, and the newer session must win. Both together also cover
      // "closed and reopened the same file", which a URL comparison would not.
      guard let appState, appState.isCurrentDocumentLoad(claim) else { return }

      switch result {
      case .success(let text):
        appState.documentSession.load(document: ref, text: text)
        appState.lastError = nil
      case .failure(let failure):
        // Unlike the synchronous path, there is no previous session left to fall
        // back to — it was released in stage one, which is the price of showing
        // the right file name immediately. So land somewhere honest: an empty
        // window carrying the error, not a placeholder spinning forever.
        appState.documentSession.clear()
        appState.selectedDocumentID = nil
        appState.lastError =
          "Could not load \(ref.url.lastPathComponent): \(failure.localizedMessage)"
      }
      appState.finishDocumentLoad(claim)
    }
    appState.trackPendingDocumentLoad(task)
  }

  @discardableResult
  func select(ref: DocumentRef?, into appState: AppState) -> Bool {
    self.appState = appState

    guard saveDirtySessionIfNeeded(appState: appState) else {
      return false
    }

    guard let ref else {
      cancelOwnDebouncesOnSessionChange(appState: appState)
      // Closing the document is also an answer to "is that staged open still
      // wanted?" — no. Without this the read would land afterwards and reopen
      // the file the user just closed.
      appState.cancelPendingDocumentLoad()
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
  /// The auto-save setting is read HERE, per close, so a flip in Settings
  /// changes the very next ⌘W without a restart: with auto-save on, a
  /// file-backed document flushes and closes (asking would offer a "Don't Save"
  /// that cannot undo the writes already on disk); with it off, every dirty
  /// document asks.
  func closeDecision(appState: AppState) -> DocumentCloseDecision {
    DocumentCloseDecision.resolve(
      for: appState.documentSession,
      autoSavesPathedDocuments: savingSettings.autoSavesPathedDocuments)
  }

  /// What a completed close does to the Open Files working set. Stated by the
  /// caller, because only the caller knows which gesture it serves.
  enum OpenFilesRetirement {
    /// Leave the row alone — the close was a window/teardown, and the next
    /// launch is supposed to bring this file back.
    case keep
    /// Retire the document now: an explicit single-document close
    /// (operator decision 2026-08-03).
    case now
    /// Hand the settled location to `report` and let the caller decide. The
    /// window route needs this: whether its close was one TAB leaving a live
    /// window or the whole window going down is only knowable a runloop turn
    /// later, but the url to retire is only knowable HERE, after the save
    /// branches.
    case deferred(@MainActor (URL) -> Void)
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
  ///
  /// `retiring` states what this close means for the Open Files working set.
  /// Only the CALLER knows which gesture it is serving, so the store never
  /// guesses: see `OpenFilesRetirement`.
  @discardableResult
  func finishClose(
    decision: DocumentCloseDecision,
    response: SaveChangesResponse?,
    appState: AppState,
    retiring: OpenFilesRetirement = .keep
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

    autosaver.cancel()
    // The settled location, read AFTER the save branches: a draft that only
    // earned a path through "Save As…" retires under THAT url, not the nil it
    // arrived with. A cancelled or failed close returned above, so it forgets
    // nothing.
    if let closedURL = appState.documentSession.url {
      switch retiring {
      case .keep:
        break
      case .now:
        forgetOpenFile(closedURL, into: appState)
      case .deferred(let report):
        report(closedURL)
      }
    }
    // Whatever the answer was, no buffer is holding this draft any more, so the
    // launcher may offer it again. (Discard/Save already removed the file
    // outright; this only releases the claim when one survived.)
    recoveryStore.markDraftClosed(id: appState.documentSession.recoveryID)
    appState.selectedDocumentID = nil
    appState.documentSession.clear()
    // The window is now empty BECAUSE the user asked for it. Any workspace
    // walk still in flight captured an older generation and will stand down
    // instead of selecting a document back into this window.
    appState.windowModel.noteConsciousDocumentClose()
    return true
  }

  func save(appState: AppState) {
    _ = saveExisting(appState: appState, indexNow: true)
  }

  @discardableResult
  func saveAs(appState: AppState, to url: URL) -> Bool {
    self.appState = appState
    cancelOwnDebouncesOnSessionChange(appState: appState)

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
      appState.resolveError()
      // Same publication, same exposure: saving AS an existing file makes our bytes that file's
      // content, so a settled window already open on it holds a buffer this write has just made
      // stale. Our own entry is already gone — `cancelOwnDebouncesOnSessionChange` above.
      retireSettledForeignIndexDebounces(for: ref.id, by: appState)
      indexDocument(ref, appState.documentSession.text, appState)
      return true
    } catch {
      let message = "Could not save \(targetURL.lastPathComponent): \(error.localizedDescription)"
      // DATA LOSS: the edit reached no file, so the buffer is the only copy
      // of it and the document on disk is stale.
      appState.reportDataLoss(message)
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
    // The ONE edit funnel, which is why the last-edit marker is stamped here and nowhere else. It is
    // what orders the quit's window flush when two windows hold the SAME file — see
    // `TerminationSequence.flushPendingWindowSaves`.
    appState.noteEdit()
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
  /// buffer is a no-op.
  ///
  /// Returns whether anything was persisted — and that is a REPORT ON THE WRITE,
  /// not on having taken the branch. Both recovery branches used to return `true`
  /// unconditionally: the draft write set `appState.lastError` and told nobody, so
  /// a caller whose buffer survives the flush (`importDocument`) read success over
  /// a draft that does not exist. `false` here means the bytes are in memory and
  /// nowhere else, and `appState.lastError` says why.
  ///
  /// `releasesDraftClaim` is the part of "on close" that is about the WINDOW
  /// rather than the bytes: the buffer dies with it, so the draft this pass just
  /// wrote stops being live work and goes back on the launcher as an unhandled
  /// artifact. A caller whose buffer SURVIVES the flush passes `false` —
  /// `AppController.importDocument` persists the converted draft into a window
  /// that stays on screen, and releasing the claim there advertises a LIVE
  /// buffer's draft on every other launcher surface. Adopting it from one puts
  /// two buffers on a single recovery ID, autosaving over each other, which is
  /// exactly what the claim exists to forbid.
  @discardableResult
  func savePendingChangesOnClose(appState: AppState, releasesDraftClaim: Bool = true) -> Bool {
    self.appState = appState
    // BEFORE the dirty guard, deliberately. A CLEAN session can still be holding a sleeping index
    // debounce: the 1.5 s autosave already wrote the bytes and marked the buffer clean while the
    // 5 s index write was still asleep. The old order returned on the guard without ever reaching
    // the autosaver, so a close (or a quit) inside that window left the FTS row stale with no one
    // owning the repair.
    //
    // FLUSH, not cancel — an armed debounce may belong to a DIFFERENT window than the one closing,
    // and cancelling it there would drop that window's freshness for good on an ad-hoc document (no
    // workspace signature ⇒ no cold-open self-heal).
    //
    // …with ONE exception, which is why this is not an unconditional flush: a debounce whose OWNER is
    // still dirty carries an in-memory edit whose bytes are not on disk yet. Flushing it here submits
    // that text to SQLite BEFORE that owner's file write is even attempted, and no later cancel can
    // retract an already-scheduled database task — so a write that fails (full volume, revoked
    // permissions) would leave FTS advertising content that never reached the disk. The rule is about
    // the OWNER, not about who is closing: a dirty owner's debounce waits for that owner's own
    // successful save; a clean (or vanished) owner's debounce is owed NOW.
    //
    // Round 15 turned that rule from a single-slot decision into a per-owner sweep. It used to be
    // expressible as one disposition because `Autosaver` held at most one debounce and the only
    // question was whose it was; now every window may hold one, so the same classification runs over
    // all of them — clean owners' bodies land here, dirty owners' bodies stay armed, including this
    // session's own, which the `saveExisting(indexNow: true)` below re-issues after its bytes land.
    // See `Autosaver.flushIndexDebouncesWithSettledOwners()`.
    autosaver.flushIndexDebouncesWithSettledOwners()
    guard appState.documentSession.hasEditableBuffer,
      appState.documentSession.isDirty
    else {
      return false
    }

    // Only OUR armed save. The same reasoning as the index debounce above, one debounce over:
    // cancelling a foreign 1.5 s autosave here deletes the write that the sweep above just deferred
    // that window's index debounce to — its bytes would then stay in memory while its index write
    // fires at 5 s over them, which is the FTS-ahead-of-disk ordering this guard exists to forbid,
    // this time in a RUNNING app. Left armed, a foreign save simply fires on its own schedule; ours
    // is redundant because `saveExisting(indexNow: true)` below writes the same bytes now, and
    // cancelling it is what keeps that from becoming a second write.
    cancelArmedSaveIfOwned(by: appState)
    // Cancelling the index debounce is right when it is OURS — `saveExisting(indexNow: true)` below
    // re-issues that write after the bytes land — and wrong when it belongs to another dirty window:
    // dropping it there would be the cancel this whole guard exists to avoid. Deferred means LEFT
    // ARMED, not cancelled; that owner's own close still runs the sweep above, and if its window
    // simply stays open the debounce fires on its own schedule. On quit nothing is stranded either:
    // `TerminationSequence` runs `savePendingChangesOnClose` for EVERY live controller and only then
    // calls `Autosaver.quiesceForTermination()`, which flushes whatever survived. Since round 15 the
    // scoping is structural rather than a comparison: only this session's own entry is reachable
    // through `ownedBy:`, so there is no longer a case in which a foreign entry could be meant.
    cancelArmedIndexIfOwned(by: appState)
    if appState.documentSession.isUntitled {
      let persisted = saveRecoveryDraft(appState: appState)
      // The buffer goes away with the window; the draft it just wrote is a
      // recovery artifact from here on, not live work, so it goes back on the
      // launcher like any other unhandled draft — unless the caller told us the
      // buffer SURVIVES this flush, in which case the write-time claim stands.
      //
      // Released even when the write FAILED, deliberately. The claim is in-memory
      // and the buffer is dying either way; an EARLIER draft of this same session
      // may well be on disk from a successful autosave tick, and holding a claim
      // over it after its buffer is gone strands it — invisible on every launcher
      // for the rest of the process. Releasing offers whatever content survived.
      if releasesDraftClaim {
        recoveryStore.markDraftClosed(id: appState.documentSession.recoveryID)
      }
      return persisted
    }
    // A file-backed buffer. Auto-save owns the file only when it is ON: then the
    // teardown flush keeps that file current, as designed. With auto-save OFF,
    // writing the file here would be exactly the silent write the setting
    // forbids — and this teardown path has no veto point left (a raw
    // `window.close()`, or a SwiftUI-scene close that never reached the
    // shouldClose sheet). Either way — auto-save off, OR an auto-save write that
    // FAILED — the buffer must not die with the window: stash it as a recovery
    // draft and leave the file exactly as it is. Nothing is written behind the
    // user's back, and nothing is lost.
    if savingSettings.autoSavesPathedDocuments,
      saveExisting(appState: appState, indexNow: true)
    {
      return true
    }
    let stashed = stashClosingBufferAsRecoveryDraft(appState: appState)
    if releasesDraftClaim {
      recoveryStore.markDraftClosed(id: appState.documentSession.recoveryID)
    }
    return stashed
  }

  /// The `Autosaver.cancel()` a session change used to call, with the SAVE half narrowed to this
  /// window's own debounce.
  ///
  /// `Autosaver` holds at most ONE armed save, belonging to the LAST edited session — so loading a
  /// different document, clearing the session, restoring a draft or saving under a new name would all
  /// cancel a debounce that may belong to a completely different window. That window's bytes would
  /// then sit in memory with nothing scheduled to write them, while its index debounce (left armed
  /// since round 7 precisely to wait for that save) fires at 5 s over text that is not on disk.
  ///
  /// The INDEX half is narrowed the same way, and for the symmetrical defect. Window B armed both
  /// debounces and window A then switches, clears, restores or saves-as; the ownership check above
  /// preserved B's SAVE, while an unconditional `cancelIndex()` here threw away the index write that
  /// save exists to publish. B's 1.5 s autosave then lands its edited text through
  /// `saveExisting(indexNow: false)` and nothing re-issues the FTS row — and for an AD-HOC document
  /// there is no workspace scan to repair it, so the stale row is permanent.
  ///
  /// Cancel, not flush, for our OWN debounce: every caller here is on its way to replace this
  /// session's document, and the paths that publish text (`saveAs`) index it explicitly afterwards.
  /// A FOREIGN debounce is left ARMED — not flushed — because flushing it would submit another
  /// window's unsaved buffer to SQLite ahead of its file write, which is the ordering
  /// `savePendingChangesOnClose` forbids. Left armed it fires on its own 5 s schedule over bytes its
  /// owner's surviving autosave has by then written, or is deferred again by that owner's own close.
  private func cancelOwnDebouncesOnSessionChange(appState: AppState) {
    cancelArmedSaveIfOwned(by: appState)
    cancelArmedIndexIfOwned(by: appState)
  }

  /// Cancels the armed 5 s index debounce ONLY when it belongs to `appState`'s CURRENT document — the
  /// one this session is about to leave behind. A no-op when nothing is armed, when the session has
  /// no document (an untitled window never owns an index debounce: `scheduleIndex` is only ever
  /// called with one), or when the armed owner is another window's document.
  ///
  /// Identity is the SESSION, since round 15: only this window's own entry is reachable through
  /// `ownedBy:`, so two windows on the same file are no longer indistinguishable — round 8's named
  /// residual, in which one of them could still cancel the other's debounce, is closed. The document
  /// comparison stays, and now means what it says: cancel only the entry armed for the document this
  /// session is leaving behind, never a stale one of our own armed for something else, which nothing
  /// downstream would re-issue.
  private func cancelArmedIndexIfOwned(by appState: AppState) {
    guard let armedDocument = autosaver.armedIndexDocument(ownedBy: appState),
      armedDocument == appState.documentSession.document?.id
    else { return }
    autosaver.cancelIndex(ownedBy: appState)
  }

  /// Retires every OTHER window's armed index debounce over the document `appState` has just written,
  /// for the owners that are SETTLED. Called by the save paths that publish an index row of their own
  /// (`saveExisting(indexNow: true)`, `saveAs`), immediately before they publish it.
  ///
  /// The defect this closes: two windows on one file. Window A edits, its 1.5 s autosave lands A's
  /// bytes and marks A CLEAN, and its 5 s index debounce stays armed — correctly, that debounce is
  /// what publishes A's row. Window B then writes different text to the same file and indexes it now.
  /// `cancelArmedIndexIfOwned` scopes to B's own entry since round 15, so A's survives, and when it
  /// fires it publishes A's session buffer over B's row. B's bytes are the file's final content, so
  /// FTS ends up advertising text that is on nobody's disk, and nothing ever corrects it: A is clean,
  /// and a clean window has no future save.
  ///
  /// That last sentence is exactly where the round 7/15 reservation stops applying. Leaving a foreign
  /// entry armed is right when its owner is DIRTY — its autosave is still owed and will land and
  /// correct FTS — and wrong when its owner is settled, for whom no such correction is ever coming.
  /// So the disposition splits on the owner's LIVE dirtiness, not on whose entry it is.
  ///
  /// Retire means CANCEL. See `Autosaver.retireSettledIndexDebounces(for:except:)` for why flushing
  /// would publish the very body being retired.
  ///
  /// This also restores the invariant `savePendingChangesOnClose`'s settled-owner flush already
  /// assumes — that a settled owner's buffer matches the document on disk. A settled entry could only
  /// go stale by somebody else writing the file, and every in-app write of that file now passes
  /// through here.
  private func retireSettledForeignIndexDebounces(for document: URL, by appState: AppState) {
    autosaver.retireSettledIndexDebounces(for: document, except: appState)
  }

  /// Cancels the armed 1.5 s save debounce ONLY when it belongs to `appState`. A no-op when nothing
  /// is armed, when the debounce belongs to another window, or when its owner is already gone — an
  /// orphaned body captures its session weakly and no-ops when it fires, so there is nothing to
  /// cancel on its behalf.
  private func cancelArmedSaveIfOwned(by appState: AppState) {
    guard autosaver.armedSaveIsOwned(by: appState) else { return }
    autosaver.cancelSave(ownedBy: appState)
  }

  /// Single-window "settle the dirty session, report whether the user
  /// cancelled" primitive: decides AND immediately applies the dirty-session
  /// guard — force-save a pathed doc, or Save/Discard/Cancel an untitled draft —
  /// without clearing the session, returning `false` only when the untitled
  /// prompt was cancelled. Correct for switching the document within one window,
  /// where there is no later step that could still abort. A multi-window pass
  /// that CAN be cancelled late — "Clear Open Files" and ⌘Q — must instead split
  /// decide from apply via
  /// `confirmDirtySessionForExternalClose` / `applyDeferredDirtySessionResolution`.
  @discardableResult
  func prepareForDocumentSwitch(appState: AppState) -> Bool {
    self.appState = appState
    return saveDirtySessionIfNeeded(appState: appState)
  }

  /// Debounced persistence for the live buffer (1.5s after the last edit, the
  /// interval this path has always used — the setting decides WHETHER a
  /// file-backed document is written, it does not introduce a new cadence).
  ///
  /// The auto-save setting is checked when the timer FIRES, not when it is
  /// scheduled: turning auto-save off must also stop the write that was already
  /// pending from the keystroke before the flip, instead of letting one last
  /// edit slip onto disk under the old setting.
  ///
  /// An untitled draft is never gated by the setting — its write target is the
  /// recovery store, not a file the user owns, and crash recovery works the same
  /// in both states.
  private func scheduleAutosave(appState: AppState) {
    guard appState.documentSession.isDirty else {
      return
    }

    // The owner is the session itself, so any other window can tell "this armed save is mine to
    // cancel" from "this one belongs to somebody who is still counting on it". The body captures the
    // same session weakly, so an owner whose window is gone leaves a debounce that owns nothing and
    // writes nothing. See `Autosaver.armedSaveOwner`.
    autosaver.scheduleSave(owner: appState) { [weak self, weak appState] in
      guard let self, let appState else { return }
      if appState.documentSession.isUntitled {
        self.saveRecoveryDraft(appState: appState)
      } else if self.savingSettings.autoSavesPathedDocuments {
        self.saveExisting(appState: appState, indexNow: false)
      }
    }
  }

  /// Returns whether the draft actually reached disk. A failure here is the ONLY
  /// copy of an untitled buffer failing to be written, so it may not be reported
  /// as a success: the caller decides what to do about a buffer that is now live
  /// in memory and nowhere else, and `appState.lastError` carries the reason.
  @discardableResult
  private func saveRecoveryDraft(appState: AppState) -> Bool {
    guard appState.documentSession.isUntitled, appState.documentSession.isDirty else {
      return false
    }

    do {
      let draft = try recoveryStore.saveDraft(
        id: appState.documentSession.recoveryID,
        title: appState.documentSession.displayTitle,
        text: appState.documentSession.text
      )
      appState.documentSession.recoveryID = draft.id
      appState.resolveError()
      return true
    } catch {
      // DATA LOSS: this write IS the durable copy. It failed, so the text exists
      // only in the buffer and dies with the process.
      appState.reportDataLoss(
        "Could not write recovery draft: \(error.localizedDescription)")
      return false
    }
  }

  /// Preserves a dirty FILE-BACKED buffer as a recovery draft when its window is
  /// tearing down without reaching disk — auto-save is off, or an auto-save write
  /// just failed. Unlike `saveRecoveryDraft` (untitled), this never clears
  /// `appState.lastError`: when the stash follows a FAILED save that error must
  /// stay surfaced (a recovery draft AND a visible error), so the user learns the
  /// file on disk is stale rather than believing the close saved it.
  ///
  /// The read-and-write-back of `recoveryID` around the save is what keeps this
  /// buffer on ONE draft. It used to be a pair of no-ops here — `recoveryID`
  /// lived inside `DocumentSession.Kind.untitled`, so a file-backed session read
  /// `nil` and its write-back was swallowed — and every stash of the same file
  /// therefore minted a fresh UUID. Nothing sweeps the recovery directory either
  /// (no age limit, no cap — a draft is retired only by a decision), so a single
  /// unsaved document produced a new draft on every close, without bound.
  ///
  /// Returns whether the stash reached disk, for the same reason
  /// `saveRecoveryDraft` does: this path is reached precisely because the file on
  /// disk is stale, so a failed stash leaves the edit in memory only and must not
  /// be reported as work persisted.
  @discardableResult
  private func stashClosingBufferAsRecoveryDraft(appState: AppState) -> Bool {
    guard appState.documentSession.isDirty else { return false }

    do {
      let draft = try recoveryStore.saveDraft(
        id: appState.documentSession.recoveryID,
        title: appState.documentSession.displayTitle,
        text: appState.documentSession.text
      )
      appState.documentSession.recoveryID = draft.id
      // Deliberately NOT `resolveError()`, unlike the other durable writes. A
      // stash often follows a save that FAILED, and the file the user actually
      // asked to write is still stale — the draft is a backstop, not the
      // outcome they wanted. Retiring the latch here would take "could not save
      // X" off the screen on the strength of a copy they never asked for. It is
      // retired when a real save of that file lands.
      return true
    } catch {
      // DATA LOSS: the file on disk is already stale — that is why this path
      // runs — so the stash was the last chance to put the edit anywhere
      // durable. It failed, and the buffer is about to be torn down.
      appState.reportDataLoss(
        "Could not write recovery draft: \(error.localizedDescription)")
      return false
    }
  }

  private func scheduleIndexUpdate(appState: AppState) {
    guard let armedDocument = appState.documentSession.document else {
      // An UNTITLED session has nothing of its own armed here: `scheduleIndex` is only ever called
      // with a document, and every path that drops a session's document (`loadClean`, `select(nil)`,
      // `restoreRecoveredDraft`) already cancelled this window's debounce on the way. So the only
      // debounce this branch could ever cancel belongs to ANOTHER window — typing in an untitled
      // draft would drop a neighbour's pending index write, which for an ad-hoc document is the
      // permanent loss of searchability the flush-over-cancel rule exists to prevent.
      return
    }

    // The owner is the SESSION — the window — recorded alongside the document the body would write
    // and a LIVE read of that owner's dirtiness, so any close can tell "this debounce would publish
    // text that is not on disk yet" from "this debounce owes an already-saved write" without caring
    // which window is asking. Since round 15 arming here also replaces nothing but this window's own
    // previous entry: a neighbour typing in the same 5 s keeps its debounce, and so does a second
    // window open on the SAME file. Both closures capture the same session weakly, so an owner whose
    // window is gone answers "not dirty" and its orphaned body flushes. See
    // `savePendingChangesOnClose`.
    autosaver.scheduleIndex(
      owner: appState,
      document: armedDocument.id,
      ownerIsDirty: { [weak appState] in
        guard let appState else { return false }
        return appState.documentSession.hasEditableBuffer && appState.documentSession.isDirty
      }
    ) { [weak self, weak appState] in
      guard let self, let appState, let ref = appState.documentSession.document else { return }
      // Deliberately NOT a `retireSettledForeignIndexDebounces` site, unlike the two save paths. The
      // retire is licensed by having just written the file: it cancels a neighbour's row because the
      // row replacing it is built from the bytes now on disk. A debounce publishes an in-memory
      // buffer without writing anything, so it has no such claim — cancelling a neighbour's entry
      // from here would be the plain freshness loss the flush-over-cancel rule forbids.
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
    /// The user chose Don't Save on a FILE-BACKED document while auto-save is
    /// off. The DESTRUCTIVE part — cancelling the pending debounced write and
    /// marking the buffer clean, which lets the in-memory edit go — is deferred
    /// for the same reason as `.discardUntitled`: a Cancel later in a
    /// multi-window pass must leave the edit intact and still dirty. The file on
    /// disk is never touched by this case, in either half.
    case discardPathedEdit
  }

  /// Non-destructive DECIDE half of the dirty-session guard. Prompts
  /// Save/Discard/Cancel for an untitled draft, and — when auto-save is off —
  /// for a file-backed document too; otherwise it force-saves the pathed doc.
  /// It performs NO irreversible drop: a Discard is only RECORDED, as
  /// `.discardUntitled` or `.discardPathedEdit`. Returns `nil` when the user
  /// cancelled (or a forced save failed). A Save DOES write bytes here — that
  /// write is the only step where a failed I/O can still abort the pass, so it
  /// must stay in decide, never move to apply.
  private func decideDirtySessionResolution(appState: AppState) -> DirtySessionResolution? {
    guard appState.documentSession.isDirty else {
      return .settled
    }

    if appState.documentSession.isUntitled {
      switch dirtySessionPrompt(appState.documentSession) {
      case .save:
        guard let url = savePanelURLProvider(appState) else { return nil }
        return saveAs(appState: appState, to: url) ? .settled : nil
      case .discard:
        return .discardUntitled
      case .cancel:
        return nil
      }
    }

    if !savingSettings.autoSavesPathedDocuments {
      switch dirtySessionPrompt(appState.documentSession) {
      case .save:
        // Falls through to the save below — the one write path for this branch.
        break
      case .discard:
        // RECORD ONLY. The buffer is being replaced and whatever is on disk
        // stays as it is, but cancelling the pending debounced write and
        // clearing `isDirty` lets the in-memory edit go — so both wait for the
        // apply half, where a Cancel in a later window can no longer intervene.
        return .discardPathedEdit
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

  /// APPLY half: performs the deferred destructive step recorded by decide.
  /// `.settled` is a no-op; the two Discard cases each drop what makes their
  /// edit recoverable. Neither clears the session, the identity or the buffer —
  /// the caller tears the window down separately.
  private func applyDirtySessionResolution(
    _ resolution: DirtySessionResolution, appState: AppState
  ) {
    switch resolution {
    case .settled:
      break
    case .discardUntitled:
      recoveryStore.deleteDraft(id: appState.documentSession.recoveryID)
      appState.documentSession.isDirty = false
    case .discardPathedEdit:
      // The pending debounced write must not resurrect the dropped edit; the
      // file on disk keeps the bytes it already had. Scoped to THIS window's
      // session — a blanket cancel would also disarm another window's armed
      // save, which is a data-loss path of its own.
      autosaver.cancelSave(ownedBy: appState)
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

  /// Settles the current buffer before something replaces it WITHIN this window:
  /// a document switch or a new document. Single-window path — decide and apply
  /// run back to back, because nothing later in such a pass can still cancel it.
  ///
  /// App termination is deliberately NOT on this path: ⌘Q resolves every window
  /// and a Cancel in the LAST one aborts the quit, so the fused form would have
  /// destroyed an earlier window's draft before the pass could be called off.
  /// That pass runs the split
  /// `confirmDirtySessionForExternalClose` / `applyDeferredDirtySessionResolution`
  /// pair instead, exactly like "Clear Open Files".
  ///
  /// Auto-save decides who owns a file-backed buffer here as well. With auto-save
  /// on, the switch flushes silently — keeping that file current is Pensieve's
  /// job. With it off, the Close rule applies to this lifecycle too: nothing
  /// reaches disk, and nothing is dropped, until the user answers
  /// `Save / Don't Save / Cancel`. Otherwise "auto-save off" would still write
  /// the file the moment the user clicked another document in the sidebar.
  /// An untitled draft asks in both states — it has no file to be saved into.
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
    // This write makes THIS session's armed autosave redundant and nobody else's: an ordinary ⌘S in
    // one window must not delete another window's pending autosave. When this runs as the debounce's
    // own body the autosaver has already disarmed itself, so the call is simply skipped.
    cancelArmedSaveIfOwned(by: appState)

    // Both halves, and the first one is not redundant. A session that has a URL
    // used to be a session that has bytes; a STAGED open breaks that pairing for
    // as long as the read runs — it carries the document so the window can name
    // it, over an empty placeholder buffer. Writing that buffer would truncate
    // the very file being opened. `saveAs` already gates on exactly this
    // predicate; for every pre-existing session shape the two guards are
    // equivalent, because only `.fileBacked` and `.loading` ever carry a URL.
    guard appState.documentSession.hasEditableBuffer,
      let url = appState.documentSession.url
    else { return false }
    let ref = documentRef(for: url, appState: appState)
    // Read BEFORE the write: `documentSession.document` below drops the
    // association, and a successful save is one of the three closed reasons a
    // draft may be retired — the edit it was standing in for is now the file.
    let stashedRecoveryID = appState.documentSession.recoveryID

    do {
      try writeDocument(appState.documentSession.text, url)
      selfWriteObserver(url)
      registerSavedDocument(ref, previousID: appState.documentSession.id, appState: appState)
      // A file-backed buffer whose window tore down with auto-save off left a
      // stash behind (`stashClosingBufferAsRecoveryDraft`). Now that the same
      // bytes are on disk that stash is not recoverable work any more, and
      // leaving it would have the launcher offering content the user already
      // saved — forever, since nothing sweeps drafts.
      recoveryStore.deleteDraft(id: stashedRecoveryID)
      appState.documentSession.document = ref
      appState.documentSession.isDirty = false
      appState.resolveError()
      if indexNow {
        // Only THIS session's debounce, and only when it is armed for the document just written: the
        // write below supersedes it, so leaving it would duplicate the same row. A debounce armed for
        // ANOTHER document is superseded by nothing here, and dropping it is the silent loss of
        // freshness the flush-over-cancel rule forbids — worse, `savePendingChangesOnClose` may have
        // just DEFERRED exactly that debounce to its owner's own save, and an unconditional cancel
        // here undid that deferral the moment the closing window's save succeeded.
        //
        // Round 15 narrowed the same-document case too. A second window open on this file holds its
        // OWN entry now, over its own unsaved buffer; this save publishes our bytes, not theirs, so
        // cancelling their debounce would leave FTS holding our text with nothing scheduled to
        // correct it once their autosave lands.
        cancelArmedIndexIfOwned(by: appState)
        // …and that "once their autosave lands" is a promise only a DIRTY owner keeps. A second
        // window that is already CLEAN owes no further save, so its armed debounce would fire over a
        // session buffer this write has just made stale and leave FTS holding text that is on no
        // disk. Retired here, immediately before we publish the row that supersedes it.
        retireSettledForeignIndexDebounces(for: ref.id, by: appState)
        indexDocument(ref, appState.documentSession.text, appState)
      }
      return true
    } catch {
      let message = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
      // DATA LOSS: the edit reached no file, so the buffer is the only copy
      // of it and the document on disk is stale.
      appState.reportDataLoss(message)
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

  /// Same contract as `FolderManager`'s: whatever the cap drops out of the list
  /// also leaves the persisted set, so the two never disagree about what the
  /// working set is.
  private func pruneOpenFiles(into appState: AppState, protecting protectedID: URL? = nil) {
    let evicted = pruneOpenFilesWorkingSet(into: appState, protecting: protectedID)
    guard !evicted.isEmpty else { return }
    bookmarkStore.removeFiles(urls: evicted.map(\.url))
  }

  /// The switch/termination save question. Asked for a dirty untitled draft in
  /// both auto-save states, and for a dirty file-backed document when auto-save
  /// is off. App-modal on purpose: this is not a per-window close but a buffer
  /// about to be replaced everywhere the caller is heading.
  private static func promptForDirtySession(
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

/// Lock-guarded counter of workspace OPENS, readable from the detached executor a close pass's
/// barrier is taken on. See `FolderManager.scheduleIndexMaintenance(after:)` for why the main-actor
/// `UInt64` it replaced could not serve that read.
///
/// Deliberately NOT a one-way latch like `IndexDatabase.TerminationLatch`, and the difference is the
/// whole reason this is a snapshot/compare: a workspace can open, close and open again, so "has
/// anything happened since?" is the only question with a stable answer. `hasChanged(since:)` is
/// monotone for a fixed snapshot, which is what lets the pass ask it twice and trust the second
/// answer.
private final class WorkspaceOpenGeneration: @unchecked Sendable {
  private let lock = NSLock()
  private var value: UInt64 = 0

  var current: UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func bump() {
    lock.lock()
    value &+= 1
    lock.unlock()
  }

  func hasChanged(since snapshot: UInt64) -> Bool {
    current != snapshot
  }
}

/// Trims the working set to its declared size and RETURNS what it dropped, so
/// the caller can take the evicted files out of the persisted set too. A
/// bookmark with no row is the same invisible state as a row with no window: the
/// next launch resolves it, restores it, and — since the startup restore opens
/// the working set for real — hands the user a tab for a file they stopped using
/// months ago.
@MainActor
private func pruneOpenFilesWorkingSet(into appState: AppState, protecting protectedID: URL? = nil)
  -> [DocumentRef]
{
  guard appState.openFiles.count > WorkspaceStore.maxOpenFiles else { return [] }

  let activePath = (protectedID ?? appState.selectedDocumentID)?.path
  var protected: DocumentRef?
  var candidates = appState.openFiles
  if let activePath,
    let index = candidates.firstIndex(where: { $0.id.path == activePath })
  {
    protected = candidates.remove(at: index)
  }

  let allowedCount = WorkspaceStore.maxOpenFiles - (protected == nil ? 0 : 1)
  let evicted = Array(candidates.dropLast(min(max(allowedCount, 0), candidates.count)))
  candidates = Array(candidates.suffix(max(allowedCount, 0)))
  if let protected {
    candidates.append(protected)
  }
  appState.openFiles = candidates
  return evicted
}
