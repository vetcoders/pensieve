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
