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

enum WorkspaceValidationStage: String, CaseIterable, Hashable, Sendable {
  case workspaceScan
  case treeFingerprint
  case substrateValidation
  case searchSignature
}

struct WorkspaceValidationResult: @unchecked Sendable {
  var scans: [WorkspaceScan]
  var fingerprint: TreeFingerprint?
  var verdict: WorkspaceCacheVerdict?
  /// Baseline to restore on a valid skip: the PERSISTED `.md` signature when one exists (it
  /// matches the live index), else the freshly stated one.
  var searchSignature: WorkspaceSignature?
  /// The `.md` signature of the tree that was just walked. This is the one a cold reindex must
  /// diff against the persisted baseline — using `searchSignature` there compares the persisted
  /// signature with itself and reports an empty delta for a genuinely changed workspace.
  var currentSignature: WorkspaceSignature?
}

/// Immutable validation configuration shared with detached open jobs. The cache store is itself
/// thread-safe (operation-local coders), and the bookmark callback is explicitly Sendable.
final class WorkspaceSubstrate: @unchecked Sendable {
  typealias ValidationProbe = @Sendable (WorkspaceValidationStage) -> Void

  static let shared = WorkspaceSubstrate()

  let store: WorkspaceCacheStore
  private let scannerVersion: Int
  private let cacheSchemaVersion: Int
  private let bookmarkStatus: @Sendable (WorkspaceIdentity, [URL]) -> WorkspaceBookmarkStatus

  init(
    store: WorkspaceCacheStore = .shared,
    scannerVersion: Int = 1,
    cacheSchemaVersion: Int = 1,
    bookmarkStatus: @escaping @Sendable (WorkspaceIdentity, [URL]) -> WorkspaceBookmarkStatus = {
      _, _ in
      .resolved
    }
  ) {
    self.store = store
    self.scannerVersion = scannerVersion
    self.cacheSchemaVersion = cacheSchemaVersion
    self.bookmarkStatus = bookmarkStatus
  }

  /// Starts the sole background-open validation path without waiting for a main-actor scheduling
  /// turn. One detached job owns the real tree walk, derives both cache evidence values from that
  /// walk, and evaluates the substrate without a fallback traversal. The caller owns/cancels the
  /// returned task; scanner cancellation is thrown, never converted into a complete result.
  func startValidation(
    identity: WorkspaceIdentity,
    currentRoots: [URL],
    currentExclusions: Set<String>,
    workspaceBuilder: @escaping WorkspaceScanner.Builder,
    persistPresentationCache: Bool,
    probe: @escaping ValidationProbe = { _ in }
  ) -> Task<WorkspaceValidationResult, Error> {
    Task.detached(priority: .userInitiated) { [self] in
      try Task.checkCancellation()
      probe(.workspaceScan)
      let scans = workspaceBuilder(currentRoots, currentExclusions)
      try Task.checkCancellation()
      DebugTrace.log("workspace validation walk.count=1 roots=\(currentRoots.count)")

      probe(.treeFingerprint)
      let fingerprint: TreeFingerprint?
      do {
        fingerprint = try TreeFingerprint.compute(from: scans, roots: currentRoots)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // A file can disappear between enumeration and stat. Keep the complete scan for the
        // cold-index fallback, but do not manufacture a cache verdict without file evidence.
        fingerprint = nil
      }
      try Task.checkCancellation()

      let verdict: WorkspaceCacheVerdict?
      if let fingerprint {
        probe(.substrateValidation)
        verdict = try open(
          identity: identity,
          currentRoots: currentRoots,
          currentExclusions: currentExclusions,
          precomputedFingerprint: fingerprint
        )
      } else {
        verdict = nil
      }
      try Task.checkCancellation()

      probe(.searchSignature)
      // One stat pass over the walked documents, off the main actor, feeding BOTH roles: the
      // freshly measured signature (what the reindex diffs) and the baseline the valid-skip
      // path restores (the persisted one when it exists — it matches the live index).
      let currentSignature = FolderManager.signature(from: scans)
      let searchSignature = store.readSearchSignature(for: identity) ?? currentSignature
      try Task.checkCancellation()

      if persistPresentationCache, case .valid = verdict {
        do {
          try store.writeWorkspaceScans(scans, for: identity)
        } catch {
          // Optional acceleration artifact: the manifest/index verdict remains authoritative.
          NSLog("%@", "Presentation cache migration failed: \(error)")
        }
      }

      return WorkspaceValidationResult(
        scans: scans,
        fingerprint: fingerprint,
        verdict: verdict,
        searchSignature: searchSignature,
        currentSignature: currentSignature
      )
    }
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
    guard !currentRoots.isEmpty else {
      return .accessDenied(reason: "workspace requires at least one root")
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

    // Reachability: EVERY root must be a reachable directory. Iterating in the
    // caller's order and naming the first unreachable root keeps the single-root
    // diagnostic message byte-identical to the pre-multi-root behavior.
    let standardizedRoots = currentRoots.map(\.standardizedFileURL)
    for root in standardizedRoots where !Self.isReachableDirectory(root) {
      return .accessDenied(reason: "workspace root is not reachable: \(root.path)")
    }

    let currentFingerprint =
      try precomputedFingerprint
      ?? TreeFingerprint.compute(roots: currentRoots, exclusions: currentExclusions)

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

    // Root-SET comparison over standardized paths, canonicalized by path order:
    // adding / removing / moving a root is `.rootMoved`; a pure reorder is NOT.
    // Matches TreeFingerprint.canonicalRootOrder so the two never disagree.
    let storedRoots = manifest.roots.map(\.standardizedFileURL).sorted { $0.path < $1.path }
    let comparedRoots = standardizedRoots.sorted { $0.path < $1.path }
    if storedRoots != comparedRoots {
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
        roots: identity.canonicalRootURLs.isEmpty
          ? [identity.canonicalRootURL.standardizedFileURL]
          : identity.canonicalRootURLs.map(\.standardizedFileURL),
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
