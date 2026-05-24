import Combine
import CoreGraphics
import Foundation

@MainActor
final class AppController: ObservableObject {
    private let appState: AppState
    private let folderManager: FolderManager
    private let documentStore: DocumentStore

    convenience init(appState: AppState) {
        self.init(
            appState: appState,
            folderManager: FolderManager.shared,
            documentStore: DocumentStore.shared
        )
    }

    init(appState: AppState, folderManager: FolderManager, documentStore: DocumentStore) {
        self.appState = appState
        self.folderManager = folderManager
        self.documentStore = documentStore
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
