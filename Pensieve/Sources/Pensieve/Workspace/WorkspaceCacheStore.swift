import Foundation

struct TreeFingerprint: Codable, Equatable {
  var treeHash: String
  var fileCount: Int
  var folderCount: Int
  var computedAt: Date
  var algorithmVersion: Int

  static func compute(rootURL: URL, exclusions: Set<String>) throws -> TreeFingerprint {
    let root = rootURL.standardizedFileURL
    let scans = WorkspaceScanner.build(rootURLs: [root], exclusions: exclusions)
    let documents = scans.flatMap(\.documents)

    // Fingerprint v1: sorted "relativePath|mtimeSeconds|size" markdown-file tuples from WorkspaceScanner.
    let entries = try documents.map { document in
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

    return TreeFingerprint(
      treeHash: WorkspaceHash.sha256Hex(payload),
      fileCount: entries.count,
      folderCount: scans.reduce(0) { $0 + visibleFolderCount(in: $1.rootNode) },
      computedAt: Date(),
      algorithmVersion: 1
    )
  }

  private static func visibleFolderCount(in node: WorkspaceNode) -> Int {
    guard node.kind == .folder, let children = node.children, !children.isEmpty else {
      return 0
    }
    return 1 + children.reduce(0) { $0 + visibleFolderCount(in: $1) }
  }

  private struct FingerprintEntry {
    var relativePath: String
    var mtime: Int
    var size: Int
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

final class WorkspaceCacheStore {
  static let shared = WorkspaceCacheStore()

  private let baseDirectory: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  convenience init() {
    self.init(baseDirectory: WorkspaceMetadataStore.applicationSupportDirectory())
  }

  init(baseDirectory: URL) {
    self.baseDirectory = baseDirectory
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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
    let data = try encoder.encode(fingerprint)
    try data.write(to: root.appendingPathComponent("tree-fingerprint.json"), options: [.atomic])
  }

  func writeManifest(_ manifest: WorkspaceManifest, for identity: WorkspaceIdentity) throws {
    let root = try ensureCacheRoot(for: identity)
    let data = try encoder.encode(manifest)
    try data.write(to: root.appendingPathComponent("manifest.json"), options: [.atomic])
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
    let data = try encoder.encode(signature)
    try data.write(to: root.appendingPathComponent("search-signature.json"), options: [.atomic])
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

  func readTreeFingerprint(for identity: WorkspaceIdentity) throws -> TreeFingerprint? {
    guard existingCacheRoot(for: identity) != nil else {
      return nil
    }
    let url = fingerprintURL(for: identity)
    guard FileManager.default.fileExists(atPath: url.path) else {
      return nil
    }
    let data = try Data(contentsOf: url)
    return try decoder.decode(TreeFingerprint.self, from: data)
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
    return try decoder.decode(WorkspaceManifest.self, from: data)
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
    return try? decoder.decode(WorkspaceSignature.self, from: data)
  }

  private func cacheRootURL(for identity: WorkspaceIdentity) -> URL {
    baseDirectory
      .appendingPathComponent("Workspaces", isDirectory: true)
      .appendingPathComponent(identity.workspaceID, isDirectory: true)
  }

  private func writeIdentityIfNeeded(_ identity: WorkspaceIdentity, to url: URL) throws {
    let data = try encoder.encode(identity)
    if let existing = try? Data(contentsOf: url), existing == data {
      return
    }
    try data.write(to: url, options: [.atomic])
  }
}
