import Foundation

struct RecoveryDraft: Equatable, Identifiable {
  let id: UUID
  let url: URL
  let title: String
  let text: String
  let updatedAt: Date
}

final class RecoveryStore {
  static let shared = RecoveryStore()

  private let directoryURL: URL
  private let fileManager: FileManager

  init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
  }

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
    return RecoveryDraft(
      id: id,
      url: url,
      title: resolvedTitle,
      text: text,
      updatedAt: Self.modifiedDate(for: url, fileManager: fileManager) ?? Date()
    )
  }

  /// Hand out the newest pending draft AT MOST ONCE per store. All production
  /// windows share `RecoveryStore.shared`, and every restoring window — a
  /// state-restored scene, a relaunched launcher — asks for the draft on
  /// start; without the single-handout rule each of them adopted the same
  /// draft, multiplying one crash draft into a flood of dirty "Untitled"
  /// windows.
  func claimDraftForRestore() -> RecoveryDraft? {
    guard !hasHandedOutRestoreDraft, let draft = loadDrafts().first else { return nil }
    hasHandedOutRestoreDraft = true
    return draft
  }

  private var hasHandedOutRestoreDraft = false

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
    try? fileManager.removeItem(at: draftURL(for: id))
    try? fileManager.removeItem(at: titleURL(for: id))
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
