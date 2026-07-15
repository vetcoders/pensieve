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
    return RecoveryDraft(
      id: id,
      url: url,
      title: title.isEmpty ? "Recovered Untitled.md" : title,
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
