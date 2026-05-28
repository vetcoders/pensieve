import Foundation
import XCTest

@testable import Pensieve

final class WorkspaceSubstrateTests: XCTestCase {
  func testWorkspaceIdentityIsStableAcrossRepeatedComputations() throws {
    let root = try makeTemporaryWorkspace()
    let bookmarkData = Data("bookmark-a".utf8)

    let first = WorkspaceIdentity.make(rootURL: root, bookmarkData: bookmarkData)
    let second = WorkspaceIdentity.make(rootURL: root, bookmarkData: bookmarkData)
    let third = WorkspaceIdentity.make(rootURL: root, bookmarkData: bookmarkData)

    XCTAssertEqual(first.workspaceID, second.workspaceID)
    XCTAssertEqual(second.workspaceID, third.workspaceID)
  }

  func testWorkspaceIdentityDiffersForDifferentRoots() throws {
    let firstRoot = try makeTemporaryWorkspace()
    let secondRoot = try makeTemporaryWorkspace()
    let bookmarkData = Data("same-bookmark".utf8)

    let first = WorkspaceIdentity.make(rootURL: firstRoot, bookmarkData: bookmarkData)
    let second = WorkspaceIdentity.make(rootURL: secondRoot, bookmarkData: bookmarkData)

    XCTAssertNotEqual(first.workspaceID, second.workspaceID)
  }

  func testWorkspaceIdentityDiffersForDifferentBookmarks() throws {
    let root = try makeTemporaryWorkspace()

    let first = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark-a".utf8))
    let second = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark-b".utf8))

    XCTAssertNotEqual(first.workspaceID, second.workspaceID)
  }

