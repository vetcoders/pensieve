import Foundation

@MainActor
final class BookmarkStore {
  static let shared = BookmarkStore()

  private let defaults: UserDefaults
  private let legacyFolderBookmarkKey = "Pensieve.openFolder.bookmark"
  private let rootBookmarksKey = "Pensieve.workspace.rootBookmarks"
  private let fileBookmarksKey = "Pensieve.workspace.fileBookmarks"
  private var activeAccess: [URL: Bool] = [:]

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

  /// Drops the persisted file bookmark whose resolved target matches `url`.
  ///
  /// A file opened from OUTSIDE the workspace persists a security-scoped
  /// bookmark (via `persistFile`) so it survives a relaunch. When such a file
  /// is consciously closed it must STAY closed — leaving the bookmark behind
  /// lets launch restore resolve it and resurrect the file on every launch.
  /// Only `fileBookmarksKey` is touched; workspace roots are never affected.
  ///
  /// Each stored bookmark is resolved just to compare paths — the list is
  /// small (`maxOpenFiles`-bounded). Entries that no longer resolve (target
  /// deleted, stale beyond repair) are pruned in the same pass rather than
  /// left to fail again on the next restore. Security-scoped access this store
  /// opened for the removed URL is released.
  func forgetFile(url: URL) {
    let targetPath = url.standardizedFileURL.path
    var survivors: [Data] = []
    for data in fileBookmarkData {
      var bookmarkIsStale = false
      guard
        let resolved = try? URL(
          resolvingBookmarkData: data,
          options: [.withSecurityScope],
          relativeTo: nil,
          bookmarkDataIsStale: &bookmarkIsStale
        )
      else {
        // Unresolvable blob: prune it (stale-bookmark hygiene) instead of
        // carrying a dead entry forward to fail again next restore.
        continue
      }
      if resolved.standardizedFileURL.path == targetPath {
        // The file being closed. Drop the bookmark and release the scope this
        // store opened for it, if any.
        stopAccess(matching: resolved)
        continue
      }
      survivors.append(data)
    }
    defaults.set(survivors, forKey: fileBookmarksKey)
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
    if activeAccess[url] != nil {
      return
    }

    activeAccess[url] = url.startAccessingSecurityScopedResource()
  }

  private func stopAllAccess() {
    for (url, accessWasGranted) in activeAccess where accessWasGranted {
      url.stopAccessingSecurityScopedResource()
    }
    activeAccess.removeAll()
  }

  /// Releases security-scoped access for a single tracked URL, matched by
  /// standardized path so it finds the entry regardless of whether it was
  /// activated with the raw or the resolved URL form.
  private func stopAccess(matching url: URL) {
    let targetPath = url.standardizedFileURL.path
    for (key, accessWasGranted) in activeAccess
    where key.standardizedFileURL.path == targetPath {
      if accessWasGranted {
        key.stopAccessingSecurityScopedResource()
      }
      activeAccess.removeValue(forKey: key)
    }
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
