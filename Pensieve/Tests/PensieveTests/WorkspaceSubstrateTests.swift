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

  private func cacheRootURL(for identity: WorkspaceIdentity, in store: WorkspaceCacheStore) -> URL {
    store.fingerprintURL(for: identity).deletingLastPathComponent()
  }
}
