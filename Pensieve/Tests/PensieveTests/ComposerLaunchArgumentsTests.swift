import XCTest

@testable import Pensieve

final class ComposerLaunchArgumentsTests: XCTestCase {
  func testEmptyArgvIsNoWaitNoFiles() {
    let parsed = ComposerLaunchArguments.parse(["/path/to/Pensieve"])
    XCTAssertFalse(parsed.wait)
    XCTAssertTrue(parsed.fileURLs.isEmpty)
    XCTAssertFalse(parsed.showHelp)
    XCTAssertTrue(parsed.unknownFlags.isEmpty)
  }

  func testWaitFlagLongAndShort() {
    XCTAssertTrue(ComposerLaunchArguments.parse(["Pensieve", "--wait"]).wait)
    XCTAssertTrue(ComposerLaunchArguments.parse(["Pensieve", "-w"]).wait)
    XCTAssertFalse(ComposerLaunchArguments.parse(["Pensieve", "notes.md"]).wait)
  }

  func testHelpFlag() {
    XCTAssertTrue(ComposerLaunchArguments.parse(["Pensieve", "--help"]).showHelp)
    XCTAssertTrue(ComposerLaunchArguments.parse(["Pensieve", "-h"]).showHelp)
  }

  func testPositionalFilesResolveAbsolute() {
    let parsed = ComposerLaunchArguments.parse([
      "Pensieve",
      "--wait",
      "/tmp/composer-prompt.md",
      "/var/tmp/other.txt",
    ])
    XCTAssertTrue(parsed.wait)
    XCTAssertEqual(
      parsed.fileURLs.map(\.path),
      [
        URL(fileURLWithPath: "/tmp/composer-prompt.md").standardizedFileURL.path,
        URL(fileURLWithPath: "/var/tmp/other.txt").standardizedFileURL.path,
      ])
  }

  func testDoubleDashEndsFlags() {
    let parsed = ComposerLaunchArguments.parse([
      "Pensieve",
      "--",
      "--wait",
      "/tmp/not-a-flag.md",
    ])
    // `--wait` after `--` is a path token, not the wait flag.
    XCTAssertFalse(parsed.wait)
    XCTAssertEqual(parsed.fileURLs.count, 2)
    XCTAssertTrue(parsed.fileURLs[0].path.hasSuffix("--wait"))
    XCTAssertTrue(parsed.fileURLs[1].path.hasSuffix("not-a-flag.md"))
  }

  func testUnknownFlagsAreRecordedAndSkipped() {
    let parsed = ComposerLaunchArguments.parse([
      "Pensieve",
      "--wait",
      "--bogus",
      "/tmp/file.md",
    ])
    XCTAssertTrue(parsed.wait)
    XCTAssertEqual(parsed.unknownFlags, ["--bogus"])
    XCTAssertEqual(parsed.fileURLs.count, 1)
    XCTAssertTrue(parsed.fileURLs[0].path.hasSuffix("file.md"))
  }

  func testTildeExpansion() {
    let parsed = ComposerLaunchArguments.parse(["Pensieve", "~/composer.md"])
    let expected = (NSHomeDirectory() as NSString).appendingPathComponent("composer.md")
    XCTAssertEqual(
      parsed.fileURLs.first?.standardizedFileURL.path,
      URL(fileURLWithPath: expected).standardizedFileURL.path)
  }

  func testRelativePathUsesCWD() {
    let cwd = FileManager.default.currentDirectoryPath
    let parsed = ComposerLaunchArguments.parse(["Pensieve", "relative/prompt.md"])
    let expected = URL(fileURLWithPath: cwd)
      .appendingPathComponent("relative/prompt.md")
      .standardizedFileURL
    XCTAssertEqual(parsed.fileURLs, [expected])
  }

  func testUsageIsNonEmptyContract() {
    XCTAssertTrue(ComposerLaunchArguments.usage.contains("--wait"))
    XCTAssertTrue(ComposerLaunchArguments.usage.contains("VC_COMPOSER"))
  }

  @MainActor
  func testApplyComposerLaunchArgumentsEnablesWaitAndQueuesFiles() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveComposerWaitArgs-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let fileURL = folder.appendingPathComponent("prompt.md")
    try "hello composer".write(to: fileURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let indexDatabase = Self.makeTemporaryIndexDatabase(in: folder)
    let controller = AppController(
      appState: appState,
      folderManager: FolderManager(
        metadataStore: Self.makeTemporaryMetadataStore(),
        indexDatabase: indexDatabase,
        bookmarkStore: BookmarkStore(
          defaults: makeEphemeralDefaults(prefix: "PensieveComposerWaitBookmark"))
      ),
      documentStore: makeTestDocumentStore(indexDatabase: indexDatabase),
      indexDatabase: indexDatabase,
      importsFoldersInBackground: true
    )

    // Isolated coordinator — not the process-wide shared instance.
    let coordinator = LaunchIntentCoordinator(settleDelayNanoseconds: 0)
    let args = ComposerLaunchArguments(
      wait: true,
      fileURLs: [fileURL],
      showHelp: false,
      unknownFlags: [])

    coordinator.applyComposerLaunchArguments(args)
    XCTAssertTrue(coordinator.isComposerWaitMode)
    XCTAssertTrue(coordinator.hasExplicitLaunchIntent)

    // `.coldLaunch` on purpose: wait-mode must UPGRADE an ordinary cold launch
    // to `.explicitDocument` (see the settle in LaunchIntentCoordinator) — the
    // assertions below only prove the upgrade if the input intent is the weak one.
    coordinator.startWhenLaunchIntentsSettle(controller: controller, intent: .coldLaunch)
    await coordinator.waitForStartupDecision()

    XCTAssertEqual(
      appState.documentSession.url?.standardizedFileURL,
      fileURL.standardizedFileURL)
    XCTAssertEqual(appState.activeDocumentText, "hello composer")
    XCTAssertTrue(appState.workspaceRoots.isEmpty)
  }

  @MainActor
  func testWaitModeAloneIsExplicitLaunchIntentWithoutFiles() {
    let coordinator = LaunchIntentCoordinator()
    coordinator.applyComposerLaunchArguments(
      ComposerLaunchArguments(wait: true, fileURLs: [], showHelp: false, unknownFlags: []))
    XCTAssertTrue(coordinator.isComposerWaitMode)
    XCTAssertTrue(coordinator.hasExplicitLaunchIntent)
    coordinator.resetComposerWaitModeForTests()
    XCTAssertFalse(coordinator.isComposerWaitMode)
  }

  // MARK: - Local harness helpers (mirrors PensieveTests private factories)

  private static func makeTemporaryMetadataStore() -> WorkspaceMetadataStore {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveComposerMeta-\(UUID().uuidString)", isDirectory: true)
    return WorkspaceMetadataStore(
      metadataURL: folder.appendingPathComponent("workspace.json", isDirectory: false))
  }

  @MainActor
  private static func makeTemporaryIndexDatabase(in folder: URL) -> IndexDatabase {
    IndexDatabase(databaseURL: folder.appendingPathComponent("index.db", isDirectory: false))
  }
}
