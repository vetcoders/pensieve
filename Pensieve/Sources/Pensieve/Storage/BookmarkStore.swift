import Foundation

@MainActor
final class BookmarkStore {
  static let shared = BookmarkStore()

  private let defaults: UserDefaults
  private let legacyFolderBookmarkKey = "Pensieve.openFolder.bookmark"
  private let rootBookmarksKey = "Pensieve.workspace.rootBookmarks"
  private let fileBookmarksKey = "Pensieve.workspace.fileBookmarks"
  private let activeDocumentKey = "Pensieve.workspace.activeDocument"
  private var activeAccess: [URL: Bool] = [:]
  private var hasHandedOutActiveDocument = false

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var bookmarkData: Data? {
    rootBookmarkData.first ?? defaults.data(forKey: legacyFolderBookmarkKey)
  }

  func persist(url: URL, into appState: AppState) throws {
    try persistRoot(url: url, into: appState)
  }

  func persistRoot(url: URL, into appState: AppState) throws {
    let data = try url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    var bookmarks = rootBookmarkData
    if !bookmarks.contains(data) {
      bookmarks.append(data)
    }
    defaults.set(bookmarks, forKey: rootBookmarksKey)
    defaults.set(data, forKey: legacyFolderBookmarkKey)
    appState.bookmarkData = data
    activate(url)
  }

  func persistFile(url: URL, into appState: AppState) throws {
    let data = try url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    defaults.set(fileBookmarks(replacingEntryFor: url, with: data), forKey: fileBookmarksKey)
    activate(url)
    appState.lastError = nil
  }

  /// One blob per file. The old guard was `Data` equality, but the bookmark
  /// bytes minted for the SAME file are not stable — reopening a file through
  /// a different (non-standardized) path, or after the volume metadata moves,
  /// yields a byte-different blob the contains-check could not recognise. The
  /// persisted list grew a new entry every time: six copies of one file among
  /// fifteen entries on the operator's install. Identity is the RESOLVED path.
  private func fileBookmarks(replacingEntryFor url: URL, with data: Data) -> [Data] {
    var seenPaths: Set<String> = [url.standardizedFileURL.path]
    var deduplicated = fileBookmarkData.filter { bookmark in
      // Unresolvable today ≠ garbage: an unplugged volume or a file the user
      // will restore must not cost them the bookmark, so keep what cannot be
      // identified rather than pruning it.
      guard let path = resolvedPath(for: bookmark) else { return true }
      return seenPaths.insert(path).inserted
    }
    deduplicated.append(data)
    return deduplicated
  }

  private func resolvedPath(for bookmark: Data) -> String? {
    var bookmarkIsStale = false
    guard
      let url = try? URL(
        resolvingBookmarkData: bookmark,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &bookmarkIsStale
      )
    else { return nil }
    return url.standardizedFileURL.path
  }

  private func uniqueByPath(_ urls: [URL]) -> [URL] {
    var seenPaths: Set<String> = []
    return urls.filter { seenPaths.insert($0.standardizedFileURL.path).inserted }
  }

  /// Replaces the complete persisted workspace only after every new bookmark has been created.
  /// This preserves the previous relaunch state if one of the requested URLs cannot produce a
  /// security-scoped bookmark; callers can still update their live in-memory workspace and surface
  /// the persistence failure without erasing otherwise valid roots.
  func replaceWorkspace(rootURLs: [URL], fileURLs: [URL], into appState: AppState) throws {
    let roots = try uniqueByPath(rootURLs).map { url in
      (
        url.standardizedFileURL,
        try url.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
      )
    }
    let files = try uniqueByPath(fileURLs).map { url in
      (
        url.standardizedFileURL,
        try url.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
      )
    }

    stopAllAccess()
    defaults.set(roots.map(\.1), forKey: rootBookmarksKey)
    defaults.set(files.map(\.1), forKey: fileBookmarksKey)
    if let firstRoot = roots.first?.1 {
      defaults.set(firstRoot, forKey: legacyFolderBookmarkKey)
    } else {
      defaults.removeObject(forKey: legacyFolderBookmarkKey)
    }
    appState.bookmarkData = roots.first?.1
    for root in roots { activate(root.0) }
    for file in files { activate(file.0) }
    appState.lastError = nil
  }

  func restore(into appState: AppState) -> URL? {
    guard let data = bookmarkData else {
      appState.bookmarkData = nil
      return nil
    }

    appState.bookmarkData = data
    var bookmarkIsStale = false

    do {
      let url = try URL(
        resolvingBookmarkData: data,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &bookmarkIsStale
      )

      guard isExistingDirectory(url) else {
        clear(
          into: appState, error: "Saved folder bookmark no longer points to an existing folder.")
        return nil
      }

      activate(url)

      if bookmarkIsStale {
        try persist(url: url, into: appState)
      }

      return url
    } catch {
      clear(into: appState, error: "Could not restore saved folder: \(error.localizedDescription)")
      return nil
    }
  }

