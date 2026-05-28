import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @EnvironmentObject private var appState: AppState
  @EnvironmentObject private var controller: AppController
  @EnvironmentObject private var themeManager: ThemeManager

  var body: some View {
    NavigationSplitView {
      SidebarView()
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
    } detail: {
      VStack(spacing: 0) {
        DocumentTabStrip()
        Divider()
        EditorPreviewSplit()
      }
    }
    .navigationTitle(appState.selectedDocument?.title ?? "Pensieve")
    .navigationSubtitle(appState.activeDocumentDirty ? "Edited" : "")
    .toolbar {
      EditorToolbelt(
        appState: appState,
        controller: controller,
        themeManager: themeManager
      )
    }
  }
}

struct DocumentTabStrip: View {
  @EnvironmentObject private var appState: AppState
  @EnvironmentObject private var controller: AppController

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 0) {
        ForEach(appState.documentTabs) { tab in
          tabButton(tab)
        }

        Button {
          createNewFile()
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 34, height: 30)
        }
        .buttonStyle(.plain)
        .help("New File")
        .accessibilityIdentifier("pensieve.tabStrip.newFile")
      }
      .padding(.leading, 6)
    }
    .frame(height: 31)
    .background(Color(NSColor.controlBackgroundColor))
    .accessibilityIdentifier("pensieve.tabStrip")
  }

  private func tabButton(_ tab: DocumentRef) -> some View {
    let isSelected = appState.selectedDocumentID?.standardizedFileURL == tab.id.standardizedFileURL
    let isDirty = isSelected && appState.activeDocumentDirty

    return HStack(spacing: 6) {
      Text(isDirty ? "\(tab.title) *" : tab.title)
        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
        .lineLimit(1)
        .truncationMode(.middle)

      Button {
        controller.closeDocumentTab(id: tab.id)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 9, weight: .semibold))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Close Tab")
    }
    .frame(minWidth: 92, maxWidth: 170, minHeight: 30)
    .padding(.horizontal, 8)
    .background(tabBackground(isSelected))
    .overlay(alignment: .trailing) {
      Rectangle()
        .fill(Color(NSColor.separatorColor))
        .frame(width: 1)
    }
    .contentShape(Rectangle())
    .onTapGesture {
      controller.selectDocument(id: tab.id)
    }
    .help(tab.displayPath)
  }

  private func tabBackground(_ isSelected: Bool) -> some View {
    Rectangle()
      .fill(isSelected ? Color(NSColor.windowBackgroundColor) : Color.clear)
  }

  private func createNewFile() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = markdownContentTypes
    panel.canCreateDirectories = true
    panel.directoryURL = defaultNewFileDirectory
    panel.nameFieldStringValue = uniqueNewFileName(in: panel.directoryURL)
    panel.prompt = "Create"
    if panel.runModal() == .OK, let url = panel.url {
      controller.createMarkdownFile(url: url)
    }
  }

  private var markdownContentTypes: [UTType] {
    [
      UTType(filenameExtension: "md"),
      UTType(filenameExtension: "markdown"),
    ].compactMap { $0 }
  }

  private var defaultNewFileDirectory: URL? {
    if let activeURL = appState.documentSession.url {
      return activeURL.deletingLastPathComponent()
    }
    if let rootURL = appState.workspaceRoots.first?.url {
      return rootURL
    }
    if let openFileURL = appState.openFiles.first?.url {
      return openFileURL.deletingLastPathComponent()
    }
    return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
  }

  private func uniqueNewFileName(in directory: URL?) -> String {
    guard let directory else { return "Untitled.md" }

    let fm = FileManager.default
    let base = "Untitled"
    let ext = "md"
    var candidate = "\(base).\(ext)"
    var index = 2

    while fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
      candidate = "\(base) \(index).\(ext)"
      index += 1
    }

    return candidate
  }
}

struct EditorPreviewSplit: View {
  @EnvironmentObject private var appState: AppState

  /// Minimum pane width below which `.split` collapses to a single pane.
  /// Two panes × 260 + ~40 chrome = 560; below that, side-by-side stops
  /// being usable.
  static let narrowSplitThreshold: CGFloat = 580
  static let paneMinWidth: CGFloat = 260

  var body: some View {
    GeometryReader { geo in
      content(forWidth: geo.size.width)
    }
    .frame(
      minWidth: Self.paneMinWidth, maxWidth: .infinity,
      minHeight: 320, maxHeight: .infinity)
  }

  @ViewBuilder
  private func content(forWidth width: CGFloat) -> some View {
    if appState.documentSession.document == nil {
      DocumentEmptyStateView(
        hasWorkspace: appState.hasWorkspaceContent,
        activity: appState.workspaceActivity
      )
    } else {
      switch appState.mode {
      case .source, .focus:
        // Focus mode shares source layout (Wave 2 dimming TBD).
        EditorView()
      case .preview:
        PreviewView()
      case .split:
        if width < Self.narrowSplitThreshold {
          // Window is too narrow for a real two-pane view; honor the
          // editor as source-of-truth. User can switch to .preview to
          // see rendered output.
          EditorView()
        } else {
          HSplitView {
            EditorView()
              .frame(minWidth: Self.paneMinWidth)
            PreviewView()
              .frame(minWidth: Self.paneMinWidth)
          }
        }
      }
    }
  }
}

/// Detail-pane placeholder shown when no document session is active. Reached
/// from a fresh launch with no restored selection, after File > Close, or
/// after the workspace is cleared. The window stays alive; this view is the
/// thing the operator sees instead of stale editor/preview state.
struct DocumentEmptyStateView: View {
  let hasWorkspace: Bool
  let activity: WorkspaceActivity?

  var body: some View {
    VStack(spacing: 18) {
      if let activity {
        WorkspaceActivityView(activity: activity)
          .frame(maxWidth: 340)
          .accessibilityIdentifier("pensieve.emptyState.activity")
      }

      VStack(spacing: 12) {
        Image(systemName: "doc.text")
          .font(.system(size: 48, weight: .light))
          .foregroundStyle(.tertiary)

        Text("No Document Open")
          .font(.title2)
          .foregroundStyle(.secondary)

        Text(secondaryMessage)
          .font(.callout)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 32)
          .accessibilityIdentifier("pensieve.emptyState.message")

        Text(BuildIdentity.current.conciseLabel)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .accessibilityIdentifier("pensieve.emptyState.buildIdentity")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(NSColor.windowBackgroundColor))
    .accessibilityIdentifier("pensieve.emptyState")
  }

  private var secondaryMessage: String {
    if hasWorkspace {
      return "Pick a note in the sidebar, or open a Markdown file from File ▸ Open."
    }
    return "Open a Markdown file or folder from the File menu to get started."
  }
}

struct WorkspaceActivityView: View {
  let activity: WorkspaceActivity

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text(activity.title)
          .font(.headline)
      }

      Text(activity.detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineLimit(2)

      ProgressView(value: activity.progress)
        .progressViewStyle(.linear)
    }
    .padding(14)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color(NSColor.controlBackgroundColor))
    }
  }
}
