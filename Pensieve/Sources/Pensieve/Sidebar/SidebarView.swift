import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: AppController
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            if appState.folderURL == nil {
                emptyState
            } else {
                documentList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let folderURL = appState.folderURL {
                Text(folderURL.lastPathComponent)
                    .font(.headline)
                    .lineLimit(1)
            } else {
                Text("Pensieve")
                    .font(.headline)
            }

            TextField("Search…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .disabled(appState.documents.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No folder open")
                .font(.headline)
            Text("⌘⇧O to open a folder of `.md` files")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var documentList: some View {
        List(filteredDocuments, selection: documentSelection) { doc in
            HStack {
                Image(systemName: "doc.text")
                    .foregroundColor(.secondary)
                Text(doc.title)
                    .lineLimit(1)
            }
            .tag(doc.id as DocumentRef.ID?)
        }
        .listStyle(.sidebar)
    }

    private var documentSelection: Binding<DocumentRef.ID?> {
        Binding(
            get: { appState.selectedDocumentID },
            set: { newID in
                controller.selectDocument(id: newID)
            }
        )
    }

    private var filteredDocuments: [DocumentRef] {
        guard !searchText.isEmpty else { return appState.documents }
        return appState.documents.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }
}
