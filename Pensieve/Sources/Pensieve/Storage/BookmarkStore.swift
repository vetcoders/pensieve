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
    var bookmarks = fileBookmarkData
    if !bookmarks.contains(data) {
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
    let files = try fileURLs.map { url in
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
      staleHandler: { [weak self] url, appState in
        try self?.persistRoot(url: url, into: appState)
      },
      into: appState
    )
    let fileURLs = restoreURLs(
      from: files,
      expectedKind: .file,
      staleHandler: { [weak self] url, appState in
        try self?.persistFile(url: url, into: appState)
      },
      into: appState
    )

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

  private enum ExpectedKind {
    case directory
    case file
  }

  private func restoreURLs(
    from bookmarks: [Data],
    expectedKind: ExpectedKind,
    staleHandler: (URL, AppState) throws -> Void,
    into appState: AppState
  ) -> [URL] {
    bookmarks.compactMap { data in
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
          return nil
        }

        activate(url)

        if bookmarkIsStale {
          try staleHandler(url, appState)
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
}

struct RestoredWorkspaceBookmarks {
  var rootURLs: [URL]
  var fileURLs: [URL]
}
