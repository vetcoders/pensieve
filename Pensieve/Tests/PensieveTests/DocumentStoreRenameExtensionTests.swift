import XCTest

@testable import Pensieve

/// Sidebar inline-rename prefills the field with the full filename, extension
/// included. If the user retypes just the base name and drops the extension,
/// `FolderManager.rename` must reinstate it — otherwise the file silently
/// falls out of `WorkspaceScanner.isMarkdownFile`'s allow-list and disappears
/// from the workspace tree even though it is still on disk.
final class DocumentStoreRenameExtensionTests: XCTestCase {

  @MainActor
  func testRenamingAFileWithoutTypingAnExtensionKeepsTheOriginalExtension() throws {
    let folder = try makeTemporaryFolder()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(), indexDatabase: temporaryIndexDatabase(in: folder))
    let appState = AppState()

    let source = folder.appendingPathComponent("a.md")
    try "body".write(to: source, atomically: true, encoding: .utf8)

    XCTAssertTrue(manager.rename(url: source, to: "b", into: appState))

    let expected = folder.appendingPathComponent("b.md")
    XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
  }

  @MainActor
  func testRenamingAFileWithAnExplicitExtensionRespectsIt() throws {
    let folder = try makeTemporaryFolder()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(), indexDatabase: temporaryIndexDatabase(in: folder))
    let appState = AppState()

    let source = folder.appendingPathComponent("a.md")
    try "body".write(to: source, atomically: true, encoding: .utf8)

    XCTAssertTrue(manager.rename(url: source, to: "b.txt", into: appState))

    let expected = folder.appendingPathComponent("b.txt")
    XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
  }

  @MainActor
  func testRenamingAFolderNeverAppendsAnExtension() throws {
    let folder = try makeTemporaryFolder()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(), indexDatabase: temporaryIndexDatabase(in: folder))
    let appState = AppState()

    let source = folder.appendingPathComponent("x", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

    XCTAssertTrue(manager.rename(url: source, to: "y", into: appState))

    var isDirectory: ObjCBool = false
    let expected = folder.appendingPathComponent("y", isDirectory: true)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: expected.path, isDirectory: &isDirectory))
    XCTAssertTrue(isDirectory.boolValue)
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
  }

  @MainActor
  func testRenamingAFileToANameWithAnInteriorDotButNoRealExtensionKeepsTheOriginalExtension()
    throws
  {
    let folder = try makeTemporaryFolder()
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(), indexDatabase: temporaryIndexDatabase(in: folder))
    let appState = AppState()

    let source = folder.appendingPathComponent("a.md")
    try "body".write(to: source, atomically: true, encoding: .utf8)

    XCTAssertTrue(manager.rename(url: source, to: "ver 2.5", into: appState))

    let expected = folder.appendingPathComponent("ver 2.5.md")
    XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
  }

  // MARK: - Sidebar rename-field prefill (pure, view-side helper)

  func testRenamePrefillStripsARealExtension() {
    XCTAssertEqual(
      WorkspaceScanner.renamePrefill(for: URL(fileURLWithPath: "/tmp/plik.md")), "plik")
  }

  func testRenamePrefillLeavesADirectoryNameUnchanged() {
    XCTAssertEqual(
      WorkspaceScanner.renamePrefill(for: URL(fileURLWithPath: "/tmp/katalog", isDirectory: true)),
      "katalog")
  }

  func testRenamePrefillLeavesAnExtensionlessFileNameUnchanged() {
    XCTAssertEqual(
      WorkspaceScanner.renamePrefill(for: URL(fileURLWithPath: "/tmp/README")), "README")
  }

  private func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveRenameExtensionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: folder)
    }
    return folder
  }

  private func temporaryMetadataStore() -> WorkspaceMetadataStore {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveRenameExtensionMetadataTests-\(UUID().uuidString)", isDirectory: true)
    return WorkspaceMetadataStore(
      metadataURL: folder.appendingPathComponent("workspace.json", isDirectory: false))
  }

  @MainActor
  private func temporaryIndexDatabase(in folder: URL) -> IndexDatabase {
    IndexDatabase(databaseURL: folder.appendingPathComponent("index.db", isDirectory: false))
  }
}
