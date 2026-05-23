import SwiftUI
import WebKit

// MARK: - SwiftUI wrapper (Wave C-3 agent replaces with full swift-markdown render)

struct PreviewView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        PreviewRepresentable(
            markdown: appState.activeDocumentText,
            fontSize: appState.fontSize
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}

struct PreviewRepresentable: NSViewRepresentable {
    let markdown: String
    let fontSize: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        loadHTML(in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        loadHTML(in: webView)
    }

    private func loadHTML(in webView: WKWebView) {
        let baseURL = Bundle.module.resourceURL
        let escaped = markdown
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <link rel="stylesheet" href="markdown.css">
        <style>body { font-size: \(fontSize)px; padding: 24px; }</style>
        </head><body><pre>\(escaped)</pre></body></html>
        """
        webView.loadHTMLString(html, baseURL: baseURL)
    }
}
