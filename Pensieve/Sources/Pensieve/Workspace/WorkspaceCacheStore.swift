import Foundation

struct TreeFingerprint: Codable, Equatable {
  var treeHash: String
  var fileCount: Int
  var folderCount: Int
  var computedAt: Date
  var algorithmVersion: Int

  static func compute(rootURL: URL, exclusions: Set<String>) throws -> TreeFingerprint {
    let root = rootURL.standardizedFileURL
    let scans = try WorkspaceScanner.buildCancellable(rootURLs: [root], exclusions: exclusions)
    return try compute(from: scans, root: root)
  }

  static func compute(roots: [URL], exclusions: Set<String>) throws -> TreeFingerprint {
    let roots = roots.map(\.standardizedFileURL)
    guard roots.count != 1 else {
      return try compute(rootURL: roots[0], exclusions: exclusions)
    }

    let sortedRoots = canonicalRootOrder(roots)
    let scans = try WorkspaceScanner.buildCancellable(
      rootURLs: sortedRoots, exclusions: exclusions)
    return try compute(from: scans, roots: sortedRoots)
  }

  /// Computes the SAME fingerprint v1 as `compute(rootURL:exclusions:)` but from an
  /// already-walked `[WorkspaceScan]` instead of re-walking the filesystem. The cold-open path
  /// has already built the workspace tree once (`workspaceBuilder`), so feeding that single walk
  /// in here lets the cold-start skip-gate consult the substrate verdict WITHOUT a second tree
  /// walk (the per-file `resourceValues` stat below is the same metadata read either way). The
  /// hash, file/folder counts, and algorithm version are byte-for-byte identical to the
  /// re-walking variant for the same tree, so the persisted `tree-fingerprint.json` (written via
  /// `commit`) compares equal on an unchanged relaunch.
  static func compute(from scans: [WorkspaceScan], root: URL) throws -> TreeFingerprint {
    let documents = scans.flatMap(\.documents)

    // Fingerprint v1: sorted "relativePath|mtimeSeconds|size" markdown-file tuples from WorkspaceScanner.
    let entries = try documents.map { document in
      try Task.checkCancellation()
      let relativePath =
        document.relativePath ?? WorkspaceScanner.relativePath(for: document.url, root: root)
      let values = try document.url.resourceValues(forKeys: [
        .contentModificationDateKey,
        .fileSizeKey,
      ])
      let mtime = Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
      let size = values.fileSize ?? 0
      return FingerprintEntry(relativePath: relativePath, mtime: mtime, size: size)
    }
    .sorted { $0.relativePath < $1.relativePath }

    let payload =
      entries
      .map { "\($0.relativePath)|\($0.mtime)|\($0.size)\n" }
      .joined()
    let folderCount = try scans.reduce(into: 0) { total, scan in
      total += try visibleFolderCount(in: scan.rootNode)
    }

    return TreeFingerprint(
      treeHash: WorkspaceHash.sha256Hex(payload),
      fileCount: entries.count,
      folderCount: folderCount,
      computedAt: Date(),
      algorithmVersion: 1
    )
  }

  static func compute(from scans: [WorkspaceScan], roots: [URL]) throws -> TreeFingerprint {
    let roots = roots.map(\.standardizedFileURL)
    guard roots.count != 1 else {
      return try compute(from: scans, root: roots[0])
    }

    let sortedRoots = canonicalRootOrder(roots)
    let documents = scans.flatMap(\.documents)
    let entries = try documents.map { document in
      try Task.checkCancellation()
      let rootIndex = try rootIndex(for: document, in: sortedRoots)
      let root = sortedRoots[rootIndex]
      let relativePath =
        document.relativePath ?? WorkspaceScanner.relativePath(for: document.url, root: root)
      let values = try document.url.resourceValues(forKeys: [
        .contentModificationDateKey,
        .fileSizeKey,
      ])
      let mtime = Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
      let size = values.fileSize ?? 0
      return FingerprintEntry(
        relativePath: "\(rootIndex):\(relativePath)", mtime: mtime, size: size)
    }
    .sorted { $0.relativePath < $1.relativePath }

    let payload =
      entries
      .map { "\($0.relativePath)|\($0.mtime)|\($0.size)\n" }
      .joined()
    let folderCount = try scans.reduce(into: 0) { total, scan in
      total += try visibleFolderCount(in: scan.rootNode)
    }

    return TreeFingerprint(
      treeHash: WorkspaceHash.sha256Hex(payload),
      fileCount: entries.count,
      folderCount: folderCount,
      computedAt: Date(),
      algorithmVersion: 2
    )
  }

