import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            EditorPreviewSplit()
        }
        .navigationTitle(appState.selectedDocument?.title ?? "Pensieve")
        .navigationSubtitle(appState.activeDocumentDirty ? "Edited" : "")
    }
}

struct EditorPreviewSplit: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        switch appState.mode {
        case .source:
            EditorView()
        case .split:
            HSplitView {
                EditorView()
                    .frame(minWidth: 320)
                PreviewView()
                    .frame(minWidth: 320)
            }
        case .preview:
            PreviewView()
        case .focus:
            // Focus mode = source with dimmed surroundings (Wave 2)
            EditorView()
        }
    }
}