  func restoreWorkspace(into appState: AppState) -> RestoredWorkspaceBookmarks {
    let roots =
      rootBookmarkData.isEmpty
      ? defaults.data(forKey: legacyFolderBookmarkKey).map { [$0] } ?? []
      : rootBookmarkData
    let files = fileBookmarkData
    // Persisted-blob counts BEFORE resolution — distinguishes "no saved workspace"
    // from "saved bookmarks failed to resolve" when tracing startup restores.
    DebugTrace.log("open bookmarks persisted roots=\(roots.count) files=\(files.count)")

    appState.bookmarkData = roots.first

    let rootURLs = restoreURLs(
      from: roots,
      expectedKind: .directory,
      deduplicatingInto: rootBookmarksKey,
      staleHandler: { [weak self] url, appState in
        try self?.persistRoot(url: url, into: appState)
      },
      into: appState
    )
    let fileURLs = restoreURLs(
      from: files,
      expectedKind: .file,
      deduplicatingInto: fileBookmarksKey,
      staleHandler: { [weak self] url, appState in
        try self?.persistFile(url: url, into: appState)
      },
      into: appState
    )

    return RestoredWorkspaceBookmarks(rootURLs: rootURLs, fileURLs: fileURLs)
  }

  /// Records the document the user is on so the next launch reopens it. Only a
  /// path is stored: reading it back needs no scope of its own — the file is
  /// either inside a restored root or already carries its own file bookmark,
  /// and minting a second bookmark per launch would grow `fileBookmarks`
  /// without bound.
  /// Writes only when the ACTIVE DOCUMENT'S IDENTITY changes: every window
  /// activation and every load funnels through here, so an unconditional
  /// `defaults.set` would rewrite the same path on churn the user never caused.
  func persistActiveDocument(url: URL?) {
    let path = url?.standardizedFileURL.path
    guard path != persistedActiveDocumentPath else { return }
    guard let path else {
      defaults.removeObject(forKey: activeDocumentKey)
      return
    }
    defaults.set(path, forKey: activeDocumentKey)
  }

  /// Forgets the restore record when it names `url` — the document the user
  /// just closed must not come back on the next launch. Conditional because
  /// Open Files/tab closes cross windows: another window's document may
  /// already own the record, and clearing it would strand that window.
  func clearActiveDocument(ifMatching url: URL) {
    guard persistedActiveDocumentPath == url.standardizedFileURL.path else { return }
    defaults.removeObject(forKey: activeDocumentKey)
  }

  /// Follows the active document through a Save As: the record is a path, so
  /// leaving it on the pre-save URL would restore a file the user renamed away
  /// from (or nothing at all, once the old path is gone).
  func repointActiveDocument(from previousURL: URL?, to newURL: URL) {
    guard let previousURL,
      persistedActiveDocumentPath == previousURL.standardizedFileURL.path
    else { return }
    defaults.set(newURL.standardizedFileURL.path, forKey: activeDocumentKey)
  }

  private var persistedActiveDocumentPath: String? {
    defaults.string(forKey: activeDocumentKey)
  }

  /// Hands the previous session's active document to the FIRST restoring
  /// window, at most once per launch — the same single-handout discipline
  /// `RecoveryStore.claimDraftForRestore` uses. Without it every restoring
  /// window would reopen the same document, and the pending crash draft would
  /// have no window left to come back in.
  ///
  /// CONSUMES the record, because a claim is a hand-off and not a standing
  /// instruction. The in-process latch alone made the key immortal: once a
  /// document had been active, every later launch claimed the same path, so a
  /// file that got in there by accident (see `selectRestoredDocument`) came back
  /// forever and no amount of closing it helped — the close only clears the
  /// record when that document still owns it, and the app is quite capable of
  /// rewriting it in between.
  ///
  /// Consuming costs the live session nothing: `loadClean` re-publishes the
  /// document the moment the restored window shows it, and every key activation
  /// re-publishes it again, so a quit with that document frontmost restores it
  /// on the next launch exactly as before. Only a launch that opens NOTHING
  /// leaves the record empty — which is the honest answer to "nothing was open".
  ///
  /// A record naming a file that is gone from disk is dropped too: it can never
  /// restore anything, and leaving it would keep it in the way of the next one.
  func claimActiveDocumentForRestore() -> URL? {
    guard !hasHandedOutActiveDocument else { return nil }
    hasHandedOutActiveDocument = true
    guard let path = defaults.string(forKey: activeDocumentKey) else { return nil }
    defaults.removeObject(forKey: activeDocumentKey)
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard isExistingFile(url) else { return nil }
    return url
  }

