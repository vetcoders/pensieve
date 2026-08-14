import Foundation

@MainActor
final class BookmarkStore {
  static let shared = BookmarkStore()

  private let defaults: UserDefaults
  private let legacyFolderBookmarkKey = "Pensieve.openFolder.bookmark"
  private let rootBookmarksKey = "Pensieve.workspace.rootBookmarks"
  private let fileBookmarksKey = "Pensieve.workspace.fileBookmarks"

  /// One tracked security-scope access attempt: the URL access was actually
  /// STARTED on (start/stop must balance on the same object) and whether the
  /// start succeeded. Filed under `identityPath` — see `stopAccess(to:)`.
  ///
  /// `bookmark` is the persisted blob this grant was taken alongside, when the
  /// activation happened next to one. It is the ONLY way back to this entry for
  /// a caller that holds a blob whose minted path it cannot read — see
  /// `stopAccess(forBookmark:)`.
  private struct ActiveAccess {
    let exactURL: URL
    let wasGranted: Bool
    var bookmark: Data?
  }

  /// A persisted blob together with the URL that carries the security-scope
  /// extension obtained by resolving that exact blob.
  ///
  /// `resolvedURL` is NIL for a blob carried forward from the previous workspace
  /// because its file cannot be reached today (see `replaceWorkspace`): there is
  /// nothing live to take a grant on, and the entry is kept precisely so the
  /// grant can be taken again once the file comes back.
  private struct WorkspaceBookmark {
    let data: Data
    let resolvedURL: URL?
  }

  private var activeAccess: [String: ActiveAccess] = [:]

  /// How many access attempts this store is still tracking, including URLs
  /// that did not need or could not obtain a security-scoped grant.
  var activeSecurityScopeCount: Int { activeAccess.count }

  /// How many security-scoped grants this store actually obtained and still
  /// has to balance. Keeping this separate from `activeSecurityScopeCount`
  /// makes a failed `startAccessingSecurityScopedResource()` observable rather
  /// than indistinguishable from a live App Store sandbox grant.
  var grantedSecurityScopeCount: Int {
    activeAccess.values.count(where: \.wasGranted)
  }

  private let trashMembership: (URL) -> Bool
  private let startSecurityScopedAccess: (URL) -> Bool
  private let stopSecurityScopedAccess: (URL) -> Void

  /// How the Trash prune reads the path a blob was minted for. Injectable for
  /// one reason only: a blob that answers NIL is the case whose bookkeeping used
  /// to leak, and no fixture can mint a real bookmark that fails this read.
  private let bookmarkedOrigin: (Data) -> URL?

  /// How a working-set entry's persisted blob is minted. Injectable for the same
  /// reason as `bookmarkedOrigin`: a `persistFile` that FAILS is the case whose
  /// warning used to be swallowed by the save paths downstream of it, and no
  /// fixture can make a real file on a real volume refuse to produce a bookmark.
  private let mintFileBookmark: (URL) throws -> Data

  init(
    defaults: UserDefaults = .standard,
    trashMembership: @escaping (URL) -> Bool = TrashLocation.contains,
    startSecurityScopedAccess: @escaping (URL) -> Bool = {
      $0.startAccessingSecurityScopedResource()
    },
    stopSecurityScopedAccess: @escaping (URL) -> Void = {
      $0.stopAccessingSecurityScopedResource()
    },
    bookmarkedOrigin: @escaping (Data) -> URL? = BookmarkStore.bookmarkedOriginURL,
    mintFileBookmark: @escaping (URL) throws -> Data = BookmarkStore.securityScopedBookmark
  ) {
    self.defaults = defaults
    self.trashMembership = trashMembership
    self.startSecurityScopedAccess = startSecurityScopedAccess
    self.stopSecurityScopedAccess = stopSecurityScopedAccess
    self.bookmarkedOrigin = bookmarkedOrigin
    self.mintFileBookmark = mintFileBookmark
  }

