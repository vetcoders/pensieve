import GRDB
import XCTest

@testable import Pensieve

@MainActor
final class IndexDatabaseV2WriterTests: XCTestCase {
  func testFolderManagerColdScanWritesWorkspaceAndDocumentsRows() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let nested = folder.appendingPathComponent("Nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

    let alphaBody = "# Alpha Title\n\nalpha body"
    let betaBody = "beta body without heading"
    let alphaURL = folder.appendingPathComponent("alpha.md")
    let betaURL = nested.appendingPathComponent("beta.markdown")
    try alphaBody.write(to: alphaURL, atomically: true, encoding: .utf8)
    try betaBody.write(to: betaURL, atomically: true, encoding: .utf8)

    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let appState = AppState()
    let indexDatabase = IndexDatabase(databaseURL: databaseURL)
    let manager = FolderManager(
      metadataStore: temporaryMetadataStore(),
      indexDatabase: indexDatabase,
      bookmarkStore: temporaryBookmarkStore(),
      workspaceSubstrate: WorkspaceSubstrate(store: WorkspaceCacheStore(baseDirectory: folder))
    )

    manager.openInBackground(url: folder, into: appState)
    await manager.waitForPendingWorkspaceBuild()

    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: appState.bookmarkData)
    let workspaces = try readWorkspaces(at: databaseURL)
    XCTAssertEqual(workspaces.count, 1)
    XCTAssertEqual(workspaces.first?.workspaceID, identity.workspaceID)
    XCTAssertEqual(workspaces.first?.canonicalPath, folder.standardizedFileURL.path)
    XCTAssertEqual(workspaces.first?.bookmarkHash, identity.rootBookmarkHash)
    XCTAssertEqual(workspaces.first?.status, "active")
    XCTAssertEqual(workspaces.first?.firstSeenAt, workspaces.first?.lastSeenAt)

    let documents = try readDocuments(at: databaseURL)
    XCTAssertEqual(Set(documents.map(\.path)), ["alpha.md", "Nested/beta.markdown"])
    let alpha = try XCTUnwrap(documents.first { $0.path == "alpha.md" })
    XCTAssertEqual(alpha.workspaceID, identity.workspaceID)
    XCTAssertEqual(alpha.title, "Alpha Title")
    XCTAssertEqual(alpha.body, alphaBody)
    XCTAssertEqual(alpha.mtime, try fileMTime(alphaURL))
    XCTAssertEqual(alpha.size, try fileSize(alphaURL))
    XCTAssertEqual(alpha.isAdHoc, 0)
    XCTAssertGreaterThan(alpha.indexedAt, 0)
    XCTAssertTrue(workspaces.contains { $0.workspaceID == alpha.workspaceID })

