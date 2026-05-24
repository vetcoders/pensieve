import Combine
import CoreGraphics
import Foundation

@MainActor
final class AppController: ObservableObject {
    private let appState: AppState
    private let folderManager: FolderManager
    private let documentStore: DocumentStore
    private let indexDatabase: IndexDatabase

    convenience init(appState: AppState) {
        self.init(
            appState: appState,
            folderManager: FolderManager.shared,
            documentStore: DocumentStore.shared,
            indexDatabase: IndexDatabase.shared
        )
    }

    init(
        appState: AppState,
        folderManager: FolderManager,
        documentStore: DocumentStore,
        indexDatabase: IndexDatabase? = nil
    ) {
        self.appState = appState
        self.folderManager = folderManager
        self.documentStore = documentStore
        self.indexDatabase = indexDatabase ?? .shared
    }

    func openFolder(url: URL) {
        folderManager.open(url: url, into: appState)
    }

    func openFile(url: URL) {
        folderManager.openFile(url: url, into: appState)
    }

    func restoreLastFolder() {
        folderManager.restoreLastFolder(into: appState)
    }

    func excludeFromWorkspace(urls: [URL]) {
        folderManager.addExcludedURLs(urls, into: appState)
    }

    func clearWorkspaceExclusions() {
        folderManager.clearExclusions(into: appState)
    }

    func saveActiveDocument() {
        documentStore.save(appState: appState)
    }

    func selectDocument(id: DocumentRef.ID?) {
        guard let id else {
            _ = documentStore.select(ref: nil, into: appState)
            return
        }

        guard let ref = appState.allDocuments.first(where: { $0.id == id }) else {
            return
        }

        _ = documentStore.select(ref: ref, into: appState)
    }

    func selectSearchResult(_ result: WorkspaceSearchResult) {
        selectDocument(id: result.document.id)
    }

    func updateWorkspaceSearch(query: String) {
        appState.workspaceSearchQuery = query
        indexDatabase.refreshSearchResults(in: appState)
    }

    func setMode(_ mode: EditorMode) {
        appState.mode = mode
    }

    func toggleSidebar() {
        appState.sidebarVisible.toggle()
    }

    func toggleRichMarkdown() {
        appState.richMarkdownEnabled.toggle()
    }

    func bumpFontSize(by delta: CGFloat) {
        appState.bumpFontSize(by: delta)
    }

    func resetFontSize() {
        appState.resetFontSize()
    }

    func documentDidChange() {
        documentStore.documentDidChange(appState: appState)
    }
}