  private static func canonicalRootOrder(_ roots: [URL]) -> [URL] {
    roots.sorted { $0.path < $1.path }
  }

  private static func rootIndex(for document: DocumentRef, in roots: [URL]) throws -> Int {
    if let documentRoot = document.rootURL?.standardizedFileURL,
      let exactIndex = roots.firstIndex(where: { $0.path == documentRoot.path })
    {
      return exactIndex
    }

    let documentURL = document.url.standardizedFileURL
    if let containingIndex = roots.firstIndex(where: {
      WorkspaceScanner.contains(documentURL, in: $0)
    }) {
      return containingIndex
    }

    throw FingerprintError.documentOutsideRoots(documentURL)
  }

  private static func visibleFolderCount(in node: WorkspaceNode) throws -> Int {
    try Task.checkCancellation()
    guard node.kind == .folder, let children = node.children, !children.isEmpty else {
      return 0
    }
    var count = 1
    for child in children {
      count += try visibleFolderCount(in: child)
    }
    return count
  }

  private struct FingerprintEntry {
    var relativePath: String
    var mtime: Int
    var size: Int
  }

  private enum FingerprintError: Error {
    case documentOutsideRoots(URL)
  }
}

enum BasicCacheVerdict: Equatable {
  case valid
  case staleFingerprint(stored: TreeFingerprint, current: TreeFingerprint)
  case missing

  static func evaluate(
    identity: WorkspaceIdentity,
    currentFingerprint: TreeFingerprint,
    store: WorkspaceCacheStore
  ) throws -> BasicCacheVerdict {
    guard let stored = try store.readTreeFingerprint(for: identity) else {
      return .missing
    }
    // computedAt intentionally excluded from validity comparison; hash + algorithmVersion are the truth.
    if stored.treeHash == currentFingerprint.treeHash
      && stored.algorithmVersion == currentFingerprint.algorithmVersion
    {
      return .valid
    }
    return .staleFingerprint(stored: stored, current: currentFingerprint)
  }
}

/// Immutable cache-root handle safe to share with detached validation jobs. Encoders/decoders are
/// created per operation below; Foundation coders are not shared across threads.
final class WorkspaceCacheStore: @unchecked Sendable {
  static let shared = WorkspaceCacheStore()

  private static let protectedWriteOptions: Data.WritingOptions = [
    .atomic,
    .completeFileProtection,
  ]
  private static let fallbackWriteOptions: Data.WritingOptions = [
    .atomic
  ]

  private let baseDirectory: URL

  convenience init() {
    self.init(baseDirectory: WorkspaceMetadataStore.applicationSupportDirectory())
  }

  init(baseDirectory: URL) {
    self.baseDirectory = baseDirectory
  }

  func ensureCacheRoot(for identity: WorkspaceIdentity) throws -> URL {
    let root = cacheRootURL(for: identity)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try writeIdentityIfNeeded(identity, to: root.appendingPathComponent("identity.json"))
    return root
  }

  func writeTreeFingerprint(_ fingerprint: TreeFingerprint, for identity: WorkspaceIdentity) throws
  {
    let root = try ensureCacheRoot(for: identity)
    let data = try Self.jsonEncoder().encode(fingerprint)
    try Self.writeProtected(data, to: root.appendingPathComponent("tree-fingerprint.json"))
  }

  func writeManifest(_ manifest: WorkspaceManifest, for identity: WorkspaceIdentity) throws {
    let root = try ensureCacheRoot(for: identity)
    let data = try Self.jsonEncoder().encode(manifest)
    try Self.writeProtected(data, to: root.appendingPathComponent("manifest.json"))
  }

  /// Persists the workspace's `.md` signature alongside the identity-keyed cache
  /// (`Workspaces/<workspaceID>/search-signature.json`). Written ONLY after the matching FTS
  /// index write succeeds so the persisted signature never points at an index that was not
  /// actually written. Used by the cold-open path to decide skip / incremental / full on the
  /// NEXT launch.
  func writeSearchSignature(
    _ signature: WorkspaceSignature, for identity: WorkspaceIdentity
  ) throws {
    let root = try ensureCacheRoot(for: identity)
    let data = try Self.jsonEncoder().encode(signature)
    try Self.writeProtected(data, to: root.appendingPathComponent("search-signature.json"))
  }

