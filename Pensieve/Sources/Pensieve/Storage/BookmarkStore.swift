import Foundation

@MainActor
final class BookmarkStore {
  static let shared = BookmarkStore()

  private let defaults: UserDefaults
  private let legacyFolderBookmarkKey = "Pensieve.openFolder.bookmark"
  private let rootBookmarksKey = "Pensieve.workspace.rootBookmarks"
  private let fileBookmarksKey = "Pensieve.workspace.fileBookmarks"

  /// One live security-scoped grant: the URL access was actually STARTED on
  /// (start/stop must balance on the same object) and whether the start
  /// succeeded. Filed under the standardized URL — see `stopAccess(to:)`.
  private struct ActiveAccess {
    let exactURL: URL
    let wasGranted: Bool
  }

  private var activeAccess: [URL: ActiveAccess] = [:]

  /// How many security-scoped grants this store is still holding. A leaked
  /// grant has no observable effect until the process exits, so this is the
  /// only seam a test can measure the balance through.
  var activeSecurityScopeCount: Int { activeAccess.count }

  private let trashMembership: (URL) -> Bool

  init(
    defaults: UserDefaults = .standard,
    trashMembership: @escaping (URL) -> Bool = TrashLocation.contains
  ) {
    self.defaults = defaults
    self.trashMembership = trashMembership
  }

  /// Whether `url` names a document that has been thrown away.
  ///
  /// Exposed from the bookmark store on purpose: this store is what makes a file
  /// outlive its path, so it is also what has to say when that survival stopped
  /// meaning "still open". Every caller then shares one answer — and one
  /// injection point for tests, which must not depend on the real Trash.
  func isTrashed(_ url: URL) -> Bool {
    trashMembership(url)
  }

