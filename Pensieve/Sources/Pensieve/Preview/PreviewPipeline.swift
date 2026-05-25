import Combine
import Dispatch
import Foundation

// MARK: - Pipeline value types

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
  let documentURL: URL?
  var refreshToken: Int = 0
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
}

extension PreviewDocument {
  /// Compose the preview HTML around a rendered markdown body. Theme CSS is
  /// sanitized so an embedded `</style>` fragment cannot escape the style
  /// block; appearance CSS and the viewport bridge script come from
  /// `PreviewWebView` so the renderer-side and webview-side surfaces share
  /// one source of truth.
  static func make(
    body: String,
    css: String,
    fontSize: CGFloat,
    baseURL: URL?,
    mermaidJavaScript: String? = nil
  ) -> PreviewDocument {
    let safeCSS = css.replacingOccurrences(of: "</style>", with: "<\\/style>")
    let mermaidScripts =
      mermaidJavaScript.map { javascript in
        let safeJavaScript = javascript.replacingOccurrences(of: "</script>", with: "<\\/script>")
        return """
          <script>\(safeJavaScript)</script>
          <script>\(PreviewWebView.mermaidBootstrapScript)</script>
          """
      } ?? ""
    let html = """
      <!DOCTYPE html>
      <html><head><meta charset="utf-8">
      <style>
      \(safeCSS)
      \(PreviewWebView.appearanceCSS(fontSize: fontSize))
      </style>
      </head><body>
      <article class="markdown-body">
      \(body)
      </article>
      \(mermaidScripts)
      <script>\(PreviewWebView.bridgeScript)</script>
      </body></html>
      """
    return PreviewDocument(html: html, baseURL: baseURL)
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
///      coalesced through `removeDuplicates` and debounced 200 ms on the main
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
    debounce: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(200)
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
  func makeDocument(for request: PreviewRenderRequest) -> PreviewDocument {
    let output = renderer.render(request.markdown)
    let css = themeManager.css(for: request.theme)
    let mermaidJavaScript =
      output.body.contains("class=\"mermaid\"")
      ? PreviewResourceLocator.javascript(named: "mermaid.min")
      : nil
    return PreviewDocument.make(
      body: output.body,
      css: css,
      fontSize: request.fontSize,
      baseURL: PreviewRepresentable.resolveBaseURL(for: request.documentURL),
      mermaidJavaScript: mermaidJavaScript
    )
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
