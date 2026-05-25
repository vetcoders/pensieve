import SwiftUI
import Combine

enum EditorMode: Int, CaseIterable, Identifiable {
    case source = 1
    case split = 2
    case preview = 3
    case focus = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .source:  return "Source"
        case .split:   return "Split"
        case .preview: return "Preview"
        case .focus:   return "Focus"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    // Workspace + document selection
    @Published var folderURL: URL?
    @Published var workspaceRoots: [WorkspaceRoot] = []
    @Published var workspaceTree: [WorkspaceNode] = []
    @Published var documents: [DocumentRef] = []
    @Published var openFiles: [DocumentRef] = []
    @Published var documentTabs: [DocumentRef] = []
    @Published var excludedWorkspacePaths: Set<String> = []
    @Published var selectedDocumentID: DocumentRef.ID?
    @Published var workspaceSearchQuery: String = ""
    @Published var workspaceSearchResults: [WorkspaceSearchResult] = []

    // Active document
    @Published var documentSession: DocumentSession = .empty

    var activeDocumentURL: URL? {
        get {
            documentSession.url
        }
        set {
            guard let newValue else {
                documentSession.clear()
                return
            }

            let standardizedURL = newValue.standardizedFileURL
            documentSession.document = documentRef(for: standardizedURL)
        }
    }

    var activeDocumentText: String {
        get {
            documentSession.text
        }
        set {
            documentSession.text = newValue
        }
    }

    var activeDocumentDirty: Bool {
        get {
            documentSession.isDirty
        }
        set {
            documentSession.isDirty = newValue
        }
    }

    // Editor preferences
    @Published var mode: EditorMode = .split
    @Published var fontSize: CGFloat = 14
    @Published var richMarkdownEnabled: Bool = true
    @Published var pendingMarkdownFormatCommand: MarkdownFormatCommand?

    // Preview behaviour. `previewAutoReload` mirrors the legacy
    // "Automatically reload page" checkbox; `previewRefreshToken` is bumped
    // by the toolbar refresh button to force a re-render even when
    // auto-reload is paused or the markdown text is identical.
    @Published var previewAutoReload: Bool = true
    @Published var previewRefreshToken: Int = 0

    // Sidebar visibility
    @Published var sidebarVisible: Bool = true

    // Storage persistence + user-visible errors
    @Published var bookmarkData: Data?
    @Published var lastError: String?

    var selectedDocument: DocumentRef? {
        guard let id = selectedDocumentID else { return nil }
        return allDocuments.first(where: { $0.id == id })
    }

    var allDocuments: [DocumentRef] {
        var seen = Set<DocumentRef.ID>()
        return (documents + openFiles).filter { ref in
            seen.insert(ref.id).inserted
        }
    }

    var hasWorkspaceContent: Bool {
        !workspaceRoots.isEmpty || !openFiles.isEmpty
    }

    var isSearchingWorkspace: Bool {
        !workspaceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func bumpFontSize(by delta: CGFloat) {
        fontSize = max(8, min(48, fontSize + delta))
    }

    func resetFontSize() {
        fontSize = 14
    }

    /// Bumps `previewRefreshToken`, asking the preview pipeline to re-render
    /// even when the markdown payload is identical or auto-reload is off.
    func requestPreviewRefresh() {
        previewRefreshToken &+= 1
    }

    func documentRef(for url: URL) -> DocumentRef {
        let standardizedURL = url.standardizedFileURL
        return allDocuments.first { $0.url.standardizedFileURL == standardizedURL }
            ?? DocumentRef(id: standardizedURL, isAdHoc: workspaceRoots.isEmpty)
    }

    func rememberDocumentTab(_ ref: DocumentRef) {
        documentTabs.removeAll { $0.id.standardizedFileURL == ref.id.standardizedFileURL }
        documentTabs.append(ref)
        if documentTabs.count > 12 {
            documentTabs.removeFirst(documentTabs.count - 12)
        }
    }

    func forgetDocumentTab(id: DocumentRef.ID) {
        documentTabs.removeAll { $0.id.standardizedFileURL == id.standardizedFileURL }
    }

    func pruneDocumentTabs() {
        let liveIDs = Set(allDocuments.map { $0.id.standardizedFileURL })
        documentTabs.removeAll { !liveIDs.contains($0.id.standardizedFileURL) }
    }
}

struct DocumentRef: Identifiable, Hashable, Sendable {
    let id: URL
    var rootURL: URL?
    var relativePath: String?
    var isAdHoc: Bool = false

    var url: URL { id }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var displayPath: String {
        relativePath ?? url.lastPathComponent
    }
}

struct WorkspaceRoot: Identifiable, Hashable, Sendable {
    let id: URL
    var url: URL { id }
    var name: String { url.lastPathComponent }
}

struct WorkspaceNode: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case folder
        case document
    }

    let id: String
    var name: String
    var kind: Kind
    var url: URL?
    var children: [WorkspaceNode]?

    var documentID: DocumentRef.ID? {
        kind == .document ? url : nil
    }
}
