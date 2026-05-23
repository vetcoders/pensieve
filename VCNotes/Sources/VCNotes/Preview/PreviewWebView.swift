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
        :root { --vc-font-size: \(Int(fontSize))px; }
        \(safeCSS)
        body { font-size: var(--vc-font-size); padding: 24px; box-sizing: border-box; }
        .markdown-body { max-width: 980px; margin: 0 auto; }
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
    static let vcEditorViewportChanged = Notification.Name("VCNotes.editorViewportChanged")

    /// Posted by the preview when its visible viewport top changes. UserInfo
    /// includes `["block": Int]`. Editor consumes for two-way sync.
    static let vcPreviewViewportChanged = Notification.Name("VCNotes.previewViewportChanged")
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
