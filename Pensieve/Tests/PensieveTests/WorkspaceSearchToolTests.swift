import XCTest

@testable import Pensieve

@MainActor
final class WorkspaceSearchToolTests: XCTestCase {

  private struct Payload: Decodable {
    var query: String
    var count: Int
    var matches: [Match]

    struct Match: Decodable {
      var path: String
      var title: String
      var updatedAt: String
      var snippet: String
      var match: String

      enum CodingKeys: String, CodingKey {
        case path
        case title
        case snippet
        case match
        case updatedAt = "updated_at"
      }
    }
  }

  private struct Harness {
    var base: URL
    var database: IndexDatabase

    func cleanup() {
      try? FileManager.default.removeItem(at: base)
    }
  }

  private func makeHarness() throws -> Harness {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkspaceSearchTool-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let databaseURL = base.appendingPathComponent("index.db", isDirectory: false)
    let database = IndexDatabase(databaseURL: databaseURL)
    database.open()
    return Harness(base: base, database: database)
  }

  private func makeRoot(in base: URL, name: String) throws -> URL {
    let root = base.appendingPathComponent(name, isDirectory: true).standardizedFileURL
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func makeDoc(root: URL, name: String, body: String, modifiedAt: Date? = nil) throws
    -> DocumentRef
  {
    let fileURL = root.appendingPathComponent(name)
    try body.write(to: fileURL, atomically: true, encoding: .utf8)
    if let modifiedAt {
      try FileManager.default.setAttributes(
        [.modificationDate: modifiedAt],
        ofItemAtPath: fileURL.path
      )
    }
    return DocumentRef(
      id: fileURL.standardizedFileURL,
      rootURL: root,
      relativePath: name
    )
  }

  private func identity(root: URL) -> WorkspaceIdentity {
    WorkspaceIdentity.make(rootURL: root, bookmarkData: nil)
  }

  private func decode(_ json: String) throws -> Payload {
    let data = Data(json.utf8)
    return try JSONDecoder().decode(Payload.self, from: data)
  }

  func testToolNameIsWorkspaceSearch() {
    XCTAssertEqual(WorkspaceSearchTool.toolName, "workspace_search")
  }

  func testEmptyOrWhitespaceQueryIsRejected() throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    for query in ["", " ", "\n", "\t", " \n\t "] {
      XCTAssertThrowsError(
        try WorkspaceSearchTool.workspaceSearch(
          query: query,
          documents: [],
          database: harness.database
        )
      ) { error in
        XCTAssertEqual(
          error.localizedDescription,
          "Missing required non-empty string field 'query'"
        )
      }
    }
  }

  func testLimitOutsideRangeIsAnErrorAndInRangeIsNotClamped() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let root = try makeRoot(in: harness.base, name: "ws")
    let first = try makeDoc(root: root, name: "one.md", body: "alpha beta one")
    let second = try makeDoc(root: root, name: "two.md", body: "alpha beta two")
    await harness.database.upsertWorkspace(
      identity: identity(root: root),
      roots: [root],
      documents: [first, second]
    )

    for bad in [0, -1, 21, 50] {
      XCTAssertThrowsError(
        try WorkspaceSearchTool.workspaceSearch(
          query: "alpha",
          limit: bad,
          documents: [first, second],
          database: harness.database
        )
      ) { error in
        XCTAssertEqual(
          error.localizedDescription,
          "Limit \(bad) is outside 1...20"
        )
      }
    }

    let one = try decode(
      try WorkspaceSearchTool.workspaceSearch(
        query: "alpha beta",
        limit: 1,
        documents: [first, second],
        database: harness.database
      )
    )
    XCTAssertEqual(one.count, 1)
    XCTAssertEqual(one.matches.count, 1)

