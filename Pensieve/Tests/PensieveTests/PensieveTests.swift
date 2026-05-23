import AppKit
import SwiftUI
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

    @MainActor
    func testMarkdownEditorSurfaceLoadsAndUpdatesDocumentText() {
        let loadedText = "# Loaded\n\nThe editor must show this text."
        let surface = MarkdownEditorSurface(text: loadedText, fontSize: 14)

        XCTAssertTrue(surface.scrollView.documentView === surface.textView)
        XCTAssertEqual((surface.scrollView.documentView as? NSTextView)?.string, loadedText)
        XCTAssertEqual(surface.textStorage.string, loadedText)
        XCTAssertNotNil(surface.textView.gutter)
        XCTAssertNotNil(surface.textStorage.attribute(.font, at: 0, effectiveRange: nil))

        let updatedText = "## Updated\n\nBinding changes must reach AppKit."
        surface.update(text: updatedText, fontSize: 18)

        XCTAssertEqual(surface.textView.string, updatedText)
        XCTAssertEqual(surface.textView.gutter?.fontSize, 18)
    }

    @MainActor
    func testMarkdownEditorTypingMarksDirtyAndPostsDocumentChanged() {
        var boundText = "before"
        var isDirty = false
        let representable = EditorRepresentable(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            fontSize: 14,
            isDirty: Binding(get: { isDirty }, set: { isDirty = $0 })
        )
        let coordinator = representable.makeCoordinator()
        let surface = MarkdownEditorSurface(text: boundText, fontSize: 14)
        surface.onTextChanged = { newText in
            boundText = newText
            isDirty = true
            NotificationCenter.default.post(name: .vcDocumentChanged, object: nil)
        }
        coordinator.surface = surface

        let documentChanged = expectation(forNotification: .vcDocumentChanged, object: nil)
        surface.textView.string = "typed edit"
        surface.textDidChange(Notification(name: NSText.didChangeNotification, object: surface.textView))

        wait(for: [documentChanged], timeout: 1.0)
        XCTAssertEqual(boundText, "typed edit")
        XCTAssertTrue(isDirty)
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
    func testDirtyDocumentIsSavedBeforeFastSelectionLoad() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveDirtySwitchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let alphaURL = folder.appendingPathComponent("alpha.md")
        let betaURL = folder.appendingPathComponent("beta.md")
        try "alpha original".write(to: alphaURL, atomically: true, encoding: .utf8)
        try "beta original".write(to: betaURL, atomically: true, encoding: .utf8)

        let appState = AppState()
        appState.documents = [DocumentRef(id: alphaURL), DocumentRef(id: betaURL)]
        DocumentStore.shared.load(ref: DocumentRef(id: alphaURL), into: appState)

        appState.activeDocumentText = "alpha unsaved"
        appState.activeDocumentDirty = true

        // SwiftUI List selection can mutate before its onChange load callback runs.
        appState.selectedDocumentID = betaURL
        DocumentStore.shared.load(ref: DocumentRef(id: betaURL), into: appState)

        XCTAssertEqual(try String(contentsOf: alphaURL, encoding: .utf8), "alpha unsaved")
        XCTAssertEqual(try String(contentsOf: betaURL, encoding: .utf8), "beta original")
        XCTAssertEqual(appState.activeDocumentText, "beta original")
        XCTAssertEqual(appState.activeDocumentURL?.resolvingSymlinksInPath(), betaURL.resolvingSymlinksInPath())
        XCTAssertFalse(appState.activeDocumentDirty)
    }

    @MainActor
    func testExplicitSaveWritesLoadedDocumentEvenIfSelectionAlreadyMoved() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveExplicitSaveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let alphaURL = folder.appendingPathComponent("alpha.md")
        let betaURL = folder.appendingPathComponent("beta.md")
        try "alpha original".write(to: alphaURL, atomically: true, encoding: .utf8)
        try "beta original".write(to: betaURL, atomically: true, encoding: .utf8)

        let appState = AppState()
        appState.documents = [DocumentRef(id: alphaURL), DocumentRef(id: betaURL)]
        DocumentStore.shared.load(ref: DocumentRef(id: alphaURL), into: appState)

        appState.activeDocumentText = "alpha command save"
        appState.activeDocumentDirty = true
        appState.selectedDocumentID = betaURL

        DocumentStore.shared.save(appState: appState)

        XCTAssertEqual(try String(contentsOf: alphaURL, encoding: .utf8), "alpha command save")
        XCTAssertEqual(try String(contentsOf: betaURL, encoding: .utf8), "beta original")
        XCTAssertFalse(appState.activeDocumentDirty)
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
