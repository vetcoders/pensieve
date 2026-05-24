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
    func testMarkdownEditorTypingMarksDirtyAndRoutesDocumentChanged() {
        var boundText = "before"
        var isDirty = false
        var didRouteDocumentChange = false
        let representable = EditorRepresentable(
            text: Binding(get: { boundText }, set: { boundText = $0 }),
            fontSize: 14,
            isDirty: Binding(get: { isDirty }, set: { isDirty = $0 }),
            onDocumentChanged: {
                didRouteDocumentChange = true
            }
        )
        let coordinator = representable.makeCoordinator()
        let surface = MarkdownEditorSurface(text: boundText, fontSize: 14)
        surface.onTextChanged = { newText in
            boundText = newText
            isDirty = true
            didRouteDocumentChange = true
        }
        coordinator.surface = surface

        surface.textView.string = "typed edit"
        surface.textDidChange(Notification(name: NSText.didChangeNotification, object: surface.textView))

        XCTAssertEqual(boundText, "typed edit")
        XCTAssertTrue(isDirty)
        XCTAssertTrue(didRouteDocumentChange)
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
        let controller = AppController(appState: appState)
        controller.openFolder(url: folder)

        XCTAssertEqual(
            appState.documents.map { $0.url.resolvingSymlinksInPath() },
            [noteURL.resolvingSymlinksInPath()]
        )
        XCTAssertEqual(appState.selectedDocumentID?.resolvingSymlinksInPath(), noteURL.resolvingSymlinksInPath())
        XCTAssertEqual(appState.activeDocumentText, "initial")
        XCTAssertFalse(appState.activeDocumentDirty)

        appState.activeDocumentText = "changed"
        appState.activeDocumentDirty = true
        controller.documentDidChange()

        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "changed")
        XCTAssertFalse(appState.activeDocumentDirty)

        BookmarkStore.shared.clear(into: appState)
    }

    @MainActor
    func testFolderOpenImportsMarkdownRecursivelyAndSkipsDefaultNoise() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveRecursiveImportTests-\(UUID().uuidString)", isDirectory: true)
        let nested = folder.appendingPathComponent("Nested", isDirectory: true)
        let nodeModules = folder.appendingPathComponent("node_modules", isDirectory: true)
        let git = folder.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nodeModules, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let alphaURL = folder.appendingPathComponent("alpha.md")
        let betaURL = nested.appendingPathComponent("beta.markdown")
        try "alpha".write(to: alphaURL, atomically: true, encoding: .utf8)
        try "beta".write(to: betaURL, atomically: true, encoding: .utf8)
        try "ignored".write(to: nested.appendingPathComponent("ignored.txt"), atomically: true, encoding: .utf8)
        try "package".write(to: nodeModules.appendingPathComponent("package.md"), atomically: true, encoding: .utf8)
        try "git".write(to: git.appendingPathComponent("config.md"), atomically: true, encoding: .utf8)

        let appState = AppState()
        let manager = FolderManager(metadataStore: temporaryMetadataStore())
        manager.open(url: folder, into: appState)

        XCTAssertEqual(
            Set(appState.documents.map { $0.url.resolvingSymlinksInPath() }),
            Set([alphaURL.resolvingSymlinksInPath(), betaURL.resolvingSymlinksInPath()])
        )
        XCTAssertEqual(appState.workspaceRoots.map(\.url), [folder.standardizedFileURL])
        XCTAssertEqual(appState.workspaceTree.first?.name, folder.lastPathComponent)
        XCTAssertTrue(appState.workspaceTree.first?.children?.contains(where: { $0.name == "Nested" }) == true)
    }

    @MainActor
    func testWorkspaceExclusionsPersistAndFilterImportedPaths() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveExclusionTests-\(UUID().uuidString)", isDirectory: true)
        let drafts = folder.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let keepURL = folder.appendingPathComponent("keep.md")
        let skipURL = drafts.appendingPathComponent("skip.md")
        try "keep".write(to: keepURL, atomically: true, encoding: .utf8)
        try "skip".write(to: skipURL, atomically: true, encoding: .utf8)

        let metadataStore = temporaryMetadataStore()
        let appState = AppState()
        let manager = FolderManager(metadataStore: metadataStore)
        manager.open(url: folder, into: appState)
        XCTAssertEqual(appState.documents.count, 2)

        manager.addExcludedURLs([drafts], into: appState)

        XCTAssertEqual(appState.excludedWorkspacePaths, Set(["Drafts"]))
        XCTAssertEqual(appState.documents.map { $0.url.resolvingSymlinksInPath() }, [keepURL.resolvingSymlinksInPath()])
        XCTAssertEqual(metadataStore.load().excludedPaths, ["Drafts"])
        XCTAssertFalse(appState.documents.contains(where: { $0.url == skipURL.standardizedFileURL }))

        let relaunchedState = AppState()
        let relaunchedManager = FolderManager(metadataStore: metadataStore)
        relaunchedManager.open(url: folder, into: relaunchedState)
        XCTAssertEqual(relaunchedState.documents.map { $0.url.resolvingSymlinksInPath() }, [keepURL.resolvingSymlinksInPath()])
    }

    @MainActor
    func testOpenSingleMarkdownFileLoadsWithoutWorkspaceFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveOpenFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let noteURL = folder.appendingPathComponent("single.md")
        try "# Single".write(to: noteURL, atomically: true, encoding: .utf8)

        let appState = AppState()
        let controller = AppController(
            appState: appState,
            folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
            documentStore: .shared
        )
        controller.openFile(url: noteURL)

        XCTAssertNil(appState.folderURL)
        XCTAssertTrue(appState.workspaceRoots.isEmpty)
        XCTAssertTrue(appState.documents.isEmpty)
        XCTAssertEqual(appState.openFiles.map { $0.url.resolvingSymlinksInPath() }, [noteURL.resolvingSymlinksInPath()])
        XCTAssertEqual(appState.selectedDocumentID?.resolvingSymlinksInPath(), noteURL.resolvingSymlinksInPath())
        XCTAssertEqual(appState.activeDocumentText, "# Single")
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
        let controller = AppController(appState: appState)
        controller.selectDocument(id: alphaURL)

        appState.activeDocumentText = "alpha unsaved"
        appState.activeDocumentDirty = true

        // SwiftUI List selection can mutate before its onChange load callback runs.
        appState.selectedDocumentID = betaURL
        controller.selectDocument(id: betaURL)

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
        let controller = AppController(appState: appState)

        appState.activeDocumentText = "alpha command save"
        appState.activeDocumentDirty = true
        appState.selectedDocumentID = betaURL

        controller.saveActiveDocument()

        XCTAssertEqual(try String(contentsOf: alphaURL, encoding: .utf8), "alpha command save")
        XCTAssertEqual(try String(contentsOf: betaURL, encoding: .utf8), "beta original")
        XCTAssertFalse(appState.activeDocumentDirty)
    }

    @MainActor
    func testControllerRoutesModeAndPreferenceCommands() {
        let appState = AppState()
        let controller = AppController(appState: appState)

        controller.setMode(.preview)
        XCTAssertEqual(appState.mode, .preview)

        controller.toggleSidebar()
        XCTAssertFalse(appState.sidebarVisible)

        controller.toggleRichMarkdown()
        XCTAssertTrue(appState.richMarkdownEnabled)

        controller.bumpFontSize(by: 2)
        XCTAssertEqual(appState.fontSize, 16)

        controller.resetFontSize()
        XCTAssertEqual(appState.fontSize, 14)
    }

    @MainActor
    func testControllerRoutesWorkspaceCommands() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveWorkspaceCommandTests-\(UUID().uuidString)", isDirectory: true)
        let hidden = folder.appendingPathComponent("Hidden", isDirectory: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        try "visible".write(to: folder.appendingPathComponent("visible.md"), atomically: true, encoding: .utf8)
        try "hidden".write(to: hidden.appendingPathComponent("hidden.md"), atomically: true, encoding: .utf8)

        let appState = AppState()
        let controller = AppController(
            appState: appState,
            folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
            documentStore: .shared
        )

        controller.openFolder(url: folder)
        XCTAssertEqual(appState.documents.count, 2)

        controller.excludeFromWorkspace(urls: [hidden])
        XCTAssertEqual(appState.excludedWorkspacePaths, Set(["Hidden"]))
        XCTAssertEqual(appState.documents.count, 1)

        controller.clearWorkspaceExclusions()
        XCTAssertTrue(appState.excludedWorkspacePaths.isEmpty)
        XCTAssertEqual(appState.documents.count, 2)
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

    private func temporaryMetadataStore() -> WorkspaceMetadataStore {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveMetadataTests-\(UUID().uuidString)", isDirectory: true)
        return WorkspaceMetadataStore(metadataURL: folder.appendingPathComponent("workspace.json", isDirectory: false))
    }
}
