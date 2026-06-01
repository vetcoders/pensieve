import AppKit
import SwiftUI

struct SidebarView: View {
  @EnvironmentObject private var appState: AppState
  @EnvironmentObject private var controller: AppController
  @State private var expandedNodeIDs: Set<WorkspaceNode.ID> = []
  @State private var knownRootNodeIDs: Set<WorkspaceNode.ID> = []
  @State private var hoveredDocumentID: DocumentRef.ID?

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
    .onAppear {
      reconcileWorkspaceRootExpansion()
    }
    .onChange(of: rootNodeIDs) { _ in
      reconcileWorkspaceRootExpansion()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text(sidebarTitle)
          .font(.headline)
          .lineLimit(1)
          .accessibilityIdentifier("pensieve.sidebar.title")

        Spacer(minLength: 8)

        Button {
          controller.createUntitledDocument()
        } label: {
          Image(systemName: "square.and.pencil")
        }
        .buttonStyle(.borderless)
        .help("New Markdown File")
        .accessibilityIdentifier("pensieve.sidebar.newFile")
      }

      TextField("Search…", text: searchText)
        .textFieldStyle(.roundedBorder)
        .disabled(appState.allDocuments.isEmpty)
        .accessibilityIdentifier("pensieve.sidebar.search")

      if !appState.excludedWorkspacePaths.isEmpty {
        Text("\(appState.excludedWorkspacePaths.count) excluded")
          .font(.caption2)
          .foregroundColor(.secondary)
      }

      if let activity = appState.workspaceActivity {
        WorkspaceActivityMiniView(activity: activity)
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
      Button("New File…") {
        controller.createUntitledDocument()
      }
      .accessibilityIdentifier("pensieve.sidebar.emptyState.newFile")
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .accessibilityIdentifier("pensieve.sidebar.emptyState")
  }

  private var explorer: some View {
    List {
      if !appState.openFiles.isEmpty {
        Section("Open Files") {
          ForEach(appState.openFiles) { doc in
            Button {
              controller.selectDocument(id: doc.id)
            } label: {
              documentRow(
                doc,
                isSelected: isSelectedOrHovered(doc.id)
              )
            }
            .buttonStyle(.plain)
            .onHover { updateHoveredDocument(doc.id, isHovered: $0) }
            .contextMenu {
              documentContextMenu(for: doc)
            }
          }
        }
        .accessibilityIdentifier("pensieve.sidebar.list.openFiles")
      }

      if !appState.workspaceTree.isEmpty {
        Section("Workspace") {
          ForEach(flattenedWorkspaceRows) { row in
            workspaceRowView(row)
          }
        }
        .accessibilityIdentifier("pensieve.sidebar.list.workspace")
      }
    }
    .listStyle(.sidebar)
  }

  private var searchResults: some View {
    List {
      let workspaceResults = appState.workspaceSearchResults.filter { !$0.isAdHoc }
      let openFileResults = appState.workspaceSearchResults.filter(\.isAdHoc)

      if appState.workspaceSearchResults.isEmpty {
        Text("No results")
          .foregroundColor(.secondary)
      }

      if !workspaceResults.isEmpty {
        Section("Workspace Results") {
          ForEach(workspaceResults) { result in
            Button {
              controller.selectSearchResult(result)
            } label: {
              searchResultRow(
                result,
                isSelected: isSelectedOrHovered(result.document.id)
              )
            }
            .buttonStyle(.plain)
            .onHover { updateHoveredDocument(result.document.id, isHovered: $0) }
            .contextMenu {
              documentContextMenu(for: result.document)
            }
          }
        }
      }

      if !openFileResults.isEmpty {
        Section("Open Files") {
          ForEach(openFileResults) { result in
            Button {
              controller.selectSearchResult(result)
            } label: {
              searchResultRow(
                result,
                isSelected: isSelectedOrHovered(result.document.id)
              )
            }
            .buttonStyle(.plain)
            .onHover { updateHoveredDocument(result.document.id, isHovered: $0) }
            .contextMenu {
              documentContextMenu(for: result.document)
            }
          }
        }
      }
    }
    .listStyle(.sidebar)
    .accessibilityIdentifier("pensieve.sidebar.list.searchResults")
  }

