import AppKit
import WebKit

/// AppKit-side preview sink.
///
/// Owns a WKWebView and the viewport / external-link bridge surface. This is
/// the terminal stage of the preview pipeline:
///
///     markdown -> render scheduling -> HTML document -> WKWebView load
///                                                       ^^^^^^^^^^^^^
///                                                       this type
///
/// What this type does today:
///   • Loads a `PreviewDocument` into the underlying WKWebView.
///   • Routes activated `http(s)` / `mailto` links to `NSWorkspace` instead of
///     navigating the WebView itself.
final class PreviewWebView: NSView {
  private let webView: WKWebView
  private var loadedIdentity: PreviewLoadIdentity?

  override init(frame frameRect: NSRect) {
    let config = WKWebViewConfiguration()
    webView = WKWebView(frame: .zero, configuration: config)
    webView.setValue(false, forKey: "drawsBackground")
    webView.setAccessibilityIdentifier("pensieve.preview")
    super.init(frame: frameRect)

    addSubview(webView)
    webView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: trailingAnchor),
      webView.topAnchor.constraint(equalTo: topAnchor),
      webView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    webView.navigationDelegate = NavigationProxy.shared
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) not used")
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: - Public

  /// Load a composed `PreviewDocument` into the WebView. The first load, manual
  /// refreshes, and document switches use a full HTML load; same-document edits
  /// update the already-loaded article/style in place so scroll position and the
  /// WKWebView process stay stable while typing.
  func load(document: PreviewDocument) {
    let identity = PreviewLoadIdentity(document: document)
    guard loadedIdentity == identity else {
      loadFullPage(document, identity: identity)
      return
    }
    updateLoadedPage(document)
  }

  private func loadFullPage(_ document: PreviewDocument, identity: PreviewLoadIdentity) {
    webView.loadHTMLString(document.html, baseURL: document.baseURL)
    loadedIdentity = identity
  }

  private func updateLoadedPage(_ document: PreviewDocument) {
    let script = """
      (function() {
        const previousX = window.scrollX || 0;
        const previousY = window.scrollY || 0;
        const article = document.querySelector('article.markdown-body');
        if (!article) {
          return false;
        }

        let style = document.getElementById('vc-preview-style');
        if (!style) {
          style = document.createElement('style');
          style.id = 'vc-preview-style';
          document.head.appendChild(style);
        }
        style.textContent = \(PreviewWebView.javaScriptStringLiteral(document.styleHTML));
        article.innerHTML = \(PreviewWebView.javaScriptStringLiteral(document.bodyHTML));

        const mermaidRuntime = \(PreviewWebView.javaScriptStringLiteral(document.mermaidJavaScript ?? ""));
        if (mermaidRuntime && !window.mermaid) {
          const script = document.createElement('script');
          script.text = mermaidRuntime;
          document.head.appendChild(script);
        }

        const katexCSS = \(PreviewWebView.javaScriptStringLiteral(document.katexCSS ?? ""));
        if (katexCSS) {
          let katexStyle = document.getElementById('vc-katex-style');
          if (!katexStyle) {
            katexStyle = document.createElement('style');
            katexStyle.id = 'vc-katex-style';
            document.head.appendChild(katexStyle);
          }
          if (katexStyle.textContent !== katexCSS) {
            katexStyle.textContent = katexCSS;
          }
        }

        const katexRuntime = \(PreviewWebView.javaScriptStringLiteral(document.katexJavaScript ?? ""));
        if (katexRuntime && !window.katex) {
          const script = document.createElement('script');
          script.text = katexRuntime;
          document.head.appendChild(script);
        }

        \(document.containsMath ? Self.mathBootstrapScript : "")
        \(document.mermaidJavaScript == nil ? "" : Self.mermaidBootstrapScript)

        requestAnimationFrame(function() {
          const maxY = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
          window.scrollTo(previousX, Math.min(previousY, maxY));
        });
        return true;
      })();
      """
    webView.evaluateJavaScript(script) { [weak self, document] result, error in
      guard error == nil, (result as? Bool) == true else {
        self?.loadFullPage(document, identity: PreviewLoadIdentity(document: document))
        return
      }
    }
  }

  static func appearanceCSS(fontSize: CGFloat, skin: ThemeManager.PreviewTheme = .default)
    -> String
  {
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
      --vc-preview-diagram-bg: #ffffff;
      --vc-preview-diagram-error-bg: #fff1f1;
      --vc-preview-diagram-error-text: #8c1d18;
      --vc-preview-math-bg: #f6f8fa;
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
        --vc-preview-diagram-bg: #18181b;
        --vc-preview-diagram-error-bg: #3f1d1d;
        --vc-preview-diagram-error-text: #fecaca;
        --vc-preview-math-bg: #27272a;
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
      border: 1px solid var(--vc-preview-border);
      border-radius: 6px;
      padding: 12px 14px;
      margin: 1rem 0;
      font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Monaco, "Cascadia Code", monospace;
      font-size: 0.92em;
      line-height: 1.5;
    }

    .markdown-body pre code,
    .markdown-body pre tt {
      white-space: pre !important;
      overflow-wrap: normal;
      word-break: normal;
      font-family: inherit;
    }

    /* Task lists: GFM-style — no bullet, checkbox inline with its label. */
    .markdown-body .task-list-item {
      list-style: none;
    }

    .markdown-body .task-list-item-checkbox {
      margin: 0 0.45em 0 -1.35em;
      vertical-align: middle;
    }

    .markdown-body .task-list-item > p {
      display: inline;
      margin: 0;
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

    .markdown-body .vc-math {
      background: var(--vc-preview-math-bg);
      border-radius: 4px;
      color: var(--vc-preview-text);
      font-family: "KaTeX_Main", "STIX Two Math", "Times New Roman", serif;
      overflow-wrap: anywhere;
    }

    .markdown-body .vc-math-inline {
      display: inline-block;
      padding: 0 0.22em;
      vertical-align: baseline;
    }

    .markdown-body .vc-math-display {
      border: 1px solid var(--vc-preview-border);
      display: block;
      margin: 1rem 0;
      overflow-x: auto;
      padding: 0.85rem 1rem;
      text-align: center;
      white-space: pre-wrap;
    }

    .markdown-body .vc-math.vc-math-error {
      color: var(--vc-preview-diagram-error-text);
    }

    /* Mermaid preview support added by pensieve-mermaid-preview-20260525. */
    .markdown-body .mermaid {
      background: var(--vc-preview-diagram-bg);
      border: 1px solid var(--vc-preview-border);
      border-radius: 6px;
      box-sizing: border-box;
      color: var(--vc-preview-text);
      margin: 1rem 0;
      max-width: 100%;
      overflow-x: auto;
      padding: 1rem;
      text-align: center;
    }

    .markdown-body .mermaid svg {
      background: transparent !important;
      height: auto;
      max-width: 100%;
    }

    .markdown-body .mermaid .label,
    .markdown-body .mermaid .nodeLabel,
    .markdown-body .mermaid .edgeLabel,
    .markdown-body .mermaid text {
      color: var(--vc-preview-text) !important;
      fill: var(--vc-preview-text) !important;
    }

    .markdown-body .mermaid .edgePath .path,
    .markdown-body .mermaid .flowchart-link,
    .markdown-body .mermaid .relationshipLine {
      stroke: var(--vc-preview-muted) !important;
    }

    .markdown-body .mermaid.vc-mermaid-error {
      background: var(--vc-preview-diagram-error-bg);
      color: var(--vc-preview-diagram-error-text) !important;
      font-family: "Monaco", monospace, "Courier", "Inconsolata", "Bitstream Vera Sans Mono";
      text-align: left;
      white-space: pre-wrap;
    }

    /* Reading-surface skin overlay — re-tunes the base appearance tokens and
       body typography. Comes last so it wins over the base block above without
       re-implementing any flavor (markdown.css / gfm.css) rules. */
    \(skinCSS(for: skin))
    """
  }

  /// CSS overlay for a reading-surface skin. Each skin overrides design tokens
  /// (`--vc-preview-*`) and `.markdown-body` typography only; structural rules
  /// stay owned by the base appearance block and the flavor bundle. `.default`
  /// emits nothing so the established GitHub surface is byte-for-byte unchanged.
  static func skinCSS(for skin: ThemeManager.PreviewTheme) -> String {
    switch skin {
    case .default:
      return "/* vc-skin:default — base appearance, no overlay */"

    case .paper:
      // Warm paper: serif body, narrow measure, generous line height, ink-on-cream.
      return """
        /* vc-skin:paper */
        :root {
          --vc-preview-text: #2b2620;
          --vc-preview-muted: #6b6358;
          --vc-preview-border: #e3d9c6;
          --vc-preview-code-bg: #f3ecda;
          --vc-preview-link: #8a5a2b;
          --vc-preview-row-alt: #f3ecda;
          --vc-preview-paper-bg: #faf4e6;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --vc-preview-text: #e8e0d0;
            --vc-preview-muted: #b3a892;
            --vc-preview-border: #4a4234;
            --vc-preview-code-bg: #2b2820;
            --vc-preview-link: #d9a566;
            --vc-preview-row-alt: #26231c;
            --vc-preview-paper-bg: #1d1a14;
          }
        }
        html, body {
          background: var(--vc-preview-paper-bg) !important;
        }
        .markdown-body {
          max-width: 720px;
          font-family: "New York", Georgia, "Iowan Old Style", "Times New Roman", serif;
          line-height: 1.78;
          letter-spacing: 0.1px;
        }
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          font-family: "New York", Georgia, "Iowan Old Style", serif;
          letter-spacing: 0.2px;
        }
        """

    case .code:
      // Code surface: monospace everything, terminal-ish slate tokens, tight rhythm.
      return """
        /* vc-skin:code */
        :root {
          --vc-preview-text: #d6deeb;
          --vc-preview-muted: #8694a8;
          --vc-preview-border: #20293a;
          --vc-preview-code-bg: #0d1623;
          --vc-preview-link: #7fb3ff;
          --vc-preview-row-alt: #131d2c;
          --vc-preview-code-surface: #0a121d;
        }
        @media (prefers-color-scheme: light) {
          :root {
            --vc-preview-text: #1b2330;
            --vc-preview-muted: #5a6675;
            --vc-preview-border: #d2dae6;
            --vc-preview-code-bg: #eef2f7;
            --vc-preview-link: #1f6feb;
            --vc-preview-row-alt: #f1f5fa;
            --vc-preview-code-surface: #f6f9fc;
          }
        }
        html, body {
          background: var(--vc-preview-code-surface) !important;
        }
        .markdown-body {
          max-width: 900px;
          font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Monaco, "Cascadia Code", monospace;
          line-height: 1.55;
          font-size: 0.95em;
        }
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Monaco, monospace;
          letter-spacing: -0.2px;
        }
        """

    case .raw:
      // Raw: stripped chrome, full width, monospace, near "view source".
      return """
        /* vc-skin:raw */
        .markdown-body {
          max-width: none;
          margin: 0;
          font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Monaco, monospace;
          line-height: 1.5;
          font-size: 0.92em;
        }
        .markdown-body pre,
        .markdown-body code,
        .markdown-body tt {
          border: 0 !important;
          border-radius: 0 !important;
          background: transparent !important;
          padding: 0 !important;
        }
        .markdown-body blockquote {
          border-left-width: 2px;
        }
        """
    }
  }

  static let mathBootstrapScript: String = """
    (function() {
      const nodes = Array.from(document.querySelectorAll('[data-vc-math]'));
      if (!nodes.length) return;

      if (!window.katex || typeof window.katex.render !== 'function') {
        nodes.forEach(function(node) {
          node.setAttribute('title', 'KaTeX runtime unavailable');
        });
        return;
      }

      nodes.forEach(function(node) {
        const tex = node.getAttribute('data-vc-tex') || '';
        const displayMode = node.getAttribute('data-vc-math') === 'display';
        try {
          window.katex.render(tex, node, {
            displayMode: displayMode,
            throwOnError: false,
            strict: false
          });
        } catch (error) {
          node.classList.add('vc-math-error');
          node.setAttribute('title', error && error.message ? error.message : String(error));
        }
      });
    })();
    """

  static let mermaidBootstrapScript: String = """
    (function() {
      const diagrams = Array.from(document.querySelectorAll('.mermaid'));
      if (!diagrams.length) return;

      function markFailed(el, message) {
        el.classList.add('vc-mermaid-error');
        el.setAttribute('role', 'img');
        el.setAttribute('aria-label', 'Invalid Mermaid diagram');
        el.setAttribute('data-vc-mermaid-error', String(message || 'Invalid Mermaid diagram'));
      }

      if (!window.mermaid) {
        diagrams.forEach(function(el) {
          markFailed(el, 'Mermaid runtime unavailable');
        });
        return;
      }

      const dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
      const themeVariables = dark ? {
        background: '#18181b',
        primaryColor: '#27272a',
        primaryTextColor: '#f0f0f0',
        primaryBorderColor: '#71717a',
        lineColor: '#a1a1aa',
        secondaryColor: '#1f2937',
        tertiaryColor: '#111827'
      } : {
        background: '#ffffff',
        primaryColor: '#f6f8fa',
        primaryTextColor: '#1f2328',
        primaryBorderColor: '#8c959f',
        lineColor: '#57606a',
        secondaryColor: '#eef6ff',
        tertiaryColor: '#ffffff'
      };

      try {
        window.mermaid.parseError = function(error) {
          console.warn('Mermaid parse error', error);
        };
        window.mermaid.initialize({
          startOnLoad: false,
          securityLevel: 'strict',
          suppressErrorRendering: true,
          theme: 'base',
          themeVariables: themeVariables
        });

        Promise.all(diagrams.map(function(el) {
          const source = el.textContent || '';
          return Promise.resolve(window.mermaid.parse(source, { suppressErrors: true }))
            .then(function(result) {
              if (result === false) {
                markFailed(el, 'Invalid Mermaid diagram');
                return null;
              }
              return el;
            })
            .catch(function(error) {
              markFailed(el, error && error.message ? error.message : error);
              return null;
            });
        })).then(function(results) {
          const validDiagrams = results.filter(Boolean);
          if (!validDiagrams.length) return;
          return window.mermaid.run({ nodes: validDiagrams, suppressErrors: true });
        }).catch(function(error) {
          diagrams.forEach(function(el) {
            if (!el.querySelector('svg')) {
              markFailed(el, error && error.message ? error.message : error);
            }
          });
        });
      } catch (error) {
        diagrams.forEach(function(el) {
          markFailed(el, error && error.message ? error.message : error);
        });
      }
    })();
    """

  private static func javaScriptStringLiteral(_ value: String) -> String {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: value,
        options: [.fragmentsAllowed]),
      let literal = String(data: data, encoding: .utf8)
    else {
      return "\"\""
    }
    return literal
  }
}

private struct PreviewLoadIdentity: Equatable {
  let baseURL: URL?
  let sourceURL: URL?
  let refreshToken: Int

  init(document: PreviewDocument) {
    baseURL = document.baseURL
    sourceURL = document.sourceURL
    refreshToken = document.refreshToken
  }
}

// MARK: - PreviewSink conformance

extension PreviewWebView: PreviewSink {}

// MARK: - WKNavigationDelegate proxy
// Singleton: opens activated http(s)/mailto links in the default browser,
// allows everything else (initial HTML load, JS-driven scrollIntoView, …).

private final class NavigationProxy: NSObject, WKNavigationDelegate {
  static let shared = NavigationProxy()

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    if navigationAction.navigationType == .linkActivated,
      let url = navigationAction.request.url
    {
      if let scheme = url.scheme?.lowercased(),
        ["http", "https", "mailto"].contains(scheme)
      {
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
        return
      }
    }
    decisionHandler(.allow)
  }
}
