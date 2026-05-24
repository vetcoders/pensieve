import Foundation

@MainActor
final class FolderManager {
    static let shared = FolderManager()
    private let watcher = FileWatcher()

    private init() {}

    func open(url: URL, into appState: AppState) {
        do {
            try BookmarkStore.shared.persist(url: url, into: appState)
            openResolvedFolder(url, into: appState)
        } catch {
            appState.lastError = "Could not open folder: \(error.localizedDescription)"
        }
    }

    func restoreLastFolder(into appState: AppState) {
        guard let url = BookmarkStore.shared.restore(into: appState) else {
            return
        }

        openResolvedFolder(url, into: appState)
    }

    func refresh(into appState: AppState) {
        guard let folderURL = appState.folderURL else { return }

        let previousSelection = appState.selectedDocumentID
        let documents = scan(folder: folderURL)
        appState.documents = documents

        if let previousSelection, documents.contains(where: { $0.id == previousSelection }) {
            appState.selectedDocumentID = previousSelection
            if !appState.activeDocumentDirty,
               let ref = documents.first(where: { $0.id == previousSelection }) {
                DocumentStore.shared.load(ref: ref, into: appState)
            }
            return
        }

        if let first = documents.first {
            DocumentStore.shared.select(ref: first, into: appState)
        } else {
            appState.selectedDocumentID = nil
            appState.activeDocumentURL = nil
            appState.activeDocumentText = ""
            appState.activeDocumentDirty = false
        }
    }

    private func openResolvedFolder(_ url: URL, into appState: AppState) {
        IndexDatabase.shared.open(into: appState)
        appState.folderURL = url
        appState.lastError = nil
        appState.documents = scan(folder: url)

        if let first = appState.documents.first {
            DocumentStore.shared.select(ref: first, into: appState)
        } else {
            appState.selectedDocumentID = nil
            appState.activeDocumentURL = nil
            appState.activeDocumentText = ""
            appState.activeDocumentDirty = false
        }

        startWatching(url: url, appState: appState)
    }

    private func scan(folder url: URL) -> [DocumentRef] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls
            .filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { DocumentRef(id: $0) }
    }

    private func startWatching(url: URL, appState: AppState) {
        do {
            try watcher.start(watching: url) { [weak appState] in
                Task { @MainActor in
                    guard let appState else { return }
                    FolderManager.shared.refresh(into: appState)
                }
            }
        } catch {
            appState.lastError = "Could not watch folder: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class DocumentStore {
    static let shared = DocumentStore()
    private let autosaver = Autosaver.shared
    private weak var appState: AppState?

    private init() {}

    func load(ref: DocumentRef, into appState: AppState) {
        self.appState = appState
        let activeDocumentURL = appState.activeDocumentURL

        if appState.activeDocumentDirty {
            save(appState: appState)
            guard !appState.activeDocumentDirty else {
                appState.selectedDocumentID = activeDocumentURL
                return
            }
        }

        autosaver.cancel()

        do {
            let text = try String(contentsOf: ref.url, encoding: .utf8)
            appState.activeDocumentURL = ref.url
            appState.selectedDocumentID = ref.id
            appState.activeDocumentText = text
            appState.activeDocumentDirty = false
            appState.lastError = nil
        } catch {
            appState.lastError = "Could not load \(ref.url.lastPathComponent): \(error.localizedDescription)"
            appState.activeDocumentDirty = false
        }
    }

    @discardableResult
    func select(ref: DocumentRef?, into appState: AppState) -> Bool {
        self.appState = appState

        if appState.activeDocumentDirty {
            save(appState: appState)
            guard !appState.activeDocumentDirty else {
                return false
            }
        }

        guard let ref else {
            autosaver.cancel()
            appState.selectedDocumentID = nil
            appState.activeDocumentURL = nil
            appState.activeDocumentText = ""
            appState.activeDocumentDirty = false
            return true
        }

        load(ref: ref, into: appState)
        return true
    }

    func save(appState: AppState) {
        self.appState = appState
        autosaver.cancel()

        guard let url = appState.activeDocumentURL ?? appState.selectedDocument?.url else { return }
        do {
            try appState.activeDocumentText.write(to: url, atomically: true, encoding: .utf8)
            appState.activeDocumentURL = url
            appState.activeDocumentDirty = false
            appState.lastError = nil
        } catch {
            let message = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
            appState.lastError = message
            NSLog(message)
        }
    }

    func documentDidChange(appState: AppState) {
        self.appState = appState
        scheduleAutosave(appState: appState)
    }

    private func scheduleAutosave(appState: AppState) {
        guard appState.selectedDocument != nil, appState.activeDocumentDirty else {
            return
        }

        autosaver.schedule { [weak self, weak appState] in
            guard let appState else { return }
            self?.save(appState: appState)
        }
    }
}
