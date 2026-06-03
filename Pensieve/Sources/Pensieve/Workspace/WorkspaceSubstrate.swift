import Foundation

enum StaleReason: Equatable, Hashable, CaseIterable {
  case rootMoved
  case bookmarkExpired
  case manifestSchemaBumped
  case fileEvidenceChanged
  case exclusionsChanged
}

enum WorkspaceCacheVerdict: Equatable {
  case valid(WorkspaceManifest)
  case stale(
    StaleReason,
    storedManifest: WorkspaceManifest?,
    currentFingerprint: TreeFingerprint
  )
  case incompatibleSchema(storedCacheSchemaVersion: Int, expectedCacheSchemaVersion: Int)
  case missing
  case corrupted(error: String)
  case accessDenied(reason: String)
}

enum WorkspaceBookmarkStatus {
  case resolved
  case expiredButDirectPathAccessible
}

final class WorkspaceSubstrate {
  static let shared = WorkspaceSubstrate()

  let store: WorkspaceCacheStore
  private let scannerVersion: Int
  private let cacheSchemaVersion: Int
  private let bookmarkStatus: (WorkspaceIdentity, [URL]) -> WorkspaceBookmarkStatus

  init(
    store: WorkspaceCacheStore = .shared,
    scannerVersion: Int = 1,
    cacheSchemaVersion: Int = 1,
    bookmarkStatus: @escaping (WorkspaceIdentity, [URL]) -> WorkspaceBookmarkStatus = { _, _ in
      .resolved
    }
  ) {
    self.store = store
    self.scannerVersion = scannerVersion
    self.cacheSchemaVersion = cacheSchemaVersion
    self.bookmarkStatus = bookmarkStatus
  }

  func validate(
    identity: WorkspaceIdentity,
    currentRoots: [URL],
    currentExclusions: Set<String>
  ) throws -> WorkspaceCacheVerdict {
    try validate(
      identity: identity,
      currentRoots: currentRoots,
      currentExclusions: currentExclusions,
      precomputedFingerprint: nil
    )
  }

  /// Same verdict logic as `validate(identity:currentRoots:currentExclusions:)` but lets the
  /// caller supply an ALREADY-COMPUTED `TreeFingerprint` instead of re-walking the filesystem.
  /// The cold-open path walks the tree exactly once (via `workspaceBuilder`) and derives the
  /// fingerprint from that single walk (`TreeFingerprint.compute(from:root:)`); passing it here
  /// lets the cold-start skip-gate consult the SAME substrate verdict (schema / scanner /
  /// exclusions / roots / bookmark / file-evidence checks) without the substrate doing its own
  /// second walk. When `precomputedFingerprint` is `nil` the substrate computes it itself (the
  /// original behavior), so every existing caller is unchanged.
  func validate(
    identity: WorkspaceIdentity,
    currentRoots: [URL],
    currentExclusions: Set<String>,
    precomputedFingerprint: TreeFingerprint?
  ) throws -> WorkspaceCacheVerdict {
    guard currentRoots.count == 1 else {
      return .accessDenied(reason: "multi-root not supported in B-1b")
    }

    let manifest: WorkspaceManifest
    do {
      guard let loadedManifest = try store.readManifest(for: identity) else {
        return .missing
      }
      manifest = loadedManifest
    } catch {
      return .corrupted(error: error.localizedDescription)
    }

    guard manifest.workspaceID == identity.workspaceID else {
      return .corrupted(error: "manifest workspaceID does not match identity")
    }

    if manifest.cacheSchemaVersion != cacheSchemaVersion {
      return .incompatibleSchema(
        storedCacheSchemaVersion: manifest.cacheSchemaVersion,
        expectedCacheSchemaVersion: cacheSchemaVersion
      )
    }

    let root = currentRoots[0].standardizedFileURL
    guard Self.isReachableDirectory(root) else {
      return .accessDenied(reason: "workspace root is not reachable: \(root.path)")
    }

    let currentFingerprint =
      try precomputedFingerprint
      ?? TreeFingerprint.compute(rootURL: root, exclusions: currentExclusions)

    // Diagnostic order is pinned by tests: schema, scanner, exclusions, roots,
    // bookmark, file evidence, then valid.
    if manifest.scannerVersion != scannerVersion {
      return .stale(
        .manifestSchemaBumped, storedManifest: nil, currentFingerprint: currentFingerprint)
    }

    if manifest.exclusions != currentExclusions.sorted() {
      return .stale(
        .exclusionsChanged, storedManifest: nil, currentFingerprint: currentFingerprint)
    }

    if manifest.roots.map(\.standardizedFileURL) != [root] {
      return .stale(.rootMoved, storedManifest: nil, currentFingerprint: currentFingerprint)
    }

    if bookmarkStatus(identity, currentRoots) == .expiredButDirectPathAccessible {
      return .stale(.bookmarkExpired, storedManifest: nil, currentFingerprint: currentFingerprint)
    }

    if manifest.treeFingerprint.treeHash != currentFingerprint.treeHash
      || manifest.treeFingerprint.algorithmVersion != currentFingerprint.algorithmVersion
    {
      return .stale(
        .fileEvidenceChanged,
        storedManifest: manifest,
        currentFingerprint: currentFingerprint
      )
    }

    return .valid(manifest)
  }

