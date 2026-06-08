import GRDB
import XCTest

@testable import Pensieve

@MainActor
final class IndexDatabaseBacklinksTests: XCTestCase {
  func testExactWikilinkInSourceDocumentResolvesBacklinkToTarget() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let targetURL = folder.appendingPathComponent("target.md")
    let sourceURL = folder.appendingPathComponent("doc-a.md")
    try "# Target\n".write(to: targetURL, atomically: true, encoding: .utf8)
    try "Doc A links [[Target]].".write(to: sourceURL, atomically: true, encoding: .utf8)

    let documents = [
      document(targetURL, root: folder),
      document(sourceURL, root: folder),
    ]
    let database = IndexDatabase(databaseURL: folder.appendingPathComponent("index.db"))
    database.reindex(documents: documents)

    let backlinks = database.backlinks(to: documents[0], documents: documents)

    XCTAssertEqual(backlinks.map(\.sourceDocument), [documents[1]])
    XCTAssertEqual(backlinks.map(\.displayPath), ["doc-a.md"])
    XCTAssertEqual(backlinks.map(\.matchedTarget), ["Target"])
    XCTAssertEqual(backlinks.first?.snippet, "Doc A links [[Target]].")
  }

  func testBacklinksResolveFilenameTitleAndHeadingAliases() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let targetURL = folder.appendingPathComponent("alpha.md")
    let titleLinkURL = folder.appendingPathComponent("title-link.md")
    let filenameLinkURL = folder.appendingPathComponent("filename-link.md")
    let noiseURL = folder.appendingPathComponent("noise.md")
    try "# Alpha Heading\n\nSelf [[Alpha Heading]] should not count.".write(
      to: targetURL, atomically: true, encoding: .utf8)
    try "See [[Alpha Heading|the heading alias]].".write(
      to: titleLinkURL, atomically: true, encoding: .utf8)
    try "Also see [[alpha]].".write(to: filenameLinkURL, atomically: true, encoding: .utf8)
    try "Noise [[Missing]].".write(to: noiseURL, atomically: true, encoding: .utf8)

    let documents = [
      document(targetURL, root: folder),
      document(titleLinkURL, root: folder),
      document(filenameLinkURL, root: folder),
      document(noiseURL, root: folder),
    ]
    let database = IndexDatabase(databaseURL: folder.appendingPathComponent("index.db"))
    database.reindex(documents: documents)

    let backlinks = database.backlinks(to: documents[0], documents: documents)

    XCTAssertEqual(backlinks.map(\.displayPath).sorted(), ["filename-link.md", "title-link.md"])
    XCTAssertEqual(Set(backlinks.map(\.matchedTarget)), ["Alpha Heading", "alpha"])
    XCTAssertTrue(backlinks.allSatisfy { $0.sourceDocument != documents[0] })
    XCTAssertTrue(backlinks.contains { $0.snippet == "See [[Alpha Heading|the heading alias]]." })
  }

  func testBacklinksAreScopedToTheProvidedWorkspaceDocuments() throws {
    let firstRoot = try makeTemporaryFolder(prefix: "PensieveBacklinksFirst")
    let secondRoot = try makeTemporaryFolder(prefix: "PensieveBacklinksSecond")
    defer {
      try? FileManager.default.removeItem(at: firstRoot)
      try? FileManager.default.removeItem(at: secondRoot)
    }

    let targetURL = firstRoot.appendingPathComponent("alpha.md")
    let inScopeURL = firstRoot.appendingPathComponent("in-scope.md")
    let outOfScopeURL = secondRoot.appendingPathComponent("out-of-scope.md")
    try "# Alpha\n".write(to: targetURL, atomically: true, encoding: .utf8)
    try "Workspace link [[Alpha]].".write(to: inScopeURL, atomically: true, encoding: .utf8)
    try "Other workspace [[Alpha]].".write(to: outOfScopeURL, atomically: true, encoding: .utf8)

    let firstDocs = [document(targetURL, root: firstRoot), document(inScopeURL, root: firstRoot)]
    let allDocs = firstDocs + [document(outOfScopeURL, root: secondRoot)]
    let database = IndexDatabase(databaseURL: firstRoot.appendingPathComponent("index.db"))
    database.reindex(documents: allDocs)

    let backlinks = database.backlinks(to: firstDocs[0], documents: firstDocs)

    XCTAssertEqual(backlinks.map(\.displayPath), ["in-scope.md"])
  }

  func testBacklinksIgnoreStaleRenameAliasAndMissingTargetLinks() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let targetURL = folder.appendingPathComponent("target.md")
    let sourceURL = folder.appendingPathComponent("rename-edge.md")
    try "# Target\n".write(to: targetURL, atomically: true, encoding: .utf8)
    try """
      Stale rename alias [[Old Target]].
      Missing target [[Missing Target]].
      Current link [[Target]].
      """.write(to: sourceURL, atomically: true, encoding: .utf8)

    let documents = [
      document(targetURL, root: folder),
      document(sourceURL, root: folder),
    ]
    let database = IndexDatabase(databaseURL: folder.appendingPathComponent("index.db"))
    database.reindex(documents: documents)

    let backlinks = database.backlinks(to: documents[0], documents: documents)

    XCTAssertEqual(backlinks.map(\.displayPath), ["rename-edge.md"])
    XCTAssertEqual(backlinks.map(\.matchedTarget), ["Target"])
    XCTAssertEqual(backlinks.first?.snippet, "Current link [[Target]].")
  }

  func testBacklinkLookupAndFTSSearchReadIndexedRowsAfterDiskMutation() throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }

    let databaseURL = folder.appendingPathComponent("index.db")
    let targetURL = folder.appendingPathComponent("target.md")
    let sourceURL = folder.appendingPathComponent("indexed-source.md")
    try "# Target\n".write(to: targetURL, atomically: true, encoding: .utf8)
    try "Indexed row keeps [[Target]] with backlinkneedle.".write(
      to: sourceURL, atomically: true, encoding: .utf8)

    let documents = [
      document(targetURL, root: folder),
      document(sourceURL, root: folder),
    ]
    let database = IndexDatabase(databaseURL: databaseURL)
    database.reindex(documents: documents)

    try "Disk no longer mentions the link or token.".write(
      to: sourceURL, atomically: true, encoding: .utf8)

    let backlinks = database.backlinks(to: documents[0], documents: documents)
    let searchResults = database.search(query: "backlinkneedle", documents: documents)
    let ftsPaths = try ftsHitPaths(matching: "backlinkneedle", at: databaseURL)

    XCTAssertEqual(backlinks.map(\.displayPath), ["indexed-source.md"])
    XCTAssertEqual(backlinks.map(\.matchedTarget), ["Target"])
    XCTAssertEqual(
      searchResults.map(\.document.id),
      [sourceURL.standardizedFileURL],
      "FTS-backed workspace search should read the indexed source row, not the mutated file")
    XCTAssertEqual(ftsPaths, ["indexed-source.md"])
  }

  private func makeTemporaryFolder(prefix: String = "PensieveBacklinksTests") throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func document(_ url: URL, root: URL) -> DocumentRef {
    DocumentRef(
      id: url.standardizedFileURL,
      rootURL: root.standardizedFileURL,
      relativePath: url.lastPathComponent)
  }

  private func ftsHitPaths(matching query: String, at databaseURL: URL) throws -> [String] {
    let pool = try DatabasePool(path: databaseURL.path)
    defer { try? pool.close() }
    return try pool.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT d.path
          FROM document_fts
          JOIN documents d ON d.id = document_fts.rowid
          WHERE document_fts MATCH ?
          ORDER BY d.path
          """,
        arguments: [query]
      ).map { row in
        row["path"]
      }
    }
  }
}
