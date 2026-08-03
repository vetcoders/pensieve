import XCTest

@testable import Pensieve

/// The sidebar's second defense layer against files that silently vanish because their
/// extension falls outside `WorkspaceScanner.isMarkdownFile`'s allow-list: such a file must
/// still surface as a visible, inert `.foreignFile` node instead of being dropped from the
/// scan entirely (that silence is how the rename-extension-loss bug looked like data loss).
final class WorkspaceForeignFileScanTests: XCTestCase {

  func testForeignExtensionFileProducesAForeignNodeAndIsExcludedFromDocuments() throws {
    let root = try makeTemporaryFolder(prefix: "PensieveForeignExtension")
    defer { try? FileManager.default.removeItem(at: root) }

    let foreign = root.appendingPathComponent("notes.xyz")
    try "body".write(to: foreign, atomically: true, encoding: .utf8)

    let scans = WorkspaceScanner.build(rootURLs: [root], exclusions: [])

    XCTAssertEqual(scans.count, 1)
    XCTAssertTrue(scans[0].documents.isEmpty)

    let nodes = flatten(scans[0].rootNode)
    let foreignNode = try XCTUnwrap(nodes.first { $0.url == foreign.standardizedFileURL })
    XCTAssertEqual(foreignNode.kind, .foreignFile)
    XCTAssertEqual(foreignNode.name, "notes.xyz", "shows the full filename, extension included")
  }

  func testExtensionlessFileProducesAForeignNode() throws {
    let root = try makeTemporaryFolder(prefix: "PensieveForeignNoExtension")
    defer { try? FileManager.default.removeItem(at: root) }

    let foreign = root.appendingPathComponent("notatka")
    try "body".write(to: foreign, atomically: true, encoding: .utf8)

    let scans = WorkspaceScanner.build(rootURLs: [root], exclusions: [])

    XCTAssertTrue(scans[0].documents.isEmpty)
    let nodes = flatten(scans[0].rootNode)
    let foreignNode = try XCTUnwrap(nodes.first { $0.url == foreign.standardizedFileURL })
    XCTAssertEqual(foreignNode.kind, .foreignFile)
  }

  func testDotfilesAndExcludedPathsProduceNoNodeAtAll() throws {
    let root = try makeTemporaryFolder(prefix: "PensieveForeignExclusions")
    defer { try? FileManager.default.removeItem(at: root) }

    let hidden = root.appendingPathComponent(".hidden")
    try "body".write(to: hidden, atomically: true, encoding: .utf8)

    let excludedDir = root.appendingPathComponent("node_modules", isDirectory: true)
    try FileManager.default.createDirectory(at: excludedDir, withIntermediateDirectories: true)
    try "body".write(
      to: excludedDir.appendingPathComponent("pkg.xyz"), atomically: true, encoding: .utf8)

    let explicitlyExcludedDir = root.appendingPathComponent("scratch", isDirectory: true)
    try FileManager.default.createDirectory(
      at: explicitlyExcludedDir, withIntermediateDirectories: true)
    try "body".write(
      to: explicitlyExcludedDir.appendingPathComponent("draft.xyz"), atomically: true,
      encoding: .utf8)

    let scans = WorkspaceScanner.build(rootURLs: [root], exclusions: ["scratch"])

    XCTAssertTrue(scans[0].documents.isEmpty)
    let nodes = flatten(scans[0].rootNode)
    XCTAssertFalse(nodes.contains { $0.name == ".hidden" })
    XCTAssertFalse(nodes.contains { $0.name == "node_modules" })
    XCTAssertFalse(nodes.contains { $0.name == "scratch" })
    XCTAssertFalse(nodes.contains { $0.name == "pkg.xyz" })
    XCTAssertFalse(nodes.contains { $0.name == "draft.xyz" })
  }

  func testMarkdownFileScanIsUnaffectedByForeignNodeHandling() throws {
    let root = try makeTemporaryFolder(prefix: "PensieveForeignMarkdownBaseline")
    defer { try? FileManager.default.removeItem(at: root) }

    let note = root.appendingPathComponent("notes.md")
    try "# Notes".write(to: note, atomically: true, encoding: .utf8)

    let scans = WorkspaceScanner.build(rootURLs: [root], exclusions: [])

    XCTAssertEqual(scans[0].documents.map(\.url), [note.standardizedFileURL])
    let nodes = flatten(scans[0].rootNode)
    let documentNode = try XCTUnwrap(nodes.first { $0.url == note.standardizedFileURL })
    XCTAssertEqual(documentNode.kind, .document)
    XCTAssertEqual(documentNode.name, "notes", "document nodes show the stem, not the extension")
  }

  @MainActor
  func testAddMdExtensionRenamesAForeignFileIntoADocumentOnNextScan() throws {
    let root = try makeTemporaryFolder(prefix: "PensieveForeignRepair")
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(), indexDatabase: temporaryIndexDatabase(in: root))
    let appState = AppState()

    let foreign = root.appendingPathComponent("notatka")
    try "body".write(to: foreign, atomically: true, encoding: .utf8)

    // Mirrors the sidebar's "Add .md Extension" context-menu action: rename through the
    // same `FolderManager.rename` path with `lastPathComponent + ".md"`.
    XCTAssertTrue(manager.rename(url: foreign, to: "notatka.md", into: appState))

    let scans = WorkspaceScanner.build(rootURLs: [root], exclusions: [])
    XCTAssertEqual(
      scans[0].documents.map(\.url),
      [root.appendingPathComponent("notatka.md").standardizedFileURL])
  }

  private func makeTemporaryFolder(prefix: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func temporaryMetadataStore() -> WorkspaceMetadataStore {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveForeignMetadata-\(UUID().uuidString)", isDirectory: true)
    return WorkspaceMetadataStore(
      metadataURL: folder.appendingPathComponent("workspace.json", isDirectory: false))
  }

  @MainActor
  private func temporaryIndexDatabase(in folder: URL) -> IndexDatabase {
    IndexDatabase(databaseURL: folder.appendingPathComponent("index.db", isDirectory: false))
  }

  private func flatten(_ root: WorkspaceNode) -> [WorkspaceNode] {
    [root] + (root.children ?? []).flatMap(flatten)
  }
}
