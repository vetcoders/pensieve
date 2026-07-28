import XCTest

@testable import Pensieve

extension XCTestCase {
  @MainActor
  func makeTestDocumentStore(
    autosaver: Autosaver? = nil,
    indexDatabase: IndexDatabase? = nil,
    bookmarkStore: BookmarkStore? = nil,
    recoveryStore: RecoveryStore? = nil,
    writeDocument: ((String, URL) throws -> Void)? = nil,
    indexDocument: (@MainActor (DocumentRef, String, AppState?) -> Void)? = nil,
    dirtyUntitledPrompt: (@MainActor (DocumentSession) -> DocumentStore.DirtyUntitledResponse)? = nil,
    savePanelURLProvider: (@MainActor (AppState) -> URL?)? = nil,
    selfWriteObserver: (@MainActor (URL) -> Void)? = nil
  ) -> DocumentStore {
    let recoveryRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: recoveryRoot)
    }
    return DocumentStore(
      autosaver: autosaver,
      indexDatabase: indexDatabase,
      bookmarkStore: bookmarkStore,
      recoveryStore: recoveryStore ?? RecoveryStore(directoryURL: recoveryRoot),
      writeDocument: writeDocument,
      indexDocument: indexDocument,
      dirtyUntitledPrompt: dirtyUntitledPrompt,
      savePanelURLProvider: savePanelURLProvider,
      selfWriteObserver: selfWriteObserver
    )
  }
}
