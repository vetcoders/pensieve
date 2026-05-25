import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            EditorPreviewSplit()
        }
        .navigationTitle(appState.selectedDocument?.title ?? "Pensieve")
        .navigationSubtitle(appState.activeDocumentDirty ? "Edited" : "")
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
        .frame(minWidth: Self.paneMinWidth, maxWidth: .infinity,
               minHeight: 320, maxHeight: .infinity)
    }

    @ViewBuilder
    private func content(forWidth width: CGFloat) -> some View {
        if appState.documentSession.document == nil {
            DocumentEmptyStateView(hasWorkspace: appState.hasWorkspaceContent)
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

    var body: some View {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var secondaryMessage: String {
        if hasWorkspace {
            return "Pick a note in the sidebar, or open a Markdown file from File ▸ Open."
        }
        return "Open a Markdown file or folder from the File menu to get started."
    }
}
