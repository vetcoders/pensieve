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
    // Folder + document selection
    @Published var folderURL: URL?
    @Published var documents: [DocumentRef] = []
    @Published var selectedDocumentID: DocumentRef.ID?

    // Active document
    @Published var activeDocumentText: String = ""
    @Published var activeDocumentDirty: Bool = false

    // Editor preferences
    @Published var mode: EditorMode = .split
    @Published var fontSize: CGFloat = 14
    @Published var richMarkdownEnabled: Bool = false

    // Sidebar visibility
    @Published var sidebarVisible: Bool = true

    // Storage persistence + user-visible errors
    @Published var bookmarkData: Data?
    @Published var lastError: String?

    var selectedDocument: DocumentRef? {
        guard let id = selectedDocumentID else { return nil }
        return documents.first(where: { $0.id == id })
    }

    func bumpFontSize(by delta: CGFloat) {
        fontSize = max(8, min(48, fontSize + delta))
    }

    func resetFontSize() {
        fontSize = 14
    }
}

struct DocumentRef: Identifiable, Hashable {
    let id: URL
    var url: URL { id }
    var title: String { url.deletingPathExtension().lastPathComponent }
}
