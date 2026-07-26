import Foundation

struct WorkspaceMetadata: Codable, Equatable {
  var excludedPaths: [String] = []
}

final class WorkspaceMetadataStore {
  static let shared = WorkspaceMetadataStore()

  private static let protectedWriteOptions: Data.WritingOptions = [
    .atomic,
    .completeFileProtection,
  ]
  private static let fallbackWriteOptions: Data.WritingOptions = [
    .atomic
  ]

  private let metadataURL: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  convenience init() {
    self.init(metadataURL: Self.defaultMetadataURL())
  }

  init(metadataURL: URL) {
    self.metadataURL = metadataURL
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  }

  func load() -> WorkspaceMetadata {
    guard let data = try? Data(contentsOf: metadataURL) else {
      return WorkspaceMetadata()
    }
    return (try? decoder.decode(WorkspaceMetadata.self, from: data)) ?? WorkspaceMetadata()
  }

  func save(_ metadata: WorkspaceMetadata) throws {
    let directory = metadataURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try encoder.encode(metadata)
    try Self.writeProtected(data, to: metadataURL)
  }

  static func defaultMetadataURL() -> URL {
    applicationSupportDirectory()
      .appendingPathComponent("workspace.json", isDirectory: false)
  }

  static func applicationSupportDirectory() -> URL {
    if let overrideRoot = AppSupportLocation.overrideRoot() { return overrideRoot }
    do {
      return try FileManager.default
        .url(
          for: .applicationSupportDirectory,
          in: .userDomainMask,
          appropriateFor: nil,
          create: true
        )
        .appendingPathComponent("Pensieve", isDirectory: true)
    } catch {
      NSLog(
        "%@",
        "WorkspaceMetadataStore: Application Support unavailable, "
          + "falling back to temporary directory: \(error)")
      return FileManager.default.temporaryDirectory
        .appendingPathComponent("Pensieve", isDirectory: true)
    }
  }

  private static func writeProtected(_ data: Data, to url: URL) throws {
    do {
      try data.write(to: url, options: protectedWriteOptions)
    } catch {
      NSLog(
        "%@",
        "WorkspaceMetadataStore: protected write failed for \(url.lastPathComponent), "
          + "falling back to unprotected atomic write: \(error)")
      try data.write(to: url, options: fallbackWriteOptions)
    }
  }
}
