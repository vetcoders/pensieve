import AppKit
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
      EditorToolbelt(appState: appState, controller: controller, themeManager: themeManager)
    }
  }
}

struct DocumentTabStrip: View {
  @EnvironmentObject private var appState: AppState
  @EnvironmentObject private var controller: AppController

  var body: some View {
    HStack(spacing: 0) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 0) {
          if appState.documentSession.isUntitled {
            untitledTabButton()
          }

          ForEach(appState.documentTabs) { tab in
            tabButton(tab)
          }
        }
        .padding(.leading, 6)
        // Trackpad gives horizontal scroll for free; a plain mouse wheel only
        // emits vertical deltas. This redirector maps that vertical wheel onto
        // the enclosing scroll view's horizontal axis so the strip is reachable
        // without a trackpad.
        .background(HorizontalWheelRedirector())
      }

      // The "+" stays pinned to the trailing edge instead of scrolling off with
      // the tabs, so New File is always one click away.
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

/// Parked inside a horizontal `ScrollView`, this installs a window-scoped local
/// scroll-wheel monitor that maps a vertical-dominant wheel event (typical of a
/// plain mouse, which can't emit horizontal deltas) onto the enclosing scroll
/// view's horizontal axis. A passive `scrollWheel` override would never fire —
/// AppKit hit-tests wheel events to the frontmost view, and the SwiftUI tab
/// buttons sit on top — so the monitor is the reliable path. It acts only while
/// the cursor is over this strip's scroll view and vertical motion dominates;
/// every other event (incl. trackpad horizontal gestures) passes through.
struct HorizontalWheelRedirector: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.attach(to: view)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator() }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.detach()
  }

  final class Coordinator {
    private weak var anchor: NSView?
    private var monitor: Any?

    func attach(to view: NSView) {
      anchor = view
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        self?.redirect(event) ?? event
      }
    }

    func detach() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    private func redirect(_ event: NSEvent) -> NSEvent? {
      guard let anchor, let window = anchor.window, event.window === window,
        let scrollView = anchor.enclosingScrollView
      else { return event }

      // Only when the pointer is actually over this strip's scroll view.
      let pointInScroll = scrollView.convert(event.locationInWindow, from: nil)
      guard scrollView.bounds.contains(pointInScroll) else { return event }

      // Only when vertical motion dominates — leave native horizontal scroll alone.
      guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
        event.scrollingDeltaY != 0
      else { return event }

      let clip = scrollView.contentView
      let documentWidth = scrollView.documentView?.frame.width ?? clip.bounds.width
      let maxX = max(0, documentWidth - clip.bounds.width)
      guard maxX > 0 else { return event }

      var origin = clip.bounds.origin
      origin.x = min(maxX, max(0, origin.x - event.scrollingDeltaY))
      clip.scroll(to: origin)
      scrollView.reflectScrolledClipView(clip)
      return nil
    }
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
