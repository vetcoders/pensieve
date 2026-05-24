import SwiftUI
import AppKit
import WebKit

// MARK: - SwiftUI surface

/// SwiftUI entry point for the preview pane.
///
/// The full pipeline is wired in `PreviewPipeline`:
///
///     PreviewRenderRequest -> PreviewPipeline (schedule)
///                          -> PreviewDocument (compose)
///                          -> PreviewWebView (sink)
///
/// `PreviewView` only translates `AppState` into render requests; the
/// scheduling and document construction live in `PreviewPipeline`.
struct PreviewView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var themeManager = ThemeManager()

    var body: some View {
        PreviewRepresentable(
            markdown: appState.activeDocumentText,
            fontSize: appState.fontSize,
            theme: themeManager.current,
            themeManager: themeManager,
            documentURL: appState.activeDocumentURL
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}

// MARK: - NSViewRepresentable bridge

struct PreviewRepresentable: NSViewRepresentable {
    let markdown: String
    let fontSize: CGFloat
    let theme: ThemeManager.Theme
    let themeManager: ThemeManager
    let documentURL: URL?

    /// Base URL for relative resource resolution inside the preview WebView.
    /// File-first markdown: relative images/links belong to the note's folder.
    /// Falls back to the module bundle so a fresh app (no document loaded) is
    /// still well-defined.
    static func resolveBaseURL(for documentURL: URL?) -> URL? {
        if let documentURL {
            return documentURL.deletingLastPathComponent()
        }
        return Bundle.module.resourceURL
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(themeManager: themeManager)
    }

    func makeNSView(context: Context) -> PreviewWebView {
        let view = PreviewWebView(frame: .zero)
        context.coordinator.attach(view: view)
        context.coordinator.submit(request: currentRequest, initial: true)
        return view
    }

    func updateNSView(_ nsView: PreviewWebView, context: Context) {
        context.coordinator.submit(request: currentRequest, initial: false)
    }

    static func dismantleNSView(_ nsView: PreviewWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private var currentRequest: PreviewRenderRequest {
        PreviewRenderRequest(
            markdown: markdown,
            fontSize: fontSize,
            theme: theme,
            documentURL: documentURL
        )
    }

    // MARK: - Coordinator

    /// Thin NSViewRepresentable lifecycle adapter. The actual scheduling,
    /// rendering, and document composition live in `PreviewPipeline`.
    final class Coordinator {
        let pipeline: PreviewPipeline

        init(themeManager: ThemeManager) {
            self.pipeline = PreviewPipeline(themeManager: themeManager)
        }

        func attach(view: PreviewWebView) {
            pipeline.attach(sink: view)
        }

        func detach() {
            pipeline.detach()
        }

        func submit(request: PreviewRenderRequest, initial: Bool) {
            pipeline.submit(request, initial: initial)
        }
    }
}
