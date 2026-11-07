import Foundation

/// A conversation owns its immutable capabilities. Changing the selection in
/// the editor does not change an existing thread; New thread captures a new one.
struct AskContext: Equatable, Sendable {
  let roots: Set<URL>
  let files: [DocumentRef]
  /// An unsaved buffer can be selected without inventing a filesystem path.
  let draftID: UUID?

  static let empty = AskContext()

  init(roots: Set<URL> = [], files: [DocumentRef] = [], draftID: UUID? = nil) {
    self.roots = Set(roots.map { Self.canonicalURL($0) })
    var seen: Set<URL> = []
    self.files = files.compactMap { file in
      let url = Self.canonicalURL(file.url)
      guard seen.insert(url).inserted else { return nil }
      return DocumentRef(
        id: url, rootURL: file.rootURL.map(Self.canonicalURL),
        relativePath: file.relativePath, isAdHoc: file.isAdHoc)
    }
    self.draftID = draftID
  }

  /// The history payload already stores birth-canonical paths. Resolving them
  /// again after a restart could silently widen a thread through a new symlink.
  init(restoringRoots: Set<URL>, restoringFiles: [DocumentRef], draftID: UUID? = nil) {
    self.roots = Set(restoringRoots.map { Self.pinnedURL($0) })
    var seen: Set<URL> = []
    self.files = restoringFiles.compactMap { file in
      let url = Self.pinnedURL(file.url)
      guard seen.insert(url).inserted else { return nil }
      return DocumentRef(
        id: url, rootURL: file.rootURL.map(Self.pinnedURL),
        relativePath: file.relativePath, isAdHoc: file.isAdHoc)
    }
    self.draftID = draftID
  }

  /// File URL directory markers are presentation, not capability identity. Use
  /// one representation so a persisted root compares exactly with its birth URL.
  static func canonicalURL(_ url: URL) -> URL {
    guard url.isFileURL else { return url }
    return pinnedURL(url.standardizedFileURL.resolvingSymlinksInPath())
  }

  private static func pinnedURL(_ url: URL) -> URL {
    guard url.isFileURL else { return url }
    return URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: false)
  }

  var isEmpty: Bool { roots.isEmpty && files.isEmpty && draftID == nil }
  var draftPath: String? { draftID.map { "draft:\($0.uuidString.lowercased())" } }
}