  func open(
    identity: WorkspaceIdentity,
    currentRoots: [URL],
    currentExclusions: Set<String>
  ) throws -> WorkspaceCacheVerdict {
    try validate(
      identity: identity,
      currentRoots: currentRoots,
      currentExclusions: currentExclusions,
      precomputedFingerprint: nil
    )
  }

  /// `open` variant fed a fingerprint computed from the cold-open's single tree walk, so the
  /// cold-start skip-gate reuses the substrate verdict without a second walk. See the matching
  /// `validate(...:precomputedFingerprint:)`.
  func open(
    identity: WorkspaceIdentity,
    currentRoots: [URL],
    currentExclusions: Set<String>,
    precomputedFingerprint: TreeFingerprint?
  ) throws -> WorkspaceCacheVerdict {
    try validate(
      identity: identity,
      currentRoots: currentRoots,
      currentExclusions: currentExclusions,
      precomputedFingerprint: precomputedFingerprint
    )
  }

  func commit(
    identity: WorkspaceIdentity,
    roots: [URL],
    exclusions: Set<String>,
    fingerprint: TreeFingerprint,
    now: Date = Date()
  ) throws -> WorkspaceManifest {
    let manifest = WorkspaceManifest.makeForFreshCommit(
      identity: identity,
      roots: roots,
      exclusions: exclusions.sorted(),
      fingerprint: fingerprint,
      scannerVersion: scannerVersion,
      cacheSchemaVersion: cacheSchemaVersion,
      now: now
    )
    try store.writeManifest(manifest, for: identity)
    try store.writeTreeFingerprint(fingerprint, for: identity)
    return manifest
  }

  func markFailure(identity: WorkspaceIdentity, kind: String, now: Date = Date()) throws {
    var manifest =
      (try? store.readManifest(for: identity))
      ?? WorkspaceManifest(
        workspaceID: identity.workspaceID,
        roots: [identity.canonicalRootURL.standardizedFileURL],
        exclusions: [],
        scannerVersion: scannerVersion,
        cacheSchemaVersion: cacheSchemaVersion,
        fileCount: 0,
        folderCount: 0,
        lastFullScanAt: now,
        lastIncrementalScanAt: nil,
        treeFingerprint: TreeFingerprint(
          treeHash: "failure-only",
          fileCount: 0,
          folderCount: 0,
          computedAt: now,
          algorithmVersion: 1
        ),
        lastFailureAt: nil,
        lastFailureKind: nil
      )
    manifest.lastFailureAt = now
    manifest.lastFailureKind = kind
    try store.writeManifest(manifest, for: identity)
  }

  private static func isReachableDirectory(_ url: URL) -> Bool {
    var isDirectory = ObjCBool(false)
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}
