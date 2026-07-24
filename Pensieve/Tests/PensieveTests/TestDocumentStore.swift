import XCTest

@testable import Pensieve

extension XCTestCase {
  @MainActor
  func makeTestDocumentStore(
    autosaver: Autosaver? = nil,
    indexDatabase: IndexDatabase? = nil,
    bookmarkStore: BookmarkStore? = nil,
    recoveryStore: RecoveryStore? = nil,
    savingSettings: DocumentSavingSettings? = nil,
    writeDocument: ((String, URL) throws -> Void)? = nil,
    indexDocument: (@MainActor (DocumentRef, String, AppState?) -> Void)? = nil,
    dirtySessionPrompt: (@MainActor (DocumentSession) -> SaveChangesResponse)? = nil,
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
      // Never the shared preference: whatever the developer running the suite has
      // toggled in the real app must not decide how these tests behave.
      savingSettings: savingSettings ?? makeAutoSaveSettings(enabled: true),
      writeDocument: writeDocument,
      indexDocument: indexDocument,
      dirtySessionPrompt: dirtySessionPrompt,
      savePanelURLProvider: savePanelURLProvider,
      selfWriteObserver: selfWriteObserver
    )
  }

  /// Auto-save preference on a throwaway defaults suite, so a test states the
  /// state it exercises instead of inheriting the machine's.
  @MainActor
  func makeAutoSaveSettings(enabled: Bool) -> DocumentSavingSettings {
    let settings = DocumentSavingSettings(
      defaults: makeEphemeralDefaults(prefix: "PensieveAutoSaveTests"))
    settings.autoSavesPathedDocuments = enabled
    return settings
  }
}