  /// Persists the already-built sidebar/document tree as a compact binary plist. This is the
  /// presentation cache: a relaunch can publish the last known-good workspace immediately while
  /// a fresh filesystem walk validates it in the background. Search correctness remains guarded
  /// independently by the signature + index cache.
  func writeWorkspaceScans(_ scans: [WorkspaceScan], for identity: WorkspaceIdentity) throws {
    let root = try ensureCacheRoot(for: identity)
    let data = try Self.treeEncoder().encode(scans)
    try Self.writeProtected(data, to: root.appendingPathComponent("workspace-tree.plist"))
  }

  func clearCache(for identity: WorkspaceIdentity) throws {
    let root = cacheRootURL(for: identity)
    guard FileManager.default.fileExists(atPath: root.path) else { return }
    try FileManager.default.removeItem(at: root)
  }

  func existingCacheRoot(for identity: WorkspaceIdentity) -> URL? {
    let root = cacheRootURL(for: identity)
    var isDirectory = ObjCBool(false)
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return nil
    }
    return root
  }

  func fingerprintURL(for identity: WorkspaceIdentity) -> URL {
    cacheRootURL(for: identity)
      .appendingPathComponent("tree-fingerprint.json", isDirectory: false)
  }

  func manifestURL(for identity: WorkspaceIdentity) -> URL {
    cacheRootURL(for: identity)
      .appendingPathComponent("manifest.json", isDirectory: false)
  }

  func searchSignatureURL(for identity: WorkspaceIdentity) -> URL {
    cacheRootURL(for: identity)
      .appendingPathComponent("search-signature.json", isDirectory: false)
  }

  func workspaceScansURL(for identity: WorkspaceIdentity) -> URL {
    cacheRootURL(for: identity)
      .appendingPathComponent("workspace-tree.plist", isDirectory: false)
  }

  func readTreeFingerprint(for identity: WorkspaceIdentity) throws -> TreeFingerprint? {
    guard existingCacheRoot(for: identity) != nil else {
      return nil
    }
    let url = fingerprintURL(for: identity)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(TreeFingerprint.self, from: data)
  }

  func readManifest(for identity: WorkspaceIdentity) throws -> WorkspaceManifest? {
    guard existingCacheRoot(for: identity) != nil else {
      return nil
    }
    let url = manifestURL(for: identity)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(WorkspaceManifest.self, from: data)
  }

  /// Reads the persisted `.md` signature for this workspace identity, or nil when none exists
  /// (true first run / post-reset) or it cannot be decoded (schema drift → treat as absent →
  /// full reindex; never crash). Best-effort: a decode failure is swallowed, returning nil.
  func readSearchSignature(for identity: WorkspaceIdentity) -> WorkspaceSignature? {
    guard existingCacheRoot(for: identity) != nil else {
      return nil
    }
    let url = searchSignatureURL(for: identity)
    guard FileManager.default.fileExists(atPath: url.path),
      let data = try? Data(contentsOf: url)
    else {
      return nil
    }
    return try? JSONDecoder().decode(WorkspaceSignature.self, from: data)
  }

  func readWorkspaceScans(for identity: WorkspaceIdentity) throws -> [WorkspaceScan]? {
    guard existingCacheRoot(for: identity) != nil else { return nil }
    let url = workspaceScansURL(for: identity)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    return try PropertyListDecoder().decode([WorkspaceScan].self, from: data)
  }

  private func cacheRootURL(for identity: WorkspaceIdentity) -> URL {
    baseDirectory
      .appendingPathComponent("Workspaces", isDirectory: true)
      .appendingPathComponent(identity.workspaceID, isDirectory: true)
  }

  private func writeIdentityIfNeeded(_ identity: WorkspaceIdentity, to url: URL) throws {
    let data = try Self.jsonEncoder().encode(identity)
    if let existing = try? Data(contentsOf: url), existing == data {
      return
    }
    try Self.writeProtected(data, to: url)
  }

  private static func jsonEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private static func treeEncoder() -> PropertyListEncoder {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    return encoder
  }

  private static func writeProtected(_ data: Data, to url: URL) throws {
    do {
      try data.write(to: url, options: protectedWriteOptions)
    } catch {
      NSLog(
        "%@",
        "WorkspaceCacheStore: protected write failed for \(url.lastPathComponent), "
          + "falling back to unprotected atomic write: \(error)")
      try data.write(to: url, options: fallbackWriteOptions)
    }
  }
}
