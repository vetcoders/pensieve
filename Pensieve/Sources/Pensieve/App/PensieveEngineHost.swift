import CodescribeBridge
import Foundation

enum PensieveEngineHost {
  static func configure() throws {
    let identity = identity()
    try configureEmbeddedRuntime(
      dataDirectory: identity.directory.path, keychainService: identity.keychainService)
  }

  static func identity(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default,
    isTestProcess: Bool? = nil
  ) -> (directory: URL, keychainService: String) {
    let testing = isTestProcess ?? AppSupportLocation.isRunningTests(environment: environment)
    let support =
      AppSupportLocation.isolationRoot(
        environment: environment, fileManager: fileManager, isTestProcess: testing)
      ?? (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support"))
      .appendingPathComponent("Pensieve", isDirectory: true)
    let service =
      testing && environment[KeychainProviderAPIKeyStore.serviceEnvironmentKey] == nil
      ? "io.vetcoders.pensieve.tests.\(support.lastPathComponent)"
      : KeychainProviderAPIKeyStore.defaultService(environment: environment)
    return (
      support.appendingPathComponent("Agent", isDirectory: true),
      service
    )
  }
}
