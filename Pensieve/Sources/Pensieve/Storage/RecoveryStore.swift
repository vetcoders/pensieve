import Foundation

struct RecoveryDraft: Equatable, Identifiable, Sendable {
  let id: UUID
  let url: URL
  let title: String
  let text: String
  let updatedAt: Date
  /// The file whose unsaved in-memory edits this recovery record protects.
  /// `nil` means the record belongs to a draft that never had a location.
  let sourceURL: URL?

  init(
    id: UUID,
    url: URL,
    title: String,
    text: String,
    updatedAt: Date,
    sourceURL: URL? = nil
  ) {
    self.id = id
    self.url = url
    self.title = title
    self.text = text
    self.updatedAt = updatedAt
    self.sourceURL = sourceURL
  }

  var displayTitle: String {
    guard let sourceURL else { return title }
    return "Unsaved changes — \(sourceURL.lastPathComponent)"
  }

  /// One-line gist for the Recovered Drafts list. The draft file carries no
  /// name of its own, so the first non-empty line is the only thing that tells
  /// two crash drafts apart.
  var previewSnippet: String {
    let firstLine =
      text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
      .map { $0.trimmingCharacters(in: .whitespaces) }

    guard let firstLine, !firstLine.isEmpty else { return "Empty draft" }
    guard firstLine.count > Self.snippetLimit else { return firstLine }
    return String(firstLine.prefix(Self.snippetLimit)) + "…"
  }

  private static let snippetLimit = 80
}

@MainActor
final class RecoveryStore {
  static let shared = RecoveryStore()

  /// A draft outlives everything except the user's own decision about it.
  ///
  /// There is deliberately no age limit and no count cap here. The store used to
  /// carry both (30 days, 20 drafts, swept at every launch); Monika's decision of
  /// 04.08 — "they don't disappear without my decision" — retired them, and the
  /// lifecycle contract's Recovery section already spelled out the same closed
  /// list of reasons a draft may be removed: a successful save, an explicit
  /// discard, or a confirmed Don't Save. Time passing is not on that list, and
  /// neither is the arrival of a newer draft. Nothing in this file deletes a
  /// draft except `deleteDraft`, which only ever runs off one of those actions.
  private let directoryURL: URL
  private let fileManager: FileManager
  private let removeItem: (URL) throws -> Void

  /// Drafts a window is holding open and editing RIGHT NOW. They are not
  /// "unhandled", so no other launcher surface may offer them: two buffers on
  /// one recovery ID autosave over each other.
  private var openDraftIDs: Set<UUID> = []

  init(
    directoryURL: URL? = nil,
    fileManager: FileManager = .default,
    removeItem: ((URL) throws -> Void)? = nil
  ) {
    self.fileManager = fileManager
    self.removeItem = removeItem ?? { try fileManager.removeItem(at: $0) }
    self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
  }

  @discardableResult
  func saveDraft(
    id existingID: UUID?,
    title: String,
    text: String,
    sourceURL: URL? = nil
  ) throws -> RecoveryDraft {
    let id = existingID ?? UUID()
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let url = draftURL(for: id)
    let resolvedTitle = title.isEmpty ? Self.fallbackTitle : title
    // The draft's own name lives in a sidecar. Without it the title died at the
    // process boundary and EVERY recovered draft came back called
    // "Recovered Untitled.md", no matter what the user had been working on.
    // Required identity metadata lands BEFORE the visible `.md` payload. A
    // failed `.source` write must not leave a newly discoverable file-backed
    // recovery item that has already forgotten which original it protects.
    // An orphan sidecar is harmless and invisible to `loadDrafts`; a visible
    // payload without its source would be another ambiguous ghost.
    if let sourceURL {
      try Data(sourceURL.standardizedFileURL.path.utf8).write(
        to: sourceURLSidecar(for: id), options: .atomic)
    } else {
      // Reusing a recovery ID after the buffer became a normal untitled draft
      // must not retain an older file association. This is required metadata,
      // not cleanup: if the stale sidecar cannot be removed, publishing new
      // untitled bytes would later offer "Save to Original" for the WRONG file.
      // Fail before touching the visible payload instead.
      try removeItemIfPresent(at: sourceURLSidecar(for: id))
    }
    try text.write(to: url, atomically: true, encoding: .utf8)
    try? Data(resolvedTitle.utf8).write(to: titleURL(for: id), options: .atomic)
    // Writing a draft IS the claim: the buffer that produced it is live.
    openDraftIDs.insert(id)
    // A new draft used to evict the oldest one here to hold a 20-draft ceiling.
    // It no longer does: the arrival of newer work is not a decision the user
    // made about the older draft.
    return RecoveryDraft(
      id: id,
      url: url,
      title: resolvedTitle,
      text: text,
      updatedAt: Self.modifiedDate(for: url, fileManager: fileManager) ?? Date(),
      sourceURL: sourceURL?.standardizedFileURL
    )
  }

  func loadDrafts() -> [RecoveryDraft] {
    guard
      let urls = try? fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return []
    }

