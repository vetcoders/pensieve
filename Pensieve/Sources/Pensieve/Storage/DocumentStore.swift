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
  private let workspaceSubstrate: WorkspaceSubstrate
  /// Shares the substrate's cache store so the persisted `.md` signature lands in the SAME
  /// identity-keyed cache directory (`Workspaces/<workspaceID>/`) as the manifest/fingerprint.
  /// Keeping a single store keeps the signature, manifest, and fingerprint co-located and keyed
  /// identically — critical for the cold-open skip/incremental decision to read its own writes.
  private var cacheStore: WorkspaceCacheStore { workspaceSubstrate.store }
  private let selfWriteSuppressionInterval: TimeInterval
  private let watcherDebounceNanoseconds: UInt64
  private var workspaceBuildTask: Task<Void, Never>?
  private var watcherRefreshTask: Task<Void, Never>?
  /// Tracks the off-main FTS index write launched by `rebuildWorkspace` (incremental delta OR
  /// full fallback). Held so `closeWorkspace` can cancel a still-awaiting update and so callers
  /// can await it. The underlying `pool.write` is a single transaction inside
  /// `IndexDatabase`, so cancelling here only abandons the await — it never half-writes the
  /// index. The actual writes are serialized by `IndexDatabase.pendingIndexUpdateTask`.
  private var indexUpdateTask: Task<Void, Never>?
  private var recentSelfWritePaths: [String: Date] = [:]
  /// Last applied `.md` signature (structured `path -> FileSignature` map). The
  /// baseline the next watcher/refresh diffs against. `nil` means "no baseline"
  /// (cold open, or after `closeWorkspace`) — the next rebuild full-indexes.
  private var lastWorkspaceSignature: WorkspaceSignature?

  init(
    metadataStore: WorkspaceMetadataStore = .shared,
    indexDatabase: IndexDatabase? = nil,
    bookmarkStore: BookmarkStore? = nil,
    workspaceBuilder: WorkspaceScanner.Builder? = nil,
    workspaceSubstrate: WorkspaceSubstrate = .shared,
    selfWriteSuppressionInterval: TimeInterval = 1.2,
    watcherDebounceMilliseconds: UInt64 = 300
  ) {
    self.metadataStore = metadataStore
    self.indexDatabase = indexDatabase ?? .shared
    self.bookmarkStore = bookmarkStore ?? .shared
    self.workspaceBuilder = workspaceBuilder ?? WorkspaceScanner.defaultBuilder
    self.workspaceSubstrate = workspaceSubstrate
    self.selfWriteSuppressionInterval = selfWriteSuppressionInterval
    self.watcherDebounceNanoseconds = watcherDebounceMilliseconds * 1_000_000
  }

  /// Single choke-point for open-flow activity transitions so `PENSIEVE_TRACE=1`
  /// exposes the honest presentation sequence (`open activity=<case>`), and so the
  /// choreography stays auditable in one place. Presentation only — every set-point
  /// keeps its position relative to the skip/fingerprint/identity decisions.
  private func setOpenActivity(_ activity: WorkspaceActivity?, into appState: AppState) {
    DebugTrace.log("open activity=\(activity?.kind.rawValue ?? "nil")")
    appState.workspaceActivity = activity
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

    let standardizedURL = url.standardizedFileURL
    if let ref = appState.allDocuments.first(where: {
      $0.url.standardizedFileURL == url.standardizedFileURL
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
    appState.openFiles.removeAll { $0.id.standardizedFileURL == standardizedURL }
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
  func moveToTrash(url: URL, into appState: AppState) -> Bool {
    let source = url.standardizedFileURL
    appState.lastError = nil
    NSWorkspace.shared.recycle([source]) { [weak self, weak appState] _, error in
      Task { @MainActor in
        guard let self, let appState else { return }
        if let error {
          appState.lastError =
            "Could not move \(source.lastPathComponent) to Trash: \(error.localizedDescription)"
          return
        }
        self.noteSelfWrite(at: source)
        self.removeReferences(for: source, into: appState)
        self.refresh(into: appState)
        appState.lastError = nil
      }
    }
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

    appState.openFiles = appState.openFiles.map { ref in
      ref.url.standardizedFileURL == sourceURL ? appState.makeDocumentRef(for: targetURL) : ref
    }
    if appState.selectedDocumentID?.standardizedFileURL == sourceURL {
      appState.selectedDocumentID = targetURL
      appState.documentSession.document = appState.makeDocumentRef(for: targetURL)
    }
  }

  private func removeReferences(for source: URL, into appState: AppState) {
    let sourceURL = source.standardizedFileURL
    appState.openFiles.removeAll { isSameOrDescendant($0.url, of: sourceURL) }
    if let selected = appState.selectedDocumentID, isSameOrDescendant(selected, of: sourceURL) {
      appState.selectedDocumentID = nil
      appState.documentSession.clear()
    }
  }

  private func isSameOrDescendant(_ url: URL, of ancestor: URL) -> Bool {
    let path = url.standardizedFileURL.path
    let ancestorPath = ancestor.standardizedFileURL.path
    return path == ancestorPath || path.hasPrefix(ancestorPath + "/")
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
  /// so tests can drive `scheduleWatcherRefresh` deterministically instead of sleeping.
  func waitForPendingWatcherRefresh() async {
    await watcherRefreshTask?.value
  }

  /// Awaits the off-main FTS index write launched by the most recent `rebuildWorkspace` so
  /// tests can assert on the index deterministically. This awaits the FolderManager-side
  /// handle; the canonical write-completion sync point is `IndexDatabase.waitForPendingReindex()`
  /// (which both background variants chain on and await internally).
  func waitForPendingIndexUpdate() async {
    await indexUpdateTask?.value
  }

  func noteSelfWrite(at url: URL) {
    recentSelfWritePaths[url.standardizedFileURL.path] = Date()
  }

  /// Synchronous refresh. Computes the `.md` signature on the calling actor (cheap for the
  /// explicit one-shot callers: file create, exclusion edits, tests) and rebuilds when it
  /// differs from the last applied signature. The watcher path does NOT call this directly —
  /// it goes through `scheduleWatcherRefresh` so the expensive scan runs off the main actor
  /// (RC-2).
  func refresh(into appState: AppState, force: Bool = false) {
    guard appState.hasWorkspaceContent else { return }

    let roots = appState.workspaceRoots.map(\.url)
    let exclusions = appState.excludedWorkspacePaths
    let signature = FolderManager.currentWorkspaceSignature(roots: roots, exclusions: exclusions)
    applyRefresh(into: appState, signature: signature, force: force)
  }

  /// Debounced, off-main watcher refresh (RC-2). Coalesces a burst of watcher events into a
  /// single refresh after a short quiet period, then computes the `.md` signature on a
  /// background task (full directory enumeration + per-file stat) so foreign filesystem churn
  /// (Spotlight, a live folder, sibling app writes) never blocks the main actor. Only the
  /// cheap signature comparison and — if it changed — the rebuild hop back to the main actor.
  /// A new event cancels the in-flight debounce/scan, so overlapping scans cannot pile up.
  func scheduleWatcherRefresh(into appState: AppState) {
    watcherRefreshTask?.cancel()
    watcherRefreshTask = Task { [weak self, weak appState, watcherDebounceNanoseconds] in
      try? await Task.sleep(nanoseconds: watcherDebounceNanoseconds)
      guard !Task.isCancelled else { return }
      guard let self, let appState else { return }
      await self.performWatcherRefresh(into: appState)
    }
  }

  /// Body of the debounced watcher refresh. The signature scan runs off the main actor; only
  /// the comparison + rebuild touch `appState` / `lastWorkspaceSignature` on the main
  /// actor. Re-checks `hasWorkspaceContent` after the hop in case the workspace was closed
  /// while the scan was in flight.
  private func performWatcherRefresh(into appState: AppState) async {
    guard appState.hasWorkspaceContent else { return }
    let roots = appState.workspaceRoots.map(\.url)
    let exclusions = appState.excludedWorkspacePaths

    // Step 1 — the `.md` signature scan OFF the main actor (full enumeration + per-file stat).
    let signature = await Task.detached(priority: .utility) {
      FolderManager.currentWorkspaceSignature(roots: roots, exclusions: exclusions)
    }.value
    guard !Task.isCancelled else { return }
    guard appState.hasWorkspaceContent else { return }

    // Step 2 — cheap delta check on the main actor. A non-`.md` change (screenshot, .DS_Store,
    // .git, sibling app writes) leaves the `.md` signature unchanged → skip the rebuild entirely.
    // Only a genuine `.md` change pays for the rebuild scan.
    if let baseline = lastWorkspaceSignature, let signature,
      WorkspaceSignature.delta(from: baseline, to: signature).isEmpty
    {
      return
    }

    // Step 3 — a `.md` file actually changed: enumerate the tree for the rebuild OFF the main
    // actor too, then hop to main only to assign it. Previously `rebuildWorkspace` re-enumerated
    // the whole tree (54k+ files) ON the main actor here — the steady beachball under live churn.
    let workspaceBuilder = workspaceBuilder
    let scans = await Task.detached(priority: .utility) {
      workspaceBuilder(roots, exclusions)
    }.value
    guard !Task.isCancelled else { return }
    guard appState.hasWorkspaceContent else { return }
    applyRefresh(into: appState, signature: signature, scans: scans)
  }

  /// Shared rebuild tail used by both the synchronous `refresh` and the off-main watcher
  /// path. Compares the freshly-computed `.md` signature against the last applied one; when
  /// unchanged it skips the full rebuild + FTS reindex storm. When changed it rebuilds the
  /// in-memory tree and updates the FTS index proportionally to the CHANGE (delta upsert/
  /// delete) when a baseline exists — full reindex only on cold open. Reselects, preserving
  /// dirty-session protection (a dirty active buffer is never clobbered). Must run on the main
  /// actor — it mutates `appState`.
  private func applyRefresh(
    into appState: AppState,
    signature: WorkspaceSignature?,
    force: Bool = false,
    scans: [WorkspaceScan]? = nil
  ) {
    if !force, let signature, let baseline = lastWorkspaceSignature,
      WorkspaceSignature.delta(from: baseline, to: signature).isEmpty
    {
      // The .md tree is unchanged — a non-.md change (screenshot, .DS_Store, sibling
      // app writes) fired the watcher. Skip the full rebuild + FTS reindex storm.
      return
    }

    workspaceBuildTask?.cancel()
    let previousSelection = appState.selectedDocumentID
    rebuildWorkspace(into: appState, signature: signature, precomputedScans: scans)
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

  /// Closes the workspace: cancels any in-flight build, stops the file watcher, clears the
  /// persisted bookmarks and all workspace state, returning to the "No folder open" state.
  /// Protects unsaved work — if the active document has unsaved edits it stays open in the
  /// editor; otherwise the editor is cleared too.
  func closeWorkspace(into appState: AppState) {
    workspaceBuildTask?.cancel()
    watcherRefreshTask?.cancel()
    // Cancel any still-awaiting off-main index update. The underlying single-transaction
    // `pool.write` commits wholly or not at all, so this never leaves the index half-written.
    indexUpdateTask?.cancel()
    watcher.stop()
    bookmarkStore.clear(into: appState)
    // Clearing the baseline means the next open of any workspace cold-starts with a FULL
    // reindex (no stale delta against a foreign workspace's signature).
    lastWorkspaceSignature = nil
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
    _ = commitWorkspaceManifest(
      rootURLs: rootURLs,
      exclusions: appState.excludedWorkspacePaths,
      precomputedFingerprint: coldFingerprint,
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
  /// `rebuildWorkspace` — the watcher/refresh tail that always issues an index write keyed on the
  /// IN-MEMORY baseline — this honors the on-disk baseline so a relaunch with no `.md` changes
  /// SKIPS the reindex entirely. The caller owns the one walk; this never re-walks.
  private func coldRebuildWorkspace(scans: [WorkspaceScan], into appState: AppState) {
    let roots = appState.workspaceRoots.map(\.url)
    let exclusions = appState.excludedWorkspacePaths
    let currentSignature =
      FolderManager.currentWorkspaceSignature(roots: roots, exclusions: exclusions)
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
    let label = workspaceLabel(rootURLs: rootURLs, fileURLs: fileURLs)
    let metadata = metadataStore.load()
    let exclusions = Set(metadata.excludedPaths)
    if attemptHotReopen(rootURLs: rootURLs, exclusions: exclusions, into: appState) {
      return
    }

    // The index is opened OFF the main thread inside `workspaceBuildTask` below (every DB consumer on
    // this path — the skip-gate count, manifest commit, cold index — now opens via the background
    // path). Opening + migrating here on main was a source of the "Scanning…" hang.
    let previousSelection = appState.selectedDocumentID
    prepareWorkspaceShell(rootURLs: rootURLs, fileURLs: fileURLs, into: appState)
    // Honest open state for the WHOLE walk: the skip decision lands only after the walk +
    // fingerprint + DB count below, so claiming "Importing Workspace" here would present
    // every cached open as a full import (the operator's "indeksuje non stop" perception).
    // `.opening` is subtle (sidebar progress, no center takeover); the import claim is
    // made only after the skip-gate genuinely fails.
    setOpenActivity(.opening(label), into: appState)

    let expectedRootPaths = appState.workspaceRoots.map { $0.url.standardizedFileURL.path }
    let expectedOpenFilePaths = appState.openFiles.map { $0.url.standardizedFileURL.path }
    let roots = appState.workspaceRoots.map(\.url)
    let scanExclusions = appState.excludedWorkspacePaths
    let workspaceBuilder = workspaceBuilder
    let scanTask = Task.detached(priority: .userInitiated) {
      workspaceBuilder(roots, scanExclusions)
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

      // Open the index OFF the main thread (coalesced — subsequent DB consumers reuse this pool).
      await self.indexDatabase.openInBackground(into: appState)
      guard !Task.isCancelled else { return }

      // Cold-start skip-gate: a fresh launch hits this background path (empty in-memory tree, so
      // `attemptHotReopen` short-circuited). Before re-committing every document + re-running the
      // FTS reindex + flashing "Indexing N", consult the EXISTING substrate verdict against the
      // persisted `tree-fingerprint.json`. The fingerprint is computed OFF the main actor from
      // the single walk we already have (no second walk), then the main-actor gate decides.
      let liveRoots = appState.workspaceRoots.map(\.url)
      let coldStartFingerprint: TreeFingerprint? =
        await Task.detached(priority: .utility) {
          // Keyed on the FULL root set: N==1 reduces to the legacy v1 hash, N>1 is root-qualified v2.
          try? TreeFingerprint.compute(from: scans, roots: liveRoots)
        }.value
      guard !Task.isCancelled else { return }
      // The empty-index guard reads a COUNT — also off the main thread — before the skip decision.
      // Counts rows across EVERY root so a multi-root workspace passes the invariant-2 guard.
      let coldStartIndexedCount =
        await self.indexDatabase.indexedDocumentCountInBackground(
          forRootPaths: liveRoots.map { $0.standardizedFileURL.path }, appState: appState)
      guard !Task.isCancelled else { return }
      if let coldStartFingerprint,
        self.attemptColdStartValidSkip(
          scans: scans,
          rootURLs: liveRoots,
          exclusions: appState.excludedWorkspacePaths,
          precomputedFingerprint: coldStartFingerprint,
          precomputedIndexedDocumentCount: coldStartIndexedCount,
          into: appState
        )
      {
        // Unchanged workspace: tree already restored from the single walk; no manifest re-commit,
        // no reindex, no "Indexing N". Just select + watch.
        self.selectRestoredDocument(previousSelection: previousSelection, into: appState)
        self.startWatching(urls: appState.workspaceRoots.map(\.url), appState: appState)
        self.setOpenActivity(nil, into: appState)
        return
      }

      DebugTrace.log("cold reindex roots=\(liveRoots.count)")
      // The skip-gate said no: manifest commit + index writes are genuinely ahead — the
      // "Importing Workspace" claim becomes honest exactly here, never during the walk.
      self.setOpenActivity(
        .indexing(documentCount: appState.allDocuments.count), into: appState)
      let workspaceIndexWriteTask = self.commitWorkspaceManifest(
        rootURLs: appState.workspaceRoots.map(\.url),
        exclusions: appState.excludedWorkspacePaths,
        precomputedFingerprint: coldStartFingerprint,
        into: appState
      )
      self.selectRestoredDocument(previousSelection: previousSelection, into: appState)
      self.startWatching(urls: appState.workspaceRoots.map(\.url), appState: appState)
      await workspaceIndexWriteTask?.value
      // Cold open: instead of an UNCONDITIONAL full reindex, consult the PERSISTED `.md`
      // signature + the index-content guard. Compute the current `.md` signature off the main
      // actor first (it doubles as the next watcher baseline whether we skip, delta, or full).
      let currentSignature = await Task.detached(priority: .utility) {
        FolderManager.currentWorkspaceSignature(roots: roots, exclusions: scanExclusions)
      }.value
      guard !Task.isCancelled else { return }
      // Content guard for the cold-index decision, read OFF the main thread (the sync read inside
      // `performColdIndex` would otherwise run on main during "Indexing…").
      let coldRoots = appState.workspaceRoots.map(\.url)
      let coldIndexHasContent =
        await self.indexDatabase.indexedDocumentCountInBackground(
          forRootPaths: coldRoots.map { $0.standardizedFileURL.path }, appState: appState) > 0
      guard !Task.isCancelled else { return }
      let indexTask = self.performColdIndex(
        rootURLs: coldRoots,
        currentSignature: currentSignature,
        precomputedIndexHasContent: coldIndexHasContent,
        into: appState
      )
      self.indexUpdateTask = indexTask
      await indexTask?.value
      guard !Task.isCancelled else { return }
      self.setOpenActivity(nil, into: appState)
    }
  }

  private func attemptHotReopen(
    rootURLs: [URL], exclusions: Set<String>, into appState: AppState
  ) -> Bool {
    let label = workspaceLabel(rootURLs: rootURLs, fileURLs: appState.openFiles.map(\.url))
    setOpenActivity(.checkingCache(label), into: appState)

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
      // Cold-start short-circuit: the substrate was never consulted, so this is NOT a
      // cache miss — the cold path's skip-gate may still validate the cache. Keep the
      // subtle `.checkingCache`; the caller sets `.opening` right after.
      return false
    }

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

  /// Rebuilds the in-memory document tree (always full — it is metadata-only and cheap) and
  /// updates the FTS index. The index update is proportional to the CHANGE: when a previous
  /// `.md` signature baseline exists, only the added/modified files are re-upserted and the
  /// removed files' rows are deleted (delta). A FULL reindex happens ONLY on cold open — when
  /// there is no baseline yet (first open, or after `closeWorkspace` cleared it). After the
  /// rebuild the freshly-computed signature becomes the new baseline.
  ///
  /// `signature` is the pre-computed `.md` signature from the caller (already computed off the
  /// main actor on the watcher path). When `nil` (a callsite that did not pre-compute, or a
  /// stat failure), it is recomputed here so the baseline is never left stale.
  private func rebuildWorkspace(
    into appState: AppState, signature: WorkspaceSignature? = nil,
    precomputedScans: [WorkspaceScan]? = nil
  ) {
    let roots = appState.workspaceRoots.map(\.url)
    let exclusions = appState.excludedWorkspacePaths
    let baseline = lastWorkspaceSignature
    // Reuse an off-main enumeration when the caller already walked the tree (watcher path), so
    // the main actor never re-enumerates a large workspace (54k+ files) just to rebuild it —
    // that on-main re-walk was the steady beachball under live `.md` churn.
    let scans = precomputedScans ?? workspaceBuilder(roots, exclusions)
    applyWorkspaceScans(scans, into: appState)

    let newSignature =
      signature ?? FolderManager.currentWorkspaceSignature(roots: roots, exclusions: exclusions)

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

    lastWorkspaceSignature =
      newSignature
      ?? FolderManager.currentWorkspaceSignature(roots: roots, exclusions: exclusions)
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
  /// `nonisolated static` so the watcher path can run this expensive full-directory
  /// enumeration + per-file `resourceValues` stat OFF the main actor (RC-2). Inputs (`[URL]`,
  /// `Set<String>`) and the `WorkspaceSignature?` result are all `Sendable`, so it crosses the
  /// actor boundary cleanly. Instance callers (the synchronous `refresh`) reach it via the
  /// same static.
  nonisolated static func currentWorkspaceSignature(roots: [URL], exclusions: Set<String>)
    -> WorkspaceSignature?
  {
    guard !roots.isEmpty else { return nil }
    return signature(from: WorkspaceScanner.build(rootURLs: roots, exclusions: exclusions))
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
      try watcher.start(watching: urls) { [weak self, weak appState] in
        Task { @MainActor in
          guard let self, let appState else { return }
          guard !self.shouldSuppressWatcherRefresh(into: appState) else { return }
          // RC-2: coalesce bursts + run the expensive .md scan off the main actor.
          self.scheduleWatcherRefresh(into: appState)
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

  private func shouldSuppressWatcherRefresh(into appState: AppState) -> Bool {
    pruneExpiredSelfWrites()
    guard !recentSelfWritePaths.isEmpty else { return false }

    let workspaceRoots = appState.workspaceRoots.map(\.url)
    return recentSelfWritePaths.keys.contains { path in
      let url = URL(fileURLWithPath: path)
      return workspaceRoots.contains { WorkspaceScanner.contains(url, in: $0) }
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

struct WorkspaceScan: Sendable {
  var documents: [DocumentRef]
  var rootNode: WorkspaceNode
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

enum WorkspaceScanner {
  typealias Builder = @Sendable (_ rootURLs: [URL], _ exclusions: Set<String>) -> [WorkspaceScan]

  static let defaultBuilder: Builder = { rootURLs, exclusions in
    build(rootURLs: rootURLs, exclusions: exclusions)
  }

  static func build(rootURLs: [URL], exclusions: Set<String>) -> [WorkspaceScan] {
    rootURLs.map { scan(folder: $0, exclusions: exclusions) }
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

  private static func scan(folder url: URL, exclusions: Set<String>) -> WorkspaceScan {
    let root = url.standardizedFileURL
    let scan = scanChildren(folder: root, root: root, exclusions: exclusions, gitIgnoreRules: [])
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
    gitIgnoreRules inheritedGitIgnoreRules: [GitIgnoreRule]
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
    let gitIgnoreRules =
      inheritedGitIgnoreRules + loadGitIgnoreRules(folder: url, root: root)
    let entries = urls.compactMap {
      entry(for: $0, root: root, exclusions: exclusions, gitIgnoreRules: gitIgnoreRules)
    }
    .sorted(by: workspaceSort)

    for entry in entries {
      if entry.isDirectory {
        let childScan = scanChildren(
          folder: entry.url,
          root: root,
          exclusions: exclusions,
          gitIgnoreRules: gitIgnoreRules
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
    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
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
      url: url,
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
  enum DirtyUntitledResponse {
    case save
    case discard
    case cancel
  }

  static let shared = DocumentStore()
  private let autosaver: Autosaver
  private let indexDatabase: IndexDatabase
  private let bookmarkStore: BookmarkStore
  private let recoveryStore: RecoveryStore
  private let writeDocument: (String, URL) throws -> Void
  private let indexDocument: @MainActor (DocumentRef, String, AppState?) -> Void
  private let dirtyUntitledPrompt: @MainActor (DocumentSession) -> DirtyUntitledResponse
  private let savePanelURLProvider: @MainActor (AppState) -> URL?
  private var selfWriteObserver: @MainActor (URL) -> Void
  private weak var appState: AppState?

  init(
    autosaver: Autosaver? = nil,
    indexDatabase: IndexDatabase? = nil,
    bookmarkStore: BookmarkStore? = nil,
    recoveryStore: RecoveryStore? = nil,
    writeDocument: ((String, URL) throws -> Void)? = nil,
    indexDocument: (@MainActor (DocumentRef, String, AppState?) -> Void)? = nil,
    dirtyUntitledPrompt: (@MainActor (DocumentSession) -> DirtyUntitledResponse)? = nil,
    savePanelURLProvider: (@MainActor (AppState) -> URL?)? = nil,
    selfWriteObserver: (@MainActor (URL) -> Void)? = nil
  ) {
    let resolvedIndexDatabase = indexDatabase ?? .shared
    self.autosaver = autosaver ?? .shared
    self.indexDatabase = resolvedIndexDatabase
    self.bookmarkStore = bookmarkStore ?? .shared
    self.recoveryStore = recoveryStore ?? .shared
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
    guard let draft = recoveryStore.loadDrafts().first else { return false }

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
        recoveryStore.deleteDraft(id: appState.documentSession.recoveryID)
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
    let isNewSessionURL = previousID?.standardizedFileURL != ref.id.standardizedFileURL

    if ref.isAdHoc {
      if !appState.openFiles.contains(where: {
        $0.id.standardizedFileURL == ref.id.standardizedFileURL
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
      $0.id.standardizedFileURL == ref.id.standardizedFileURL
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

  let activeID =
    protectedID?.standardizedFileURL
    ?? appState.selectedDocumentID?.standardizedFileURL
  var protected: DocumentRef?
  var candidates = appState.openFiles
  if let activeID,
    let index = candidates.firstIndex(where: { $0.id.standardizedFileURL == activeID })
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
