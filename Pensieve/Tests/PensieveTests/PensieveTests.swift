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
    func testDocumentSessionOwnsActiveDocumentState() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveSessionOwnershipTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let noteURL = folder.appendingPathComponent("session.md")
        try "session original".write(to: noteURL, atomically: true, encoding: .utf8)

        let appState = AppState()
        appState.documents = [DocumentRef(id: noteURL.standardizedFileURL)]
        DocumentStore(indexDatabase: temporaryIndexDatabase(in: folder))
            .load(ref: DocumentRef(id: noteURL.standardizedFileURL), into: appState)

        XCTAssertEqual(appState.documentSession.url?.resolvingSymlinksInPath(), noteURL.resolvingSymlinksInPath())
        XCTAssertEqual(appState.documentSession.text, "session original")
        XCTAssertFalse(appState.documentSession.isDirty)

        appState.activeDocumentText = "session edited"
        appState.activeDocumentDirty = true

        XCTAssertEqual(appState.documentSession.text, "session edited")
        XCTAssertTrue(appState.documentSession.isDirty)
    }

    @MainActor
    func testSelectionRefusesWhenDirtySessionCannotBeSaved() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveDirtyRefusalTests-\(UUID().uuidString)", isDirectory: true)
        let deletedFolder = folder.appendingPathComponent("Deleted", isDirectory: true)
        try FileManager.default.createDirectory(at: deletedFolder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let alphaURL = deletedFolder.appendingPathComponent("alpha.md")
        let betaURL = folder.appendingPathComponent("beta.md")
        try "alpha original".write(to: alphaURL, atomically: true, encoding: .utf8)
        try "beta original".write(to: betaURL, atomically: true, encoding: .utf8)

        let appState = AppState()
        appState.documents = [
            DocumentRef(id: alphaURL.standardizedFileURL),
            DocumentRef(id: betaURL.standardizedFileURL)
        ]
        let controller = AppController(
            appState: appState,
            folderManager: FolderManager(metadataStore: temporaryMetadataStore()),
            documentStore: DocumentStore(indexDatabase: temporaryIndexDatabase(in: folder))
        )
        controller.selectDocument(id: alphaURL.standardizedFileURL)

        appState.activeDocumentText = "alpha unsaved"
        appState.activeDocumentDirty = true
        try FileManager.default.removeItem(at: deletedFolder)

        controller.selectDocument(id: betaURL.standardizedFileURL)

        XCTAssertEqual(appState.selectedDocumentID?.resolvingSymlinksInPath(), alphaURL.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(appState.documentSession.url?.resolvingSymlinksInPath(), alphaURL.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(appState.documentSession.text, "alpha unsaved")
        XCTAssertTrue(appState.documentSession.isDirty)
        XCTAssertTrue(appState.lastError?.contains("Could not save alpha.md") == true)
    }

    @MainActor
    func testExternalRefreshReloadsCleanSessionButProtectsDirtySession() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveRefreshSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let noteURL = folder.appendingPathComponent("note.md")
        try "clean original".write(to: noteURL, atomically: true, encoding: .utf8)

        let appState = AppState()
        let manager = FolderManager(metadataStore: temporaryMetadataStore(), indexDatabase: temporaryIndexDatabase(in: folder))
        manager.open(url: folder, into: appState)
        XCTAssertEqual(appState.documentSession.text, "clean original")

        try "clean external".write(to: noteURL, atomically: true, encoding: .utf8)
        manager.refresh(into: appState)
        XCTAssertEqual(appState.documentSession.text, "clean external")
        XCTAssertFalse(appState.documentSession.isDirty)

        appState.activeDocumentText = "dirty local edit"
        appState.activeDocumentDirty = true
        try "dirty external".write(to: noteURL, atomically: true, encoding: .utf8)
        manager.refresh(into: appState)

        XCTAssertEqual(appState.documentSession.text, "dirty local edit")
        XCTAssertTrue(appState.documentSession.isDirty)
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
    func testCloseActiveDocumentClearsSessionWithoutDroppingWorkspace() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveCloseClearTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let alphaURL = folder.appendingPathComponent("alpha.md")
        let betaURL = folder.appendingPathComponent("beta.md")
        try "alpha body".write(to: alphaURL, atomically: true, encoding: .utf8)
        try "beta body".write(to: betaURL, atomically: true, encoding: .utf8)

        let appState = AppState()
        let indexDatabase = temporaryIndexDatabase(in: folder)
        let controller = AppController(
            appState: appState,
            folderManager: FolderManager(metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
            documentStore: DocumentStore(indexDatabase: indexDatabase),
            indexDatabase: indexDatabase
        )

        controller.openFolder(url: folder)
        controller.selectDocument(id: alphaURL.standardizedFileURL)
        XCTAssertNotNil(appState.documentSession.document)

        let workspaceDocumentsBefore = appState.documents.map(\.id)

        let didClose = controller.closeActiveDocument()

        XCTAssertTrue(didClose)
        XCTAssertNil(appState.documentSession.document)
        XCTAssertNil(appState.selectedDocumentID)
        XCTAssertEqual(appState.documentSession.text, "")
        XCTAssertFalse(appState.documentSession.isDirty)
        // Workspace and other open documents stay alive — only the active
        // session is cleared, not the window or sidebar contents.
        XCTAssertEqual(appState.documents.map(\.id), workspaceDocumentsBefore)
        XCTAssertEqual(appState.workspaceRoots.map(\.url), [folder.standardizedFileURL])
    }

    @MainActor
    func testCloseActiveDocumentSavesDirtySessionBeforeClearing() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveCloseDirtyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let noteURL = folder.appendingPathComponent("dirty.md")
        try "original".write(to: noteURL, atomically: true, encoding: .utf8)

        let appState = AppState()
        appState.documents = [DocumentRef(id: noteURL.standardizedFileURL)]
        let indexDatabase = temporaryIndexDatabase(in: folder)
        let documentStore = DocumentStore(indexDatabase: indexDatabase)
        let controller = AppController(
            appState: appState,
            folderManager: FolderManager(metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
            documentStore: documentStore,
            indexDatabase: indexDatabase
        )
        documentStore.load(ref: DocumentRef(id: noteURL.standardizedFileURL), into: appState)

        appState.activeDocumentText = "edited before close"
        appState.activeDocumentDirty = true

        let didClose = controller.closeActiveDocument()

        XCTAssertTrue(didClose)
        XCTAssertEqual(try String(contentsOf: noteURL, encoding: .utf8), "edited before close")
        XCTAssertNil(appState.documentSession.document)
        XCTAssertNil(appState.selectedDocumentID)
        XCTAssertFalse(appState.documentSession.isDirty)
    }

    @MainActor
    func testCloseActiveDocumentRefusesWhenDirtySaveFails() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveCloseRefusalTests-\(UUID().uuidString)", isDirectory: true)
        let writable = folder.appendingPathComponent("Writable", isDirectory: true)
        try FileManager.default.createDirectory(at: writable, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let noteURL = writable.appendingPathComponent("doomed.md")
        try "original".write(to: noteURL, atomically: true, encoding: .utf8)

        let appState = AppState()
        appState.documents = [DocumentRef(id: noteURL.standardizedFileURL)]
        let indexDatabase = temporaryIndexDatabase(in: folder)
        let documentStore = DocumentStore(indexDatabase: indexDatabase)
        let controller = AppController(
            appState: appState,
            folderManager: FolderManager(metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
            documentStore: documentStore,
            indexDatabase: indexDatabase
        )
        documentStore.load(ref: DocumentRef(id: noteURL.standardizedFileURL), into: appState)

        appState.activeDocumentText = "unsaved tail"
        appState.activeDocumentDirty = true

        // Knock the directory out from under the active document so its save
        // fails. The session must stay alive and dirty rather than silently
        // dropping the user's edits.
        try FileManager.default.removeItem(at: writable)

        let didClose = controller.closeActiveDocument()

        XCTAssertFalse(didClose)
        XCTAssertNotNil(appState.documentSession.document)
        XCTAssertEqual(appState.documentSession.text, "unsaved tail")
        XCTAssertTrue(appState.documentSession.isDirty)
        XCTAssertEqual(appState.selectedDocumentID?.resolvingSymlinksInPath(), noteURL.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertTrue(appState.lastError?.contains("Could not save doomed.md") == true)
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
    func testWorkspaceSearchIndexesBodyTextAndSnippet() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveSearchBodyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let noteURL = folder.appendingPathComponent("ordinary-title.md")
        try """
        # Ordinary Title

        The hidden phrase is crystal harmonics inside the body.
        """.write(to: noteURL, atomically: true, encoding: .utf8)

        let appState = AppState()
        let indexDatabase = temporaryIndexDatabase(in: folder)
        let ref = DocumentRef(id: noteURL.standardizedFileURL, rootURL: folder.standardizedFileURL, relativePath: "ordinary-title.md")
        indexDatabase.reindex(documents: [ref], appState: appState)

        let results = indexDatabase.search(query: "crystal harmonics", documents: [ref], appState: appState)

        XCTAssertEqual(results.map(\.document.id), [noteURL.standardizedFileURL])
        XCTAssertEqual(results.first?.matchKind, .body)
        XCTAssertTrue(results.first?.snippet?.contains("crystal harmonics") == true)
    }

    @MainActor
    func testWorkspaceSearchDropsExcludedPathsAfterReindex() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveSearchExclusionTests-\(UUID().uuidString)", isDirectory: true)
        let drafts = folder.appendingPathComponent("Drafts", isDirectory: true)
        try FileManager.default.createDirectory(at: drafts, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        try "public notes".write(to: folder.appendingPathComponent("keep.md"), atomically: true, encoding: .utf8)
        let skipURL = drafts.appendingPathComponent("skip.md")
        try "private nebula keyword".write(to: skipURL, atomically: true, encoding: .utf8)

        let appState = AppState()
        let indexDatabase = temporaryIndexDatabase(in: folder)
        let manager = FolderManager(metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase)
        let controller = AppController(
            appState: appState,
            folderManager: manager,
            documentStore: DocumentStore(indexDatabase: indexDatabase),
            indexDatabase: indexDatabase
        )

        controller.openFolder(url: folder)
        controller.updateWorkspaceSearch(query: "nebula")
        XCTAssertEqual(appState.workspaceSearchResults.map(\.document.id), [skipURL.standardizedFileURL])

        controller.excludeFromWorkspace(urls: [drafts])

        XCTAssertFalse(appState.documents.contains { $0.url == skipURL.standardizedFileURL })
        XCTAssertTrue(appState.workspaceSearchResults.isEmpty)
    }

    @MainActor
    func testSearchResultSelectionLoadsDocumentThroughController() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveSearchSelectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let alphaURL = folder.appendingPathComponent("alpha.md")
        let betaURL = folder.appendingPathComponent("beta.md")
        try "alpha body".write(to: alphaURL, atomically: true, encoding: .utf8)
        try "beta contains selection-token".write(to: betaURL, atomically: true, encoding: .utf8)

        let appState = AppState()
        let indexDatabase = temporaryIndexDatabase(in: folder)
        let controller = AppController(
            appState: appState,
            folderManager: FolderManager(metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
            documentStore: DocumentStore(indexDatabase: indexDatabase),
            indexDatabase: indexDatabase
        )

        controller.openFolder(url: folder)
        controller.updateWorkspaceSearch(query: "selection-token")
        let result = try XCTUnwrap(appState.workspaceSearchResults.first)

        controller.selectSearchResult(result)

        XCTAssertEqual(appState.selectedDocumentID?.resolvingSymlinksInPath(), betaURL.resolvingSymlinksInPath())
        XCTAssertEqual(appState.activeDocumentText, "beta contains selection-token")
    }

    @MainActor
    func testWorkspaceExplorerNodeSelectionLoadsDocumentThroughController() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveExplorerSelectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let noteURL = folder.appendingPathComponent("clickable.md")
        try "click me".write(to: noteURL, atomically: true, encoding: .utf8)

        let appState = AppState()
        let indexDatabase = temporaryIndexDatabase(in: folder)
        let controller = AppController(
            appState: appState,
            folderManager: FolderManager(metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase),
            documentStore: DocumentStore(indexDatabase: indexDatabase),
            indexDatabase: indexDatabase
        )

        controller.openFolder(url: folder)
        let root = try XCTUnwrap(appState.workspaceTree.first)
        let node = try XCTUnwrap(root.children?.first(where: { $0.documentID == noteURL.standardizedFileURL }))
        controller.selectDocument(id: nil)

        controller.selectWorkspaceNode(node)

        XCTAssertEqual(appState.selectedDocumentID?.resolvingSymlinksInPath(), noteURL.resolvingSymlinksInPath())
        XCTAssertEqual(appState.activeDocumentText, "click me")
    }

    @MainActor
    func testSearchIndexUpdatesAfterSaveAndRefresh() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveSearchRefreshTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let alphaURL = folder.appendingPathComponent("alpha.md")
        let betaURL = folder.appendingPathComponent("beta.md")
        try "alpha original".write(to: alphaURL, atomically: true, encoding: .utf8)
        try "beta original".write(to: betaURL, atomically: true, encoding: .utf8)

        let appState = AppState()
        let indexDatabase = temporaryIndexDatabase(in: folder)
        let manager = FolderManager(metadataStore: temporaryMetadataStore(), indexDatabase: indexDatabase)
        let controller = AppController(
            appState: appState,
            folderManager: manager,
            documentStore: DocumentStore(indexDatabase: indexDatabase),
            indexDatabase: indexDatabase
        )

        controller.openFolder(url: folder)
        controller.selectDocument(id: alphaURL.standardizedFileURL)
        appState.activeDocumentText = "alpha saved search-token"
        appState.activeDocumentDirty = true
        controller.saveActiveDocument()

        controller.updateWorkspaceSearch(query: "search-token")
        XCTAssertEqual(appState.workspaceSearchResults.map(\.document.id), [alphaURL.standardizedFileURL])

        try "beta externally refreshed-token".write(to: betaURL, atomically: true, encoding: .utf8)
        manager.refresh(into: appState)
        controller.updateWorkspaceSearch(query: "refreshed-token")

        XCTAssertEqual(appState.workspaceSearchResults.map(\.document.id), [betaURL.standardizedFileURL])
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

    @MainActor
    private func temporaryIndexDatabase(in folder: URL) -> IndexDatabase {
        IndexDatabase(databaseURL: folder.appendingPathComponent("index.db", isDirectory: false))
    }
}