  nonisolated static func securityScopedBookmark(for url: URL) throws -> Data {
    try url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
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
  ///
  /// Succeeding here says nothing about the caller's status line, so this writes
  /// NOTHING to `appState.lastError`. It used to clear it, which made an ordinary
  /// bookmark persist erase an earlier, unrelated failure the user had not read
  /// yet — a save's own warning among them, since a save persists a bookmark
  /// mid-flight. `appState` stays in the signature because a future failure of
  /// this write may still need the state it names; deciding what the user sees
  /// belongs to the caller that owns the last write to the status.
  func persistFile(url: URL, into appState: AppState) throws {
    let data = try mintFileBookmark(url)
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
    activate(url, bookmark: data)
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
  ///
  /// A working-set file that can no longer be bookmarked does NOT abort the
  /// rewrite: its already-persisted blob is carried forward instead. All-or-
  /// nothing protects the previous workspace from a partial write, but the caller
  /// that removes a root has already changed the live workspace by the time it
  /// hears about the failure — so refusing to write left the removed root
  /// persisted and it came back on the next launch, durably. One file on an
  /// unplugged volume was enough to trigger it, and that file is guaranteed to
  /// still be in the working set: a merely-missing row is deliberately kept
  /// (unplugged ≠ trashed). Carrying the old blob keeps that file's access for
  /// when the volume returns AND lets the rewrite complete, which is what
  /// actually retires the removed root's blob.
  func replaceWorkspace(rootURLs: [URL], fileURLs: [URL], into appState: AppState) throws {
    let roots = try rootURLs.map { url in
      try makeWorkspaceBookmark(for: url)
    }
    // Read before anything is written: this is the key the fallback carries from.
    let persistedFileBookmarks = fileBookmarksByMintedIdentity()
    var seenFilePaths: Set<String> = []
    let files =
      try fileURLs
      .filter { seenFilePaths.insert($0.standardizedFileURL.path).inserted }
      .map { url in
        try makeWorkspaceBookmark(for: url, carryingForward: persistedFileBookmarks)
      }

    // Resolve every freshly minted bookmark BEFORE dropping the old grants.
    // In the App Store sandbox the extension is carried by the resolved URL,
    // not by a plain standardized URL reconstructed from its path. If any
    // bookmark cannot resolve, the previous persisted workspace and all of its
    // live grants remain intact.
    stopAllAccess()
    defaults.set(roots.map(\.data), forKey: rootBookmarksKey)
    defaults.set(files.map(\.data), forKey: fileBookmarksKey)
    if let firstRoot = roots.first?.data {
      defaults.set(firstRoot, forKey: legacyFolderBookmarkKey)
    } else {
      defaults.removeObject(forKey: legacyFolderBookmarkKey)
    }
    appState.bookmarkData = roots.first?.data
    for root in roots { if let resolvedURL = root.resolvedURL { activate(resolvedURL) } }
    for file in files {
      // A carried-forward blob has no reachable URL, so there is no grant to take
      // for it now. Launch restore activates it again the moment it resolves.
      guard let resolvedURL = file.resolvedURL else { continue }
      activate(resolvedURL, bookmark: file.data)
    }
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
  ///
  /// `.withoutMounting` is not an optimization, it is the difference between
  /// reading the working set and CHANGING the machine. Resolving a bookmark is
  /// allowed to mount the volume it names, and this runs on the repeating
  /// watcher-driven refresh path, on the main actor: measured on this machine, a
  /// resolve after `hdiutil detach` re-attached the volume and took 94 ms, while
  /// the same resolve with `.withoutMounting` returned in 0.000 s and mounted
  /// nothing. Nothing is lost by refusing the mount — a bookmark that needs a
  /// volume brought back before it can even be resolved cannot be describing a
  /// file that was just moved to the Trash, and an unresolvable blob is kept.
  @discardableResult
  func pruneTrashedFiles() -> [PrunedTrashedFile] {
    var survivors: [Data] = []
    var trashed: [PrunedTrashedFile] = []
    for data in fileBookmarkData {
      var bookmarkIsStale = false
      guard
        let resolved = try? URL(
          resolvingBookmarkData: data,
          options: [.withSecurityScope, .withoutMounting],
          relativeTo: nil,
          bookmarkDataIsStale: &bookmarkIsStale
        ),
        isTrashed(resolved)
      else {
        survivors.append(data)
        continue
      }
      // Released under the ACTIVATION key, which is the path the file had
      // before it was thrown away — a grant is taken when a file is persisted
      // or restored, both of them pre-trash events, so stopping by the Trash
      // LANDING path looked up a key that was never written and leaked the
      // grant for the rest of the process. The landing path is released too:
      // both lookups are no-ops when absent, and only one of them can ever be
      // the key that exists.
      //
      // A blob that carries no cached path names no activation key at all, and
      // that entry is leaving the working set on this pass either way — so the
      // grant is released through the blob itself rather than left dangling
      // with nothing that could ever name it again.
      let origin = bookmarkedOrigin(data)
      if let origin {
        stopAccess(to: origin)
      } else {
        stopAccess(forBookmark: data)
      }
      stopAccess(to: resolved.standardizedFileURL)
      trashed.append(
        PrunedTrashedFile(trashedURL: resolved.standardizedFileURL, originURL: origin))
    }

    guard !trashed.isEmpty else { return [] }
    defaults.set(survivors, forKey: fileBookmarksKey)
    return trashed
  }

  /// The path a bookmark was MINTED for, read out of the blob itself.
  ///
  /// This is the only thing that connects a working-set row — which still names
  /// the path its file was opened at — to the blob that has just turned up in
  /// the Trash. Resolving cannot supply it: resolution follows the file and
  /// answers where it is NOW.
  ///
  /// Read without resolving, so it costs no filesystem work and cannot mount
  /// anything (see `pruneTrashedFiles`). A blob that carries no cached path
  /// answers nil. The caller still retires that row after proving its resolved
  /// target is in the Trash, and balances any tracked grant through the blob
  /// tag recorded at activation time.
  nonisolated private static func bookmarkedOriginURL(for bookmark: Data) -> URL? {
    guard let path = URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: bookmark)?.path
    else { return nil }
    return URL(fileURLWithPath: path)
  }

  /// The one spelling both halves of the working set must agree on.
  ///
  /// A live row names a path; a bookmark blob carries the path it was minted
  /// for. Standardizing both is not enough on its own: `standardizedFileURL`
  /// drops a leading `/private` only while the result still names an EXISTING
  /// item, and the case this comparison exists for is a file that no longer sits
  /// there — so the same document reads as `/var/…` from the live row and
  /// `/private/var/…` from the blob of its trashed self, and a correlation by
  /// path would silently never match.
  ///
  /// The prefix is therefore removed here — but ONLY under the three
  /// directories macOS publishes twice. `/var`, `/tmp` and `/etc` are symlinks
  /// into `/private`, which is exactly what makes the two spellings one file.
  /// Every other `/private/…` path is an independent location and comes back
  /// untouched: folding it would give `/private/foo` and an unrelated `/foo` one
  /// identity key, and with it one security-scoped grant and one Trash
  /// correlation.
  ///
  /// This is an identity key, never a path handed back to the filesystem, and it
  /// is NOT a general macOS canonicalizer. It resolves no symlinks of its own
  /// (`standardizedFileURL` does not resolve them either), and it folds only
  /// items INSIDE the three aliases — the alias root spelled on its own
  /// (`/private/var`) is left as it stands, because identity keys are minted for
  /// documents, not for the roots themselves. `FileWatcher.canonicalPath` folds
  /// the same three aliases for FSEvents paths.
  static func identityPath(_ url: URL) -> String {
    let path = url.standardizedFileURL.path
    for alias in privateSymlinkAliases where path.hasPrefix(alias) {
      return String(path.dropFirst("/private".count))
    }
    return path
  }

  /// The only `/private` spellings `identityPath` folds. The trailing slash is
  /// load-bearing: it keeps `/private/variants` out of `/private/var`.
  private static let privateSymlinkAliases = ["/private/var/", "/private/tmp/", "/private/etc/"]

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

  /// Mints a blob for `url` and immediately resolves it, because in the App
  /// Store sandbox the security-scope extension is carried by the RESOLVED URL,
  /// not by a standardized URL rebuilt from a path.
  ///
  /// `.withoutMounting` for the same reason `pruneTrashedFiles` gives, and at no
  /// cost here: `url.bookmarkData` on the line above already needed a live file,
  /// so the volume this resolve names is mounted by definition on every path
  /// that reaches it. What the option removes is the main-actor stall a resolve
  /// is otherwise ALLOWED to take — mounting a volume that went away between the
  /// mint and the resolve — during a workspace rewrite the operator is watching.
  private func makeWorkspaceBookmark(for url: URL) throws -> WorkspaceBookmark {
    let data = try url.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    var bookmarkIsStale = false
    let resolvedURL = try URL(
      resolvingBookmarkData: data,
      options: [.withSecurityScope, .withoutMounting],
      relativeTo: nil,
      bookmarkDataIsStale: &bookmarkIsStale
    )
    return WorkspaceBookmark(data: data, resolvedURL: resolvedURL)
  }

  /// Mints `url`'s blob, or — when this machine cannot produce one today — hands
  /// back the blob the working set already holds for the same file.
  ///
  /// Minting needs a live file: a deleted document or an unplugged volume makes
  /// `bookmarkData` throw `NSFileReadNoSuchFile`, and inside an all-or-nothing
  /// rewrite that one URL used to discard the whole write (see
  /// `replaceWorkspace`). The carried blob is matched on the path it was MINTED
  /// for, read out of the blob itself — resolving cannot answer for a file that
  /// is not reachable, which is exactly the case this exists for — and folded
  /// through `identityPath`, because neither spelling can be canonicalized
  /// against a missing target.
  ///
  /// A failure with no previously persisted blob still throws: there is nothing
  /// to carry, and inventing an entry for a file the working set never recorded
  /// would be a resurrection rather than a rescue.
  private func makeWorkspaceBookmark(
    for url: URL,
    carryingForward persistedFileBookmarks: [String: Data]
  ) throws -> WorkspaceBookmark {
    do {
      return try makeWorkspaceBookmark(for: url)
    } catch {
      guard let carried = persistedFileBookmarks[Self.identityPath(url)] else { throw error }
      DebugTrace.log("bookmark carried forward for unreachable file path=\(url.path)")
      return WorkspaceBookmark(data: carried, resolvedURL: resolvedWorkspaceURL(for: carried))
    }
  }

  /// The persisted working set keyed by the path each blob was minted for, which
  /// is the only identity a file that cannot be resolved still answers to.
  /// A blob carrying no cached path is skipped: it can name no file, so nothing
  /// could ever match it.
  private func fileBookmarksByMintedIdentity() -> [String: Data] {
    var byIdentity: [String: Data] = [:]
    for data in fileBookmarkData {
      guard let origin = bookmarkedOrigin(data) else { continue }
      byIdentity[Self.identityPath(origin)] = data
    }
    return byIdentity
  }

  /// Resolves a blob for its security-scope extension, or nil when its file
  /// cannot be reached. `.withoutMounting` for the reason `pruneTrashedFiles`
  /// gives: this runs on the main actor during a rewrite the operator is
  /// watching, and a carried blob names a volume that may well be gone.
  private func resolvedWorkspaceURL(for bookmark: Data) -> URL? {
    var bookmarkIsStale = false
    return try? URL(
      resolvingBookmarkData: bookmark,
      options: [.withSecurityScope, .withoutMounting],
      relativeTo: nil,
      bookmarkDataIsStale: &bookmarkIsStale
    )
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

  /// Takes (once) the security-scoped access for `url`, and records which
  /// persisted blob that access belongs to.
  ///
  /// The blob is re-recorded even when the grant is already held, because the
  /// key survives a re-persist while the BYTES do not: `persistFile` mints fresh
  /// bookmark data for a file it already tracks, and a stale tag would point at
  /// a blob no longer in the working set.
  private func activate(_ url: URL, bookmark: Data? = nil) {
    let key = Self.identityPath(url)
    if activeAccess[key] != nil {
      if bookmark != nil {
        activeAccess[key]?.bookmark = bookmark
      }
      return
    }

    let wasGranted = startSecurityScopedAccess(url)
    if !wasGranted {
      DebugTrace.log("bookmark security-scope grant not obtained path=\(url.path)")
    }
    activeAccess[key] = ActiveAccess(exactURL: url, wasGranted: wasGranted, bookmark: bookmark)
  }

  /// Releases the security-scoped access this store took for one file.
  ///
  /// Keyed by `identityPath`, and it has to be: `activate` is called with
  /// whatever spelling reached it — `persistFile` passes the caller's raw URL,
  /// and `restoreURLs` passes the bookmark-RESOLVED URL, which for anything
  /// under `/tmp` or `/var` differs from its standardized form. `removeFile`
  /// has always stopped with the standardized URL, so a grant taken under a
  /// non-canonical spelling was never found and leaked until process exit.
  ///
  /// Plain standardization is not enough on its own for one caller: the Trash
  /// prune releases by the path the file was activated at, which by then no
  /// longer exists, and `standardizedFileURL` leaves `/private` on a path whose
  /// target is gone. See `identityPath`.
  ///
  /// The stop itself still goes through the EXACT URL that was activated:
  /// start/stop must balance on the same object, so canonicalizing the key is
  /// not licence to canonicalize the call.
  private func stopAccess(to url: URL) {
    stopAccess(atKey: Self.identityPath(url))
  }

  /// Releases the grant taken alongside one persisted blob, for the caller that
  /// has the blob but cannot name the path it was minted for.
  ///
  /// `pruneTrashedFiles` is that caller. It normally releases under the
  /// ACTIVATION key — the pre-trash path, read back out of the blob — and when
  /// the blob carries no cached path there is no such key to derive: releasing
  /// by the Trash LANDING path alone looks up a key that was never written, so
  /// the entry left the working set while its grant stayed live for the rest of
  /// the process. The blob recorded at activation time is the remaining handle
  /// on that entry, and it is exact: it is the very data the caller is dropping.
  private func stopAccess(forBookmark bookmark: Data) {
    // One identity normally has one entry. Release every exact blob match
    // anyway: an older build or future alias bug may have filed the same
    // persisted grant under more than one key, and once the blob is being
    // retired none of those entries has a surviving owner. Entries retagged to
    // a newer blob are deliberately untouched.
    let keys = activeAccess.compactMap { key, access in
      access.bookmark == bookmark ? key : nil
    }
    for key in keys { stopAccess(atKey: key) }
  }

  private func stopAccess(atKey key: String) {
    guard let access = activeAccess.removeValue(forKey: key) else { return }
    if access.wasGranted {
      stopSecurityScopedAccess(access.exactURL)
    }
  }

  private func stopAllAccess() {
    for access in activeAccess.values where access.wasGranted {
      stopSecurityScopedAccess(access.exactURL)
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

      activate(url, bookmark: data)
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
      // Minting the replacement needs the grant, so it happens AFTER the
      // activation — which is why the tag is re-filed here rather than passed
      // once: the grant has to answer to the blob that is actually persisted.
      if let refreshed { activate(url, bookmark: refreshed) }
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

/// One persisted working-set entry the Trash prune retired, named on BOTH sides
/// of the move it did not witness.
///
/// A caller reconciling a LIVE working set needs the second half. Its rows name
/// the paths their files were opened at, and a trashed file is no longer there —
/// so "which of my rows just died" can only be answered by the path the dropped
/// bookmark was minted for. Answering it by file NAME instead is how a document
/// still open from a disconnected volume could be retired because an unrelated
/// namesake was thrown away.
struct PrunedTrashedFile: Equatable {
  /// Where the bookmark resolves NOW: inside a Trash.
  let trashedURL: URL

  /// The path the bookmark was minted for — the pre-trash location a live
  /// working-set row still names. Nil when the blob carries no cached path.
  let originURL: URL?
}
