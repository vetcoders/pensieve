import AppKit
import Foundation

/// Narrow seam over the system recent-documents authority so tests can fake it.
/// `NSDocumentController` owns persistence (ordering, dedupe, relaunch
/// survival); this protocol mirrors only the three operations Pensieve uses,
/// so no second persisted list can grow behind the system one.
protocol RecentDocumentsControlling: AnyObject {
  var recentDocumentURLs: [URL] { get }
  func noteNewRecentDocumentURL(_ url: URL)
  func clearRecentDocuments(_ sender: Any?)
}

extension NSDocumentController: RecentDocumentsControlling {}

/// Observable adapter between `NSDocumentController.shared` and the SwiftUI
/// File → Open Recent menu. The system controller does not publish changes,
/// so every mutation routes through here and re-reads the authoritative list.
@MainActor
final class RecentDocumentsStore: ObservableObject {
  static let shared = RecentDocumentsStore()

  /// Menu-ready mirror of the system list: newest first, deduplicated by
  /// standardized path, existing files only. Display state, never persisted —
  /// the system controller remains the single authority.
  @Published private(set) var recentDocuments: [URL] = []

  private let controller: RecentDocumentsControlling
  private let fileExists: (URL) -> Bool

  init(
    controller: RecentDocumentsControlling? = nil,
    fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
  ) {
    // Resolved here, not as a default argument: `NSDocumentController.shared`
    // is main-actor-isolated and default arguments evaluate outside the actor.
    self.controller = controller ?? NSDocumentController.shared
    self.fileExists = fileExists
    refresh()
  }

  /// Records a successfully opened document into the native history.
  func noteOpened(_ url: URL) {
    controller.noteNewRecentDocumentURL(url.standardizedFileURL)
    refresh()
  }

  /// Clear Menu: empties the native list app-wide.
  func clear() {
    controller.clearRecentDocuments(nil)
    refresh()
  }

  /// Re-reads the system list. Vanished files are skipped from display:
  /// `NSDocumentController` has no single-item removal API, so hiding them
  /// here (while the system keeps the URL) avoids inventing a parallel list.
  func refresh() {
    var seen = Set<String>()
    recentDocuments = controller.recentDocumentURLs
      .map(\.standardizedFileURL)
      .filter { seen.insert($0.path).inserted && fileExists($0) }
  }

  /// Menu label: home-abbreviated path, so same-named files stay tellable apart.
  nonisolated static func menuTitle(for url: URL) -> String {
    (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
  }
}
