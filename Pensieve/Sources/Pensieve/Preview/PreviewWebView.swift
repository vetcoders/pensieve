import AppKit
import WebKit

/// AppKit-side preview surface.
///
/// Owns a WKWebView and the two-way scroll bridge:
///   • external links → open in default browser via NSWorkspace
///   • body scroll → posts `.vcPreviewViewportChanged` so editor can follow
///   • exposes `scroll(toBlock:)` so editor can drive preview position
///
/// Editor↔preview coordination is loose: PreviewWebView only listens for
/// `.vcEditorViewportChanged` and dispatches its own viewport changes by
/// notification. The Wave C-2 editor agent wires the editor side; until then
/// the bridge is inert but harmless.
final class PreviewWebView: NSView {
    private let webView: WKWebView
    private let scrollMessageName = "vcScroll"

    private var lastReportedBlock: Int = -1
    private var lastAppliedBlock: Int = -1

    var onViewportChanged: ((Int) -> Void)?

    override init(frame frameRect: NSRect) {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        config.userContentController = userContent
        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        super.init(frame: frameRect)

        userContent.add(MessageProxy(target: self), name: scrollMessageName)

        addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        webView.navigationDelegate = NavigationProxy.shared

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEditorViewportChanged(_:)),
            name: .vcEditorViewportChanged,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: scrollMessageName)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public

    func loadDocument(body: String, css: String, fontSize: CGFloat, baseURL: URL?) {
        let safeCSS = css.replacingOccurrences(of: "</style>", with: "<\\/style>")
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
        \(safeCSS)
        \(Self.appearanceCSS(fontSize: fontSize))
        </style>
        </head><body>
        <article class="markdown-body">
        \(body)
        </article>
        <script>\(Self.bridgeScript)</script>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: baseURL)
        lastReportedBlock = -1
        lastAppliedBlock = -1
    }

    static func appearanceCSS(fontSize: CGFloat) -> String {
        """
        :root {
          color-scheme: light dark;
          --vc-font-size: \(Int(fontSize))px;
          --vc-preview-text: #1f2328;
          --vc-preview-muted: #57606a;
          --vc-preview-border: #d0d7de;
          --vc-preview-code-bg: #f6f8fa;
          --vc-preview-link: #0969da;
          --vc-preview-row-alt: #f6f8fa;
          --vc-preview-mark-bg: #fff8c5;
          --vc-preview-mark-text: #24292f;
        }

        @media (prefers-color-scheme: dark) {
          :root {
            --vc-preview-text: #f0f0f0;
            --vc-preview-muted: #a1a1aa;
            --vc-preview-border: #3f3f46;
            --vc-preview-code-bg: #2a2a2d;
            --vc-preview-link: #8ab4f8;
            --vc-preview-row-alt: #242428;
            --vc-preview-mark-bg: #4a3f16;
            --vc-preview-mark-text: #fff3b0;
          }
        }

        html,
        body {
          background: transparent !important;
          color: var(--vc-preview-text) !important;
        }

        html {
          overflow-x: hidden;
        }

        body {
          font-size: var(--vc-font-size);
          margin: 0 !important;
          padding: clamp(12px, 3vw, 28px) !important;
          box-sizing: border-box;
          overflow-wrap: anywhere;
          word-wrap: break-word;
        }

        .markdown-body {
          max-width: 980px;
          margin: 0 auto;
          color: var(--vc-preview-text) !important;
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
          line-height: 1.65;
          overflow-wrap: anywhere;
          word-wrap: break-word;
        }

        .markdown-body h1,
        .markdown-body h2,
        .markdown-body h3,
        .markdown-body h4,
        .markdown-body h5,
        .markdown-body h6 {
          overflow-wrap: anywhere;
          word-wrap: break-word;
          hyphens: auto;
        }

        .markdown-body h1,
        .markdown-body h2,
        .markdown-body h3,
        .markdown-body h4,
        .markdown-body h5 {
          color: var(--vc-preview-text) !important;
        }

        .markdown-body h2,
        .markdown-body hr,
        .markdown-body table tr,
        .markdown-body table th,
        .markdown-body table td {
          border-color: var(--vc-preview-border) !important;
        }

        .markdown-body h6,
        .markdown-body blockquote {
          color: var(--vc-preview-muted) !important;
        }

        .markdown-body blockquote {
          border-left-color: var(--vc-preview-border) !important;
        }

        .markdown-body a {
          color: var(--vc-preview-link) !important;
          overflow-wrap: anywhere;
          word-break: break-word;
        }

        .markdown-body code,
        .markdown-body tt {
          background: var(--vc-preview-code-bg) !important;
          color: var(--vc-preview-text) !important;
          white-space: normal !important;
          overflow-wrap: anywhere;
          word-break: break-word;
        }

        .markdown-body pre {
          background: var(--vc-preview-code-bg) !important;
          color: var(--vc-preview-text) !important;
          max-width: 100%;
          overflow-x: auto;
        }

        .markdown-body pre code,
        .markdown-body pre tt {
          white-space: pre !important;
          overflow-wrap: normal;
          word-break: normal;
        }

        .markdown-body img {
          max-width: 100%;
          height: auto;
        }

        .markdown-body table {
          display: block;
          width: 100%;
          max-width: 100%;
          overflow-x: auto;
          border-collapse: collapse;
        }

        .markdown-body table tr {
          background: transparent !important;
        }

        .markdown-body table tr:nth-child(2n) {
          background: var(--vc-preview-row-alt) !important;
        }

        .markdown-body table th,
        .markdown-body table td {
          overflow-wrap: anywhere;
          word-break: break-word;
        }

        .markdown-body mark {
          background: var(--vc-preview-mark-bg) !important;
          color: var(--vc-preview-mark-text) !important;
        }
        """
    }

    func scroll(toBlock index: Int) {
        guard index >= 0, index != lastAppliedBlock else { return }
        lastAppliedBlock = index
        let js = "window.__vcScrollToBlock && window.__vcScrollToBlock(\(index));"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - Bridge plumbing

    fileprivate func receivedScrollMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let block = dict["block"] as? Int,
              block != lastReportedBlock
        else { return }
        lastReportedBlock = block
        onViewportChanged?(block)
        NotificationCenter.default.post(
            name: .vcPreviewViewportChanged,
            object: nil,
            userInfo: ["block": block]
        )
    }

    @objc private func handleEditorViewportChanged(_ note: Notification) {
        guard let block = note.userInfo?["block"] as? Int else { return }
        scroll(toBlock: block)
    }

    // MARK: - JS bridge

    private static let bridgeScript: String = """
    (function() {
      function blocks() {
        return Array.from(document.querySelectorAll('[data-vc-block]'));
      }
      window.__vcScrollToBlock = function(idx) {
        const el = document.querySelector('[data-vc-block="' + idx + '"]');
        if (el) {
          el.scrollIntoView({behavior: 'auto', block: 'start'});
        }
      };
      let pending = false;
      function report() {
        const els = blocks();
        for (const el of els) {
          const r = el.getBoundingClientRect();
          if (r.bottom > 0) {
            const idx = parseInt(el.getAttribute('data-vc-block'), 10);
            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vcScroll) {
              window.webkit.messageHandlers.vcScroll.postMessage({block: idx});
            }
            return;
          }
        }
      }
      window.addEventListener('scroll', function() {
        if (pending) return;
        pending = true;
        requestAnimationFrame(function() {
          pending = false;
          report();
        });
      }, {passive: true});
    })();
    """
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted by the editor when its visible viewport top changes. UserInfo
    /// must include `["block": Int]` with the topmost visible block index.
    static let vcEditorViewportChanged = Notification.Name("Pensieve.editorViewportChanged")

    /// Posted by the preview when its visible viewport top changes. UserInfo
    /// includes `["block": Int]`. Editor consumes for two-way sync.
    static let vcPreviewViewportChanged = Notification.Name("Pensieve.previewViewportChanged")
}

// MARK: - WKScriptMessageHandler proxy
// Avoids retain cycle: WKWebView ↣ userContentController ↣ handler ↣ NSView.
// The proxy holds weak ref to the host view.

private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: PreviewWebView?

    init(target: PreviewWebView) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.receivedScrollMessage(message.body)
    }
}

// MARK: - WKNavigationDelegate proxy
// Singleton: opens activated http(s)/mailto links in the default browser,
// allows everything else (initial HTML load, JS-driven scrollIntoView, …).

private final class NavigationProxy: NSObject, WKNavigationDelegate {
    static let shared = NavigationProxy()

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            if let scheme = url.scheme?.lowercased(),
               ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }
}
