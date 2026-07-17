import Foundation
import XCTest

@testable import Pensieve

@MainActor
final class OpenFileFastPathTests: XCTestCase {
  func testRegisterOpenFileStandardizesOnceAcrossFiveThousandDocuments() throws {
    let probe = StandardizationProbe()
    let harness = try makeHarness(standardizeFileURL: probe.standardize)
    let appState = AppState()
    let documentRoot = harness.root.appendingPathComponent("Documents", isDirectory: true)
    let documents = (0..<5_000).map { index in
      DocumentRef(id: documentRoot.appendingPathComponent("document-\(index).md"))
    }
    appState.documents = documents
    let expected = try XCTUnwrap(documents.last)

    let start = ContinuousClock.now
    let registered = harness.manager.registerOpenFile(url: expected.url, into: appState)
    let elapsed = ContinuousClock.now - start
    print(
      "[pensieve-trace] open-file-fast-path documents=5000 normalizations=\(probe.callCount) "
        + "elapsed=\(elapsed)"
    )

    XCTAssertEqual(registered, expected)
    XCTAssertEqual(probe.callCount, 1)
    XCTAssertTrue(appState.openFiles.isEmpty)
    XCTAssertLessThan(
      elapsed,
      .milliseconds(50),
      "5,000 pure path comparisons should stay below the hard main-actor budget; elapsed \(elapsed)"
    )
  }

  func testRegisterOpenFilePreservesDuplicateAndNewOpenSemantics() throws {
    let probe = StandardizationProbe()
    let harness = try makeHarness(standardizeFileURL: probe.standardize)
    let existingURL = harness.root.appendingPathComponent("existing.md").standardizedFileURL
    let newURL = harness.root.appendingPathComponent("new.md").standardizedFileURL
    try "existing".write(to: existingURL, atomically: true, encoding: .utf8)
    try "new".write(to: newURL, atomically: true, encoding: .utf8)

    let appState = AppState()
    let existing = DocumentRef(id: existingURL, isAdHoc: false)
    appState.documents = [existing]
    appState.selectedDocumentID = existingURL

    let duplicate = harness.manager.registerOpenFile(url: existingURL, into: appState)
    XCTAssertEqual(duplicate, existing)
    XCTAssertTrue(appState.openFiles.isEmpty)
    XCTAssertEqual(appState.selectedDocumentID, existingURL)

    let inserted = try XCTUnwrap(
      harness.manager.registerOpenFile(url: newURL, into: appState))
    XCTAssertEqual(inserted.id, newURL)
    XCTAssertTrue(inserted.isAdHoc)
    XCTAssertEqual(appState.openFiles, [inserted])
    XCTAssertEqual(appState.selectedDocumentID, existingURL)

    let repeated = harness.manager.registerOpenFile(url: newURL, into: appState)
    XCTAssertEqual(repeated, inserted)
    XCTAssertEqual(appState.openFiles, [inserted])
    XCTAssertEqual(appState.selectedDocumentID, existingURL)
    XCTAssertEqual(probe.callCount, 3)
    XCTAssertNil(appState.lastError)
  }

  func testRegisterOpenFileCanonicalizesNonstandardInputBeforeDeduplication() throws {
    let probe = StandardizationProbe()
    let harness = try makeHarness(standardizeFileURL: probe.standardize)
    let nestedDirectory = harness.root.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(
      at: nestedDirectory, withIntermediateDirectories: true)
    let canonicalURL = harness.root.appendingPathComponent("canonical.md").standardizedFileURL
    try "canonical".write(to: canonicalURL, atomically: true, encoding: .utf8)
    let nonstandardURL = URL(
      fileURLWithPath: nestedDirectory.path + "/../" + canonicalURL.lastPathComponent)
    XCTAssertNotEqual(nonstandardURL.path, canonicalURL.path)

    let appState = AppState()
    let inserted = try XCTUnwrap(
      harness.manager.registerOpenFile(url: nonstandardURL, into: appState))
    let repeated = harness.manager.registerOpenFile(url: canonicalURL, into: appState)

    XCTAssertEqual(inserted.id, canonicalURL)
    XCTAssertEqual(repeated, inserted)
    XCTAssertEqual(appState.openFiles, [inserted])
    XCTAssertEqual(probe.callCount, 2)
  }

  func testRegisterOpenFilePrunesByStoredPathWithoutRenormalizingCandidates() throws {
    let probe = StandardizationProbe()
    let harness = try makeHarness(standardizeFileURL: probe.standardize)
    let appState = AppState()
    let original = (0..<WorkspaceStore.maxOpenFiles).map { index in
      DocumentRef(
        id: harness.root.appendingPathComponent("open-\(index).md"),
        isAdHoc: true
      )
    }
    appState.openFiles = original
    let newURL = harness.root.appendingPathComponent("protected.md").standardizedFileURL
    try "protected".write(to: newURL, atomically: true, encoding: .utf8)

    let inserted = try XCTUnwrap(
      harness.manager.registerOpenFile(url: newURL, into: appState))

    XCTAssertEqual(probe.callCount, 1)
    XCTAssertEqual(appState.openFiles.count, WorkspaceStore.maxOpenFiles)
    XCTAssertEqual(appState.openFiles.first, original[1])
    XCTAssertEqual(appState.openFiles.last, inserted)
  }

  private func makeHarness(
    standardizeFileURL: @escaping FolderManager.StandardizeFileURL
  ) throws -> FastPathHarness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PensieveOpenFileFastPath-\(UUID().uuidString)", isDirectory: true)
    let support = root.appendingPathComponent("Support", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

    let suiteName = "PensieveOpenFileFastPathBookmarks-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    addTeardownBlock {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: root)
    }

    let manager = FolderManager(
      metadataStore: WorkspaceMetadataStore(
        metadataURL: support.appendingPathComponent("workspace.json")),
      indexDatabase: IndexDatabase(databaseURL: support.appendingPathComponent("index.db")),
      bookmarkStore: BookmarkStore(defaults: defaults),
      workspaceSubstrate: WorkspaceSubstrate(
        store: WorkspaceCacheStore(
          baseDirectory: support.appendingPathComponent("WorkspaceCache", isDirectory: true))),
      standardizeFileURL: standardizeFileURL
    )
    return FastPathHarness(root: root, manager: manager)
  }
}

@MainActor
private final class StandardizationProbe {
  private(set) var callCount = 0

  func standardize(_ url: URL) -> URL {
    callCount += 1
    return url.standardizedFileURL
  }
}

@MainActor
private struct FastPathHarness {
  let root: URL
  let manager: FolderManager
}
