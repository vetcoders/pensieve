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
  /// Stylesheet the loaded page is known to carry, so a same-identity edit can
  /// skip re-shipping an unchanged (and font-payload-heavy) style block.
  private var appliedStyleHTML: String?
  /// Last skin `applyThemeChrome` was asked for, so a re-parent can re-assert the
  /// chrome without waiting for a document the render dedupe may never send.
  private var assertedSkin: PensieveTheme?

  // Test seam: observes full-page (re)loads without a live WKWebView process.
  var fullPageLoadObserver: ((PreviewDocument) -> Void)?
  // Test seam: observes the in-place update script without a live WebContent process.
  var inPlaceUpdateObserver: ((String) -> Void)?

  override init(frame frameRect: NSRect) {
    let config = WKWebViewConfiguration()
    webView = WKWebView(frame: .zero, configuration: config)
    webView.setValue(false, forKey: "drawsBackground")
    webView.underPageBackgroundColor = WindowChromeRecipe.titlebarGlassBackingColor(for: .default)
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
    titlebarGlassController.attach(to: window)
    // A re-parent hands us a window that knows nothing about the skin, and no
    // new document has to follow (the render dedupe may hold everything back
    // while the content is unchanged). Heal it here from the last asserted skin.
    if let assertedSkin {
      applyThemeChrome(for: assertedSkin)
    }
  }

  override func layout() {
    super.layout()
    titlebarGlassController.layoutDidChange()
  }

  // The chrome offset and the scrolled dissolve have ONE owner on macOS 26:
  // WebKit's auto-adopted `obscuredContentInsets` pocket — the WebKit face of
  // the same OS mechanism that insets the editor's scroll view
  // (`automaticallyAdjustsContentInsets`). The pocket parks the page start at
  // the glass line AND renders the native scroll-edge ghosts through the band
  // (measured on the polarize L3 rig: pocket band p95 2–12/255 vs editor
  // 3–11/255; zeroing the insets instead painted scrolled text CRISP through
  // the title at 192/255). Never zero or re-assert these insets: fighting the
  // adoption is what forced the CSS offset + masked-veil imitation (cuts
  // 7-10 → 7-12b) that could not reach pixel parity. Before macOS 26 there is
  // no pocket API; `PreviewTitlebarGlassController` plumbs the measured glass
  // height as the CSS fallback offset instead.

  // MARK: - Public

  /// Load a composed `PreviewDocument` into the WebView. The first load, manual
  /// refreshes, and document switches use a full HTML load; same-document edits
  /// update the already-loaded article/style in place so scroll position and the
  /// WKWebView process stay stable while typing.
  func load(document: PreviewDocument) {
    lastDocument = document
    applyThemeChrome(for: document.skin)
    let identity = PreviewLoadIdentity(document: document)
    guard loadedIdentity == identity else {
      loadFullPage(document, identity: identity)
      return
    }
    updateLoadedPage(document)
  }

  /// Pins the WebView (and its container) to the theme's appearance and feeds
  /// the chrome the theme's source surface as the titlebar backing colour.
  ///
  /// Single-mode skins ship NO `@media (prefers-color-scheme:)`, so an explicit
  /// `NSAppearance` is the only thing stopping the flavour bundle (`gfm.css`,
  /// which DOES branch on `prefers-color-scheme`) from painting a dark theme's
  /// code blocks light (or vice versa) when the system appearance disagrees
  /// with the chosen theme. Adaptive themes (`default`/`raw`) pass `nil` and
  /// keep following the system.
  ///
  /// Re-asserted (compare-and-set) on every hosting update pass and on every
  /// re-parent — NOT once per rendered document. Riding `load(document:)` alone
  /// was not enough: `PreviewPipeline.apply` drops a request equal to
  /// `lastApplied`, so while the content is unchanged no document reaches the
  /// sink at all, and in preview-only mode there is no `MarkdownEditorSurface` to
  /// heal the host window instead. A toolbar re-bridge or tab-group reshuffle
  /// that clobbered the appearance therefore stayed clobbered for as long as the
  /// reader did not type — the same bug class `c454889` fixed on the editor path.
  ///
  /// Equal values are skipped at every level (this view, the WebView, the
  /// window), so a steady state issues no sets and there is no recomposite storm.
  func applyThemeChrome(for skin: PensieveTheme) {
    assertedSkin = skin

    let appearance = WindowChromeRecipe.windowAppearance(for: skin)
    if self.appearance?.name != appearance?.name {
      self.appearance = appearance
    }
    if webView.appearance?.name != appearance?.name {
      webView.appearance = appearance
    }
    let backing = WindowChromeRecipe.titlebarGlassBackingColor(for: skin)
    if !WindowChromeRecipe.colorsMatch(webView.underPageBackgroundColor, backing) {
      webView.underPageBackgroundColor = backing
    }

    // Preview-only mode mounts NO source editor, so `MarkdownEditorSurface`
    // never runs and nobody else asserts the HOST WINDOW's chrome — pinning
    // this view's appearance alone leaves the titlebar and sidebar on the
    // previous skin. One shared definition of "wanted chrome"; equal values are
    // skipped inside.
    if let window = self.window {
      WindowChromeRecipe.assertWindowChrome(on: window, for: skin)
    }
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
    // The full HTML embeds this stylesheet inline, so the page carries it
    // already — the next same-identity edit has nothing to re-ship.
    appliedStyleHTML = document.styleHTML
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

      \(styleUpdateScript(for: document))
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
    inPlaceUpdateObserver?(script)
    webView.evaluateJavaScript(script) { [weak self, document] result, error in
      self?.handleUpdateScriptResult(result, error: error, for: document)
    }
  }

  /// The `<style>` half of the in-place update — omitted entirely when the loaded
  /// page already carries this exact stylesheet.
  ///
  /// The composed stylesheet embeds the skin's `@font-face` payload, so for a
  /// bundled-font theme it is a 0.2–0.8 MB string. Shipping it on every debounced
  /// keystroke meant escaping that blob into a JS literal and marshalling it
  /// across the WebKit bridge only for the page to compare it and throw it away.
  /// The payload still goes out whenever it genuinely changed (skin switch, font
  /// size), and a full page load re-embeds it in the HTML — both update the
  /// bookkeeping, so the page and this side never disagree about what is loaded.
  private func styleUpdateScript(for document: PreviewDocument) -> String {
    guard appliedStyleHTML != document.styleHTML else { return "" }
    appliedStyleHTML = document.styleHTML
    return """
        let style = document.getElementById('vc-preview-style');
        if (!style) {
          style = document.createElement('style');
          style.id = 'vc-preview-style';
          document.head.appendChild(style);
        }
        const nextStyle = \(PreviewWebView.javaScriptStringLiteral(document.styleHTML));
        if (style.textContent !== nextStyle) {
          style.textContent = nextStyle;
        }
      """
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

  /// Assembled `@font-face` payload per skin. The bundle cannot change at
  /// runtime, so a skin's payload is a process constant — and it is a big one
  /// (0.2–0.8 MB of base64 for a bundled-font theme). Rebuilding it inside
  /// `appearanceCSS` meant every debounced keystroke rescanned the `Fonts`
  /// directory, re-read the faces and re-joined the whole blob before anything
  /// compared it. Assembled at most once per skin instead.
  private static let fontFaceCSSLock = NSLock()
  private static var fontFaceCSSBySkin: [PensieveTheme: String] = [:]

  /// Test seam: how many times a skin payload has actually been assembled, so
  /// the cache can be pinned without a wall-clock measurement.
  private(set) static var fontFaceCSSAssemblyCount = 0

  private static func cachedFontFaceCSS(for skin: PensieveTheme, referencedIn skinBlock: String)
    -> String
  {
    fontFaceCSSLock.lock()
    defer { fontFaceCSSLock.unlock() }
    if let cached = fontFaceCSSBySkin[skin] { return cached }
    let assembled = BundledFonts.fontFaceCSS(referencedIn: skinBlock)
    fontFaceCSSBySkin[skin] = assembled
    fontFaceCSSAssemblyCount += 1
    return assembled
  }

  static func appearanceCSS(fontSize: CGFloat, skin: PensieveTheme = .default)
    -> String
  {
    let skinBlock = skinCSS(for: skin)
    // Deliver the bundled families to WebContent via @font-face data URIs —
    // process-scope CTFontManager registration does not cross into the WebView's
    // out-of-process content. Scoped to the families this skin references, so
    // `default`/`raw` carry no font payload.
    let fontFaces = cachedFontFaceCSS(for: skin, referencedIn: skinBlock)
    return """
      \(fontFaces)
      :root {
        color-scheme: light dark;
        --vc-font-size: \(Int(fontSize))px;
        --vc-preview-text: #1f2328;
        --vc-preview-muted: #57606a;
        --vc-preview-border: #d0d7de;
        --vc-preview-code-bg: #f6f8fa;
        --vc-preview-code-shadow: 0 1px 2px rgba(31, 35, 40, 0.06), 0 8px 24px rgba(31, 35, 40, 0.05);
        --vc-preview-link: #0969da;
        --vc-preview-row-alt: #f6f8fa;
        --vc-preview-mark-bg: #fff8c5;
        --vc-preview-mark-text: #24292f;
        /* Semantic status tokens (P0/HOLD/OPEN markers). Kept in the base block so
           `default` and `raw` carry them too; single-mode skins re-tune them. */
        --vc-preview-danger: #cf222e;
        --vc-preview-warning: #9a6700;
        --vc-preview-positive: #1a7f37;
        --vc-preview-diagram-bg: #ffffff;
        --vc-preview-diagram-error-bg: #fff1f1;
        --vc-preview-diagram-error-text: #8c1d18;
        --vc-preview-math-bg: #f6f8fa;
        --vc-preview-page-background: transparent;
        \(PreviewTitlebarGlassController.titlebarGlassHeightCSSVariable): 0px;
      }

      @media (prefers-color-scheme: dark) {
        :root {
          --vc-preview-text: #f0f0f0;
          --vc-preview-muted: #a1a1aa;
          --vc-preview-border: #3f3f46;
          --vc-preview-code-bg: #2a2a2d;
          --vc-preview-code-shadow: 0 1px 2px rgba(0, 0, 0, 0.28), 0 8px 24px rgba(0, 0, 0, 0.18);
          --vc-preview-link: #8ab4f8;
          --vc-preview-row-alt: #242428;
          --vc-preview-mark-bg: #4a3f16;
          --vc-preview-mark-text: #fff3b0;
          --vc-preview-danger: #ff7b72;
          --vc-preview-warning: #d29922;
          --vc-preview-positive: #3fb950;
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

      /* No page-side chrome band here — deliberately. The dissolve under the
         titlebar glass is owned by the OS on macOS 26 (WebKit's auto-adopted
         obscuredContentInsets pocket renders the same scroll-edge ghosts as the
         editor pane; measured, polarize L3). Two imitations died against
         measured platform walls and must not come back: (1) backdrop-filter is
         dead in exactly this strip — Core Animation refuses nested backdrop
         capture under the native titlebar glass (cut 7-12; the same rule blurs
         fine in a plain window, and @supports lies because the limit is
         positional); (2) a masked backing veil (cuts 7-12/7-12b) sits ON TOP of
         the pocket's own ghosts and can only mute them — it transmitted 0/255
         on the operator window (polarize L2). */

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
        border: 0 !important;
        font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Monaco, "Cascadia Code", monospace;
        white-space: normal !important;
        overflow-wrap: anywhere;
        word-break: break-word;
      }

      .markdown-body pre {
        background: var(--vc-preview-code-bg) !important;
        color: var(--vc-preview-text) !important;
        max-width: 100%;
        overflow-x: auto;
        border: 0 !important;
        border-radius: 8px;
        box-shadow: var(--vc-preview-code-shadow);
        padding: 12px 14px;
        margin: 1rem 0;
        font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Monaco, "Cascadia Code", monospace;
        font-size: 0.92em;
        line-height: 1.5;
      }

      .markdown-body pre code,
      .markdown-body pre tt {
        background: transparent !important;
        margin: 0;
        padding: 0;
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

      /* Third task state — `[~]` "in progress" (mockups 1a–1e, 2a). GFM has no
         such checkbox, so HTMLEmitter tags the input with `data-vc-task-state`
         and CSS draws it: an accent frame with a diamond inside. `[ ]` and `[x]`
         never match this selector and keep the native control untouched. The
         accent is `--vc-preview-link` — the one token every skin already
         re-tunes — so the diamond follows the skin without per-skin CSS, and the
         attribute selector outranks the skin overlays' bare class rules. */
      .markdown-body .task-list-item-checkbox[data-vc-task-state="in-progress"] {
        appearance: none;
        -webkit-appearance: none;
        box-sizing: border-box;
        width: 13px;
        height: 13px;
        border: 1.5px solid var(--vc-preview-link);
        border-radius: 3px;
        background: transparent;
        /* inline-block, not a flex/grid box: those take their baseline from the
           first in-flow item and would drop the frame ~2px below the native
           `[ ]`/`[x]` controls sitting in the same list. The diamond is
           positioned instead of laid out, so the box keeps an empty
           inline-block's baseline — the same one a bare checkbox has. */
        display: inline-block;
        position: relative;
      }

      .markdown-body .task-list-item-checkbox[data-vc-task-state="in-progress"]::after {
        content: "";
        position: absolute;
        top: 50%;
        left: 50%;
        width: 6px;
        height: 6px;
        margin: -3px 0 0 -3px;
        background: var(--vc-preview-link);
        transform: rotate(45deg);
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
      \(skinBlock)
      """
  }

  /// CSS overlay for a reading-surface skin. Each skin overrides design tokens
  /// (`--vc-preview-*`) and `.markdown-body` typography only; structural rules
  /// stay owned by the base appearance block and the flavor bundle. `.default`
  /// emits nothing so the established GitHub surface is byte-for-byte unchanged.
  ///
  /// The five fixed-palette skins are SINGLE-MODE: they set every token
  /// unconditionally (no `@media (prefers-color-scheme:)`) and come LAST in the
  /// stylesheet, so they win over the base block's dark `@media` regardless of
  /// system appearance. The WebView's pinned `NSAppearance` (see `PensieveTheme
  /// .appearanceName`) keeps the flavour bundle (`gfm.css`) from flipping the
  /// base the other way.
  static func skinCSS(for skin: PensieveTheme) -> String {
    switch skin {
    case .default:
      return "/* vc-skin:default — base appearance, no overlay */"

    case .raw:
      // Raw: true plaintext — mono, flat headings, one text colour, underlined links.
      return """
        /* vc-skin:raw */
        .markdown-body {
          max-width: none;
          margin: 0;
          font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Monaco, monospace;
          line-height: 1.5;
          font-size: 0.92em;
        }
        .markdown-body h1,
        .markdown-body h2,
        .markdown-body h3,
        .markdown-body h4,
        .markdown-body h5,
        .markdown-body h6 {
          font-size: 1em;
          font-weight: 700;
          color: inherit !important;
          border-bottom: 0;
          padding-bottom: 0;
          margin: 1.2em 0 0.4em;
        }
        .markdown-body a {
          color: inherit !important;
          text-decoration: underline;
        }
        .markdown-body li::marker {
          color: inherit;
        }
        .markdown-body blockquote {
          color: inherit !important;
          border-left-width: 2px;
        }
        .markdown-body pre,
        .markdown-body code,
        .markdown-body tt {
          border: 0 !important;
          border-radius: 0 !important;
          box-shadow: none !important;
          background: transparent !important;
          padding: 0 !important;
        }
        """

    case .parchment:
      return """
        /* vc-skin:parchment — light-only, warm paper, serif measure */
        :root {
          --vc-preview-text: #2a251d;
          --vc-preview-muted: #7a7062;
          --vc-preview-border: #e2d8c2;
          --vc-preview-code-bg: #efe8d6;
          --vc-preview-link: #9a5b28;
          --vc-preview-row-alt: #f2ece0;
          --vc-preview-mark-bg: #e8dcae;
          --vc-preview-mark-text: #2a251d;
          --vc-preview-math-bg: #f3ecda;
          --vc-preview-diagram-bg: #fbf8ef;
          --vc-preview-danger: #8a3a2a;
          --vc-preview-warning: #8a6a20;
          --vc-preview-positive: #4a5a3c;
          --vc-preview-parchment-bg: #f7f2e4;
          --vc-preview-page-background: var(--vc-preview-parchment-bg);
        }
        .markdown-body {
          max-width: 680px;
          font-family: "Newsreader", "New York", Georgia, "Iowan Old Style", serif;
          font-size: 1.02em;
          line-height: 1.78;
          letter-spacing: 0.1px;
        }
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          font-family: "Newsreader", "New York", Georgia, serif;
          font-weight: 600;
          letter-spacing: -0.005em;
        }
        .markdown-body h2 {
          border-bottom: 1px solid var(--vc-preview-border) !important;
          padding-bottom: 0.3em;
        }
        /* Tabele książkowe: tylko linie poziome, bez ramki i bez zebry w środku. */
        .markdown-body table {
          border: 0 !important;
          border-top: 1px solid var(--vc-preview-border) !important;
          border-bottom: 1px solid var(--vc-preview-border) !important;
          border-collapse: collapse;
        }
        .markdown-body thead th {
          background: transparent !important;
          border-bottom: 1px solid var(--vc-preview-border) !important;
          font: 500 0.72em/1 "Newsreader", Georgia, serif;
          letter-spacing: 0.09em;
          text-transform: uppercase;
          color: var(--vc-preview-muted) !important;
        }
        .markdown-body table td, .markdown-body table th {
          border-left: 0 !important;
          border-right: 0 !important;
        }
        .markdown-body pre, .markdown-body code, .markdown-body tt {
          font-family: "Sometype Mono", ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
        }
        .markdown-body :not(pre) > code, .markdown-body tt {
          color: #8a4a3a !important;
        }
        """

    case .graphite:
      return """
        /* vc-skin:graphite — dark-only, cool desaturated, report instrument */
        :root {
          --vc-preview-text: #d2d2d2;
          --vc-preview-muted: #848484;
          --vc-preview-border: #2a2a2a;
          --vc-preview-code-bg: #1f1f1f;
          --vc-preview-link: #86b8c4;
          --vc-preview-row-alt: #191919;
          --vc-preview-mark-bg: #343434;
          --vc-preview-mark-text: #e4e4e4;
          --vc-preview-math-bg: #1f1f1f;
          --vc-preview-diagram-bg: #161616;
          --vc-preview-danger: #c88a8a;
          --vc-preview-warning: #c49a72;
          --vc-preview-positive: #86b8c4;
          --vc-preview-graphite-bg: #1d1d1d;
          --vc-preview-graphite-thead: #1c1c1c;
          --vc-preview-page-background: var(--vc-preview-graphite-bg);
        }
        .markdown-body {
          max-width: 860px;
          font-family: "Instrument Sans", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          line-height: 1.68;
        }
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          font-family: "Instrument Sans", -apple-system, sans-serif;
          font-weight: 700;
          letter-spacing: -0.02em;
        }
        /* Tabela raportowa: mono w komórkach, żeby liczby stały w kolumnie. */
        .markdown-body table {
          border: 1px solid var(--vc-preview-border) !important;
          border-radius: 4px;
          border-collapse: separate;
          border-spacing: 0;
          overflow: hidden;
          font-family: "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace;
          font-size: 0.9em;
          font-variant-numeric: tabular-nums;
        }
        .markdown-body thead th {
          background: var(--vc-preview-graphite-thead) !important;
          font: 500 0.72em/1 "JetBrains Mono", monospace;
          letter-spacing: 0.1em;
          text-transform: uppercase;
          color: var(--vc-preview-muted) !important;
        }
        .markdown-body pre, .markdown-body code, .markdown-body tt {
          font-family: "JetBrains Mono", ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
        }
        .markdown-body :not(pre) > code, .markdown-body tt {
          color: var(--vc-preview-warning) !important;
        }
        """

    case .ink:
      return """
        /* vc-skin:ink — dark-only, signature surface: mercury silver + one violet */
        :root {
          --vc-preview-text: #c6ccd6;
          --vc-preview-muted: #8590a0;
          --vc-preview-border: #232a36;
          --vc-preview-code-bg: #1a2130;
          --vc-preview-link: #8a7fc8;
          --vc-preview-row-alt: #151b26;
          --vc-preview-mark-bg: #2b2540;
          --vc-preview-mark-text: #e4e8ef;
          --vc-preview-math-bg: #1a2130;
          --vc-preview-diagram-bg: #121722;
          --vc-preview-danger: #c88a8a;
          --vc-preview-warning: #c8b07a;
          --vc-preview-positive: #8fa89a;
          --vc-preview-ink-bg: #0f131a;
          --vc-preview-ink-silver: #b8c4d4;
          --vc-preview-ink-strong: #e4e8ef;
          --vc-preview-page-background: var(--vc-preview-ink-bg);
        }
        .markdown-body {
          max-width: 780px;
          font-family: "Literata", "New York", Georgia, serif;
          font-size: 1.01em;
          line-height: 1.72;
        }
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          font-family: "Archivo", -apple-system, BlinkMacSystemFont, sans-serif;
          font-weight: 700;
          letter-spacing: -0.02em;
          color: var(--vc-preview-ink-strong) !important;
        }
        /* Sygnatura motywu: gasnąca srebrna linia pod h2 zamiast pełnej reguły. */
        .markdown-body h2 {
          border-bottom: 0 !important;
          padding-bottom: 0.35em;
          position: relative;
        }
        .markdown-body h2::after {
          content: "";
          position: absolute;
          left: 0; right: 0; bottom: 0;
          height: 1px;
          background: linear-gradient(to right, var(--vc-preview-link), rgba(138, 127, 200, 0));
        }
        .markdown-body table {
          border: 1px solid var(--vc-preview-border) !important;
          border-radius: 7px;
          border-collapse: separate;
          border-spacing: 0;
          overflow: hidden;
        }
        .markdown-body thead th {
          background: var(--vc-preview-code-bg) !important;
          font: 600 0.72em/1 "Archivo", sans-serif;
          letter-spacing: 0.08em;
          text-transform: uppercase;
          color: var(--vc-preview-muted) !important;
        }
        .markdown-body table td {
          font-variant-numeric: tabular-nums;
        }
        .markdown-body pre, .markdown-body code, .markdown-body tt {
          font-family: "JetBrains Mono", ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
        }
        .markdown-body :not(pre) > code, .markdown-body tt {
          color: #c9a8d8 !important;
        }
        """

    case .porcelain:
      return """
        /* vc-skin:porcelain — light-only, clinical neutral, semantic colour only */
        :root {
          --vc-preview-text: #14181c;
          --vc-preview-muted: #667079;
          --vc-preview-border: #e4e8ec;
          --vc-preview-code-bg: #f3f5f7;
          --vc-preview-link: #0f6f6c;
          --vc-preview-row-alt: #f8fafb;
          --vc-preview-mark-bg: #d9ecea;
          --vc-preview-mark-text: #14181c;
          --vc-preview-math-bg: #f3f5f7;
          --vc-preview-diagram-bg: #fafbfc;
          --vc-preview-danger: #b4322c;
          --vc-preview-warning: #7a4a12;
          --vc-preview-positive: #0f6f6c;
          --vc-preview-porcelain-bg: #ffffff;
          --vc-preview-page-background: var(--vc-preview-porcelain-bg);
        }
        .markdown-body {
          max-width: 820px;
          font-family: "IBM Plex Sans", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          line-height: 1.7;
        }
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          font-family: "IBM Plex Sans", -apple-system, sans-serif;
          font-weight: 600;
          letter-spacing: -0.01em;
        }
        /* Karta pacjenta: gruba reguła otwierająca tabelę, dalej włosowe linie. */
        .markdown-body table {
          border: 0 !important;
          border-top: 2px solid var(--vc-preview-text) !important;
          border-collapse: collapse;
          font-variant-numeric: tabular-nums;
        }
        .markdown-body thead th {
          background: transparent !important;
          border-bottom: 1px solid var(--vc-preview-border) !important;
          font: 600 0.7em/1 "IBM Plex Mono", ui-monospace, monospace;
          letter-spacing: 0.1em;
          text-transform: uppercase;
          color: var(--vc-preview-muted) !important;
        }
        .markdown-body tbody tr {
          background: transparent !important;
          border-bottom: 1px solid #eef1f4 !important;
        }
        .markdown-body table td, .markdown-body table th {
          border-left: 0 !important;
          border-right: 0 !important;
        }
        .markdown-body pre, .markdown-body code, .markdown-body tt {
          font-family: "IBM Plex Mono", ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
        }
        .markdown-body :not(pre) > code, .markdown-body tt {
          color: var(--vc-preview-warning) !important;
        }
        """

    // TEMPORARY — test-build line only, remove after the operator picks.
    //
    // The demo variant differs from `.typewriter` only in window chrome, so it
    // reuses that skin's stylesheet verbatim and carries its own overlay marker
    // (the exhaustiveness pin reads one marker per raw value).
    case .typewriterDarkChrome:
      return skinCSS(for: .typewriter)
        + "\n/* vc-skin:typewriter-dark-chrome — typewriter's reading surface, dark window chrome */"

    // TEMPORARY — test-build line only, remove after the operator picks.
    //
    // "Kartka": one light sheet all the way through. The preview is today's
    // typewriter sheet verbatim — what makes this a candidate is the LIGHT
    // source panel next to it, which lives in the token table, not here.
    case .typewriterLightPaper:
      return skinCSS(for: .typewriter)
        + "\n/* vc-skin:typewriter-light-paper — typewriter's light sheet, light source panel */"

    // TEMPORARY — test-build line only, remove after the operator picks.
    //
    // "Lustro": the dual truth reflected. The preview takes over every role the
    // DARK typewriter source panel plays today — `#1c1c1c` page, `#d4d4d4` body,
    // `#f2f2f2` heads, `#2b2b2b` code wash — while the source panel opposite it
    // goes light. Same ramp, same family, same centred heads: only the side of
    // the ramp each panel sits on is swapped.
    //
    // Written out rather than derived from the typewriter sheet because every
    // colour token flips; only the typography rules would have survived a reuse.
    // It also re-declares `code-shadow` and the two `diagram-error-*` tokens,
    // which the light typewriter sheet leaves to the base block — under this
    // skin's LIGHT window appearance those would otherwise stay light on a dark
    // page. Mermaid's own theme still reads `prefers-color-scheme` from JS and
    // is out of a stylesheet's reach; that is the known demo limitation named on
    // the enum case.
    case .typewriterLightMirror:
      return """
        /* vc-skin:typewriter-light-mirror — mono everywhere, achromatic, dark page under a light window */
        :root {
          --vc-preview-text: #d4d4d4;
          --vc-preview-muted: #a8a8a8;
          --vc-preview-border: #6e6e6e;
          --vc-preview-code-bg: #2b2b2b;
          --vc-preview-code-shadow: none;
          --vc-preview-link: #d4d4d4;
          --vc-preview-row-alt: #171717;
          --vc-preview-mark-bg: #e6e6e6;
          --vc-preview-mark-text: #1c1c1c;
          --vc-preview-math-bg: #171717;
          --vc-preview-diagram-bg: #171717;
          --vc-preview-diagram-error-bg: #2b2b2b;
          --vc-preview-diagram-error-text: #e6e6e6;
          --vc-preview-danger: #d4d4d4;
          --vc-preview-warning: #a8a8a8;
          --vc-preview-positive: #d4d4d4;
          --vc-preview-typewriter-mirror-bg: #1c1c1c;
          --vc-preview-page-background: var(--vc-preview-typewriter-mirror-bg);
        }
        /* Jedna rodzina na wszystko — to jest cały motyw. */
        .markdown-body,
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6,
        .markdown-body pre, .markdown-body code, .markdown-body tt,
        .markdown-body table {
          font-family: "Spline Sans Mono", ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
        }
        .markdown-body {
          max-width: 700px;
          font-size: 0.96em;
          line-height: 1.72;
          color: var(--vc-preview-text) !important;
        }
        /* Hierarchia z wagi i światła, nie z rozmiaru: wyśrodkowane, ledwo większe.
           Nagłówki idą o krok jaśniej od tekstu — lustro roli `srcHeading`. */
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          text-align: center;
          font-weight: 700;
          letter-spacing: 0;
          color: #f2f2f2 !important;
          border-bottom: 0 !important;
          margin-top: 2.1em;
          margin-bottom: 1.05em;
        }
        .markdown-body h1 { font-size: 1.22em; }
        .markdown-body h2 { font-size: 1.12em; }
        .markdown-body h3 { font-size: 1.04em; }
        .markdown-body h4, .markdown-body h5, .markdown-body h6 { font-size: 1em; }
        /* Linki bez barwy — sam podkreślnik. */
        .markdown-body a {
          color: var(--vc-preview-text) !important;
          text-decoration: none;
          border-bottom: 1px solid #6e6e6e;
        }
        .markdown-body :not(pre) > code, .markdown-body tt {
          background: var(--vc-preview-code-bg) !important;
          color: var(--vc-preview-text) !important;
          padding: 1px 4px;
        }
        .markdown-body pre {
          background: #2b2b2b !important;
          box-shadow: none;
          border-radius: 0;
        }
        .markdown-body pre code {
          color: var(--vc-preview-text) !important;
        }
        /* Checkbox jako rysowany kwadrat — ta sama figura, druga strona rampy. */
        .markdown-body .task-list-item-checkbox {
          appearance: none;
          -webkit-appearance: none;
          width: 13px;
          height: 13px;
          border: 1.5px solid #6e6e6e;
          border-radius: 3px;
          background: transparent;
          vertical-align: -2px;
        }
        .markdown-body .task-list-item-checkbox:checked {
          background: var(--vc-preview-text);
          border-color: var(--vc-preview-text);
        }
        .markdown-body .task-list-item-checkbox:checked::after {
          content: "";
          display: block;
          width: 100%;
          height: 100%;
          background: #1c1c1c;
          clip-path: polygon(18% 52%, 40% 74%, 84% 26%, 92% 36%, 40% 88%, 10% 60%);
        }
        .markdown-body table {
          border: 0 !important;
          border-top: 1px solid var(--vc-preview-border) !important;
          border-bottom: 1px solid var(--vc-preview-border) !important;
          border-collapse: collapse;
          font-size: 0.94em;
        }
        .markdown-body thead th {
          background: transparent !important;
          border: 0 !important;
          border-bottom: 1px solid var(--vc-preview-border) !important;
          font-weight: 700;
          text-align: left;
          color: var(--vc-preview-text) !important;
        }
        .markdown-body tbody tr {
          background: transparent !important;
          border-top: 1px solid var(--vc-preview-border) !important;
        }
        .markdown-body table td, .markdown-body table th {
          border-left: 0 !important;
          border-right: 0 !important;
        }
        .markdown-body blockquote {
          color: var(--vc-preview-muted) !important;
          border-left: 2px solid #6e6e6e !important;
        }
        .markdown-body hr {
          background: var(--vc-preview-border) !important;
          border: 0 !important;
        }
        """

    case .typewriter:
      return """
        /* vc-skin:typewriter — one mono family everywhere, achromatic, centred heads */
        :root {
          --vc-preview-text: #1c1c1c;
          --vc-preview-muted: #6e6e6e;
          --vc-preview-border: #e6e6e6;
          --vc-preview-code-bg: #f1f1f1;
          --vc-preview-link: #1c1c1c;
          --vc-preview-row-alt: #f7f7f7;
          --vc-preview-mark-bg: #e6e6e6;
          --vc-preview-mark-text: #1c1c1c;
          --vc-preview-math-bg: #f3f3f3;
          --vc-preview-diagram-bg: #f7f7f7;
          --vc-preview-danger: #1c1c1c;
          --vc-preview-warning: #6e6e6e;
          --vc-preview-positive: #1c1c1c;
          --vc-preview-typewriter-bg: #ffffff;
          --vc-preview-page-background: var(--vc-preview-typewriter-bg);
        }
        /* Jedna rodzina na wszystko — to jest cały motyw. */
        .markdown-body,
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6,
        .markdown-body pre, .markdown-body code, .markdown-body tt,
        .markdown-body table {
          font-family: "Spline Sans Mono", ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
        }
        .markdown-body {
          max-width: 700px;
          font-size: 0.96em;
          line-height: 1.72;
        }
        /* Hierarchia z wagi i światła, nie z rozmiaru: wyśrodkowane, ledwo większe. */
        .markdown-body h1, .markdown-body h2, .markdown-body h3,
        .markdown-body h4, .markdown-body h5, .markdown-body h6 {
          text-align: center;
          font-weight: 700;
          letter-spacing: 0;
          border-bottom: 0 !important;
          margin-top: 2.1em;
          margin-bottom: 1.05em;
        }
        .markdown-body h1 { font-size: 1.22em; }
        .markdown-body h2 { font-size: 1.12em; }
        .markdown-body h3 { font-size: 1.04em; }
        .markdown-body h4, .markdown-body h5, .markdown-body h6 { font-size: 1em; }
        /* Linki bez barwy — sam podkreślnik. */
        .markdown-body a {
          color: var(--vc-preview-text) !important;
          text-decoration: none;
          border-bottom: 1px solid #a8a8a8;
        }
        .markdown-body :not(pre) > code, .markdown-body tt {
          background: var(--vc-preview-code-bg) !important;
          color: var(--vc-preview-text) !important;
          padding: 1px 4px;
        }
        .markdown-body pre {
          background: #f3f3f3 !important;
          box-shadow: none;
          border-radius: 0;
        }
        /* Checkbox jako rysowany kwadrat. Stan „w trakcie” (`[~]`) rysuje blok
           bazowy z tokenu akcentu — tu wychodzi #1c1c1c, jak w makiecie 2a. */
        .markdown-body .task-list-item-checkbox {
          appearance: none;
          -webkit-appearance: none;
          width: 13px;
          height: 13px;
          border: 1.5px solid #a8a8a8;
          border-radius: 3px;
          background: transparent;
          vertical-align: -2px;
        }
        .markdown-body .task-list-item-checkbox:checked {
          background: var(--vc-preview-text);
          border-color: var(--vc-preview-text);
        }
        .markdown-body .task-list-item-checkbox:checked::after {
          content: "";
          display: block;
          width: 100%;
          height: 100%;
          background: #ffffff;
          clip-path: polygon(18% 52%, 40% 74%, 84% 26%, 92% 36%, 40% 88%, 10% 60%);
        }
        .markdown-body table {
          border: 0 !important;
          border-top: 1px solid var(--vc-preview-border) !important;
          border-bottom: 1px solid var(--vc-preview-border) !important;
          border-collapse: collapse;
          font-size: 0.94em;
        }
        .markdown-body thead th {
          background: transparent !important;
          border-bottom: 1px solid var(--vc-preview-border) !important;
          font-weight: 700;
          font-size: 0.8em;
          color: var(--vc-preview-muted) !important;
        }
        .markdown-body table td, .markdown-body table th {
          border-left: 0 !important;
          border-right: 0 !important;
        }
        .markdown-body blockquote {
          border-left: 2px solid var(--vc-preview-text) !important;
          background: var(--vc-preview-row-alt);
          padding: 0.6em 0.9em;
          font-style: italic;
          color: #4a4a4a !important;
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

/// Pre-macOS-26 fallback ONLY: plumbs the measured titlebar height into the
/// CSS offset variable so the page start clears the chrome on systems without
/// the `obscuredContentInsets` pocket. On macOS 26+ the controller stays
/// silent — the OS pocket owns both the offset and the scrolled dissolve, and
/// the CSS variable keeps its 0px default (polarize L3). One offset owner per
/// OS generation, boundary explicit here.
final class PreviewTitlebarGlassController: NSObject {
  static let titlebarGlassHeightCSSVariable = "--vc-preview-titlebar-glass-height"

  /// Test seam: choreography tests force-engage the pre-26 path on any OS.
  var engagementOverride: Bool?
  private var isEngaged: Bool {
    if let engagementOverride { return engagementOverride }
    if #available(macOS 26.0, *) { return false }
    return true
  }

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
  private weak var observedWindow: NSWindow?
  private var contentLayoutObservation: NSKeyValueObservation?
  private var pendingUpdate: DispatchWorkItem?
  private var pendingUpdateNeedsForce = false
  private var lastAppliedHeight: CGFloat?

  deinit {
    invalidate()
  }

  static func titlebarGlassHeightScript(height: CGFloat) -> String {
    // `height` is an already-measured glass height; measurement happens once,
    // in `WindowChromeRecipe.titlebarGlassHeight` — the only owner of that
    // number. Here we only clamp to a whole non-negative CSS pixel.
    let pixelHeight = Int(ceil(max(0, height)))
    return """
      document.documentElement.style.setProperty('\(titlebarGlassHeightCSSVariable)', '\(pixelHeight)px');
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
    guard isEngaged else { return 0 }
    observeWindowIfNeeded(nextWindow)
    return apply(force: true)
  }

  func layoutDidChange() {
    scheduleUpdate()
  }

  func fullPageLoadDidStart() {
    lastAppliedHeight = nil
    scheduleUpdate(force: true)
  }

  @discardableResult
  func navigationDidFinish() -> CGFloat {
    apply(force: true)
  }

  @discardableResult
  func apply(force: Bool = false) -> CGFloat {
    guard isEngaged else { return 0 }
    let height =
      titlebarGlassHeightProvider?(observedWindow)
      ?? WindowChromeRecipe.titlebarGlassHeight(for: observedWindow)
    guard force || lastAppliedHeight != height else {
      return height
    }

    lastAppliedHeight = height
    scriptEvaluator?(Self.titlebarGlassHeightScript(height: height))
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
