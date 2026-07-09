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
  // Newest document handed to `load(document:)` — the recovery source when the
  // WebContent process dies or an in-place update fails under the same identity.
  private var lastDocument: PreviewDocument?
  private let titlebarGlassController = PreviewTitlebarGlassController()

  // Test seam: observes full-page (re)loads without a live WKWebView process.
  var fullPageLoadObserver: ((PreviewDocument) -> Void)?

  override init(frame frameRect: NSRect) {
    let config = WKWebViewConfiguration()
    webView = WKWebView(frame: .zero, configuration: config)
    webView.setValue(false, forKey: "drawsBackground")
    webView.underPageBackgroundColor = WindowChromeRecipe.titlebarGlassBackingColor
    webView.setAccessibilityIdentifier("pensieve.preview")
    super.init(frame: frameRect)

    enforceFullBleedViewport()
    addSubview(webView)
    webView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: trailingAnchor),
      webView.topAnchor.constraint(equalTo: topAnchor),
      webView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    webView.navigationDelegate = self
    // The controller's own `scriptEvaluator` is the single injectable seam for
    // glass-script choreography (see PreviewThemeTests); here it always targets
    // the live WKWebView.
    titlebarGlassController.scriptEvaluator = { [weak self] script in
      self?.webView.evaluateJavaScript(script, completionHandler: nil)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) not used")
  }

  deinit {
    titlebarGlassController.invalidate()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    enforceFullBleedViewport()
    titlebarGlassController.attach(to: window)
  }

  // The veil band's backing colour resolves through the window's effective
  // appearance; a dark/light flip changes the colour without any geometry
  // notification, so re-plumb the CSS variables on appearance changes.
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    titlebarGlassController.appearanceDidChange()
  }

  override func layout() {
    super.layout()
    enforceFullBleedViewport()
    titlebarGlassController.layoutDidChange()
  }

  /// macOS 26 auto-adopts the view's safe area as obscured content insets:
  /// the layout viewport starts at the chrome's bottom edge, so scrolled
  /// content hard-clips mid-glyph at the toolbelt instead of gliding under
  /// the glass the way the editor's text view does — and the CSS glass-height
  /// offset would double up on the WebKit pocket, parking the page start a
  /// full chrome height below the editor's. WebKit re-applies the automatic
  /// value whenever the view lands in a window, so a single set at init is
  /// not enough; re-assert (guarded, so unchanged values never re-trigger
  /// layout) on window moves and layout passes. The measured titlebar glass
  /// height (CSS var in `appearanceCSS`) is then the only owner of the
  /// chrome offset.
  private func enforceFullBleedViewport() {
    if #available(macOS 26.0, *) {
      let insets = webView.obscuredContentInsets
      if insets.top != 0 || insets.left != 0 || insets.bottom != 0 || insets.right != 0 {
        webView.obscuredContentInsets = NSEdgeInsets()
      }
    }
  }

  // MARK: - Public

  /// Load a composed `PreviewDocument` into the WebView. The first load, manual
  /// refreshes, and document switches use a full HTML load; same-document edits
  /// update the already-loaded article/style in place so scroll position and the
  /// WKWebView process stay stable while typing.
  func load(document: PreviewDocument) {
    lastDocument = document
    let identity = PreviewLoadIdentity(document: document)
    guard loadedIdentity == identity else {
      loadFullPage(document, identity: identity)
      return
    }
    updateLoadedPage(document)
  }

  /// WKWebView leaves a blank page behind when its WebContent process dies
  /// (memory pressure, GPU reset). Without this recovery the preview stays
  /// blank until the next edit happens to fail the in-place update path —
  /// a reader who never types would stare at a white panel forever.
  func handleWebContentProcessTermination() {
    DebugTrace.log("preview web content process terminated — reloading last document")
    loadedIdentity = nil
    guard let document = lastDocument else { return }
    loadFullPage(document, identity: PreviewLoadIdentity(document: document))
  }

  // Scroll sync is deliberately ONE-WAY (editor → preview). The preview-side
  // readback that would close the loop was the re-entrancy direction that
  // crashed the original two-way design; ScrollSyncTests pins the one-way
  // contract. Do not add a preview scroll observer without going through the
  // coordinator's latch semantics.
  private func scrollToScrollSyncPosition(_ position: ScrollSyncPosition) {
    guard loadedIdentity != nil else { return }
    let progress = position.progress
    let script = """
      (function() {
        const maxY = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
        const nextY = maxY * \(progress);
        window.scrollTo({ left: window.scrollX || 0, top: nextY, behavior: 'auto' });
        return true;
      })();
      """
    webView.evaluateJavaScript(script, completionHandler: nil)
  }

  private func loadFullPage(_ document: PreviewDocument, identity: PreviewLoadIdentity) {
    webView.loadHTMLString(document.html, baseURL: document.baseURL)
    loadedIdentity = identity
    titlebarGlassController.fullPageLoadDidStart()
    fullPageLoadObserver?(document)
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
      self?.handleUpdateScriptResult(result, error: error, for: document)
    }
  }

  /// Completion for the in-place update script. A `false`/error result means
  /// the loaded page can no longer host the article (crashed process, stripped
  /// DOM), so fall back to a full load — but only while the failed document's
  /// identity is still the one on screen: the completion arrives async, and an
  /// unconditional reload here would overwrite a newer page with stale content.
  /// `lastDocument` (not the failed snapshot) is reloaded so same-identity
  /// edits that raced past the failure are not rolled back.
  func handleUpdateScriptResult(_ result: Any?, error: Error?, for document: PreviewDocument) {
    guard error != nil || (result as? Bool) != true else { return }
    guard loadedIdentity == PreviewLoadIdentity(document: document), let current = lastDocument
    else { return }
    DebugTrace.log("preview in-place update failed — falling back to full page load")
    loadFullPage(current, identity: PreviewLoadIdentity(document: current))
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
      --vc-preview-page-background: transparent;
      \(PreviewTitlebarGlassController.titlebarGlassHeightCSSVariable): 0px;
      \(PreviewTitlebarGlassController.titlebarGlassBackingCSSVariable): transparent;
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
      padding: calc(var(\(PreviewTitlebarGlassController.titlebarGlassHeightCSSVariable)) + \(Int(WindowChromeRecipe.previewContentTopInset))px) clamp(12px, 3vw, 28px) clamp(12px, 3vw, 28px) !important;
      box-sizing: border-box;
      min-height: 100vh;
      overflow-wrap: anywhere;
      word-wrap: break-word;
    }

    body::before {
      content: "";
      position: fixed;
      top: var(\(PreviewTitlebarGlassController.titlebarGlassHeightCSSVariable));
      right: 0;
      bottom: 0;
      left: 0;
      background: var(--vc-preview-page-background);
      pointer-events: none;
    }

    /* The editor pane gets AppKit's scroll-edge effect for free: content
       scrolling under the titlebar glass progressively dissolves toward the
       window edge. WebKit's equivalent only engages with a non-zero
       obscuredContentInsets, which reintroduces the hard-clip scroll pocket
       (measured in cut 7-10), and CSS backdrop-filter is dead in exactly this
       strip: Core Animation refuses nested backdrop capture under the native
       titlebar glass (measured in cut 7-12 — the same rule blurs fine in a
       plain window and below the glass line, and silently drops both the
       filter AND its mask under the glass). So the parity fade is a masked
       veil instead: a fixed band owned by the measured glass-height variable,
       painted in the native glass backing colour (plumbed by the glass
       controller from WindowChromeRecipe so both sides of the split stay
       pixel-identical), fading to transparent toward the band's bottom edge
       so gliding content dissolves the way the editor's does. */
    body::after {
      content: "";
      position: fixed;
      top: 0;
      right: 0;
      left: 0;
      height: var(\(PreviewTitlebarGlassController.titlebarGlassHeightCSSVariable));
      pointer-events: none;
      z-index: 10;
      background: var(\(PreviewTitlebarGlassController.titlebarGlassBackingCSSVariable), transparent);
      -webkit-mask-image: linear-gradient(to bottom, black 50%, rgba(0, 0, 0, 0.35) 100%);
      mask-image: linear-gradient(to bottom, black 50%, rgba(0, 0, 0, 0.35) 100%);
    }

    .markdown-body {
      max-width: 980px;
      margin: 0 auto;
      color: var(--vc-preview-text) !important;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
      line-height: 1.65;
      position: relative;
      overflow-wrap: anywhere;
      word-wrap: break-word;
    }

    .markdown-body > :first-child {
      margin-top: 0 !important;
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
      line-height: 1.25;
      margin-top: 1.4em;
      margin-bottom: 0.55em;
    }

    .markdown-body h1,
    .markdown-body h2,
    .markdown-body h3,
    .markdown-body h4 {
      font-weight: 700;
    }

    .markdown-body h1 {
      font-size: 2em;
    }

    .markdown-body h2 {
      font-size: 1.5em;
    }

    .markdown-body h3 {
      font-size: 1.25em;
    }

    .markdown-body h4 {
      font-size: 1em;
    }

    .markdown-body h5 {
      font-size: 0.875em;
    }

    .markdown-body h6 {
      font-size: 0.85em;
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
          --vc-preview-page-background: var(--vc-preview-paper-bg);
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
            --vc-preview-page-background: var(--vc-preview-paper-bg);
          }
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
          --vc-preview-page-background: var(--vc-preview-code-surface);
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
            --vc-preview-page-background: var(--vc-preview-code-surface);
          }
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

    case .notion:
      // Notion-like: warm neutral ink on white, comfortable measure, red inline
      // code accent. Palette derived from the Apache-2.0 Typora Notion theme
      // (cayxc, modified s1m4ne); dark tokens are the upstream values.
      return """
        /* vc-skin:notion */
        :root {
          --vc-preview-text: #37352f;
          --vc-preview-muted: #73716d;
          --vc-preview-border: #e1e7e8;
          --vc-preview-code-bg: #ededeb;
          --vc-preview-link: #2383e2;
          --vc-preview-row-alt: #f7f6f3;
          --vc-preview-notion-bg: #ffffff;
          --vc-preview-notion-code: #eb5757;
          --vc-preview-page-background: var(--vc-preview-notion-bg);
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --vc-preview-text: #d4d4d4;
            --vc-preview-muted: #9c9c9c;
            --vc-preview-border: #3d3d3d;
            --vc-preview-code-bg: #292927;
            --vc-preview-link: #9c9c9c;
            --vc-preview-row-alt: #202020;
            --vc-preview-notion-bg: #191919;
            --vc-preview-notion-code: #eb5757;
            --vc-preview-page-background: var(--vc-preview-notion-bg);
          }
        }
        .markdown-body {
          max-width: 820px;
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Helvetica Neue", Arial, sans-serif;
          line-height: 1.55;
        }
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          font-weight: 700;
          letter-spacing: -0.01em;
        }
        .markdown-body :not(pre) > code,
        .markdown-body tt {
          color: var(--vc-preview-notion-code) !important;
        }
        """

    case .vista:
      // Vista: Helvetica technical-doc look with framed, banded, hover-lit
      // tables.
      return """
        /* vc-skin:vista */
        :root {
          --vc-preview-text: #1a1a1a;
          --vc-preview-muted: #555555;
          --vc-preview-border: #e0e0e0;
          --vc-preview-code-bg: #f6f8fa;
          --vc-preview-link: #1f6feb;
          --vc-preview-row-alt: #fafafa;
          --vc-preview-vista-bg: #f9f9f9;
          --vc-preview-vista-thead: #f1f1f1;
          --vc-preview-vista-hover: #f5f8ff;
          --vc-preview-page-background: var(--vc-preview-vista-bg);
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --vc-preview-text: #dedede;
            --vc-preview-muted: #aaaaaa;
            --vc-preview-border: #333333;
            --vc-preview-code-bg: rgba(245, 245, 245, 0.06);
            --vc-preview-link: #8ab4f8;
            --vc-preview-row-alt: #181818;
            --vc-preview-vista-bg: #101010;
            --vc-preview-vista-thead: #1f1f1f;
            --vc-preview-vista-hover: #1a2030;
            --vc-preview-page-background: var(--vc-preview-vista-bg);
          }
        }
        .markdown-body {
          max-width: 900px;
          font-family: "Helvetica Neue", Helvetica, Arial, -apple-system, BlinkMacSystemFont, sans-serif;
          line-height: 1.6;
        }
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          font-weight: 600;
        }
        .markdown-body table {
          border: 1px solid var(--vc-preview-border) !important;
          border-radius: 6px;
          border-collapse: separate;
          border-spacing: 0;
          overflow: hidden;
        }
        .markdown-body thead th {
          background: var(--vc-preview-vista-thead) !important;
          font-weight: 600;
        }
        .markdown-body tbody tr:nth-child(even) {
          background: var(--vc-preview-row-alt) !important;
        }
        .markdown-body tbody tr:hover {
          background: var(--vc-preview-vista-hover) !important;
        }
        """

    case .mla:
      // MLA: Times serif, double-spaced, narrow academic measure with indented
      // paragraphs and a centred title.
      return """
        /* vc-skin:mla */
        :root {
          --vc-preview-text: #1a1a1a;
          --vc-preview-muted: #555555;
          --vc-preview-border: #d8d2c4;
          --vc-preview-code-bg: #f2efe6;
          --vc-preview-link: #7a4a1f;
          --vc-preview-row-alt: #f2efe6;
          --vc-preview-mla-bg: #fbfaf5;
          --vc-preview-page-background: var(--vc-preview-mla-bg);
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --vc-preview-text: #e8e4d8;
            --vc-preview-muted: #b0a890;
            --vc-preview-border: #463f31;
            --vc-preview-code-bg: #262219;
            --vc-preview-link: #d2a16a;
            --vc-preview-row-alt: #211d15;
            --vc-preview-mla-bg: #17140d;
            --vc-preview-page-background: var(--vc-preview-mla-bg);
          }
        }
        .markdown-body {
          max-width: 680px;
          font-family: "Times New Roman", Times, Georgia, serif;
          line-height: 2.0;
        }
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          font-family: "Times New Roman", Times, Georgia, serif;
          font-weight: 700;
        }
        .markdown-body h1 {
          text-align: center;
          font-size: 1.3em;
        }
        .markdown-body p {
          text-indent: 2em;
          margin: 0;
        }
        """

    case .jamstatic:
      // Jamstatic: Poppins sans, slate body, lilac accents, deep-violet links.
      return """
        /* vc-skin:jamstatic */
        :root {
          --vc-preview-text: #52525b;
          --vc-preview-muted: #71717a;
          --vc-preview-border: #b1a3cc;
          --vc-preview-code-bg: #f2f7ff;
          --vc-preview-link: #300a66;
          --vc-preview-row-alt: #f2f7ff;
          --vc-preview-jam-bg: #ffffff;
          --vc-preview-jam-accent: #b1a3cc;
          --vc-preview-page-background: var(--vc-preview-jam-bg);
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --vc-preview-text: #cdd0d6;
            --vc-preview-muted: #9b9ba6;
            --vc-preview-border: #4a4060;
            --vc-preview-code-bg: #262234;
            --vc-preview-link: #c4b5fd;
            --vc-preview-row-alt: #242031;
            --vc-preview-jam-bg: #1b1b22;
            --vc-preview-jam-accent: #b1a3cc;
            --vc-preview-page-background: var(--vc-preview-jam-bg);
          }
        }
        .markdown-body {
          max-width: 860px;
          font-family: "Poppins", system-ui, -apple-system, BlinkMacSystemFont, sans-serif;
          line-height: 1.6;
        }
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          font-family: "Poppins", system-ui, sans-serif;
          font-weight: 700;
        }
        .markdown-body a {
          font-weight: 700;
        }
        .markdown-body blockquote {
          border-left: 0.3rem solid var(--vc-preview-jam-accent) !important;
        }
        """

    case .vercel:
      // Vercel: Geist-style sans, near-black ink on white, blue links, purple
      // callout accent. Derived from the MIT Typora Vercel theme (tecladochen);
      // Geist falls back to the system sans (font fallback policy).
      return """
        /* vc-skin:vercel */
        :root {
          --vc-preview-text: #171717;
          --vc-preview-muted: #666666;
          --vc-preview-border: #eaeaea;
          --vc-preview-code-bg: #fafafa;
          --vc-preview-link: #0072f5;
          --vc-preview-row-alt: #fafafa;
          --vc-preview-vercel-bg: #ffffff;
          --vc-preview-vercel-accent: #8e4ec6;
          --vc-preview-page-background: var(--vc-preview-vercel-bg);
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --vc-preview-text: #ededed;
            --vc-preview-muted: #a1a1a1;
            --vc-preview-border: #333333;
            --vc-preview-code-bg: #1a1a1a;
            --vc-preview-link: #52aeff;
            --vc-preview-row-alt: #141414;
            --vc-preview-vercel-bg: #0a0a0a;
            --vc-preview-vercel-accent: #bf7af0;
            --vc-preview-page-background: var(--vc-preview-vercel-bg);
          }
        }
        .markdown-body {
          max-width: 880px;
          font-family: "Geist", -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", sans-serif;
          line-height: 1.65;
        }
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          font-weight: 700;
          letter-spacing: -0.02em;
        }
        .markdown-body a {
          text-decoration: none;
          border-bottom: 1px solid var(--vc-preview-link);
        }
        .markdown-body blockquote {
          border-left: 3px solid var(--vc-preview-vercel-accent) !important;
        }
        .markdown-body pre,
        .markdown-body code,
        .markdown-body tt {
          font-family: "GeistMono", ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
        }
        """

    case .themeable:
      // Themeable: Inter sans on slate, clean Tailwind-ish palette. Derived from
      // the MIT Typora Themeable theme (jhildenbiddle); Inter falls back to the
      // system sans.
      return """
        /* vc-skin:themeable */
        :root {
          --vc-preview-text: #1e293b;
          --vc-preview-muted: #64748b;
          --vc-preview-border: #e2e8f0;
          --vc-preview-code-bg: #f1f5f9;
          --vc-preview-link: #2563eb;
          --vc-preview-row-alt: #f8fafc;
          --vc-preview-themeable-bg: #ffffff;
          --vc-preview-page-background: var(--vc-preview-themeable-bg);
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --vc-preview-text: #e2e8f0;
            --vc-preview-muted: #94a3b8;
            --vc-preview-border: #334155;
            --vc-preview-code-bg: #1e293b;
            --vc-preview-link: #60a5fa;
            --vc-preview-row-alt: #1e293b;
            --vc-preview-themeable-bg: #0f172a;
            --vc-preview-page-background: var(--vc-preview-themeable-bg);
          }
        }
        .markdown-body {
          max-width: 820px;
          font-family: "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          line-height: 1.7;
        }
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          font-weight: 700;
          letter-spacing: -0.015em;
        }
        """

    case .glass:
      // Glass: translucent, backdrop-blurred panels over a soft gradient, with
      // pastel accents. Derived from the MIT Typora Foresee theme (passwordgloo).
      return """
        /* vc-skin:glass */
        :root {
          --vc-preview-text: #333333;
          --vc-preview-muted: #666666;
          --vc-preview-border: rgba(0, 0, 0, 0.08);
          --vc-preview-code-bg: rgba(255, 255, 255, 0.45);
          --vc-preview-link: #2f6fb3;
          --vc-preview-row-alt: rgba(255, 255, 255, 0.35);
          --vc-preview-glass-panel: rgba(255, 255, 255, 0.40);
          --vc-preview-glass-grad-a: #e8f0ff;
          --vc-preview-glass-grad-b: #f6e8ff;
          --vc-preview-page-background: linear-gradient(135deg, var(--vc-preview-glass-grad-a), var(--vc-preview-glass-grad-b));
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --vc-preview-text: #e0e0e0;
            --vc-preview-muted: #a8a8a8;
            --vc-preview-border: rgba(255, 255, 255, 0.10);
            --vc-preview-code-bg: rgba(255, 255, 255, 0.06);
            --vc-preview-link: #b3daff;
            --vc-preview-row-alt: rgba(255, 255, 255, 0.05);
            --vc-preview-glass-panel: rgba(40, 40, 50, 0.45);
            --vc-preview-glass-grad-a: #1b2236;
            --vc-preview-glass-grad-b: #2a1b36;
            --vc-preview-page-background: linear-gradient(135deg, var(--vc-preview-glass-grad-a), var(--vc-preview-glass-grad-b));
          }
        }
        .markdown-body {
          max-width: 820px;
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
          line-height: 1.7;
        }
        .markdown-body pre,
        .markdown-body blockquote,
        .markdown-body table {
          background: var(--vc-preview-glass-panel) !important;
          backdrop-filter: blur(12px);
          -webkit-backdrop-filter: blur(12px);
          border: 1px solid var(--vc-preview-border) !important;
          border-radius: 12px;
        }
        .markdown-body blockquote {
          padding: 0.6em 1em;
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

final class PreviewTitlebarGlassController: NSObject {
  static let titlebarGlassHeightCSSVariable = "--vc-preview-titlebar-glass-height"
  static let titlebarGlassBackingCSSVariable = "--vc-preview-titlebar-glass-backing"

  static let windowChromeNotifications: [Notification.Name] = [
    NSWindow.didResizeNotification,
    NSWindow.didEndLiveResizeNotification,
    NSWindow.willEnterFullScreenNotification,
    NSWindow.didEnterFullScreenNotification,
    NSWindow.willExitFullScreenNotification,
    NSWindow.didExitFullScreenNotification,
    NSWindow.didChangeScreenNotification,
    NSWindow.didChangeBackingPropertiesNotification,
  ]

  var scriptEvaluator: ((String) -> Void)?
  var titlebarGlassHeightProvider: ((NSWindow?) -> CGFloat)?
  var titlebarGlassBackingProvider: ((NSWindow?) -> String)?
  private weak var observedWindow: NSWindow?
  private var contentLayoutObservation: NSKeyValueObservation?
  private var pendingUpdate: DispatchWorkItem?
  private var pendingUpdateNeedsForce = false
  private var lastAppliedHeight: CGFloat?
  private var lastAppliedBacking: String?

  deinit {
    invalidate()
  }

  static func titlebarGlassHeight(frameHeight: CGFloat, contentLayoutHeight: CGFloat) -> CGFloat {
    WindowChromeRecipe.titlebarGlassHeight(
      frameHeight: frameHeight,
      contentLayoutHeight: contentLayoutHeight)
  }

  static func titlebarGlassHeight(for window: NSWindow?) -> CGFloat {
    WindowChromeRecipe.titlebarGlassHeight(for: window)
  }

  static func titlebarGlassHeightScript(height: CGFloat) -> String {
    // `height` is an already-measured glass height; measurement happens once,
    // in titlebarGlassHeight(frameHeight:contentLayoutHeight:). Here we only
    // clamp to a whole non-negative CSS pixel.
    let pixelHeight = Int(ceil(max(0, height)))
    return """
      document.documentElement.style.setProperty('\(titlebarGlassHeightCSSVariable)', '\(pixelHeight)px');
      """
  }

  static func titlebarGlassBackingScript(cssColor: String) -> String {
    """
    document.documentElement.style.setProperty('\(titlebarGlassBackingCSSVariable)', '\(cssColor)');
    """
  }

  func invalidate() {
    pendingUpdate?.cancel()
    pendingUpdate = nil
    pendingUpdateNeedsForce = false
    contentLayoutObservation?.invalidate()
    contentLayoutObservation = nil
    if let observedWindow {
      for name in Self.windowChromeNotifications {
        NotificationCenter.default.removeObserver(self, name: name, object: observedWindow)
      }
    }
    observedWindow = nil
  }

  @discardableResult
  func attach(to nextWindow: NSWindow?) -> CGFloat {
    observeWindowIfNeeded(nextWindow)
    return apply(force: true)
  }

  func layoutDidChange() {
    scheduleUpdate()
  }

  func appearanceDidChange() {
    scheduleUpdate(force: true)
  }

  func fullPageLoadDidStart() {
    lastAppliedHeight = nil
    lastAppliedBacking = nil
    scheduleUpdate(force: true)
  }

  @discardableResult
  func navigationDidFinish() -> CGFloat {
    apply(force: true)
  }

  @discardableResult
  func apply(force: Bool = false) -> CGFloat {
    let height =
      titlebarGlassHeightProvider?(observedWindow)
      ?? Self.titlebarGlassHeight(for: observedWindow)
    let backing =
      titlebarGlassBackingProvider?(observedWindow)
      ?? WindowChromeRecipe.titlebarGlassBackingCSSColor(for: observedWindow)
    guard force || lastAppliedHeight != height || lastAppliedBacking != backing else {
      return height
    }

    lastAppliedHeight = height
    lastAppliedBacking = backing
    scriptEvaluator?(
      Self.titlebarGlassHeightScript(height: height)
        + Self.titlebarGlassBackingScript(cssColor: backing))
    return height
  }

  private func observeWindowIfNeeded(_ nextWindow: NSWindow?) {
    guard observedWindow !== nextWindow else { return }

    if let observedWindow {
      for name in Self.windowChromeNotifications {
        NotificationCenter.default.removeObserver(self, name: name, object: observedWindow)
      }
    }
    observedWindow = nextWindow

    guard let nextWindow else { return }

    for name in Self.windowChromeNotifications {
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(windowChromeGeometryDidChange(_:)),
        name: name,
        object: nextWindow)
    }

    // The resize/fullscreen notifications above never fire for the one chrome
    // change every document window goes through: SwiftUI attaches the toolbar
    // AFTER the preview joins the window, which shrinks `contentLayoutRect`
    // without resizing the full-bleed web view (so no layout pass either).
    // Without this observation the controller keeps the glass height it
    // measured mid-construction — the stale value that both parked the page
    // start a band below the editor's and painted the 7-9 underlay stripe.
    contentLayoutObservation?.invalidate()
    contentLayoutObservation = nextWindow.observe(\.contentLayoutRect) { [weak self] _, _ in
      self?.scheduleUpdate()
    }
  }

  private func scheduleUpdate(force: Bool = false) {
    pendingUpdateNeedsForce = pendingUpdateNeedsForce || force
    pendingUpdate?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      let force = pendingUpdateNeedsForce
      pendingUpdateNeedsForce = false
      pendingUpdate = nil
      apply(force: force)
    }
    pendingUpdate = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: workItem)
  }

  @objc private func windowChromeGeometryDidChange(_ notification: Notification) {
    scheduleUpdate(force: true)
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

extension PreviewWebView: ScrollSyncPreviewTarget {
  func applyScrollSyncPosition(_ position: ScrollSyncPosition) {
    scrollToScrollSyncPosition(position)
  }
}

// MARK: - WKNavigationDelegate
// Opens activated http(s)/mailto links in the default browser, allows everything
// else (initial HTML load, JS-driven scrollIntoView, …), and reapplies native
// chrome measurements after full-page navigations replace the document root.

extension PreviewWebView: WKNavigationDelegate {
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

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    titlebarGlassController.navigationDidFinish()
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    handleWebContentProcessTermination()
  }
}
