import XCTest
@testable import Pensieve

final class PensieveSmokeTests: XCTestCase {
    func testEditorModeRawValues() {
        XCTAssertEqual(EditorMode.source.rawValue, 1)
        XCTAssertEqual(EditorMode.split.rawValue, 2)
        XCTAssertEqual(EditorMode.preview.rawValue, 3)
        XCTAssertEqual(EditorMode.focus.rawValue, 4)
    }

    func testEditorModeLabels() {
        XCTAssertEqual(EditorMode.source.label, "Source")
        XCTAssertEqual(EditorMode.split.label, "Split")
        XCTAssertEqual(EditorMode.preview.label, "Preview")
        XCTAssertEqual(EditorMode.focus.label, "Focus")
    }

    func testFileWatcherReportsDirectoryChanges() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let changed = expectation(description: "folder change detected")
        let watcher = FileWatcher()
        try watcher.start(watching: folder) {
            changed.fulfill()
        }

        try "watched".write(
            to: folder.appendingPathComponent("watched.md"),
            atomically: true,
            encoding: .utf8
        )

        wait(for: [changed], timeout: 2.0)
        watcher.stop()
    }

    @MainActor
    func testFolderOpenAndAutosaveWriteThrough() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let noteURL = folder.appendingPathComponent("alpha.md")
        try "initial".write(to: noteURL, atomically: true, encoding: .utf8)

        let appState = AppState()
        FolderManager.shared.open(url: folder, into: appState)

        XCTAssertEqual(
            appState.documents.map { $0.url.resolvingSymlinksInPath() },
            [noteURL.resolvingSymlinksInPath()]
        )
        XCTAssertEqual(appState.selectedDocumentID?.resolvingSymlinksInPath(), noteURL.resolvingSymlinksInPath())
        XCTAssertEqual(appState.activeDocumentText, "initial")
        XCTAssertFalse(appState.activeDocumentDirty)

        appState.activeDocumentText = "changed"
        appState.activeDocumentDirty = true
        NotificationCenter.default.post(name: .vcDocumentChanged, object: nil)

        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "changed")
        XCTAssertFalse(appState.activeDocumentDirty)

        BookmarkStore.shared.clear(into: appState)
    }

    @MainActor
    func testIndexDatabaseUsesCanonicalApplicationSupportPath() {
        let appState = AppState()

        IndexDatabase.shared.open(into: appState)

        XCTAssertNil(appState.lastError)
        XCTAssertEqual(IndexDatabase.shared.databaseURL?.lastPathComponent, "index.db")
        XCTAssertEqual(IndexDatabase.shared.databaseURL?.deletingLastPathComponent().lastPathComponent, "Pensieve")
    }

    @MainActor
    func testBookmarkRestoreClearsDeletedFolder() throws {
        let suiteName = "PensieveBookmarkTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveBookmarkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let appState = AppState()
        let store = BookmarkStore(defaults: defaults)
        try store.persist(url: folder, into: appState)
        try FileManager.default.removeItem(at: folder)

        XCTAssertNil(store.restore(into: appState))
        XCTAssertNil(appState.bookmarkData)
        XCTAssertNotNil(appState.lastError)
    }
}
