import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: AppController

    var body: some View {
        VStack(spacing: 0) {
            header

            if !appState.hasWorkspaceContent {
                emptyState
            } else if appState.isSearchingWorkspace {
                searchResults
            } else {
                explorer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if appState.workspaceRoots.count == 1, let root = appState.workspaceRoots.first {
                Text(root.name)
                    .font(.headline)
                    .lineLimit(1)
            } else if !appState.workspaceRoots.isEmpty {
                Text("Workspace")
                    .font(.headline)
                    .lineLimit(1)
            } else {
                Text("Pensieve")
                    .font(.headline)
            }

            TextField("Search…", text: searchText)
                .textFieldStyle(.roundedBorder)
                .disabled(appState.allDocuments.isEmpty)

            if !appState.excludedWorkspacePaths.isEmpty {
                Text("\(appState.excludedWorkspacePaths.count) excluded")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
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
            Text("⌘O opens a Markdown file. ⌘⇧O opens a workspace folder.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var explorer: some View {
        List(selection: documentSelection) {
            if !appState.openFiles.isEmpty {
                Section("Open Files") {
                    ForEach(appState.openFiles) { doc in
                        documentRow(doc)
                            .tag(doc.id as DocumentRef.ID?)
                    }
                }
            }

            if !appState.workspaceTree.isEmpty {
                Section("Workspace") {
                    OutlineGroup(appState.workspaceTree, children: \.children) { node in
                        nodeRow(node)
                            .tag(node.documentID)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var searchResults: some View {
        List(selection: documentSelection) {
            let workspaceResults = appState.workspaceSearchResults.filter { !$0.isAdHoc }
            let openFileResults = appState.workspaceSearchResults.filter(\.isAdHoc)

            if appState.workspaceSearchResults.isEmpty {
                Text("No results")
                    .foregroundColor(.secondary)
            }

            if !workspaceResults.isEmpty {
                Section("Workspace Results") {
                    ForEach(workspaceResults) { result in
                        searchResultRow(result)
                            .tag(result.document.id as DocumentRef.ID?)
                    }
                }
            }

            if !openFileResults.isEmpty {
                Section("Open Files") {
                    ForEach(openFileResults) { result in
                        searchResultRow(result)
                            .tag(result.document.id as DocumentRef.ID?)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func documentRow(_ doc: DocumentRef) -> some View {
        HStack {
            Image(systemName: "doc.text")
                .foregroundColor(.secondary)
            Text(doc.title)
                .lineLimit(1)
        }
        .help(doc.displayPath)
    }

    private func nodeRow(_ node: WorkspaceNode) -> some View {
        HStack {
            Image(systemName: node.kind == .folder ? "folder" : "doc.text")
                .foregroundColor(.secondary)
            Text(node.name)
                .lineLimit(1)
        }
        .help(node.url?.path ?? node.name)
    }

    private var documentSelection: Binding<DocumentRef.ID?> {
        Binding(
            get: { appState.selectedDocumentID },
            set: { newID in
                controller.selectDocument(id: newID)
            }
        )
    }

    private var searchText: Binding<String> {
        Binding(
            get: { appState.workspaceSearchQuery },
            set: { newValue in
                controller.updateWorkspaceSearch(query: newValue)
            }
        )
    }

    private func searchResultRow(_ result: WorkspaceSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .foregroundColor(.secondary)
                Text(result.title)
                    .lineLimit(1)
            }

            Text(result.displayPath)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            if let snippet = result.snippet {
                Text(snippet)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .help(result.displayPath)
    }
}