  func testWorkspaceIdentityCodableRoundtripPreservesAllFields() throws {
    let root = try makeTemporaryWorkspace()
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))

    let data = try JSONEncoder().encode(identity)
    let decoded = try JSONDecoder().decode(WorkspaceIdentity.self, from: data)

    XCTAssertEqual(decoded, identity)
  }

  func testWorkspaceCacheStoreCreatesCacheRootUnderApplicationSupport() throws {
    let baseDirectory = temporaryApplicationSupportDirectory()
    let store = WorkspaceCacheStore(baseDirectory: baseDirectory)
    let identity = try makeIdentity()

    let root = try store.ensureCacheRoot(for: identity)

    XCTAssertEqual(root.deletingLastPathComponent().lastPathComponent, "Workspaces")
    XCTAssertEqual(
      root.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Pensieve")
    XCTAssertTrue(
      root.path.hasSuffix("Application Support/Pensieve/Workspaces/\(identity.workspaceID)"))
  }

  func testWorkspaceCacheStoreRoundtripsTreeFingerprint() throws {
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let identity = try makeIdentity()
    let fingerprint = TreeFingerprint(
      treeHash: "abc123",
      fileCount: 2,
      folderCount: 1,
      computedAt: Date(timeIntervalSince1970: 42),
      algorithmVersion: 1
    )

    try store.writeTreeFingerprint(fingerprint, for: identity)

    XCTAssertEqual(try store.readTreeFingerprint(for: identity), fingerprint)
  }

  func testWorkspaceCacheStoreReturnsNilForMissingFingerprint() throws {
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let identity = try makeIdentity()

    _ = try store.ensureCacheRoot(for: identity)

    XCTAssertNil(try store.readTreeFingerprint(for: identity))
  }

  func testWorkspaceCacheStoreClearRemovesCacheRoot() throws {
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let identity = try makeIdentity()
    let fingerprint = TreeFingerprint(
      treeHash: "abc123",
      fileCount: 1,
      folderCount: 1,
      computedAt: Date(timeIntervalSince1970: 1),
      algorithmVersion: 1
    )

    try store.writeTreeFingerprint(fingerprint, for: identity)
    try store.clearCache(for: identity)
    let recreatedRoot = try store.ensureCacheRoot(for: identity)

    XCTAssertTrue(FileManager.default.fileExists(atPath: recreatedRoot.path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: recreatedRoot.appendingPathComponent("identity.json").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.fingerprintURL(for: identity).path))
    XCTAssertNil(try store.readTreeFingerprint(for: identity))
  }

  func testWorkspaceCacheStoreReadDoesNotCreateCacheRoot() throws {
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let identity = try makeIdentity()
    let expectedRoot = cacheRootURL(for: identity, in: store)

    XCTAssertNil(try store.readTreeFingerprint(for: identity))
    XCTAssertNil(store.existingCacheRoot(for: identity))
    XCTAssertFalse(FileManager.default.fileExists(atPath: expectedRoot.path))
  }

  func testWorkspaceCacheStoreDoesNotWriteInsideUserWorkspace() throws {
    let userWorkspace = try makeTemporaryWorkspace()
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let identity = WorkspaceIdentity.make(
      rootURL: userWorkspace, bookmarkData: Data("bookmark".utf8))
    let fingerprint = TreeFingerprint(
      treeHash: "abc123",
      fileCount: 0,
      folderCount: 0,
      computedAt: Date(timeIntervalSince1970: 1),
      algorithmVersion: 1
    )

    _ = try store.ensureCacheRoot(for: identity)
    try store.writeTreeFingerprint(fingerprint, for: identity)

    let workspaceEntries = try FileManager.default.contentsOfDirectory(
      at: userWorkspace,
      includingPropertiesForKeys: nil
    )
    XCTAssertTrue(workspaceEntries.isEmpty)
  }

  func testWorkspaceCacheStoreUsesIdentityJSONFile() throws {
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let identity = try makeIdentity()

    let root = try store.ensureCacheRoot(for: identity)
    let data = try Data(contentsOf: root.appendingPathComponent("identity.json"))
    let decoded = try JSONDecoder().decode(WorkspaceIdentity.self, from: data)

    XCTAssertEqual(decoded, identity)
  }

  func testWorkspaceManifestRoundtripsCodableExactly() throws {
    let root = try makeTemporaryWorkspace()
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let manifest = sampleManifest(identity: identity, root: root)

    let data = try JSONEncoder().encode(manifest)
    let decoded = try JSONDecoder().decode(WorkspaceManifest.self, from: data)

    XCTAssertEqual(decoded, manifest)
  }

  func testWorkspaceManifestFreshCommitCarriesFingerprintAndCounts() throws {
    let root = try makeTemporaryWorkspace()
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let fingerprint = TreeFingerprint(
      treeHash: "fresh",
      fileCount: 7,
      folderCount: 3,
      computedAt: Date(timeIntervalSince1970: 100),
      algorithmVersion: 1
    )

    let manifest = WorkspaceManifest.makeForFreshCommit(
      identity: identity,
      roots: [root],
      exclusions: ["Zeta", "Alpha"],
      fingerprint: fingerprint,
      scannerVersion: 2,
      cacheSchemaVersion: 3,
      now: Date(timeIntervalSince1970: 200)
    )

    XCTAssertEqual(manifest.workspaceID, identity.workspaceID)
    XCTAssertEqual(manifest.roots, [root.standardizedFileURL])
    XCTAssertEqual(manifest.exclusions, ["Alpha", "Zeta"])
    XCTAssertEqual(manifest.scannerVersion, 2)
    XCTAssertEqual(manifest.cacheSchemaVersion, 3)
    XCTAssertEqual(manifest.fileCount, 7)
    XCTAssertEqual(manifest.folderCount, 3)
    XCTAssertEqual(manifest.lastFullScanAt, Date(timeIntervalSince1970: 200))
    XCTAssertNil(manifest.lastIncrementalScanAt)
    XCTAssertEqual(manifest.treeFingerprint, fingerprint)
  }

  func testWorkspaceManifestEncodingIsStableAcrossRuns() throws {
    let root = try makeTemporaryWorkspace()
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let manifest = sampleManifest(identity: identity, root: root)

    try store.writeManifest(manifest, for: identity)
    let first = try Data(contentsOf: store.manifestURL(for: identity))
    try store.writeManifest(manifest, for: identity)
    let second = try Data(contentsOf: store.manifestURL(for: identity))

    XCTAssertEqual(first, second)
  }

  func testCacheStoreManifestRoundtrips() throws {
    let root = try makeTemporaryWorkspace()
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let manifest = sampleManifest(identity: identity, root: root)

    try store.writeManifest(manifest, for: identity)

    XCTAssertEqual(try store.readManifest(for: identity), manifest)
  }

  func testCacheStoreReadManifestReturnsNilWhenAbsent() throws {
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let identity = try makeIdentity()

    _ = try store.ensureCacheRoot(for: identity)

    XCTAssertNil(try store.readManifest(for: identity))
  }

  func testCacheStoreReadManifestDoesNotCreateCacheRoot() throws {
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let identity = try makeIdentity()
    let expectedRoot = cacheRootURL(for: identity, in: store)

    XCTAssertNil(try store.readManifest(for: identity))
    XCTAssertNil(store.existingCacheRoot(for: identity))
    XCTAssertFalse(FileManager.default.fileExists(atPath: expectedRoot.path))
  }

  func testCacheStoreManifestSurvivesClearCache() throws {
    let root = try makeTemporaryWorkspace()
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())

    try store.writeManifest(sampleManifest(identity: identity, root: root), for: identity)
    try store.clearCache(for: identity)
    _ = try store.ensureCacheRoot(for: identity)

    XCTAssertNil(try store.readManifest(for: identity))
  }

  func testTreeFingerprintIsStableForUnchangedTree() throws {
    let root = try makeTemporaryWorkspace()
    _ = try writeFile("alpha", named: "alpha.md", in: root)

    let first = try TreeFingerprint.compute(rootURL: root, exclusions: [])
    let second = try TreeFingerprint.compute(rootURL: root, exclusions: [])

    XCTAssertEqual(first.treeHash, second.treeHash)
    XCTAssertEqual(first.fileCount, second.fileCount)
    XCTAssertEqual(first.folderCount, second.folderCount)
    XCTAssertEqual(first.algorithmVersion, second.algorithmVersion)
  }

  func testTreeFingerprintChangesAfterFileAdded() throws {
    let root = try makeTemporaryWorkspace()
    _ = try writeFile("alpha", named: "alpha.md", in: root)
    let before = try TreeFingerprint.compute(rootURL: root, exclusions: [])

    _ = try writeFile("beta", named: "beta.markdown", in: root)
    let after = try TreeFingerprint.compute(rootURL: root, exclusions: [])

    XCTAssertNotEqual(before.treeHash, after.treeHash)
    XCTAssertEqual(after.fileCount, before.fileCount + 1)
  }

  func testTreeFingerprintChangesAfterFileContentChange() throws {
    let root = try makeTemporaryWorkspace()
    let file = try writeFile("alpha", named: "alpha.md", in: root)
    let before = try TreeFingerprint.compute(rootURL: root, exclusions: [])

    try "alpha with more bytes".write(to: file, atomically: true, encoding: .utf8)
    let after = try TreeFingerprint.compute(rootURL: root, exclusions: [])

    XCTAssertNotEqual(before.treeHash, after.treeHash)
    XCTAssertEqual(before.fileCount, after.fileCount)
  }

  func testTreeFingerprintChangesAfterFileDeleted() throws {
    let root = try makeTemporaryWorkspace()
    _ = try writeFile("alpha", named: "alpha.md", in: root)
    let deleted = try writeFile("beta", named: "beta.md", in: root)
    let before = try TreeFingerprint.compute(rootURL: root, exclusions: [])

    try FileManager.default.removeItem(at: deleted)
    let after = try TreeFingerprint.compute(rootURL: root, exclusions: [])

    XCTAssertNotEqual(before.treeHash, after.treeHash)
    XCTAssertEqual(after.fileCount, before.fileCount - 1)
  }

  func testTreeFingerprintRespectsExclusions() throws {
    let root = try makeTemporaryWorkspace()
    _ = try writeFile("alpha", named: "alpha.md", in: root)
    let excluded = root.appendingPathComponent("Drafts", isDirectory: true)
    try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)

    let before = try TreeFingerprint.compute(rootURL: root, exclusions: ["Drafts"])
    _ = try writeFile("beta", named: "beta.md", in: excluded)
    let after = try TreeFingerprint.compute(rootURL: root, exclusions: ["Drafts"])

    XCTAssertEqual(before.treeHash, after.treeHash)
    XCTAssertEqual(before.fileCount, after.fileCount)
  }

  func testTreeFingerprintRoundtripsCodable() throws {
    let fingerprint = TreeFingerprint(
      treeHash: "abc123",
      fileCount: 2,
      folderCount: 1,
      computedAt: Date(timeIntervalSince1970: 42),
      algorithmVersion: 1
    )

    let data = try JSONEncoder().encode(fingerprint)
    let decoded = try JSONDecoder().decode(TreeFingerprint.self, from: data)

    XCTAssertEqual(decoded, fingerprint)
  }

  func testBasicCacheVerdictMissingForFreshIdentity() throws {
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let identity = try makeIdentity()
    let current = TreeFingerprint(
      treeHash: "current",
      fileCount: 1,
      folderCount: 1,
      computedAt: Date(timeIntervalSince1970: 1),
      algorithmVersion: 1
    )
    let expectedRoot = cacheRootURL(for: identity, in: store)

    let verdict = try BasicCacheVerdict.evaluate(
      identity: identity,
      currentFingerprint: current,
      store: store
    )

    XCTAssertEqual(verdict, .missing)
    XCTAssertFalse(FileManager.default.fileExists(atPath: expectedRoot.path))
  }

  func testBasicCacheVerdictValidWhenFingerprintMatches() throws {
    let root = try makeTemporaryWorkspace()
    _ = try writeFile("alpha", named: "alpha.md", in: root)
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let stored = try TreeFingerprint.compute(rootURL: root, exclusions: [])

    try store.writeTreeFingerprint(stored, for: identity)

    let current = TreeFingerprint(
      treeHash: stored.treeHash,
      fileCount: stored.fileCount,
      folderCount: stored.folderCount,
      computedAt: stored.computedAt.addingTimeInterval(60),
      algorithmVersion: stored.algorithmVersion
    )

    XCTAssertEqual(
      try BasicCacheVerdict.evaluate(identity: identity, currentFingerprint: current, store: store),
      .valid
    )
  }

  func testBasicCacheVerdictStaleWhenFingerprintDiffers() throws {
    let root = try makeTemporaryWorkspace()
    let file = try writeFile("alpha", named: "alpha.md", in: root)
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let stored = try TreeFingerprint.compute(rootURL: root, exclusions: [])

    try store.writeTreeFingerprint(stored, for: identity)
    try "alpha with more bytes".write(to: file, atomically: true, encoding: .utf8)
    let current = try TreeFingerprint.compute(rootURL: root, exclusions: [])

    let verdict = try BasicCacheVerdict.evaluate(
      identity: identity,
      currentFingerprint: current,
      store: store
    )

    guard case .staleFingerprint(let storedVerdict, let currentVerdict) = verdict else {
      return XCTFail("Expected stale fingerprint verdict, got \(verdict)")
    }
    XCTAssertNotEqual(storedVerdict.treeHash, currentVerdict.treeHash)
  }

  func testSubstrateValidateAndCommitRoundtrip() throws {
    let root = try makeTemporaryWorkspace()
    _ = try writeFile("alpha", named: "alpha.md", in: root)
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let substrate = WorkspaceSubstrate(store: store)
    let fingerprint = try TreeFingerprint.compute(rootURL: root, exclusions: [])

    XCTAssertEqual(
      try substrate.validate(identity: identity, currentRoots: [root], currentExclusions: []),
      .missing
    )

    let manifest = try substrate.commit(
      identity: identity,
      roots: [root],
      exclusions: [],
      fingerprint: fingerprint,
      now: Date(timeIntervalSince1970: 500)
    )

    XCTAssertEqual(
      try substrate.validate(identity: identity, currentRoots: [root], currentExclusions: []),
      .valid(manifest)
    )
  }

  func testSubstrateCommitWritesManifestUnderApplicationSupport() throws {
    let root = try makeTemporaryWorkspace()
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let substrate = WorkspaceSubstrate(store: store)
    let fingerprint = TreeFingerprint(
      treeHash: "commit",
      fileCount: 1,
      folderCount: 0,
      computedAt: Date(timeIntervalSince1970: 1),
      algorithmVersion: 1
    )

    _ = try substrate.commit(
      identity: identity, roots: [root], exclusions: [], fingerprint: fingerprint)

    XCTAssertTrue(FileManager.default.fileExists(atPath: store.manifestURL(for: identity).path))
    XCTAssertEqual(try store.readManifest(for: identity)?.treeFingerprint, fingerprint)
  }

  func testSubstrateMarkFailureRecordsTimestamp() throws {
    let root = try makeTemporaryWorkspace()
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let substrate = WorkspaceSubstrate(store: store)

    try substrate.markFailure(
      identity: identity,
      kind: "manifestCorrupted",
      now: Date(timeIntervalSince1970: 900)
    )

    let manifest = try XCTUnwrap(store.readManifest(for: identity))
    XCTAssertEqual(manifest.lastFailureAt, Date(timeIntervalSince1970: 900))
    XCTAssertEqual(manifest.lastFailureKind, "manifestCorrupted")
  }

  func testSubstrateValidateProducesValidVerdict() throws {
    let root = try makeTemporaryWorkspace()
    _ = try writeFile("alpha", named: "alpha.md", in: root)
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let substrate = WorkspaceSubstrate(store: store)
    let fingerprint = try TreeFingerprint.compute(rootURL: root, exclusions: [])
    let manifest = try substrate.commit(
      identity: identity, roots: [root], exclusions: [], fingerprint: fingerprint)

    XCTAssertEqual(
      try substrate.validate(identity: identity, currentRoots: [root], currentExclusions: []),
      .valid(manifest)
    )
  }

  func testSubstrateValidateProducesRootMovedVerdict() throws {
    let root = try makeTemporaryWorkspace()
    let movedRoot = try makeTemporaryWorkspace()
    _ = try writeFile("alpha", named: "alpha.md", in: movedRoot)
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let substrate = WorkspaceSubstrate(store: store)
    try store.writeManifest(sampleManifest(identity: identity, root: root), for: identity)

    let verdict = try substrate.validate(
      identity: identity, currentRoots: [movedRoot], currentExclusions: [])

    guard case .stale(.rootMoved, let storedManifest, _) = verdict else {
      return XCTFail("Expected rootMoved, got \(verdict)")
    }
    XCTAssertNil(storedManifest)
  }

  func testSubstrateValidateProducesBookmarkExpiredVerdict() throws {
    let root = try makeTemporaryWorkspace()
    _ = try writeFile("alpha", named: "alpha.md", in: root)
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let substrate = WorkspaceSubstrate(
      store: store,
      bookmarkStatus: { _, _ in .expiredButDirectPathAccessible }
    )
    try store.writeManifest(sampleManifest(identity: identity, root: root), for: identity)

    let verdict = try substrate.validate(
      identity: identity, currentRoots: [root], currentExclusions: [])

    guard case .stale(.bookmarkExpired, let storedManifest, _) = verdict else {
      return XCTFail("Expected bookmarkExpired, got \(verdict)")
    }
    XCTAssertNil(storedManifest)
  }

  func testSubstrateValidateProducesManifestSchemaBumpedVerdict() throws {
    let root = try makeTemporaryWorkspace()
    _ = try writeFile("alpha", named: "alpha.md", in: root)
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let substrate = WorkspaceSubstrate(store: store, scannerVersion: 2)
    try store.writeManifest(sampleManifest(identity: identity, root: root), for: identity)

    let verdict = try substrate.validate(
      identity: identity, currentRoots: [root], currentExclusions: [])

    guard case .stale(.manifestSchemaBumped, _, _) = verdict else {
      return XCTFail("Expected manifestSchemaBumped, got \(verdict)")
    }
  }

  func testSubstrateValidateProducesFileEvidenceChangedVerdict() throws {
    let root = try makeTemporaryWorkspace()
    let file = try writeFile("alpha", named: "alpha.md", in: root)
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let substrate = WorkspaceSubstrate(store: store)
    let fingerprint = try TreeFingerprint.compute(rootURL: root, exclusions: [])
    _ = try substrate.commit(
      identity: identity, roots: [root], exclusions: [], fingerprint: fingerprint)

    try "alpha with more bytes".write(to: file, atomically: true, encoding: .utf8)
    let verdict = try substrate.validate(
      identity: identity, currentRoots: [root], currentExclusions: [])

    guard
      case .stale(.fileEvidenceChanged, let storedManifest, let currentFingerprint) = verdict
    else {
      return XCTFail("Expected fileEvidenceChanged, got \(verdict)")
    }
    XCTAssertNotEqual(storedManifest?.treeFingerprint.treeHash, currentFingerprint.treeHash)
  }

  func testSubstrateValidateProducesExclusionsChangedVerdict() throws {
    let root = try makeTemporaryWorkspace()
    _ = try writeFile("alpha", named: "alpha.md", in: root)
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let substrate = WorkspaceSubstrate(store: store)
    let fingerprint = try TreeFingerprint.compute(rootURL: root, exclusions: [])
    _ = try substrate.commit(
      identity: identity, roots: [root], exclusions: [], fingerprint: fingerprint)

    let verdict = try substrate.validate(
      identity: identity, currentRoots: [root], currentExclusions: ["Drafts"])

    guard case .stale(.exclusionsChanged, let storedManifest, _) = verdict else {
      return XCTFail("Expected exclusionsChanged, got \(verdict)")
    }
    XCTAssertNil(storedManifest)
  }

  func testSubstrateValidateProducesIncompatibleSchemaVerdict() throws {
    let root = try makeTemporaryWorkspace()
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let substrate = WorkspaceSubstrate(store: store)
    var manifest = sampleManifest(identity: identity, root: root)
    manifest.cacheSchemaVersion = 0
    try store.writeManifest(manifest, for: identity)

    XCTAssertEqual(
      try substrate.validate(identity: identity, currentRoots: [root], currentExclusions: []),
      .incompatibleSchema(storedCacheSchemaVersion: 0, expectedCacheSchemaVersion: 1)
    )
  }

  func testSubstrateValidateProducesMissingVerdict() throws {
    let root = try makeTemporaryWorkspace()
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let substrate = WorkspaceSubstrate(
      store: WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory()))

    XCTAssertEqual(
      try substrate.validate(identity: identity, currentRoots: [root], currentExclusions: []),
      .missing
    )
  }

  func testSubstrateValidateProducesCorruptedVerdict() throws {
    let root = try makeTemporaryWorkspace()
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    _ = try store.ensureCacheRoot(for: identity)
    try Data("{ not json".utf8).write(to: store.manifestURL(for: identity), options: [.atomic])
    let substrate = WorkspaceSubstrate(store: store)

    let verdict = try substrate.validate(
      identity: identity, currentRoots: [root], currentExclusions: [])

    guard case .corrupted(let error) = verdict else {
      return XCTFail("Expected corrupted, got \(verdict)")
    }
    XCTAssertFalse(error.isEmpty)
  }

  func testSubstrateValidateProducesAccessDeniedVerdict() throws {
    let root = try makeTemporaryWorkspace()
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    try store.writeManifest(sampleManifest(identity: identity, root: root), for: identity)
    try FileManager.default.removeItem(at: root)
    let substrate = WorkspaceSubstrate(store: store)

    let verdict = try substrate.validate(
      identity: identity, currentRoots: [root], currentExclusions: [])

    guard case .accessDenied(let reason) = verdict else {
      return XCTFail("Expected accessDenied, got \(verdict)")
    }
    XCTAssertFalse(reason.isEmpty)
  }

  func testSubstrateValidateOrderingProducesCorrectStaleReason() throws {
    let root = try makeTemporaryWorkspace()
    let movedRoot = try makeTemporaryWorkspace()
    _ = try writeFile("alpha", named: "alpha.md", in: movedRoot)
    let identity = WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
    let store = WorkspaceCacheStore(baseDirectory: temporaryApplicationSupportDirectory())
    let substrate = WorkspaceSubstrate(store: store)
    try store.writeManifest(sampleManifest(identity: identity, root: root), for: identity)

    let verdict = try substrate.validate(
      identity: identity,
      currentRoots: [movedRoot],
      currentExclusions: ["Drafts"]
    )

    guard case .stale(.exclusionsChanged, _, _) = verdict else {
      return XCTFail("Expected exclusionsChanged before rootMoved, got \(verdict)")
    }
  }

  func testWorkspaceActivityFactoriesProduceConsistentTitleDetail() {
    XCTAssertEqual(
      WorkspaceActivity.checkingCache("Notes"),
      WorkspaceActivity(
        title: "Checking Workspace Cache",
        detail: "Validating Notes",
        progress: 0.05
      )
    )
    XCTAssertEqual(
      WorkspaceActivity.cacheHit("Notes"),
      WorkspaceActivity(
        title: "Opening Cached Workspace",
        detail: "Using cached state for Notes",
        progress: 0.92
      )
    )
    XCTAssertEqual(
      WorkspaceActivity.cacheMiss("Notes"),
      WorkspaceActivity(
        title: "Importing Workspace",
        detail: "Cache miss for Notes",
        progress: 0.1
      )
    )
  }

  private func makeIdentity() throws -> WorkspaceIdentity {
    let root = try makeTemporaryWorkspace()
    return WorkspaceIdentity.make(rootURL: root, bookmarkData: Data("bookmark".utf8))
  }

  private func makeTemporaryWorkspace() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveWorkspaceSubstrateTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: folder)
    }
    return folder
  }

  private func temporaryApplicationSupportDirectory() -> URL {
    let testRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveWorkspaceSubstrateTests-\(UUID().uuidString)", isDirectory: true)
    let directory =
      testRoot
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent("Pensieve", isDirectory: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: testRoot)
    }
    return directory
  }

  private func writeFile(_ contents: String, named name: String, in directory: URL) throws -> URL {
    let file = directory.appendingPathComponent(name, isDirectory: false)
    try contents.write(to: file, atomically: true, encoding: .utf8)
    return file
  }

  private func sampleManifest(identity: WorkspaceIdentity, root: URL) -> WorkspaceManifest {
    let fingerprint = TreeFingerprint(
      treeHash: "sample",
      fileCount: 2,
      folderCount: 1,
      computedAt: Date(timeIntervalSince1970: 42),
      algorithmVersion: 1
    )
    return WorkspaceManifest(
      workspaceID: identity.workspaceID,
      roots: [root.standardizedFileURL],
      exclusions: [],
      scannerVersion: 1,
      cacheSchemaVersion: 1,
      fileCount: 2,
      folderCount: 1,
      lastFullScanAt: Date(timeIntervalSince1970: 50),
      lastIncrementalScanAt: nil,
      treeFingerprint: fingerprint,
      lastFailureAt: nil,
      lastFailureKind: nil
    )
  }

  private func cacheRootURL(for identity: WorkspaceIdentity, in store: WorkspaceCacheStore) -> URL {
    store.fingerprintURL(for: identity).deletingLastPathComponent()
  }
}
