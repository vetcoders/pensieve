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

  /// How long an unhandled draft survives. A draft is a crash artifact, not an
  /// archive: past this age it is noise the user never came back for, and the
  /// launch sweep drops it.
  static let draftRetentionInterval: TimeInterval = 30 * 24 * 60 * 60

  /// Hard ceiling on stored drafts. Oldest fall out first, so a long-running
  /// crash loop cannot grow the Recovered Drafts list without bound.
  static let maximumDraftCount = 20

  private let directoryURL: URL
  private let fileManager: FileManager

  /// Drafts a window is holding open and editing RIGHT NOW. Retention never
  /// touches these: sweeping a draft out from under the buffer that owns it
  /// would delete live work whose only copy is that file.
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
    // Writing a draft IS the claim: the buffer that produced it is live.
    openDraftIDs.insert(id)
    // Only a BRAND NEW draft can push the list past the cap. Re-saving the same
    // draft is the autosave hot path — it must not re-read the whole directory
    // every 1.5 s of typing.
    if existingID == nil {
      enforceDraftCap()
    }
    return RecoveryDraft(
      id: id,
      url: url,
      title: title.isEmpty ? "Recovered Untitled.md" : title,
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
    try? fileManager.removeItem(at: draftURL(for: id))
  }

  // MARK: - Claim tracking

  /// Records that a window adopted this draft into a live buffer.
  func markDraftOpen(id: UUID?) {
    guard let id else { return }
    openDraftIDs.insert(id)
  }

  /// Records that the buffer holding this draft is gone (closed, saved,
  /// discarded). The draft file itself is untouched — only its protection from
  /// retention ends.
  func markDraftClosed(id: UUID?) {
    guard let id else { return }
    openDraftIDs.remove(id)
  }

  func isDraftOpen(id: UUID) -> Bool {
    openDraftIDs.contains(id)
  }

  // MARK: - Retention

  /// Launch sweep: drops drafts nobody came back for. Returns the IDs actually
  /// removed so callers can report what retention did.
  ///
  /// Two rules, both bounded by the open-draft claim: anything older than
  /// `draftRetentionInterval` goes, and whatever survives is trimmed to
  /// `maximumDraftCount` newest-first.
  @discardableResult
  func pruneDrafts(now: Date = Date()) -> [UUID] {
    let drafts = loadDrafts()
    var removed: [UUID] = []

    let expired = drafts.filter { draft in
      !openDraftIDs.contains(draft.id)
        && now.timeIntervalSince(draft.updatedAt) > Self.draftRetentionInterval
    }
    for draft in expired {
      try? fileManager.removeItem(at: draft.url)
      removed.append(draft.id)
    }

    let expiredIDs = Set(removed)
    removed.append(
      contentsOf: trimToCap(drafts.filter { !expiredIDs.contains($0.id) }))
    return removed
  }

  /// Applies the count cap to the newest-first draft list, skipping open ones.
  @discardableResult
  private func trimToCap(_ draftsNewestFirst: [RecoveryDraft]) -> [UUID] {
    guard draftsNewestFirst.count > Self.maximumDraftCount else { return [] }

    var removed: [UUID] = []
    // Walk oldest-first so the ones that fall out are genuinely the stalest,
    // and stop as soon as the list fits — an open draft that cannot be dropped
    // simply keeps its slot.
    var remaining = draftsNewestFirst.count
    for draft in draftsNewestFirst.reversed() where remaining > Self.maximumDraftCount {
      guard !openDraftIDs.contains(draft.id) else { continue }
      try? fileManager.removeItem(at: draft.url)
      removed.append(draft.id)
      remaining -= 1
    }
    return removed
  }

  private func enforceDraftCap() {
    _ = trimToCap(loadDrafts())
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
      title: "Recovered Untitled.md",
      text: text,
      updatedAt: Self.modifiedDate(for: url, fileManager: fileManager) ?? .distantPast
    )
  }

  private func draftURL(for id: UUID) -> URL {
    directoryURL.appendingPathComponent(id.uuidString).appendingPathExtension("md")
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
