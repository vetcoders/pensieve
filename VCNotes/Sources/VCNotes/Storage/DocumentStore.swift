import Foundation

// MARK: - Placeholder DocumentStore (Wave C-1 agent replaces with autosave + security-scoped bookmarks)

@MainActor
final class FolderManager {
    static let shared = FolderManager()
    private init() {}

    func open(url: URL, into appState: AppState) {
        appState.folderURL = url
        appState.documents = scan(folder: url)
        if let first = appState.documents.first {
            appState.selectedDocumentID = first.id
            DocumentStore.shared.load(ref: first, into: appState)
        } else {
            appState.selectedDocumentID = nil
            appState.activeDocumentText = ""
            appState.activeDocumentDirty = false
        }
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
}

@MainActor
final class DocumentStore {
    static let shared = DocumentStore()
    private init() {}

    func load(ref: DocumentRef, into appState: AppState) {
        do {
            let text = try String(contentsOf: ref.url, encoding: .utf8)
            appState.activeDocumentText = text
            appState.activeDocumentDirty = false
        } catch {
            appState.activeDocumentText = "// Failed to load: \(error.localizedDescription)"
            appState.activeDocumentDirty = false
        }
    }

    func save(appState: AppState) {
        guard let ref = appState.selectedDocument else { return }
        do {
            try appState.activeDocumentText.write(to: ref.url, atomically: true, encoding: .utf8)
            appState.activeDocumentDirty = false
        } catch {
            NSLog("VC Notes save failed: \(error.localizedDescription)")
        }
    }
}
