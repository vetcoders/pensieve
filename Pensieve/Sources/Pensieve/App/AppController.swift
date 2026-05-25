import Combine
import CoreGraphics
import Foundation

@MainActor
final class AppController: ObservableObject {
    private let appState: AppState
    private let folderManager: FolderManager
    private let documentStore: DocumentStore
    private let indexDatabase: IndexDatabase
    private var didStart = false

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

    func start() {
        guard !didStart else { return }
        didStart = true

        indexDatabase.open(into: appState)
        folderManager.restoreLastFolderInBackground(into: appState)
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

    /// Closes the active document session without exiting Pensieve.
    /// Dirty sessions are routed through the existing save semantics in
    /// `DocumentStore.select(ref:nil:into:)` before the session is cleared,
    /// so the window stays alive and reverts to its empty state.
    @discardableResult
    func closeActiveDocument() -> Bool {
        documentStore.select(ref: nil, into: appState)
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

    func selectWorkspaceNode(_ node: WorkspaceNode) {
        guard let documentID = node.documentID else { return }
        selectDocument(id: documentID)
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

    // MARK: - Toolbar Actions

    func formatSelection(with wrapper: String) {
        // TODO: Coordinate with formatter worker to implement selection wrapping
        print("Format selection with \(wrapper)")
    }
}
