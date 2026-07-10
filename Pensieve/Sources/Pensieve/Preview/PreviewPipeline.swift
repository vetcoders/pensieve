import Combine
import Dispatch
import Foundation

// MARK: - Pipeline value types

enum PreviewRenderMode: Equatable {
  case markdown
  case plainText
}

/// One render request to the preview pipeline. Equatable on every input the
/// pipeline observes so the scheduler can drop duplicates without re-rendering
/// the markdown AST.
///
/// `refreshToken` is bumped by manual reload affordances (toolbar refresh
/// button, `AppState.requestPreviewRefresh()`); it carries no semantic payload
/// but participates in equality so the dedupe step releases an otherwise
/// identical request.
struct PreviewRenderRequest: Equatable {
  let markdown: String
  let fontSize: CGFloat
  let theme: ThemeManager.Theme
  /// Reading-surface skin layered on top of the flavor CSS. Defaulted so the
  /// many constructors that predate the skin axis (export, command palette,
  /// tests) keep compiling and render the established GitHub surface.
  var skin: ThemeManager.PreviewTheme = .default
  let documentURL: URL?
  var refreshToken: Int = 0

  var renderMode: PreviewRenderMode {
    if Self.hasShebang(markdown) {
      return .plainText
    }
    guard let documentURL else {
      return .markdown
    }
    let ext = documentURL.pathExtension.lowercased()
    guard !ext.isEmpty else {
      return .plainText
    }
    return Self.markdownExtensions.contains(ext) ? .markdown : .plainText
  }

  private static let markdownExtensions: Set<String> = [
    "md", "markdown", "mdown", "mdwn", "mkd", "mkdn",
  ]

  private static func hasShebang(_ text: String) -> Bool {
    let start =
      text.hasPrefix("\u{feff}")
      ? text.dropFirst()
      : text[...]
    return start.hasPrefix("#!")
  }
}

/// A fully composed HTML payload plus its base URL, ready to be loaded into a
/// `WKWebView`. Constructing this is the "HTML document" stage of the pipeline:
///
///     markdown -> render scheduling -> HTML document -> WKWebView load
///
/// Tests inspect `html` directly without spinning up a WebView.
struct PreviewDocument: Equatable {
  let html: String
  let baseURL: URL?
  let bodyHTML: String
  let styleHTML: String
  let mermaidJavaScript: String?
  let katexJavaScript: String?
  let katexCSS: String?
  let containsMath: Bool
  let sourceURL: URL?
  let refreshToken: Int
}

extension PreviewDocument {
  /// Compose the preview HTML around a rendered markdown body. Theme CSS is
  /// sanitized so an embedded `</style>` fragment cannot escape the style
  /// block; appearance CSS comes from `PreviewWebView` so the renderer-side and
  /// webview-side surfaces share one source of truth.
  static func make(
    body: String,
    css: String,
    fontSize: CGFloat,
    skin: ThemeManager.PreviewTheme = .default,
    baseURL: URL?,
    mermaidJavaScript: String? = nil,
    katexJavaScript: String? = nil,
    katexCSS: String? = nil,
    sourceURL: URL? = nil,
    refreshToken: Int = 0
  ) -> PreviewDocument {
    let safeCSS = sanitizedForInlineEmbedding(css)
    let styleHTML = """
      \(safeCSS)
      \(PreviewWebView.appearanceCSS(fontSize: fontSize, skin: skin))
      """
    let mermaidScripts =
      mermaidJavaScript.map { javascript in
        """
        <script>\(sanitizedForInlineEmbedding(javascript))</script>
        <script>\(PreviewWebView.mermaidBootstrapScript)</script>
        """
      } ?? ""
    // KaTeX runtime mirrors the mermaid dance: the bundled <style> and runtime
    // <script> must precede the math bootstrap so `window.katex` exists when
    // the bootstrap runs.
    let katexStyle =
      katexCSS.map { css in
        "<style id=\"vc-katex-style\">\(sanitizedForInlineEmbedding(css))</style>"
      } ?? ""
    let katexRuntime =
      katexJavaScript.map { javascript in
        "<script>\(sanitizedForInlineEmbedding(javascript))</script>"
      } ?? ""
    let mathScript =
      body.contains("data-vc-math=")
      ? """
      \(katexStyle)
      \(katexRuntime)
      <script>\(PreviewWebView.mathBootstrapScript)</script>
      """
      : ""
    let baseElement =
      baseURL.map { url in
        "<base href=\"\(HTMLEmitter.escapeAttribute(url.absoluteString))\">"
      } ?? ""
    let containsMath = body.contains("data-vc-math=")
    let html = """
      <!DOCTYPE html>
      <html><head><meta charset="utf-8">
      \(baseElement)
      <style id="vc-preview-style">
      \(styleHTML)
      </style>
      </head><body>
      <article class="markdown-body">
      \(body)
      </article>
      \(mermaidScripts)
      \(mathScript)
      </body></html>
      """
    return PreviewDocument(
      html: html,
      baseURL: baseURL,
      bodyHTML: body,
      styleHTML: styleHTML,
      mermaidJavaScript: mermaidJavaScript,
      katexJavaScript: katexJavaScript,
      katexCSS: katexCSS,
      containsMath: containsMath,
      sourceURL: sourceURL,
      refreshToken: refreshToken)
  }

  /// Neutralizes element-closing sequences inside inline <script>/<style>
  /// payloads. The HTML parser closes those elements on `</script` / `</style`
  /// case-insensitively, so a plain lowercase `</script>` replacement leaves
  /// `</SCRIPT>` or `</style >` breakouts open; escape the `</` for every case
  /// variant instead.
  private static func sanitizedForInlineEmbedding(_ payload: String) -> String {
    // Template note: "\\" collapses to one literal backslash, yielding "<\/".
    payload.replacingOccurrences(
      of: #"</(?=script|style)"#,
      with: #"<\\/"#,
      options: [.regularExpression, .caseInsensitive]
    )
  }
}