    let twenty = try decode(
      try WorkspaceSearchTool.workspaceSearch(
        query: "alpha beta",
        limit: 20,
        documents: [first, second],
        database: harness.database
      )
    )
    XCTAssertEqual(twenty.count, 2)
  }

  func testMissingLimitDefaultsToFive() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let root = try makeRoot(in: harness.base, name: "ws")
    var documents: [DocumentRef] = []
    for index in 0..<6 {
      documents.append(
        try makeDoc(
          root: root,
          name: "quota-\(index).md",
          body: "quota marker \(index)"
        )
      )
    }
    await harness.database.upsertWorkspace(
      identity: identity(root: root),
      roots: [root],
      documents: documents
    )

    let payload = try decode(
      try WorkspaceSearchTool.workspaceSearch(
        query: "quota",
        documents: documents,
        database: harness.database
      )
    )
    XCTAssertEqual(payload.count, WorkspaceSearchTool.defaultLimit)
    XCTAssertEqual(payload.matches.count, 5)
    XCTAssertEqual(payload.query, "quota")
  }

  func testAndRequiresEveryTerm() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let root = try makeRoot(in: harness.base, name: "ws")
    let onlyAlpha = try makeDoc(root: root, name: "only-alpha.md", body: "alpha alone in this note")
    let both = try makeDoc(root: root, name: "both-words.md", body: "alpha sits with beta")
    await harness.database.upsertWorkspace(
      identity: identity(root: root),
      roots: [root],
      documents: [onlyAlpha, both]
    )

    let payload = try decode(
      try WorkspaceSearchTool.workspaceSearch(
        query: "alpha beta",
        documents: [onlyAlpha, both],
        database: harness.database
      )
    )
    XCTAssertEqual(payload.query, "alpha beta")
    XCTAssertEqual(payload.count, 1)
    XCTAssertEqual(payload.matches.count, 1)
    XCTAssertEqual(payload.matches[0].path, both.url.standardizedFileURL.path)
    XCTAssertEqual(payload.matches[0].title, "both-words")
    XCTAssertFalse(payload.matches[0].updatedAt.isEmpty)
    XCTAssertFalse(payload.matches[0].match.isEmpty)
    XCTAssertTrue(payload.matches[0].snippet.contains("alpha"))
    XCTAssertTrue(payload.matches[0].snippet.contains("beta"))
    XCTAssertLessThanOrEqual(payload.matches[0].snippet.count, 320)
    XCTAssertFalse(
      payload.matches.map(\.path).contains(onlyAlpha.url.standardizedFileURL.path)
    )
  }

  func testOtherWorkspaceIsExcluded() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let rootA = try makeRoot(in: harness.base, name: "A")
    let rootB = try makeRoot(in: harness.base, name: "B")
    let docA = try makeDoc(root: rootA, name: "a.md", body: "xenon lives in workspace A")
    let docB = try makeDoc(root: rootB, name: "b.md", body: "xenon lives in workspace B")
    await harness.database.upsertWorkspace(
      identity: identity(root: rootA),
      roots: [rootA],
      documents: [docA]
    )
    await harness.database.upsertWorkspace(
      identity: identity(root: rootB),
      roots: [rootB],
      documents: [docB]
    )

    let payload = try decode(
      try WorkspaceSearchTool.workspaceSearch(
        query: "xenon",
        documents: [docA],
        database: harness.database
      )
    )
    XCTAssertEqual(payload.matches.map(\.path), [docA.url.standardizedFileURL.path])
    XCTAssertFalse(payload.matches.map(\.path).contains(docB.url.standardizedFileURL.path))
  }

  func testSnippetIsReadFromTheFileAndCappedAt320() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let root = try makeRoot(in: harness.base, name: "ws")
    let ref = try makeDoc(
      root: root,
      name: "note.md",
      body: "alpha beta INDEXED_ONLY_TOKEN"
    )
    await harness.database.upsertWorkspace(
      identity: identity(root: root),
      roots: [root],
      documents: [ref]
    )
    let rewritten = "alpha beta FILE_ONLY_TOKEN " + String(repeating: "n", count: 500)
    try rewritten.write(to: ref.url, atomically: true, encoding: .utf8)

    let sidebar = harness.database.search(query: "alpha beta", documents: [ref])
    XCTAssertEqual(sidebar.count, 1)
    XCTAssertTrue(sidebar[0].snippet?.contains("INDEXED_ONLY_TOKEN") == true)

    let payload = try decode(
      try WorkspaceSearchTool.workspaceSearch(
        query: "alpha beta",
        documents: [ref],
        database: harness.database
      )
    )
    XCTAssertEqual(payload.matches.count, 1)
    let snippet = payload.matches[0].snippet
    XCTAssertEqual(snippet.count, 320)
    XCTAssertTrue(snippet.contains("FILE_ONLY_TOKEN"))
    XCTAssertFalse(snippet.contains("INDEXED_ONLY_TOKEN"))
    XCTAssertNotEqual(snippet, sidebar[0].snippet)
  }

  func testKeepsSearchOrderRatherThanUpdatedAtAlone() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let root = try makeRoot(in: harness.base, name: "ws")
    let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
    let newerDate = Date(timeIntervalSince1970: 1_700_086_400)
    let older = try makeDoc(
      root: root,
      name: "older.md",
      body: "# Alpha Beta\nstale heading",
      modifiedAt: olderDate
    )
    let newer = try makeDoc(
      root: root,
      name: "newer.md",
      body: "alpha beta lives only in the body",
      modifiedAt: newerDate
    )
    await harness.database.upsertWorkspace(
      identity: identity(root: root),
      roots: [root],
      documents: [older, newer]
    )

    let searched = harness.database.search(
      query: "alpha beta",
      documents: [older, newer],
      limit: WorkspaceSearchTool.defaultLimit
    )
    XCTAssertEqual(
      searched.map(\.document.id),
      [older.url.standardizedFileURL, newer.url.standardizedFileURL],
      "title match outranks a newer body match; search does not sort by date alone"
    )
    let newestFirst = searched.sorted { $0.updatedAt > $1.updatedAt }.map(\.document.id)
    XCTAssertNotEqual(searched.map(\.document.id), newestFirst)
    XCTAssertGreaterThan(searched[1].updatedAt, searched[0].updatedAt)

    let payload = try decode(
      try WorkspaceSearchTool.workspaceSearch(
        query: "alpha beta",
        documents: [older, newer],
        database: harness.database
      )
    )
    XCTAssertEqual(
      payload.matches.map(\.path),
      searched.map { $0.document.url.standardizedFileURL.path }
    )
    XCTAssertEqual(payload.matches.map(\.match), ["title", "body"])
  }

  func testSidebarSearchKeepsDefaultLimitOfFifty() async throws {
    let harness = try makeHarness()
    defer { harness.cleanup() }
    let root = try makeRoot(in: harness.base, name: "ws")
    var documents: [DocumentRef] = []
    for index in 0..<51 {
      documents.append(
        try makeDoc(
          root: root,
          name: String(format: "quota-%02d.md", index),
          body: "quota marker \(index)"
        )
      )
    }
    await harness.database.upsertWorkspace(
      identity: identity(root: root),
      roots: [root],
      documents: documents
    )

    let implicit = harness.database.search(query: "quota", documents: documents)
    let explicit = harness.database.search(query: "quota", documents: documents, limit: 50)
    XCTAssertEqual(implicit.count, 50)
    XCTAssertEqual(implicit.map(\.document.id), explicit.map(\.document.id))
  }
}