  private func documentRow(_ doc: DocumentRef, isSelected: Bool) -> some View {
    HStack {
      Image(systemName: "doc.text")
        .foregroundColor(.secondary)
      Text(doc.title)
        .lineLimit(1)
    }
    .padding(.vertical, 4)
    .padding(.horizontal, 6)
    .help(doc.displayPath)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background(selectionBackground(isSelected))
  }

  /// Currently-visible workspace rows, flattened so the `List` only materializes
  /// on-screen rows instead of eagerly building the entire expanded subtree.
  /// Walks only expanded branches (O(visible)).
  private var flattenedWorkspaceRows: [FlattenedWorkspaceRow] {
    flattenWorkspaceTree(appState.workspaceTree, expandedNodeIDs: expandedNodeIDs)
  }

  @ViewBuilder
  private func workspaceRowView(_ row: FlattenedWorkspaceRow) -> some View {
    let node = row.node
    if node.kind == .document {
      Button {
        controller.selectWorkspaceNode(node)
      } label: {
        nodeRow(
          node,
          depth: row.depth,
          isSelected: node.documentID.map(isSelectedOrHovered) ?? false
        )
      }
      .buttonStyle(.plain)
      .onHover { isHovered in
        guard let documentID = node.documentID else { return }
        updateHoveredDocument(documentID, isHovered: isHovered)
      }
      .contextMenu {
        nodeContextMenu(for: node)
      }
    } else {
      Button {
        toggleExpanded(node.id)
      } label: {
        folderRow(node, depth: row.depth, isExpanded: row.isExpanded)
      }
      .buttonStyle(.plain)
      .contextMenu {
        nodeContextMenu(for: node)
      }
    }
  }

  private func folderRow(_ node: WorkspaceNode, depth: Int, isExpanded: Bool) -> some View {
    HStack(spacing: 5) {
      Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        .font(.caption2.weight(.semibold))
        .foregroundColor(.secondary)
        .frame(width: 10)

      Image(systemName: "folder")
        .foregroundColor(.secondary)

      Text(node.name)
        .lineLimit(1)
    }
    .padding(.leading, CGFloat(depth) * 14)
    .padding(.vertical, 4)
    .padding(.horizontal, 6)
    .help(node.url?.path ?? node.name)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }

  private func nodeRow(_ node: WorkspaceNode, depth: Int, isSelected: Bool) -> some View {
    HStack {
      Image(systemName: "doc.text")
        .foregroundColor(.secondary)
      Text(node.name)
        .lineLimit(1)
    }
    .padding(.leading, CGFloat(depth) * 14 + 15)
    .padding(.vertical, 4)
    .padding(.horizontal, 6)
    .help(node.url?.path ?? node.name)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background(selectionBackground(isSelected))
  }

  private var searchText: Binding<String> {
    Binding(
      get: { appState.workspaceSearchQuery },
      set: { newValue in
        controller.updateWorkspaceSearch(query: newValue)
      }
    )
  }

  private func searchResultRow(_ result: WorkspaceSearchResult, isSelected: Bool) -> some View {
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
    .padding(.vertical, 4)
    .padding(.horizontal, 6)
    .help(result.displayPath)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background(selectionBackground(isSelected))
  }

