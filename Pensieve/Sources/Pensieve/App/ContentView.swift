import SwiftUI

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
        if !appState.documentTabs.isEmpty || appState.documentSession.isUntitled {
          DocumentTabStrip()
          Divider()
        }
        EditorPreviewSplit()
      }
    }
    .navigationTitle(
      appState.documentSession.hasEditableBuffer
        ? appState.documentSession.displayTitle : "Pensieve"
    )
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
        if appState.documentSession.isUntitled {
          untitledTabButton()
        }

        ForEach(appState.documentTabs) { tab in
          tabButton(tab)
        }

        Button {
          controller.createUntitledDocument()
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
    .padding(.vertical, 2)
    .background(tabBackground(isSelected))
    .contentShape(Rectangle())
    .onTapGesture {
      controller.selectDocument(id: tab.id)
    }
    .help(tab.displayPath)
  }

  private func tabBackground(_ isSelected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 6, style: .continuous)
      .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
  }

  private func untitledTabButton() -> some View {
    let isDirty = appState.activeDocumentDirty

    return HStack(spacing: 6) {
      Text(
        isDirty
          ? "\(appState.documentSession.displayTitle) *" : appState.documentSession.displayTitle
      )
      .font(.system(size: 12, weight: .semibold))
      .lineLimit(1)
      .truncationMode(.middle)

      Button {
        controller.closeActiveDocument()
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
    .padding(.vertical, 2)
    .background(tabBackground(true))
    .contentShape(Rectangle())
    .help(appState.documentSession.displayTitle)
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
    if !appState.documentSession.hasEditableBuffer {
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
