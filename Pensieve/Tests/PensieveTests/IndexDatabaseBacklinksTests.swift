import XCTest

@testable import Pensieve

@MainActor
final class IndexDatabaseBacklinksTests: XCTestCase {
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
}
