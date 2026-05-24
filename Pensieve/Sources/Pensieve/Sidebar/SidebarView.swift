import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: AppController
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            if !appState.hasWorkspaceContent {
                emptyState
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

            TextField("Search…", text: $searchText)
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
            if !filteredOpenFiles.isEmpty {
                Section("Open Files") {
                    ForEach(filteredOpenFiles) { doc in
                        documentRow(doc)
                            .tag(doc.id as DocumentRef.ID?)
                    }
                }
            }

            if !filteredTree.isEmpty {
                Section("Workspace") {
                    OutlineGroup(filteredTree, children: \.children) { node in
                        nodeRow(node)
                            .tag(node.documentID)
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

    private var filteredOpenFiles: [DocumentRef] {
        guard !searchText.isEmpty else { return appState.openFiles }
        return appState.openFiles.filter(matchesSearch)
    }

    private var filteredTree: [WorkspaceNode] {
        guard !searchText.isEmpty else { return appState.workspaceTree }
        return appState.workspaceTree.compactMap(filterNode)
    }

    private func matchesSearch(_ doc: DocumentRef) -> Bool {
        doc.title.localizedCaseInsensitiveContains(searchText)
            || doc.displayPath.localizedCaseInsensitiveContains(searchText)
    }

    private func filterNode(_ node: WorkspaceNode) -> WorkspaceNode? {
        if node.name.localizedCaseInsensitiveContains(searchText) {
            return node
        }

        guard let children = node.children else {
            return nil
        }

        let matchingChildren = children.compactMap(filterNode)
        guard !matchingChildren.isEmpty else {
            return nil
        }

        return WorkspaceNode(
            id: node.id,
            name: node.name,
            kind: node.kind,
            url: node.url,
            children: matchingChildren
        )
    }
}