  /// Drops ONE file's bookmark, because the user closed that file out of Open
  /// Files. Without it a close is only ever a close of the WINDOW: the working
  /// set the next launch restores from still names the file, so it comes back —
  /// and comes back on every launch after that, since nothing else ever prunes
  /// this key.
  ///
  /// Identity is the RESOLVED path — the same identity the dedup below writes
  /// under — so a file bookmarked through a different path spelling is still
  /// recognised as the one being closed.
  ///
  /// The "unresolvable ≠ garbage" rule from that method holds here in the
  /// opposite direction and matters more: an entry we cannot resolve today (an
  /// unplugged volume) is KEPT, because failing to identify a bookmark must
  /// never be a reason to silently forget a file the user did not close.
  func removeFile(url: URL) {
    let target = url.standardizedFileURL.path
    let remaining = fileBookmarkData.filter { bookmark in
      guard let path = resolvedPath(for: bookmark) else { return true }
      return path != target
    }
    defaults.set(remaining, forKey: fileBookmarksKey)
    stopAccess(to: url.standardizedFileURL)
  }

  func clear(into appState: AppState, error: String? = nil) {
    stopAllAccess()
    defaults.removeObject(forKey: legacyFolderBookmarkKey)
    defaults.removeObject(forKey: rootBookmarksKey)
    defaults.removeObject(forKey: fileBookmarksKey)
    defaults.removeObject(forKey: activeDocumentKey)
    appState.bookmarkData = nil
    if let error {
      appState.lastError = error
    }
  }

  private func activate(_ url: URL) {
    if activeAccess[url] != nil {
      return
    }

    activeAccess[url] = url.startAccessingSecurityScopedResource()
  }

  /// Releases the security-scoped access this store took for one file. Keyed by
  /// the URL `activate` recorded, so a spelling that never granted access is a
  /// no-op rather than an unbalanced stop.
  private func stopAccess(to url: URL) {
    guard let accessWasGranted = activeAccess.removeValue(forKey: url) else { return }
    if accessWasGranted {
      url.stopAccessingSecurityScopedResource()
    }
  }

  private func stopAllAccess() {
    for (url, accessWasGranted) in activeAccess where accessWasGranted {
      url.stopAccessingSecurityScopedResource()
    }
    activeAccess.removeAll()
  }

  private func isExistingDirectory(_ url: URL) -> Bool {
    var isDirectory = ObjCBool(false)
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }

  private func isExistingFile(_ url: URL) -> Bool {
    var isDirectory = ObjCBool(false)
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && !isDirectory.boolValue
  }

  private var rootBookmarkData: [Data] {
    defaults.array(forKey: rootBookmarksKey) as? [Data] ?? []
  }

  private var fileBookmarkData: [Data] {
    defaults.array(forKey: fileBookmarksKey) as? [Data] ?? []
  }

  private enum ExpectedKind {
    case directory
    case file
  }

  /// Resolves a saved list AND heals it: installs polluted by the old
  /// byte-equality guard carry several blobs for one file, and every launch
  /// resolved each of them. The surviving blob per path is written back under
  /// `key`, so the list shrinks to the truth once instead of being re-read
  /// forever. Entries that fail to resolve are kept untouched — unreachable is
  /// not the same as bogus.
  private func restoreURLs(
    from bookmarks: [Data],
    expectedKind: ExpectedKind,
    deduplicatingInto key: String,
    staleHandler: (URL, AppState) throws -> Void,
    into appState: AppState
  ) -> [URL] {
    var urls: [URL] = []
    var keptBookmarks: [Data] = []
    var seenPaths: Set<String> = []
    // A stale bookmark makes the stale handler mint a REPLACEMENT blob into the
    // very key this pass would rewrite. Leave the list alone in that case
    // rather than clobbering the refreshed entry with the one it replaced; the
    // next launch deduplicates on a settled list.
    var didRefreshStaleBookmark = false

    for data in bookmarks {
      var bookmarkIsStale = false
      do {
        let url = try URL(
          resolvingBookmarkData: data,
          options: [.withSecurityScope],
          relativeTo: nil,
          bookmarkDataIsStale: &bookmarkIsStale
        )

        let exists =
          expectedKind == .directory
          ? isExistingDirectory(url)
          : isExistingFile(url)
        guard exists else {
          // Resolvable but gone from disk: out of the live workspace, still
          // kept on record. Pruning it is a separate decision from removing a
          // duplicate of a file that IS there.
          keptBookmarks.append(data)
          continue
        }
        guard seenPaths.insert(url.standardizedFileURL.path).inserted else {
          continue
        }

        activate(url)

        if bookmarkIsStale {
          didRefreshStaleBookmark = true
          try staleHandler(url, appState)
        }

        keptBookmarks.append(data)
        urls.append(url)
      } catch {
        // Missing/stale saved workspace entries are startup state, not a user action failure.
        // Bare launch must still present the empty launcher instead of surfacing an old bookmark
        // error when the only saved folder was removed outside Pensieve.
        keptBookmarks.append(data)
      }
    }

    if !didRefreshStaleBookmark, keptBookmarks.count != bookmarks.count {
      defaults.set(keptBookmarks, forKey: key)
    }
    return urls
  }
}

struct RestoredWorkspaceBookmarks {
  var rootURLs: [URL]
  var fileURLs: [URL]
}