// MARK: - Sink protocol

/// The output stage of the pipeline: anything that can swallow a composed
/// `PreviewDocument`. `PreviewWebView` is the only production sink; tests use
/// a recording sink to assert on document construction and scheduling.
protocol PreviewSink: AnyObject {
  func load(document: PreviewDocument)
}

// MARK: - Pipeline

/// The preview pipeline spine.
///
/// Responsibilities, in order of the pipeline stages:
///
///   1. Accept a `PreviewRenderRequest` via `submit(_:initial:)`.
///   2. Schedule rendering: the first request is applied immediately so the
///      reader never stares at an empty pane; subsequent requests are
///      coalesced through `removeDuplicates` and debounced 400 ms on the main
///      run loop.
///   3. Render markdown to HTML via `MarkdownRenderer` and compose a
///      `PreviewDocument` via `PreviewDocument.make`.
///   4. Hand the document to the attached `PreviewSink`.
///
/// The pipeline outlives SwiftUI re-renders because it is owned by
/// `PreviewRepresentable.Coordinator`.
final class PreviewPipeline {
  private let renderer: MarkdownRenderer
  private let themeManager: ThemeManager
  private let subject = PassthroughSubject<PreviewRenderRequest, Never>()
  private let scheduler: DispatchQueue
  private let debounceInterval: DispatchQueue.SchedulerTimeType.Stride
  private var cancellable: AnyCancellable?
  private weak var sink: PreviewSink?

  /// The most recently applied request. Used to short-circuit redundant
  /// applies when the bus delivers a duplicate after the initial fast-path.
  private(set) var lastApplied: PreviewRenderRequest?

  /// The most recently composed document. Tests inspect this to assert on
  /// what the sink would have received without depending on the sink's
  /// asynchronous load behavior.
  private(set) var lastDocument: PreviewDocument?

  init(
    themeManager: ThemeManager,
    renderer: MarkdownRenderer = MarkdownRenderer(),
    scheduler: DispatchQueue = .main,
    debounce: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(400)
  ) {
    self.themeManager = themeManager
    self.renderer = renderer
    self.scheduler = scheduler
    self.debounceInterval = debounce
  }

  /// Attach a sink and start the scheduling subscription. Safe to call once
  /// per pipeline lifecycle (NSViewRepresentable mount).
  func attach(sink: PreviewSink) {
    self.sink = sink
    cancellable =
      subject
      .removeDuplicates()
      .debounce(for: debounceInterval, scheduler: scheduler)
      .sink { [weak self] request in
        self?.apply(request)
      }
  }

  func detach() {
    cancellable?.cancel()
    cancellable = nil
    sink = nil
  }

  /// Submit a request. `initial == true` applies the request synchronously
  /// before queuing it onto the bus, so the first mount renders without
  /// waiting for the debounce interval. Both branches converge on `apply`,
  /// which dedupes against `lastApplied`.
  func submit(_ request: PreviewRenderRequest, initial: Bool) {
    if initial {
      apply(request)
    }
    subject.send(request)
  }

  /// Synchronously build the document for a request without applying it.
  /// Exposed for tests that exercise document construction independently of
  /// the sink and scheduler.
  // The vendored runtimes are immutable bundle resources but heavy (mermaid
  // ~3.3MB, KaTeX runtime + inline-font CSS ~640KB), and `apply` runs on the
  // main queue per debounced keystroke — cache the disk read + decode once.
  private static let cachedMermaidJavaScript = PreviewResourceLocator.javascript(
    named: "mermaid.min")
  private static let cachedKatexJavaScript = PreviewResourceLocator.javascript(named: "katex.min")
  private static let cachedKatexCSS = PreviewResourceLocator.css(named: "katex.inline.min")

  func makeDocument(for request: PreviewRenderRequest) -> PreviewDocument {
    let body: String
    switch request.renderMode {
    case .markdown:
      body = renderer.render(request.markdown).body
    case .plainText:
      body = Self.plainTextBody(for: request.markdown)
    }
    let css = themeManager.css(for: request.theme)
    let mermaidJavaScript =
      body.contains("class=\"mermaid\"")
      ? Self.cachedMermaidJavaScript
      : nil
    // Embed the KaTeX payload only when the rendered body actually contains math.
    let containsMath = body.contains("data-vc-math=")
    let katexJavaScript = containsMath ? Self.cachedKatexJavaScript : nil
    let katexCSS = containsMath ? Self.cachedKatexCSS : nil
    return PreviewDocument.make(
      body: body,
      css: css,
      fontSize: request.fontSize,
      skin: request.skin,
      baseURL: PreviewRepresentable.resolveBaseURL(for: request.documentURL),
      mermaidJavaScript: mermaidJavaScript,
      katexJavaScript: katexJavaScript,
      katexCSS: katexCSS,
      sourceURL: request.documentURL,
      refreshToken: request.refreshToken
    )
  }

  private static func plainTextBody(for text: String) -> String {
    let escaped = HTMLEmitter.escapeText(text)
    return """
      <pre class="vc-plain-text" data-vc-block="0" style="font-size: var(--vc-font-size);"><code>\(escaped)</code></pre>
      """
  }

  private func apply(_ request: PreviewRenderRequest) {
    guard let sink else { return }
    if lastApplied == request { return }
    lastApplied = request
    let document = makeDocument(for: request)
    lastDocument = document
    sink.load(document: document)
  }
}
