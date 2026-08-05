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
    replaceExistingDocument: ((String, URL) throws -> Void)? = nil,
    indexDocument: (@MainActor (DocumentRef, String, AppState?) -> Void)? = nil,
    dirtySessionPrompt: (@MainActor (DocumentSession) -> SaveChangesResponse)? = nil,
    savePanelURLProvider: (@MainActor (AppState) -> URL?)? = nil,
    backgroundTextReader: DocumentStore.BackgroundTextReader? = nil,
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
      replaceExistingDocument: replaceExistingDocument,
      indexDocument: indexDocument,
      dirtySessionPrompt: dirtySessionPrompt,
      savePanelURLProvider: savePanelURLProvider,
      backgroundTextReader: backgroundTextReader,
      selfWriteObserver: selfWriteObserver
    )
  }

  /// The user picking a document, spelled out.
  ///
  /// Opening a workspace no longer selects anything by itself — see
  /// `LaunchOpensNothingTests` for why a launch that picks its own document is
  /// a bug and not a convenience. Tests that need an open document therefore
  /// have to open one, through the same shared store every sidebar selection
  /// and workspace path goes through.
  @MainActor
  @discardableResult
  func selectDocument(
    at url: URL,
    in appState: AppState,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Bool {
    let target = url.standardizedFileURL
    guard
      let ref = appState.allDocuments.first(where: { $0.url.standardizedFileURL == target })
    else {
      XCTFail("no document at \(target.path) to select", file: file, line: line)
      return false
    }
    return DocumentStore.shared.select(ref: ref, into: appState)
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
