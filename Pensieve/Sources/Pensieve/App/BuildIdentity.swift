import Foundation

struct BuildIdentity: Equatable {
  static let componentVersionsKey = "PensieveComponentVersions"

  let appName: String
  let version: String
  let buildNumber: String
  let commitHash: String
  let commitSlug: String
  let buildDate: String
  let componentVersions: [String: String]

  static var current: BuildIdentity {
    BuildIdentity(bundle: .main)
  }

  init(bundle: Bundle) {
    self.init(info: bundle.infoDictionary ?? [:])
  }

  init(info: [String: Any]) {
    appName =
      info["CFBundleDisplayName"] as? String
      ?? info["CFBundleName"] as? String
      ?? "Pensieve"
    version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
    buildNumber = info["CFBundleVersion"] as? String ?? "0"
    commitHash = info["PensieveBuildCommit"] as? String ?? "unknown"
    commitSlug = Self.normalizedSlug(
      info["PensieveBuildCommitSlug"] as? String,
      fallbackHash: commitHash)
    buildDate = info["PensieveBuildDate"] as? String ?? "unknown"
    componentVersions = info[Self.componentVersionsKey] as? [String: String] ?? [:]
  }

  var conciseLabel: String {
    "\(version) (\(commitSlug))"
  }

  var aboutTitle: String {
    "\(appName) \(conciseLabel)"
  }

  var aboutDetails: String {
    let components =
      componentVersions
      .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
      .map { "\($0.key): \($0.value)" }
      .joined(separator: "\n")

    return [
      "Build: \(buildNumber)",
      "Commit: \(commitHash)",
      "Built: \(buildDate)",
      components.isEmpty ? nil : "Components:\n\(components)",
    ]
    .compactMap { $0 }
    .joined(separator: "\n\n")
  }

  private static func normalizedSlug(_ rawSlug: String?, fallbackHash: String) -> String {
    let candidate = rawSlug?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let candidate, candidate.count == 8 {
      return candidate
    }

    let hash = fallbackHash.trimmingCharacters(in: .whitespacesAndNewlines)
    if hash.count >= 8 {
      return String(hash.prefix(8))
    }

    return hash.isEmpty ? "unknown" : hash
  }
}
