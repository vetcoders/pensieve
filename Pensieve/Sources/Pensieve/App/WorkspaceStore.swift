import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class WorkspaceStore {
  static let maxOpenFiles = 12
  private static let sidebarSortOrderKey = "Pensieve.sidebarSortOrder"
  private let defaults: UserDefaults

  var folderURL: URL?
  var workspaceRoots: [WorkspaceRoot] = []
  var workspaceTree: [WorkspaceNode] = []
  var documents: [DocumentRef] = [] {
    didSet { rebuildAllDocumentsCache() }
  }
  var openFiles: [DocumentRef] = [] {
    didSet { rebuildAllDocumentsCache() }
  }
  var excludedWorkspacePaths: Set<String> = []
  var workspaceSearchQuery: String = ""
  var workspaceSearchResults: [WorkspaceSearchResult] = []
  var sidebarFocusedURL: URL?
  var pendingSidebarRenameURL: URL?
  var bookmarkData: Data?
  var workspaceActivity: WorkspaceActivity?
  var sidebarSortOrder: SidebarSortOrder {
    didSet {
      defaults.set(sidebarSortOrder.rawValue, forKey: Self.sidebarSortOrderKey)
    }
  }

  @ObservationIgnored private(set) var allDocuments: [DocumentRef] = []
  @ObservationIgnored private var allDocumentsByID: [DocumentRef.ID: DocumentRef] = [:]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let rawSort = defaults.string(forKey: Self.sidebarSortOrderKey),
      let sortOrder = SidebarSortOrder(rawValue: rawSort)
    {
      self.sidebarSortOrder = sortOrder
    } else {
      self.sidebarSortOrder = .nameAscending
    }
  }

  func document(id: DocumentRef.ID) -> DocumentRef? {
    allDocumentsByID[id]
  }

  var sortedOpenFiles: [DocumentRef] {
    sortDocuments(openFiles)
  }

  var sortedWorkspaceTree: [WorkspaceNode] {
    sortNodes(workspaceTree)
  }

  var hasWorkspaceContent: Bool {
    !workspaceRoots.isEmpty || !openFiles.isEmpty
  }

  var isSearchingWorkspace: Bool {
    !workspaceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  func documentRef(for url: URL) -> DocumentRef {
    let standardizedURL = url.standardizedFileURL
    return allDocuments.first { $0.url.standardizedFileURL == standardizedURL }
      ?? makeDocumentRef(for: standardizedURL)
  }

  func makeDocumentRef(for url: URL) -> DocumentRef {
    let standardizedURL = url.standardizedFileURL
    if let root =
      workspaceRoots
      .map(\.url.standardizedFileURL)
      .filter({ WorkspaceScanner.contains(standardizedURL, in: $0) })
      .sorted(by: { $0.path.count > $1.path.count })
      .first
    {
      return DocumentRef(
        id: standardizedURL,
        rootURL: root,
        relativePath: WorkspaceScanner.relativePath(for: standardizedURL, root: root),
        isAdHoc: false
      )
    }
    return DocumentRef(id: standardizedURL, isAdHoc: true)
  }

  private func rebuildAllDocumentsCache() {
    var seen = Set<DocumentRef.ID>()
    var result: [DocumentRef] = []
    var byID: [DocumentRef.ID: DocumentRef] = [:]
    result.reserveCapacity(documents.count + openFiles.count)
    for ref in documents + openFiles where seen.insert(ref.id).inserted {
      result.append(ref)
      byID[ref.id] = ref
    }
    allDocuments = result
    allDocumentsByID = byID
  }

  private func sortDocuments(_ documents: [DocumentRef]) -> [DocumentRef] {
    guard sidebarSortOrder != .manual else { return documents }
    return documents.sorted { lhs, rhs in
      compareURLs(lhs.url, rhs.url, lhsTitle: lhs.title, rhsTitle: rhs.title)
    }
  }

  private func sortNodes(_ nodes: [WorkspaceNode]) -> [WorkspaceNode] {
    guard sidebarSortOrder != .manual else { return nodes }

    let sortedChildren =
      nodes
      .map { node in
        var copy = node
        copy.children = node.children.map(sortNodes)
        return copy
      }
    return sortedChildren.sorted { lhs, rhs in
      compareWorkspaceNodes(lhs, rhs)
    }
  }

  private func compareWorkspaceNodes(_ lhs: WorkspaceNode, _ rhs: WorkspaceNode) -> Bool {
    if lhs.kind != rhs.kind {
      return lhs.kind == .folder
    }
    return compareURLs(lhs.url, rhs.url, lhsTitle: lhs.name, rhsTitle: rhs.name)
  }

  private func compareURLs(_ lhs: URL?, _ rhs: URL?, lhsTitle: String, rhsTitle: String) -> Bool {
    switch sidebarSortOrder {
    case .manual:
      return false
    case .nameAscending, .type:
      return lhsTitle.localizedStandardCompare(rhsTitle) == .orderedAscending
    case .nameDescending:
      return lhsTitle.localizedStandardCompare(rhsTitle) == .orderedDescending
    case .modifiedNewest:
      let lhsDate = lhs.flatMap(Self.modifiedDate) ?? .distantPast
      let rhsDate = rhs.flatMap(Self.modifiedDate) ?? .distantPast
      if lhsDate != rhsDate {
        return lhsDate > rhsDate
      }
      return lhsTitle.localizedStandardCompare(rhsTitle) == .orderedAscending
    }
  }

  private static func modifiedDate(for url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }
}