  private func selectionBackground(_ isSelected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 6, style: .continuous)
      .fill(isSelected ? Color.accentColor.opacity(0.24) : Color.clear)
  }

  @ViewBuilder
  private func documentContextMenu(for doc: DocumentRef) -> some View {
    Button("Open") {
      controller.selectDocument(id: doc.id)
    }

    Button("Open in Default App") {
      openExternally(doc.url)
    }

    Button("Reveal in Finder") {
      revealInFinder(doc.url)
    }

    Divider()

    Button("Copy Name") {
      copyPath(doc.title)
    }

    Button("Copy Path") {
      copyPath(doc.url.path)
    }

    if let relativePath = doc.relativePath {
      Button("Copy Workspace Path") {
        copyPath(relativePath)
      }

      Button("Copy Markdown Link") {
        copyPath("[\(doc.title)](\(markdownLinkPath(relativePath)))")
      }
    }
  }

  @ViewBuilder
  private func nodeContextMenu(for node: WorkspaceNode) -> some View {
    if node.kind == .document, let url = node.url {
      if let documentID = node.documentID,
        let doc = appState.document(id: documentID)
      {
        documentContextMenu(for: doc)
      } else {
        Button("Open") {
          controller.selectWorkspaceNode(node)
        }

        Button("Reveal in Finder") {
          revealInFinder(url)
        }

        Button("Copy Path") {
          copyPath(url.path)
        }
      }
    } else if let url = node.url {
      Button("New File…") {
        controller.createUntitledDocument()
      }

      Divider()

      if isNodeExpanded(node) {
        Button("Collapse Folder") {
          expandedNodeIDs.remove(node.id)
        }
      } else {
        Button("Expand Folder") {
          expandedNodeIDs.insert(node.id)
        }
      }

      Button("Reveal in Finder") {
        revealInFinder(url)
      }

      Button("Copy Path") {
        copyPath(url.path)
      }
    }
  }

  private func openExternally(_ url: URL) {
    NSWorkspace.shared.open(url)
  }

  private func revealInFinder(_ url: URL) {
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  private func copyPath(_ path: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(path, forType: .string)
  }

  private func markdownLinkPath(_ path: String) -> String {
    path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
  }

  private var rootNodeIDs: [WorkspaceNode.ID] {
    appState.workspaceTree.map(\.id)
  }

  private func isNodeExpanded(_ node: WorkspaceNode) -> Bool {
    expandedNodeIDs.contains(node.id)
  }

  private func reconcileWorkspaceRootExpansion() {
    let currentRootIDs = Set(rootNodeIDs)
    let newRootIDs = currentRootIDs.subtracting(knownRootNodeIDs)
    expandedNodeIDs.formUnion(newRootIDs)
    expandedNodeIDs = expandedNodeIDs.filter { id in
      currentRootIDs.contains(id) || isDescendantNodeID(id)
    }
    knownRootNodeIDs = currentRootIDs
  }

  private func isDescendantNodeID(_ id: WorkspaceNode.ID) -> Bool {
    appState.workspaceTree.contains { root in
      containsNode(id, in: root.children ?? [])
    }
  }

  private func containsNode(_ id: WorkspaceNode.ID, in nodes: [WorkspaceNode]) -> Bool {
    nodes.contains { node in
      node.id == id || containsNode(id, in: node.children ?? [])
    }
  }

  private var sidebarTitle: String {
    if appState.workspaceRoots.count == 1, let root = appState.workspaceRoots.first {
      return root.name
    }
    if !appState.workspaceRoots.isEmpty {
      return "Workspace"
    }
    return "Pensieve"
  }

  private func isSelectedOrHovered(_ id: DocumentRef.ID) -> Bool {
    appState.selectedDocumentID == id || hoveredDocumentID == id
  }

  private func updateHoveredDocument(_ id: DocumentRef.ID, isHovered: Bool) {
    hoveredDocumentID = isHovered ? id : nil
  }

  private func toggleExpanded(_ id: WorkspaceNode.ID) {
    if expandedNodeIDs.contains(id) {
      expandedNodeIDs.remove(id)
    } else {
      expandedNodeIDs.insert(id)
    }
  }
}

private struct WorkspaceActivityMiniView: View {
  let activity: WorkspaceActivity

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(activity.detail)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)

      ProgressView(value: activity.progress)
        .progressViewStyle(.linear)
        .controlSize(.small)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(activity.title): \(activity.detail)")
    .accessibilityIdentifier("pensieve.sidebar.activity")
  }
}