    return urls.compactMap(loadDraft)
      .sorted { lhs, rhs in lhs.updatedAt > rhs.updatedAt }
  }

  /// Retires a recovery record only after its visible payload is confirmed gone.
  ///
  /// The `.md` file is the launcher's source of truth. If removing it fails, the
  /// draft still exists and remains claimed by the live buffer that owns it; the
  /// title/source sidecars are left untouched so a later retry cannot turn the
  /// record into an ambiguous ghost. Sidecars become invisible once the payload
  /// is gone, so their cleanup is best effort and logged rather than allowed to
  /// turn a completed retirement back into a user-visible failure.
  @discardableResult
  func deleteDraft(id: UUID?) -> Bool {
    guard let id else { return true }

    do {
      try removeItemIfPresent(at: draftURL(for: id))
    } catch {
      NSLog("Could not retire recovery draft %@: %@", id.uuidString, error.localizedDescription)
      return false
    }

    openDraftIDs.remove(id)
    removeSidecarIfPresent(at: titleURL(for: id), draftID: id)
    removeSidecarIfPresent(at: sourceURLSidecar(for: id), draftID: id)
    return true
  }

  private func removeSidecarIfPresent(at url: URL, draftID: UUID) {
    do {
      try removeItemIfPresent(at: url)
    } catch {
      NSLog(
        "Could not remove recovery sidecar %@ for %@: %@", url.lastPathComponent,
        draftID.uuidString, error.localizedDescription)
    }
  }

  private func removeItemIfPresent(at url: URL) throws {
    do {
      try removeItem(url)
    } catch let error as CocoaError where error.code == .fileNoSuchFile {
      // No old association is the desired state.
    }
  }

  // MARK: - Claim tracking

  /// Records that a window adopted this draft into a live buffer.
  func markDraftOpen(id: UUID?) {
    guard let id else { return }
    openDraftIDs.insert(id)
  }

  /// Records that the buffer holding this draft is gone (closed, saved,
  /// discarded). The draft file itself is untouched — releasing the claim only
  /// puts the draft back on the launcher for whoever wants it next.
  func markDraftClosed(id: UUID?) {
    guard let id else { return }
    openDraftIDs.remove(id)
  }

  func isDraftOpen(id: UUID) -> Bool {
    openDraftIDs.contains(id)
  }

  /// Every draft NO live buffer is holding — the only ones a launcher may
  /// offer. A window adopting a draft claims it, and an empty window elsewhere
  /// (a second launcher, a "+" tab) must stop listing it from that moment on:
  /// two buffers on one recovery ID autosave over each other, and a Save As… in
  /// one is undone by the other's next autosave recreating the file.
  ///
  /// The claim is deliberately in-process only. A crash takes it with the
  /// process, which is the point — the file on disk outlives it and is offered
  /// again on the next launch.
  func unclaimedDrafts() -> [RecoveryDraft] {
    loadDrafts().filter { !openDraftIDs.contains($0.id) }
  }

  private func loadDraft(from url: URL) -> RecoveryDraft? {
    guard url.pathExtension.lowercased() == "md" else { return nil }
    guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else {
      return nil
    }
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    return RecoveryDraft(
      id: id,
      url: url,
      // Drafts written before the sidecar existed have no recorded name, so the
      // generic fallback still has to hold for them.
      title: loadTitle(for: id) ?? Self.fallbackTitle,
      text: text,
      updatedAt: Self.modifiedDate(for: url, fileManager: fileManager) ?? .distantPast,
      sourceURL: loadSourceURL(for: id)
    )
  }

  private func loadTitle(for id: UUID) -> String? {
    guard let data = try? Data(contentsOf: titleURL(for: id)),
      let title = String(data: data, encoding: .utf8),
      !title.isEmpty
    else {
      return nil
    }
    return title
  }

  private func loadSourceURL(for id: UUID) -> URL? {
    guard let data = try? Data(contentsOf: sourceURLSidecar(for: id)),
      let path = String(data: data, encoding: .utf8),
      !path.isEmpty
    else {
      return nil
    }
    return URL(fileURLWithPath: path).standardizedFileURL
  }

  static let fallbackTitle = "Recovered Untitled.md"

  private func draftURL(for id: UUID) -> URL {
    directoryURL.appendingPathComponent(id.uuidString).appendingPathExtension("md")
  }

  /// Sidecar holding the draft's display name. Deliberately NOT ".md": the
  /// directory listing treats every `.md` file as a draft, so a sidecar with
  /// that extension would be handed back as a second, empty draft.
  private func titleURL(for id: UUID) -> URL {
    directoryURL.appendingPathComponent(id.uuidString).appendingPathExtension("title")
  }

  /// Sidecar holding the original path for a file-backed recovery. It is plain
  /// UTF-8 rather than a property list so a recovery record stays three small,
  /// inspectable files and never participates in Saved Application State.
  private func sourceURLSidecar(for id: UUID) -> URL {
    directoryURL.appendingPathComponent(id.uuidString).appendingPathExtension("source")
  }

  static func defaultDirectoryURL(
    fileManager: FileManager,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    isTestProcess: Bool? = nil
  ) -> URL {
    if let isolationRoot = AppSupportLocation.isolationRoot(
      environment: environment,
      fileManager: fileManager,
      isTestProcess: isTestProcess)
    {
      return
        isolationRoot
        .appendingPathComponent("Recovery", isDirectory: true)
    }
    let appSupport =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support", isDirectory: true)
    return appSupport.appendingPathComponent("Pensieve", isDirectory: true)
      .appendingPathComponent("Recovery", isDirectory: true)
  }

  private static func modifiedDate(for url: URL, fileManager: FileManager) -> Date? {
    try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
  }
}
