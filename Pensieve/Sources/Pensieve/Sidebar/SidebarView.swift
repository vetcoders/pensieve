import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
  @EnvironmentObject private var appState: AppState
  @EnvironmentObject private var controller: AppController
  @State private var expandedNodeIDs: Set<WorkspaceNode.ID> = []
  @State private var knownRootNodeIDs: Set<WorkspaceNode.ID> = []
  @State private var hoveredDocumentID: DocumentRef.ID?
  @State private var hoveredFolderID: WorkspaceNode.ID?
  @State private var dropTargetFolderID: WorkspaceNode.ID?
  @State private var renamingURL: URL?
  @State private var renameText: String = ""
  @State private var renameFocusToken: Int = 0
  @AppStorage("pensieve.sidebar.tab") private var sidebarTab: SidebarTab = .openFiles

  /// Sidebar segments: open working set vs the workspace folder tree.
  /// Persisted across launches via @AppStorage.
  private enum SidebarTab: String, CaseIterable, Identifiable {
    case openFiles
    case workspace
    var id: String { rawValue }
    var label: String {
      switch self {
      case .openFiles: return "Open Files"
      case .workspace: return "Workspace"
      }
    }
  }

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
    .onChange(of: appState.pendingSidebarRenameURL) { url in
      guard let url else { return }
      beginRename(url: url, currentName: url.lastPathComponent)
      appState.pendingSidebarRenameURL = nil
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

      NativeSearchField(
        text: searchText,
        placeholder: "Search",
        accessibilityIdentifier: "pensieve.sidebar.search"
      )
      .frame(height: 24)
      .disabled(appState.allDocuments.isEmpty)

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
    VStack(spacing: 0) {
      sidebarTabStrip

      HStack {
        Spacer()
        sortMenu
      }
      .padding(.horizontal, 10)
      .padding(.bottom, 4)

      switch sidebarTab {
      case .openFiles:
        openFilesList
      case .workspace:
        workspaceList
      }
    }
  }

  private var sidebarTabStrip: some View {
    HStack(spacing: 4) {
      ForEach(SidebarTab.allCases) { tab in
        sidebarTabButton(tab)
      }
    }
    .padding(4)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Color(NSColor.controlBackgroundColor).opacity(0.72))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    )
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .accessibilityIdentifier("pensieve.sidebar.tabStrip")
  }

  private func sidebarTabButton(_ tab: SidebarTab) -> some View {
    let isSelected = sidebarTab == tab
    return Button {
      sidebarTab = tab
    } label: {
      Text(tab.label)
        .font(.caption.weight(isSelected ? .semibold : .regular))
        .lineLimit(1)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .foregroundColor(isSelected ? .primary : .secondary)
        .background(selectionBackground(isSelected))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("pensieve.sidebar.tab.\(tab.rawValue)")
  }

  private var openFilesList: some View {
    Group {
      if appState.openFiles.isEmpty {
        sidebarEmptyTab(
          icon: "doc.text",
          message: "No open files",
          hint: "⌘O opens a file · ⌘N new file")
      } else {
        List {
          ForEach(appState.sortedOpenFiles) { doc in
            Button {
              appState.sidebarFocusedURL = doc.url.standardizedFileURL
              controller.selectDocument(id: doc.id)
            } label: {
              documentRow(
                doc,
                isSelected: isSelectedOrHovered(doc.id)
              )
            }
            .buttonStyle(.plain)
            .onHover {
              updateHoveredDocument(doc.id, isHovered: $0)
              if $0 {
                appState.sidebarFocusedURL = doc.url.standardizedFileURL
              }
            }
            .contextMenu {
              documentContextMenu(for: doc)
            }
            .onDrag {
              NSItemProvider(object: doc.url as NSURL)
            }
          }
          .onMove { source, destination in
            controller.reorderOpenFiles(fromOffsets: source, toOffset: destination)
          }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("pensieve.sidebar.list.openFiles")
      }
    }
  }

  private var workspaceList: some View {
    Group {
      if appState.workspaceTree.isEmpty {
        sidebarEmptyTab(
          icon: "folder",
          message: "No workspace folder",
          hint: "⌘⇧O opens a folder")
      } else {
        List {
          ForEach(flattenedWorkspaceRows) { row in
            workspaceRowView(row)
          }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("pensieve.sidebar.list.workspace")
      }
    }
  }

  private func sidebarEmptyTab(icon: String, message: String, hint: String) -> some View {
    VStack(spacing: 8) {
      Spacer()
      Image(systemName: icon)
        .font(.system(size: 28))
        .foregroundColor(.secondary)
      Text(message)
        .font(.subheadline)
        .foregroundColor(.secondary)
      Text(hint)
        .font(.caption2)
        .foregroundColor(.secondary)
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var sortMenu: some View {
    Menu {
      Picker("Sort", selection: $appState.sidebarSortOrder) {
        ForEach(SidebarSortOrder.allCases) { order in
          Text(order.label).tag(order)
        }
      }
    } label: {
      Image(systemName: "arrow.up.arrow.down")
        .frame(width: 22, height: 20)
    }
    .menuStyle(.borderlessButton)
    .help("Sort")
    .accessibilityIdentifier("pensieve.sidebar.sort")
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
              appState.sidebarFocusedURL = result.document.url.standardizedFileURL
              controller.selectSearchResult(result)
            } label: {
              searchResultRow(
                result,
                isSelected: isSelectedOrHovered(result.document.id)
              )
            }
            .buttonStyle(.plain)
            .onHover {
              updateHoveredDocument(result.document.id, isHovered: $0)
              if $0 {
                appState.sidebarFocusedURL = result.document.url.standardizedFileURL
              }
            }
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
              appState.sidebarFocusedURL = result.document.url.standardizedFileURL
              controller.selectSearchResult(result)
            } label: {
              searchResultRow(
                result,
                isSelected: isSelectedOrHovered(result.document.id)
              )
            }
            .buttonStyle(.plain)
            .onHover {
              updateHoveredDocument(result.document.id, isHovered: $0)
              if $0 {
                appState.sidebarFocusedURL = result.document.url.standardizedFileURL
              }
            }
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
      renameableTitle(for: doc.url, title: doc.title)
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
        if let url = node.url {
          appState.sidebarFocusedURL = url.standardizedFileURL
        }
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
        if isHovered, let url = node.url {
          appState.sidebarFocusedURL = url.standardizedFileURL
        }
      }
      .contextMenu {
        nodeContextMenu(for: node)
      }
      .onDrag {
        if let url = node.url {
          return NSItemProvider(object: url as NSURL)
        }
        return NSItemProvider()
      }
    } else {
      Button {
        if let url = node.url {
          appState.sidebarFocusedURL = url.standardizedFileURL
        }
        toggleExpanded(node.id)
      } label: {
        folderRow(
          node,
          depth: row.depth,
          isExpanded: row.isExpanded,
          isHighlighted: hoveredFolderID == node.id || dropTargetFolderID == node.id
        )
      }
      .buttonStyle(.plain)
      .onHover { isHovered in
        hoveredFolderID = isHovered ? node.id : nil
        if isHovered, let url = node.url {
          appState.sidebarFocusedURL = url.standardizedFileURL
        }
      }
      .contextMenu {
        nodeContextMenu(for: node)
      }
      .onDrop(of: [.fileURL], isTargeted: dropTargetBinding(for: node.id)) { providers in
        handleDrop(providers, into: node.url)
      }
    }
  }

  private func folderRow(
    _ node: WorkspaceNode,
    depth: Int,
    isExpanded: Bool,
    isHighlighted: Bool
  ) -> some View {
    HStack(spacing: 5) {
      Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
        .font(.caption2.weight(.semibold))
        .foregroundColor(.secondary)
        .frame(width: 10)

      Image(systemName: "folder")
        .foregroundColor(.secondary)

      renameableTitle(for: node.url, title: node.name)
    }
    .padding(.leading, CGFloat(depth) * 14)
    .padding(.vertical, 4)
    .padding(.horizontal, 6)
    .help(node.url?.path ?? node.name)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .background(selectionBackground(isHighlighted))
  }

  private func nodeRow(_ node: WorkspaceNode, depth: Int, isSelected: Bool) -> some View {
    HStack {
      Image(systemName: "doc.text")
        .foregroundColor(.secondary)
      renameableTitle(for: node.url, title: node.name)
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
  private func renameableTitle(for url: URL?, title: String) -> some View {
    if let url, renamingURL?.standardizedFileURL == url.standardizedFileURL {
      InlineRenameField(
        text: $renameText,
        focusToken: renameFocusToken,
        accessibilityIdentifier: "pensieve.sidebar.renameField",
        onCommit: {
          commitRename(url)
        },
        onCancel: {
          cancelRename()
        }
      )
    } else {
      Text(title)
        .lineLimit(1)
    }
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

    Button("Rename") {
      beginRename(url: doc.url, currentName: doc.url.lastPathComponent)
    }

    Button("Duplicate") {
      controller.duplicateItem(url: doc.url)
    }

    Button("Move to Trash") {
      controller.moveItemToTrash(url: doc.url)
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

        Button("Open in Default App") {
          openExternally(url)
        }

        Button("Reveal in Finder") {
          revealInFinder(url)
        }

        Divider()

        Button("Rename") {
          beginRename(url: url, currentName: url.lastPathComponent)
        }

        Button("Duplicate") {
          controller.duplicateItem(url: url)
        }

        Button("Move to Trash") {
          controller.moveItemToTrash(url: url)
        }

        Divider()

        Button("Copy Name") {
          copyPath(url.lastPathComponent)
        }

        Button("Copy Path") {
          copyPath(url.path)
        }
      }
    } else if let url = node.url {
      Button("New File") {
        controller.createMarkdownFile(url: url.appendingPathComponent("Untitled.md"))
      }

      Button("New Folder") {
        controller.createFolder(url: url.appendingPathComponent("New Folder"))
      }

      Divider()

      Button("Rename") {
        beginRename(url: url, currentName: url.lastPathComponent)
      }

      Button("Duplicate") {
        controller.duplicateItem(url: url)
      }

      Button("Move to Trash") {
        confirmMoveFolderToTrash(url)
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

  private func beginRename(url: URL, currentName: String) {
    renamingURL = url.standardizedFileURL
    renameText = currentName
    renameFocusToken &+= 1
  }

  private func commitRename(_ url: URL) {
    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      appState.lastError = "Name cannot be empty."
      return
    }
    guard controller.renameItem(url: url, to: trimmed) else { return }
    cancelRename()
  }

  private func cancelRename() {
    renamingURL = nil
    renameText = ""
  }

  private func confirmMoveFolderToTrash(_ url: URL) {
    let alert = NSAlert()
    alert.messageText = "Move \(url.lastPathComponent) to Trash?"
    alert.informativeText = "This folder and its contents will move to the system Trash."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Move to Trash")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn {
      controller.moveItemToTrash(url: url)
    }
  }

  private func handleDrop(_ providers: [NSItemProvider], into folderURL: URL?) -> Bool {
    guard let folderURL else { return false }
    for provider in providers
    where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
        let url: URL?
        if let data = item as? Data {
          url = URL(dataRepresentation: data, relativeTo: nil)
        } else {
          url = item as? URL
        }
        guard let url else { return }
        Task { @MainActor in
          controller.moveItem(url: url, toFolder: folderURL)
        }
      }
      return true
    }
    return false
  }

  private func dropTargetBinding(for nodeID: WorkspaceNode.ID) -> Binding<Bool> {
    Binding(
      get: { dropTargetFolderID == nodeID },
      set: { isTargeted in
        dropTargetFolderID = isTargeted ? nodeID : nil
      }
    )
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

private struct InlineRenameField: NSViewRepresentable {
  @Binding var text: String
  var focusToken: Int
  var accessibilityIdentifier: String
  var onCommit: () -> Void
  var onCancel: () -> Void

  func makeNSView(context: Context) -> RenameTextField {
    let field = RenameTextField(frame: .zero)
    field.isBordered = false
    field.drawsBackground = true
    field.backgroundColor = .controlBackgroundColor
    field.focusRingType = .none
    field.lineBreakMode = .byTruncatingMiddle
    field.delegate = context.coordinator
    field.coordinator = context.coordinator
    field.setAccessibilityIdentifier(accessibilityIdentifier)
    return field
  }

  func updateNSView(_ field: RenameTextField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text {
      field.stringValue = text
    }
    guard context.coordinator.lastFocusToken != focusToken else { return }
    context.coordinator.lastFocusToken = focusToken
    context.coordinator.isCompleting = false
    DispatchQueue.main.async {
      field.window?.makeFirstResponder(field)
      field.currentEditor()?.selectedRange = selectedNameRange(in: field.stringValue)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: InlineRenameField
    var lastFocusToken: Int
    var isCompleting = false

    init(parent: InlineRenameField) {
      self.parent = parent
      self.lastFocusToken = parent.focusToken
    }

    func commit(_ field: NSTextField) {
      isCompleting = true
      parent.text = field.stringValue
      parent.onCommit()
    }

    func cancel() {
      isCompleting = true
      parent.onCancel()
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      parent.text = field.stringValue
    }

    func controlTextDidEndEditing(_ notification: Notification) {
      guard !isCompleting, let field = notification.object as? NSTextField else { return }
      commit(field)
    }
  }

  final class RenameTextField: NSTextField {
    weak var coordinator: Coordinator?

    override func keyDown(with event: NSEvent) {
      switch event.keyCode {
      case 36, 76:
        coordinator?.commit(self)
      case 53:
        coordinator?.cancel()
      default:
        super.keyDown(with: event)
      }
    }
  }
}

private func selectedNameRange(in filename: String) -> NSRange {
  let name = (filename as NSString).deletingPathExtension
  guard !name.isEmpty else {
    return NSRange(location: 0, length: (filename as NSString).length)
  }
  return NSRange(location: 0, length: (name as NSString).length)
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
