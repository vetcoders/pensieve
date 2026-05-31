import CryptoKit
import Foundation

struct WorkspaceIdentity: Codable, Equatable, Hashable {
  var workspaceID: String
  var canonicalRootURL: URL
  var rootBookmarkHash: String
  var volumeResourceID: String?
  var computedAt: Date

  static func make(rootURL: URL, bookmarkData: Data?) -> WorkspaceIdentity {
    let canonicalRootURL = rootURL.standardizedFileURL
    let volumeResourceID = Self.volumeIdentifier(for: canonicalRootURL)
    // Stable no-bookmark sentinel, recorded as metadata only (see workspaceID note below).
    // Under v2 identity a bookmark appearing or refreshing later no longer shifts the workspaceID.
    let rootBookmarkHash =
      bookmarkData.map(WorkspaceHash.sha256Hex)
      ?? WorkspaceHash.sha256Hex("pensieve.workspace.no-bookmark.v1")

    // workspaceID scheme: SHA256(canonical path + volume id), hex, first 16 chars.
    // v1 (B-1a): bookmark hash was a primary input to workspaceID. v2 (B-03 / STAB-R03):
    // identity is defined by physical location (path + volume); bookmark hash is metadata only.
    // This means bookmark refresh produces the SAME workspaceID -> cache stays warm.
    // A changed volume id with the same path is deliberately treated as a different workspace.
    let identityInput = [
      canonicalRootURL.path,
      volumeResourceID ?? "volume:nil",
    ].joined(separator: "\n")
    let workspaceID = String(WorkspaceHash.sha256Hex(identityInput).prefix(16))

    return WorkspaceIdentity(
      workspaceID: workspaceID,
      canonicalRootURL: canonicalRootURL,
      rootBookmarkHash: rootBookmarkHash,
      volumeResourceID: volumeResourceID,
      computedAt: Date()
    )
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
