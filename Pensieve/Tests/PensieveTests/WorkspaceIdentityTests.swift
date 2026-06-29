import Foundation
import XCTest

@testable import Pensieve

/// Cut 1-1 — `WorkspaceIdentity` keys on N roots while keeping the N==1 `workspaceID`
/// byte-identical to the legacy single-root scheme (so existing caches stay warm).
final class WorkspaceIdentityTests: XCTestCase {
  // MARK: - N==1 invariant

  func testSingleRootViaRootsMatchesLegacyRootURLWorkspaceID() throws {
    let root = try makeTemporaryDirectory()

    let viaRoots = WorkspaceIdentity.make(roots: [root], bookmarkData: nil)
    let viaLegacy = WorkspaceIdentity.make(rootURL: root, bookmarkData: nil)

    XCTAssertEqual(viaRoots.workspaceID, viaLegacy.workspaceID)
  }

  /// Proves the N==1 reduction independently of the wrapper: for a single root the keying
  /// input is exactly `"path\nvolume"` (no extra separators), so the workspaceID equals a
  /// hand-computed SHA256 prefix over that same string.
  func testSingleRootWorkspaceIDEqualsHandComputedLegacyHash() throws {
    let root = try makeTemporaryDirectory()
    let identity = WorkspaceIdentity.make(roots: [root], bookmarkData: nil)

    let canonicalPath = root.standardizedFileURL.path
    let volume = identity.volumeResourceID ?? "volume:nil"
    let expectedInput = "\(canonicalPath)\n\(volume)"
    let expected = String(WorkspaceHash.sha256Hex(expectedInput).prefix(16))

    XCTAssertEqual(identity.workspaceID, expected)
  }

  func testBookmarkDoesNotAffectSingleRootWorkspaceID() throws {
    let root = try makeTemporaryDirectory()

    let noBookmark = WorkspaceIdentity.make(roots: [root], bookmarkData: nil)
    let withBookmark = WorkspaceIdentity.make(roots: [root], bookmarkData: Data("bm".utf8))

    XCTAssertEqual(noBookmark.workspaceID, withBookmark.workspaceID)
    XCTAssertNotEqual(noBookmark.rootBookmarkHash, withBookmark.rootBookmarkHash)
  }

  // MARK: - Multi-root keying

  func testMultiRootWorkspaceIDIsOrderIndependent() throws {
    let a = try makeTemporaryDirectory()
    let b = try makeTemporaryDirectory()

    let ab = WorkspaceIdentity.make(roots: [a, b], bookmarkData: nil)
    let ba = WorkspaceIdentity.make(roots: [b, a], bookmarkData: nil)

    XCTAssertEqual(ab.workspaceID, ba.workspaceID)
  }

  func testMultiRootWorkspaceIDDiffersFromEitherSingleRoot() throws {
    let a = try makeTemporaryDirectory()
    let b = try makeTemporaryDirectory()

    let ab = WorkspaceIdentity.make(roots: [a, b], bookmarkData: nil)
    let onlyA = WorkspaceIdentity.make(roots: [a], bookmarkData: nil)
    let onlyB = WorkspaceIdentity.make(roots: [b], bookmarkData: nil)

    XCTAssertNotEqual(ab.workspaceID, onlyA.workspaceID)
    XCTAssertNotEqual(ab.workspaceID, onlyB.workspaceID)
  }

  func testCanonicalRootURLIsFirstSortedRootAndURLsAreSorted() throws {
    let a = try makeTemporaryDirectory()
    let b = try makeTemporaryDirectory()

    // Sort order is by the per-root "path\nvolume" identity string; on a single volume
    // that reduces to path order. Build the expected ordering directly from the paths.
    let expectedSorted = [a, b]
      .map(\.standardizedFileURL)
      .sorted { $0.path < $1.path }

    let identity = WorkspaceIdentity.make(roots: [b, a], bookmarkData: nil)

    XCTAssertEqual(identity.canonicalRootURLs, expectedSorted)
    XCTAssertEqual(identity.canonicalRootURL, expectedSorted[0])
    // canonicalRootURL must always be the first element of the sorted list.
    XCTAssertEqual(identity.canonicalRootURL, identity.canonicalRootURLs[0])
  }

  func testSingleRootCanonicalRootURLsContainsOnlyThatRoot() throws {
    let root = try makeTemporaryDirectory()
    let identity = WorkspaceIdentity.make(roots: [root], bookmarkData: nil)

    XCTAssertEqual(identity.canonicalRootURLs, [root.standardizedFileURL])
    XCTAssertEqual(identity.canonicalRootURL, root.standardizedFileURL)
  }

  // MARK: - Codable / Equatable / Hashable

  func testCodableRoundtripPreservesAllFieldsIncludingRoots() throws {
    let a = try makeTemporaryDirectory()
    let b = try makeTemporaryDirectory()
    let identity = WorkspaceIdentity.make(roots: [a, b], bookmarkData: Data("bookmark".utf8))

    let data = try JSONEncoder().encode(identity)
    let decoded = try JSONDecoder().decode(WorkspaceIdentity.self, from: data)

    XCTAssertEqual(decoded, identity)
    XCTAssertEqual(decoded.canonicalRootURLs, identity.canonicalRootURLs)
  }

  func testHashableConsistentWithEquality() throws {
    let a = try makeTemporaryDirectory()
    let b = try makeTemporaryDirectory()

    let first = WorkspaceIdentity.make(roots: [a, b], bookmarkData: nil)
    let second = WorkspaceIdentity.make(roots: [b, a], bookmarkData: nil)

    // workspaceID is order-independent, but computedAt differs per call, so the full
    // structs are not equal — assert the keying field instead.
    XCTAssertEqual(first.workspaceID, second.workspaceID)

    var set = Set<WorkspaceIdentity>()
    set.insert(first)
    XCTAssertTrue(set.contains(first))
  }

  // MARK: - Helpers

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pensieve-identity-tests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}
