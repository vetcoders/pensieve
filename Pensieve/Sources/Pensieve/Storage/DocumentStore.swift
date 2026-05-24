import Foundation

@MainActor
final class FolderManager {
    static let shared = FolderManager()
    private let watcher = FileWatcher()
    private let metadataStore: WorkspaceMetadataStore

    init(metadataStore: WorkspaceMetadataStore = .shared) {
        self.metadataStore = metadataStore
    }

    func open(url: URL, into appState: AppState) {
        do {
            try BookmarkStore.shared.persistRoot(url: url, into: appState)
            let roots = mergedRoots(current: appState.workspaceRoots.map(\.url), adding: [url])
            openResolvedWorkspace(rootURLs: roots, fileURLs: appState.openFiles.map(\.url), into: appState)
        } catch {
            appState.lastError = "Could not open folder: \(error.localizedDescription)"
        }
    }

    func openFile(url: URL, into appState: AppState) {
        guard isMarkdownFile(url) else {
            appState.lastError = "Pensieve can open Markdown files with .md or .markdown extensions."
            return
        }

        if let ref = appState.documents.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            DocumentStore.shared.select(ref: ref, into: appState)
            return
        }

        do {
            try BookmarkStore.shared.persistFile(url: url, into: appState)
            let fileURLs = mergedRoots(current: appState.openFiles.map(\.url), adding: [url])
            openResolvedWorkspace(rootURLs: appState.workspaceRoots.map(\.url), fileURLs: fileURLs, into: appState)
            if let ref = appState.openFiles.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                DocumentStore.shared.select(ref: ref, into: appState)
            }
        } catch {
            appState.lastError = "Could not open file: \(error.localizedDescription)"
        }
    }

    func restoreLastFolder(into appState: AppState) {
        let restored = BookmarkStore.shared.restoreWorkspace(into: appState)
        guard !restored.rootURLs.isEmpty || !restored.fileURLs.isEmpty else {
            return
        }

        openResolvedWorkspace(rootURLs: restored.rootURLs, fileURLs: restored.fileURLs, into: appState)
    }

    func refresh(into appState: AppState) {
        guard appState.hasWorkspaceContent else { return }

        let previousSelection = appState.selectedDocumentID
        rebuildWorkspace(into: appState)
        let documents = appState.allDocuments

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

    func addExcludedURLs(_ urls: [URL], into appState: AppState) {
        guard !appState.workspaceRoots.isEmpty else { return }

        var excluded = appState.excludedWorkspacePaths
        for url in urls {
            guard let relativePath = relativeExcludedPath(for: url, roots: appState.workspaceRoots.map(\.url)) else {
                continue
            }
            excluded.insert(relativePath)
        }
        persistExcludedPaths(excluded, into: appState)
        refresh(into: appState)
    }

    func clearExclusions(into appState: AppState) {
        persistExcludedPaths([], into: appState)
        refresh(into: appState)
    }

    private func openResolvedWorkspace(rootURLs: [URL], fileURLs: [URL], into appState: AppState) {
        IndexDatabase.shared.open(into: appState)
        let previousSelection = appState.selectedDocumentID
        let metadata = metadataStore.load()
        appState.excludedWorkspacePaths = Set(metadata.excludedPaths)
        appState.workspaceRoots = rootURLs.map { WorkspaceRoot(id: $0.standardizedFileURL) }
        appState.folderURL = appState.workspaceRoots.first?.url
        appState.openFiles = fileURLs
            .filter(isMarkdownFile)
            .map { DocumentRef(id: $0.standardizedFileURL, isAdHoc: true) }
        appState.lastError = nil
        rebuildWorkspace(into: appState)

        if let previousSelection,
           let ref = appState.allDocuments.first(where: { $0.id == previousSelection }) {
            DocumentStore.shared.select(ref: ref, into: appState)
        } else if let first = appState.allDocuments.first {
            DocumentStore.shared.select(ref: first, into: appState)
        } else {
            appState.selectedDocumentID = nil
            appState.activeDocumentURL = nil
            appState.activeDocumentText = ""
            appState.activeDocumentDirty = false
        }

        startWatching(urls: appState.workspaceRoots.map(\.url), appState: appState)
    }

    private func rebuildWorkspace(into appState: AppState) {
        let scans = appState.workspaceRoots.map {
            scan(folder: $0.url, exclusions: appState.excludedWorkspacePaths)
        }
        appState.documents = scans.flatMap(\.documents)
        appState.workspaceTree = scans.map(\.rootNode)

        let workspaceIDs = Set(appState.documents.map(\.id))
        appState.openFiles.removeAll { workspaceIDs.contains($0.id) }
    }

    private func scan(folder url: URL, exclusions: Set<String>) -> WorkspaceScan {
        let root = url.standardizedFileURL
        let scan = scanChildren(folder: root, root: root, exclusions: exclusions)
        return WorkspaceScan(
            documents: scan.documents,
            rootNode: WorkspaceNode(
                id: "root:\(root.path)",
                name: root.lastPathComponent,
                kind: .folder,
                url: root,
                children: scan.nodes
            )
        )
    }

    private func scanChildren(
        folder url: URL,
        root: URL,
        exclusions: Set<String>
    ) -> (documents: [DocumentRef], nodes: [WorkspaceNode]) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        ) else {
            return ([], [])
        }

        var documents: [DocumentRef] = []
        var nodes: [WorkspaceNode] = []

        for item in urls.sorted(by: workspaceSort) {
            let relativePath = relativePath(for: item, root: root)
            guard shouldInclude(item, relativePath: relativePath, exclusions: exclusions) else {
                continue
            }

            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                let childScan = scanChildren(folder: item, root: root, exclusions: exclusions)
                guard !childScan.nodes.isEmpty else { continue }
                documents.append(contentsOf: childScan.documents)
                nodes.append(
                    WorkspaceNode(
                        id: "folder:\(item.standardizedFileURL.path)",
                        name: item.lastPathComponent,
                        kind: .folder,
                        url: item.standardizedFileURL,
                        children: childScan.nodes
                    )
                )
            } else if values?.isRegularFile == true, isMarkdownFile(item) {
                let ref = DocumentRef(
                    id: item.standardizedFileURL,
                    rootURL: root,
                    relativePath: relativePath,
                    isAdHoc: false
                )
                documents.append(ref)
                nodes.append(
                    WorkspaceNode(
                        id: "document:\(item.standardizedFileURL.path)",
                        name: item.deletingPathExtension().lastPathComponent,
                        kind: .document,
                        url: item.standardizedFileURL,
                        children: nil
                    )
                )
            }
        }

        return (documents, nodes)
    }

    private func startWatching(urls: [URL], appState: AppState) {
        guard !urls.isEmpty else {
            watcher.stop()
            return
        }

        do {
            try watcher.start(watching: urls) { [weak self, weak appState] in
                Task { @MainActor in
                    guard let appState else { return }
                    self?.refresh(into: appState)
                }
            }
        } catch {
            appState.lastError = "Could not watch folder: \(error.localizedDescription)"
        }
    }

    private func isMarkdownFile(_ url: URL) -> Bool {
        ["md", "markdown"].contains(url.pathExtension.lowercased())
    }

    private func workspaceSort(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsValues = try? lhs.resourceValues(forKeys: [.isDirectoryKey])
        let rhsValues = try? rhs.resourceValues(forKeys: [.isDirectoryKey])
        if lhsValues?.isDirectory == true, rhsValues?.isDirectory != true {
            return true
        }
        if lhsValues?.isDirectory != true, rhsValues?.isDirectory == true {
            return false
        }
        return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    private func shouldInclude(_ url: URL, relativePath: String, exclusions: Set<String>) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".") || WorkspaceDefaults.excludedNames.contains(name) {
            return false
        }
        return !exclusions.contains { excluded in
            relativePath == excluded || relativePath.hasPrefix("\(excluded)/")
        }
    }

    private func relativePath(for url: URL, root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= rootComponents.count else {
            return url.lastPathComponent
        }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func relativeExcludedPath(for url: URL, roots: [URL]) -> String? {
        let standardizedURL = url.standardizedFileURL
        let matchingRoot = roots
            .map(\.standardizedFileURL)
            .filter { standardizedURL.path == $0.path || standardizedURL.path.hasPrefix($0.path + "/") }
            .sorted { $0.path.count > $1.path.count }
            .first
        guard let matchingRoot else { return nil }
        let path = relativePath(for: standardizedURL, root: matchingRoot)
        return path.isEmpty ? nil : path
    }

    private func persistExcludedPaths(_ excluded: Set<String>, into appState: AppState) {
        appState.excludedWorkspacePaths = excluded
        do {
            try metadataStore.save(WorkspaceMetadata(excludedPaths: excluded.sorted()))
            appState.lastError = nil
        } catch {
            appState.lastError = "Could not save workspace exclusions: \(error.localizedDescription)"
        }
    }

    private func mergedRoots(current: [URL], adding urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return (current + urls)
            .map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
    }
}

private enum WorkspaceDefaults {
    static let excludedNames: Set<String> = [
        ".git",
        ".build",
        ".DS_Store",
        "node_modules",
        "dist",
        "DerivedData"
    ]
}

private struct WorkspaceScan {
    var documents: [DocumentRef]
    var rootNode: WorkspaceNode
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
