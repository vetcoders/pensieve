import CryptoKit
import Foundation

struct WorkspaceIdentity: Codable, Equatable, Hashable {
  var workspaceID: String
  var canonicalRootURL: URL
  var canonicalRootURLs: [URL]
  var rootBookmarkHash: String
  var volumeResourceID: String?
  var computedAt: Date

  /// Multi-root identity (B-1c / STAB-R04). `workspaceID` keys on the SET of roots
  /// (each contributing `path + volume`), order-independent. For a single root the
  /// keying input reduces byte-identically to the v2 single-root scheme, so existing
  /// single-root caches stay warm (see N==1 invariant note below).
  static func make(roots: [URL], bookmarkData: Data?) -> WorkspaceIdentity {
    precondition(!roots.isEmpty, "WorkspaceIdentity.make requires at least one root")

    // Each root contributes "<canonical path>\n<volume id>". v2/v3 identity is defined
    // by physical location (path + volume) only; the bookmark hash is metadata.
    let components: [(url: URL, volume: String?, identity: String)] = roots.map { rootURL in
      let canonical = rootURL.standardizedFileURL
      let volume = Self.volumeIdentifier(for: canonical)
      let identity = [
        canonical.path,
        volume ?? "volume:nil",
      ].joined(separator: "\n")
      return (canonical, volume, identity)
    }
    // Order-independent: sort by the per-root identity string. The FIRST sorted root is
    // the canonical root (markFailure's `[identity.canonicalRootURL]` fallback target).
    let sorted = components.sorted { $0.identity < $1.identity }
    let canonicalRootURLs = sorted.map(\.url)
    let canonicalRoot = sorted[0]

    // workspaceID scheme: SHA256(joined per-root "path\nvolume" inputs), hex, first 16 chars.
    // v1 (B-1a): bookmark hash was a primary input to workspaceID. v2 (B-03 / STAB-R03):
    // identity is defined by physical location (path + volume); bookmark hash is metadata only.
    // v3 (B-1c): keys on N roots, joined by "\n\n" after sorting.
    // This means bookmark refresh produces the SAME workspaceID -> cache stays warm.
    // A changed volume id with the same path is deliberately treated as a different workspace.
    //
    // N==1 INVARIANT: a single root joins to exactly "path\nvolume" (the lone element
    // carries no "\n\n" separator), so this reduces to the v2 single-root identityInput and
    // make(roots:[r]) yields the EXACT same workspaceID as the legacy make(rootURL:r).
    let identityInput = sorted.map(\.identity).joined(separator: "\n\n")
    let workspaceID = String(WorkspaceHash.sha256Hex(identityInput).prefix(16))

    // Stable no-bookmark sentinel, recorded as metadata only.
    // Under v2+ identity a bookmark appearing or refreshing later no longer shifts the workspaceID.
    let rootBookmarkHash =
      bookmarkData.map(WorkspaceHash.sha256Hex)
      ?? WorkspaceHash.sha256Hex("pensieve.workspace.no-bookmark.v1")

    return WorkspaceIdentity(
      workspaceID: workspaceID,
      canonicalRootURL: canonicalRoot.url,
      canonicalRootURLs: canonicalRootURLs,
      rootBookmarkHash: rootBookmarkHash,
      volumeResourceID: canonicalRoot.volume,
      computedAt: Date()
    )
  }

  /// Thin single-root wrapper so every existing `make(rootURL:bookmarkData:)` caller
  /// compiles unchanged and keeps producing the byte-identical v2 workspaceID.
  static func make(rootURL: URL, bookmarkData: Data?) -> WorkspaceIdentity {
    make(roots: [rootURL], bookmarkData: bookmarkData)
  }

  private static func volumeIdentifier(for url: URL) -> String? {
    guard let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey]),
      let volumeIdentifier = values.volumeIdentifier
    else {
      return nil
    }
    return String(describing: volumeIdentifier)
  }
}

enum WorkspaceHash {
  static func sha256Hex(_ string: String) -> String {
    sha256Hex(Data(string.utf8))
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