  /// Starts the working set's write-back to disk and hands the caller something
  /// to wait on.
  ///
  /// `UserDefaults` writes nothing itself: it hands the change to cfprefsd,
  /// which updates the backing plist on its own schedule — measured on this
  /// machine at up to ~14 s AFTER the writing process had already exited. The
  /// saved working set was therefore still in flight while the app looked
  /// entirely gone, and that late flush could land on top of whatever touched
  /// those defaults in the meantime, resurrecting state that had been cleared on
  /// purpose. Nothing about WHAT is saved changes here — only when it is durable.
  ///
  /// Started off-main and awaited rather than called inline, for exactly the
  /// reason `TerminationSequence` gives about its own checkpoint: work a quit
  /// performs SYNCHRONOUSLY on the main thread sits outside the drain budget no
  /// matter what the deadline says. `synchronize()` is a round trip to another
  /// process, so it is precisely the kind of call that must be allowed to run
  /// out of budget instead of beachballing the quit.
  func startFlush() -> Task<Void, Never> {
    let defaults = defaults
    return Task.detached { defaults.synchronize() }
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

  /// Records one ad-hoc file in the persisted working set.
  ///
  /// Identity is the RESOLVED PATH, never the bookmark blob. Blob equality is
  /// what this used to dedupe on, and it does not hold: the bytes minted for a
  /// file vary with the spelling of the URL and with volume metadata, so
  /// re-opening the same file could append a second entry pointing at it. The
  /// operator's working set carried fifteen bookmarks for twelve files — three
  /// pairs — and every one of those pairs was a duplicate the launch restore
  /// would have opened twice.
  ///
  /// An existing entry is REPLACED where it stands rather than moved to the
  /// end: the order of this key is the working set's order, and the cap prunes
  /// from the front of it. Entries a previous build already duplicated collapse
  /// onto that first position, so a key can heal through an ordinary open
  /// instead of waiting for the next launch.
  func persistFile(url: URL, into appState: AppState) throws {
    let data = try url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    let targetPath = url.standardizedFileURL.path
    var bookmarks = fileBookmarkData
    let matches = bookmarks.indices.filter { resolvedPath(for: bookmarks[$0]) == targetPath }
    if let first = matches.first {
      bookmarks[first] = data
      for duplicate in matches.dropFirst().reversed() {
        bookmarks.remove(at: duplicate)
      }
    } else {
      bookmarks.append(data)
    }
    defaults.set(bookmarks, forKey: fileBookmarksKey)
    activate(url)
    appState.lastError = nil
  }

  /// Replaces the complete persisted workspace only after every new bookmark has been created.
  /// This preserves the previous relaunch state if one of the requested URLs cannot produce a
  /// security-scoped bookmark; callers can still update their live in-memory workspace and surface
  /// the persistence failure without erasing otherwise valid roots.
  ///
  /// This is the one writer that takes a whole list at once, so it is the one
  /// writer that could put a file in the working set twice by simply being
  /// handed it twice. Its only caller passes the live Open Files list, which is
  /// de-duplicated upstream — the guard below is what keeps that a fact about
  /// this key rather than a fact about today's callers.
  func replaceWorkspace(rootURLs: [URL], fileURLs: [URL], into appState: AppState) throws {
    let roots = try rootURLs.map { url in
      (
        url.standardizedFileURL,
        try url.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
      )
    }
    var seenFilePaths: Set<String> = []
    let files =
      try fileURLs
      .filter { seenFilePaths.insert($0.standardizedFileURL.path).inserted }
      .map { url in
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

    let rootURLs = restoreRootURLs(from: roots, into: appState)
    let fileURLs = restoreFileURLs(from: files)

    return RestoredWorkspaceBookmarks(rootURLs: rootURLs, fileURLs: fileURLs)
  }

  /// Drops ONE file's bookmark, because the user closed that file out of Open
  /// Files. Without it a close is only ever a close of the WINDOW: the working
  /// set the next launch restores from still names the file, so it comes back —
  /// and comes back on every launch after that, since nothing else ever prunes
  /// this key.
  ///
  /// Identity is the RESOLVED path, NOT `Data` equality: the bookmark bytes
  /// minted for the same file are not stable across path spellings or volume
  /// metadata moves, so matching blobs would leave the entry the user just
  /// closed sitting in the key.
  ///
  /// "Unresolvable ≠ garbage" holds here and matters more than it does when
  /// writing: an entry we cannot resolve today (an unplugged volume) is KEPT,
  /// because failing to identify a bookmark must never be a reason to silently
  /// forget a file the user did not close.
  func removeFile(url: URL) {
    removeFiles(urls: [url])
  }

  /// Drops SEVERAL files' bookmarks in one pass, because the working-set prune
  /// evicts a whole tail at once — a launch inheriting a key that accumulated
  /// past the cap can drop dozens.
  ///
  /// One pass rather than one `removeFile` per URL: identity is the resolved
  /// path, and resolving a bookmark is not free, so the per-file form would
  /// re-resolve the entire key once per eviction. Same rules as the single form
  /// in every other respect, including "unresolvable ≠ garbage".
  func removeFiles(urls: [URL]) {
    guard !urls.isEmpty else { return }
    let targets = Set(urls.map(\.standardizedFileURL.path))
    let remaining = fileBookmarkData.filter { bookmark in
      guard let path = resolvedPath(for: bookmark) else { return true }
      return !targets.contains(path)
    }
    defaults.set(remaining, forKey: fileBookmarksKey)
    for url in urls { stopAccess(to: url.standardizedFileURL) }
  }

  /// Drops every persisted file bookmark whose target now sits in the Trash, and
  /// reports those targets.
  ///
  /// This is the half of trashing that `removeFile` cannot do: `removeFile`
  /// matches on the path a bookmark RESOLVES TO, and a trashed file resolves to
  /// its new home under a Trash folder — never to the path it was trashed from.
  /// Dropping by where a bookmark LANDS is also what covers every document
  /// inside a trashed folder, whose paths the caller never enumerated.
  ///
  /// Unresolvable blobs are deliberately kept: this runs on live refreshes, and
  /// "unresolvable ≠ garbage" holds here for the same reason it holds in
  /// `removeFiles` — an unplugged volume must never cost the user a file. A file
  /// that is merely missing is dropped by the restore-time resolution failure
  /// instead. Defaults are only written when something actually died, so a
  /// healthy working set costs no write at all.
  @discardableResult
  func pruneTrashedFiles() -> [URL] {
    var survivors: [Data] = []
    var trashed: [URL] = []
    for data in fileBookmarkData {
      var bookmarkIsStale = false
      guard
        let resolved = try? URL(
          resolvingBookmarkData: data,
          options: [.withSecurityScope],
          relativeTo: nil,
          bookmarkDataIsStale: &bookmarkIsStale
        ),
        isTrashed(resolved)
      else {
        survivors.append(data)
        continue
      }
      stopAccess(to: resolved.standardizedFileURL)
      trashed.append(resolved.standardizedFileURL)
    }

    guard !trashed.isEmpty else { return [] }
    defaults.set(survivors, forKey: fileBookmarksKey)
    return trashed
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

  func clear(into appState: AppState, error: String? = nil) {
    stopAllAccess()
    defaults.removeObject(forKey: legacyFolderBookmarkKey)
    defaults.removeObject(forKey: rootBookmarksKey)
    defaults.removeObject(forKey: fileBookmarksKey)
    appState.bookmarkData = nil
    if let error {
      appState.lastError = error
    }
  }

  private func activate(_ url: URL) {
    let key = url.standardizedFileURL
    if activeAccess[key] != nil {
      return
    }

    activeAccess[key] = ActiveAccess(
      exactURL: url,
      wasGranted: url.startAccessingSecurityScopedResource()
    )
  }

  /// Releases the security-scoped access this store took for one file.
  ///
  /// Keyed by the STANDARDIZED URL, and it has to be: `activate` is called with
  /// whatever spelling reached it — `persistFile` passes the caller's raw URL,
  /// and `restoreURLs` passes the bookmark-RESOLVED URL, which for anything
  /// under `/tmp` or `/var` differs from its standardized form. `removeFile`
  /// has always stopped with the standardized URL, so a grant taken under a
  /// non-canonical spelling was never found and leaked until process exit.
  ///
  /// The stop itself still goes through the EXACT URL that was activated:
  /// start/stop must balance on the same object, so canonicalizing the key is
  /// not licence to canonicalize the call.
  private func stopAccess(to url: URL) {
    guard let access = activeAccess.removeValue(forKey: url.standardizedFileURL) else { return }
    if access.wasGranted {
      access.exactURL.stopAccessingSecurityScopedResource()
    }
  }

  private func stopAllAccess() {
    for access in activeAccess.values where access.wasGranted {
      access.exactURL.stopAccessingSecurityScopedResource()
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

  private func restoreRootURLs(from bookmarks: [Data], into appState: AppState) -> [URL] {
    bookmarks.compactMap { data in
      var bookmarkIsStale = false
      do {
        let url = try URL(
          resolvingBookmarkData: data,
          options: [.withSecurityScope],
          relativeTo: nil,
          bookmarkDataIsStale: &bookmarkIsStale
        )

        guard isExistingDirectory(url) else {
          return nil
        }

        activate(url)

        if bookmarkIsStale {
          try persistRoot(url: url, into: appState)
        }

        return url
      } catch {
        // Missing/stale saved workspace entries are startup state, not a user action failure.
        // Bare launch must still present the empty launcher instead of surfacing an old bookmark
        // error when the only saved folder was removed outside Pensieve.
        return nil
      }
    }
  }

  /// Resolves the persisted working set AND writes back what resolution proved
  /// dead, because two kinds of entry must not survive a launch:
  ///
  /// - a DUPLICATE of a file already in the set. Bookmark blobs are not stable
  ///   identities, so the same file could be recorded twice (see `persistFile`);
  ///   restoring both asked the app to open one file as two tabs.
  /// - a ref that now resolves INTO THE TRASH. A trashed file still exists, so
  ///   the existence check passes and the launch faithfully reopened a document
  ///   the user threw away. The product rule is that the Trash is dead: a file
  ///   in it does not exist for Pensieve.
  ///
  /// Everything else keeps its bookmark, including entries that fail to resolve
  /// or point at something missing today — unresolvable is not garbage, and an
  /// unplugged volume must never cost the user a file. Those are dropped from
  /// the RESTORED list only, exactly as before.
  private func restoreFileURLs(from bookmarks: [Data]) -> [URL] {
    var survivingBookmarks: [Data] = []
    var restoredURLs: [URL] = []
    var seenPaths: Set<String> = []

    for data in bookmarks {
      var bookmarkIsStale = false
      guard
        let url = try? URL(
          resolvingBookmarkData: data,
          options: [.withSecurityScope],
          relativeTo: nil,
          bookmarkDataIsStale: &bookmarkIsStale
        )
      else {
        survivingBookmarks.append(data)
        continue
      }

      let standardizedURL = url.standardizedFileURL
      guard !isTrashed(standardizedURL) else { continue }
      guard seenPaths.insert(standardizedURL.path).inserted else { continue }
      guard isExistingFile(url) else {
        survivingBookmarks.append(data)
        continue
      }

      activate(url)
      // A stale bookmark is REPLACED here rather than re-persisted through
      // `persistFile`: appending a refreshed blob while the stale one stays in
      // the key is how a working set grows a second entry for a file it already
      // holds.
      let refreshed =
        bookmarkIsStale
        ? (try? url.bookmarkData(
          options: [.withSecurityScope],
          includingResourceValuesForKeys: nil,
          relativeTo: nil))
        : nil
      survivingBookmarks.append(refreshed ?? data)
      restoredURLs.append(url)
    }

    if survivingBookmarks != bookmarks {
      defaults.set(survivingBookmarks, forKey: fileBookmarksKey)
    }
    return restoredURLs
  }

}

struct RestoredWorkspaceBookmarks {
  var rootURLs: [URL]
  var fileURLs: [URL]
}
