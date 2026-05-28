import Foundation

struct WorkspaceManifest: Codable, Equatable {
  var workspaceID: String
  var roots: [URL]
  var exclusions: [String]
  var scannerVersion: Int
  var cacheSchemaVersion: Int
  var fileCount: Int
  var folderCount: Int
  var lastFullScanAt: Date
  var lastIncrementalScanAt: Date?
  var treeFingerprint: TreeFingerprint
  var lastFailureAt: Date?
  var lastFailureKind: String?

  static func makeForFreshCommit(
    identity: WorkspaceIdentity,
    roots: [URL],
    exclusions: [String],
    fingerprint: TreeFingerprint,
    scannerVersion: Int = 1,
    cacheSchemaVersion: Int = 1,
    now: Date = Date()
  ) -> WorkspaceManifest {
    WorkspaceManifest(
      workspaceID: identity.workspaceID,
      roots: roots.map(\.standardizedFileURL),
      exclusions: exclusions.sorted(),
      scannerVersion: scannerVersion,
      cacheSchemaVersion: cacheSchemaVersion,
      fileCount: fingerprint.fileCount,
      folderCount: fingerprint.folderCount,
      lastFullScanAt: now,
      lastIncrementalScanAt: nil,
      treeFingerprint: fingerprint,
      lastFailureAt: nil,
      lastFailureKind: nil
    )
  }
}