    let beta = try XCTUnwrap(documents.first { $0.path == "Nested/beta.markdown" })
    XCTAssertEqual(beta.title, "beta")
    XCTAssertEqual(beta.body, betaBody)
  }

  func testIndexDatabaseV2WriterUpdatesExistingDocumentRows() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let noteURL = folder.appendingPathComponent("note.md")
    try "old body".write(to: noteURL, atomically: true, encoding: .utf8)

    let database = IndexDatabase(databaseURL: databaseURL)
    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: nil)
    try await writeCurrentScan(
      root: folder,
      database: database,
      identity: identity,
      lastSeenAt: Date(timeIntervalSince1970: 10)
    )

    try "# New Title\n\nnew body with more bytes".write(
      to: noteURL, atomically: true, encoding: .utf8)
    try await writeCurrentScan(
      root: folder,
      database: database,
      identity: identity,
      lastSeenAt: Date(timeIntervalSince1970: 20)
    )

    let documents = try readDocuments(at: databaseURL)
    XCTAssertEqual(documents.count, 1)
    let row = try XCTUnwrap(documents.first)
    XCTAssertEqual(row.path, "note.md")
    XCTAssertEqual(row.title, "New Title")
    XCTAssertEqual(row.body, "# New Title\n\nnew body with more bytes")
    XCTAssertEqual(row.mtime, try fileMTime(noteURL))
    XCTAssertEqual(row.size, try fileSize(noteURL))
    XCTAssertEqual(row.indexedAt, 20)
  }

  func testIndexDatabaseV2WriterInsertsNewDocumentsOnRescan() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    try "alpha body".write(
      to: folder.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)

    let database = IndexDatabase(databaseURL: databaseURL)
    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: nil)
    try await writeCurrentScan(
      root: folder,
      database: database,
      identity: identity,
      lastSeenAt: Date(timeIntervalSince1970: 30)
    )

    try "# Beta\n\nbeta body".write(
      to: folder.appendingPathComponent("beta.md"), atomically: true, encoding: .utf8)
    try await writeCurrentScan(
      root: folder,
      database: database,
      identity: identity,
      lastSeenAt: Date(timeIntervalSince1970: 40)
    )

    let documents = try readDocuments(at: databaseURL)
    XCTAssertEqual(Set(documents.map(\.path)), ["alpha.md", "beta.md"])
    XCTAssertEqual(documents.first { $0.path == "beta.md" }?.title, "Beta")
  }

  func testIndexDatabaseV2WriterDeletesMissingDocumentsOnRescan() async throws {
    let folder = try makeTemporaryFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let databaseURL = folder.appendingPathComponent("index.db", isDirectory: false)
    let alphaURL = folder.appendingPathComponent("alpha.md")
    let betaURL = folder.appendingPathComponent("beta.md")
    try "alpha body".write(to: alphaURL, atomically: true, encoding: .utf8)
    try "beta body".write(to: betaURL, atomically: true, encoding: .utf8)

    let database = IndexDatabase(databaseURL: databaseURL)
    let identity = WorkspaceIdentity.make(rootURL: folder, bookmarkData: nil)
    try await writeCurrentScan(
      root: folder,
      database: database,
      identity: identity,
      lastSeenAt: Date(timeIntervalSince1970: 50)
    )

    try FileManager.default.removeItem(at: betaURL)
    try await writeCurrentScan(
      root: folder,
      database: database,
      identity: identity,
      lastSeenAt: Date(timeIntervalSince1970: 60)
    )

    let documents = try readDocuments(at: databaseURL)
    XCTAssertEqual(documents.map(\.path), ["alpha.md"])
    XCTAssertEqual(documents.first?.body, "alpha body")
  }

  // MARK: - Helpers

  private func writeCurrentScan(
    root: URL,
    database: IndexDatabase,
    identity: WorkspaceIdentity,
    lastSeenAt: Date
  ) async throws {
    let documents = WorkspaceScanner.build(rootURLs: [root], exclusions: [])
      .flatMap(\.documents)
    let appState = AppState()
    await database.upsertWorkspace(
      identity: identity,
      roots: [root.standardizedFileURL],
      lastSeenAt: lastSeenAt,
      documents: documents,
      appState: appState
    )
    XCTAssertNil(appState.lastError)
  }

  private func makeTemporaryFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveIndexV2WriterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private func temporaryMetadataStore() -> WorkspaceMetadataStore {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PensieveIndexV2MetadataTests-\(UUID().uuidString)",
        isDirectory: true
      )
    return WorkspaceMetadataStore(
      metadataURL: folder.appendingPathComponent("workspace.json", isDirectory: false))
  }

  private func temporaryBookmarkStore() -> BookmarkStore {
    let suiteName = "PensieveIndexV2BookmarkTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return BookmarkStore(defaults: defaults)
  }

  private func readWorkspaces(at databaseURL: URL) throws -> [WorkspaceRow] {
    let queue = try DatabaseQueue(path: databaseURL.path)
    return try queue.read { db in
      try WorkspaceRow.fetchAll(
        db,
        sql: """
          SELECT workspace_id, canonical_path, volume_resource_id, bookmark_hash,
                 first_seen_at, last_seen_at, status
          FROM workspaces
          ORDER BY workspace_id
          """)
    }
  }

  private func readDocuments(at databaseURL: URL) throws -> [DocumentRow] {
    let queue = try DatabaseQueue(path: databaseURL.path)
    return try queue.read { db in
      try DocumentRow.fetchAll(
        db,
        sql: """
          SELECT workspace_id, path, title, body, mtime, size, is_ad_hoc, indexed_at
          FROM documents
          ORDER BY path
          """)
    }
  }

  private func fileMTime(_ url: URL) throws -> Int {
    let date = try url.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
    return Int(try XCTUnwrap(date).timeIntervalSince1970)
  }

  private func fileSize(_ url: URL) throws -> Int {
    try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
  }
}

private struct WorkspaceRow: FetchableRecord {
  var workspaceID: String
  var canonicalPath: String
  var volumeResourceID: String?
  var bookmarkHash: String?
  var firstSeenAt: Int
  var lastSeenAt: Int
  var status: String

  init(row: Row) throws {
    workspaceID = row["workspace_id"]
    canonicalPath = row["canonical_path"]
    volumeResourceID = row["volume_resource_id"]
    bookmarkHash = row["bookmark_hash"]
    firstSeenAt = row["first_seen_at"]
    lastSeenAt = row["last_seen_at"]
    status = row["status"]
  }
}

private struct DocumentRow: FetchableRecord {
  var workspaceID: String
  var path: String
  var title: String
  var body: String
  var mtime: Int
  var size: Int
  var isAdHoc: Int
  var indexedAt: Int

  init(row: Row) throws {
    workspaceID = row["workspace_id"]
    path = row["path"]
    title = row["title"]
    body = row["body"]
    mtime = row["mtime"]
    size = row["size"]
    isAdHoc = row["is_ad_hoc"]
    indexedAt = row["indexed_at"]
  }
}
