import Foundation

struct RecoveryDraft: Equatable, Identifiable {
  let id: UUID
  let url: URL
  let title: String
  let text: String
  let updatedAt: Date

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

  /// Drafts a window is holding open and editing RIGHT NOW. They are not
  /// "unhandled", so no other launcher surface may offer them: two buffers on
  /// one recovery ID autosave over each other.
  private var openDraftIDs: Set<UUID> = []

  init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
  }

  @discardableResult
  func saveDraft(id existingID: UUID?, title: String, text: String) throws -> RecoveryDraft {
    let id = existingID ?? UUID()
    try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

    let url = draftURL(for: id)
    try text.write(to: url, atomically: true, encoding: .utf8)
    let resolvedTitle = title.isEmpty ? Self.fallbackTitle : title
    // The draft's own name lives in a sidecar. Without it the title died at the
    // process boundary and EVERY recovered draft came back called
    // "Recovered Untitled.md", no matter what the user had been working on.
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
      updatedAt: Self.modifiedDate(for: url, fileManager: fileManager) ?? Date()
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

  func deleteDraft(id: UUID?) {
    guard let id else { return }
    openDraftIDs.remove(id)
    removeDraftFiles(id: id)
  }

  /// Drops BOTH files a draft is made of. Removing only the `.md` leaves the
  /// `.title` sidecar behind — invisible (the directory listing only reads
  /// `.md`) and never collected by anything, so the recovery directory grows a
  /// permanent orphan per retired draft.
  private func removeDraftFiles(id: UUID) {
    try? fileManager.removeItem(at: draftURL(for: id))
    try? fileManager.removeItem(at: titleURL(for: id))
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
      updatedAt: Self.modifiedDate(for: url, fileManager: fileManager) ?? .distantPast
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

  private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
    if let overrideRoot = AppSupportLocation.overrideRoot(fileManager: fileManager) {
      return overrideRoot.appendingPathComponent("Recovery", isDirectory: true)
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
