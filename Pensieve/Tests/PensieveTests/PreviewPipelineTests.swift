import XCTest

@testable import Pensieve

final class PreviewPipelineTests: XCTestCase {

  // MARK: - Render request

  func testRenderRequestIsValueEquality() {
    let url = URL(fileURLWithPath: "/tmp/notes/a.md")
    let a = PreviewRenderRequest(markdown: "# A", fontSize: 14, theme: .markdown, documentURL: url)
    let b = PreviewRenderRequest(markdown: "# A", fontSize: 14, theme: .markdown, documentURL: url)
    XCTAssertEqual(a, b)

    let differentFontSize = PreviewRenderRequest(
      markdown: "# A", fontSize: 15, theme: .markdown, documentURL: url)
    XCTAssertNotEqual(a, differentFontSize)

    let differentTheme = PreviewRenderRequest(
      markdown: "# A", fontSize: 14, theme: .gfm, documentURL: url)
    XCTAssertNotEqual(a, differentTheme)
  }

  // MARK: - Document construction

  func testMakeDocumentEmbedsBodyThemeCSSAndFontSize() {
    let sourceURL = URL(fileURLWithPath: "/tmp/notes/a.md")
    let document = PreviewDocument.make(
      body: "<p data-vc-block=\"0\">hello</p>",
      css: ".markdown-body { color: tomato; }",
      fontSize: 17,
      baseURL: URL(fileURLWithPath: "/tmp"),
      sourceURL: sourceURL,
      refreshToken: 3
    )

    // Body wrapped in the markdown-body article.
    XCTAssertTrue(document.html.contains("<article class=\"markdown-body\">"))
    XCTAssertTrue(document.html.contains("<p data-vc-block=\"0\">hello</p>"))
    XCTAssertEqual(document.bodyHTML, "<p data-vc-block=\"0\">hello</p>")

    // Theme CSS is inlined.
    XCTAssertTrue(document.html.contains(".markdown-body { color: tomato; }"))
    XCTAssertTrue(document.styleHTML.contains(".markdown-body { color: tomato; }"))

    // Responsive appearance CSS is composed in with the requested font size.
    XCTAssertTrue(document.html.contains("--vc-font-size: 17px"))
    XCTAssertTrue(document.html.contains("@media (prefers-color-scheme: dark)"))

    // The old editor-preview scroll bridge was removed; preview documents
    // should not ship the dead bridge script.
    XCTAssertFalse(document.html.contains("window.__vcScrollToBlock"))
    XCTAssertFalse(document.html.contains("window.mermaid"))

    XCTAssertEqual(document.baseURL?.path, URL(fileURLWithPath: "/tmp").path)
    XCTAssertEqual(document.sourceURL, sourceURL)
    XCTAssertEqual(document.refreshToken, 3)
  }

  func testMakeDocumentIncludesMermaidRuntimeOnlyWhenProvided() {
    let withoutMermaid = PreviewDocument.make(
      body: "<p data-vc-block=\"0\">hello</p>",
      css: "",
      fontSize: 14,
      baseURL: nil
    )
    XCTAssertFalse(withoutMermaid.html.contains("mermaid.run"))

    let withMermaid = PreviewDocument.make(
      body: "<div class=\"mermaid\" data-vc-block=\"0\">graph TD\nA--&gt;B</div>",
      css: "",
      fontSize: 14,
      baseURL: nil,
      mermaidJavaScript: "window.mermaid = { initialize() {}, parse() {}, run() {} };"
    )
    XCTAssertTrue(withMermaid.html.contains("window.mermaid ="))
    XCTAssertTrue(withMermaid.html.contains("mermaid.run"))
    XCTAssertTrue(withMermaid.html.contains("suppressErrors: true"))
  }

  func testMakeDocumentIncludesMathBootstrapOnlyForMathBody() {
    let withoutMath = PreviewDocument.make(
      body: "<p data-vc-block=\"0\">hello</p>",
      css: "",
      fontSize: 14,
      baseURL: nil
    )
    XCTAssertFalse(withoutMath.html.contains("window.katex"))
    XCTAssertFalse(withoutMath.html.contains("data-vc-math"))

    let withMath = PreviewDocument.make(
      body:
        "<p data-vc-block=\"0\">A <span class=\"vc-math vc-math-inline\" data-vc-math=\"inline\" data-vc-tex=\"x+y\">x+y</span></p>",
      css: "",
      fontSize: 14,
      baseURL: nil
    )
    XCTAssertTrue(withMath.html.contains("window.katex"))
    XCTAssertTrue(withMath.html.contains("KaTeX runtime unavailable"))
    XCTAssertTrue(withMath.html.contains("data-vc-tex=\"x+y\""))
  }

  func testMakeDocumentIncludesKatexRuntimeOnlyWhenProvided() {
    let mathBody =
      "<p data-vc-block=\"0\">A <span class=\"vc-math vc-math-inline\" data-vc-math=\"inline\" data-vc-tex=\"x+y\">x+y</span></p>"

    let withoutRuntime = PreviewDocument.make(
      body: mathBody,
      css: "",
      fontSize: 14,
      baseURL: nil
    )
    XCTAssertNil(withoutRuntime.katexJavaScript)
    XCTAssertNil(withoutRuntime.katexCSS)
    XCTAssertFalse(withoutRuntime.html.contains("vc-katex-style"))

    let withRuntime = PreviewDocument.make(
      body: mathBody,
      css: "",
      fontSize: 14,
      baseURL: nil,
      katexJavaScript: "window.katex = { render() {} };",
      katexCSS: ".katex { color: inherit; }"
    )
    XCTAssertEqual(withRuntime.katexJavaScript, "window.katex = { render() {} };")
    XCTAssertEqual(withRuntime.katexCSS, ".katex { color: inherit; }")
    XCTAssertTrue(withRuntime.html.contains("window.katex = { render() {} };"))
    XCTAssertTrue(withRuntime.html.contains("<style id=\"vc-katex-style\">"))
    XCTAssertTrue(withRuntime.html.contains(".katex { color: inherit; }"))

    // Runtime must precede the bootstrap so `window.katex` exists when the
    // bootstrap walks the math nodes.
    let runtimeRange = withRuntime.html.range(of: "window.katex = { render() {} };")
    let bootstrapRange = withRuntime.html.range(of: "KaTeX runtime unavailable")
    XCTAssertNotNil(runtimeRange)
    XCTAssertNotNil(bootstrapRange)
    if let runtimeRange, let bootstrapRange {
      XCTAssertTrue(runtimeRange.lowerBound < bootstrapRange.lowerBound)
    }
  }

  func testMakeDocumentEscapesEmbeddedClosersInKatexAssets() {
    let document = PreviewDocument.make(
      body: "<p data-vc-math=\"inline\" data-vc-tex=\"x\">x</p>",
      css: "",
      fontSize: 14,
      baseURL: nil,
      katexJavaScript: "window.example = '</script>';",
      katexCSS: ".katex::after { content: '</style>'; }"
    )
    XCTAssertFalse(document.html.contains("'</script>'"))
    XCTAssertTrue(document.html.contains("'<\\/script>'"))
    XCTAssertFalse(document.html.contains("'</style>'"))
    XCTAssertTrue(document.html.contains("'<\\/style>'"))
  }

  func testMakeDocumentEscapesEmbeddedStyleClose() {
    // A hostile theme CSS string trying to break out of the <style> block
    // must be neutralized.
    let document = PreviewDocument.make(
      body: "<p></p>",
      css: "</style><script>alert('x')</script>",
      fontSize: 14,
      baseURL: nil
    )
    XCTAssertFalse(document.html.contains("</style><script>alert('x')</script>"))
    XCTAssertTrue(document.html.contains("<\\/style>"))
  }

  func testMakeDocumentEscapesEmbeddedScriptCloseInMermaidRuntime() {
    let document = PreviewDocument.make(
      body: "<div class=\"mermaid\">graph TD\nA--&gt;B</div>",
      css: "",
      fontSize: 14,
      baseURL: nil,
      mermaidJavaScript: "window.example = '</script>';"
    )
    XCTAssertFalse(document.html.contains("'</script>'"))
    XCTAssertTrue(document.html.contains("'<\\/script>'"))
  }

  // MARK: - Pipeline scheduling

  @MainActor
  func testPipelineInitialSubmitAppliesImmediately() {
    let sink = RecordingPreviewSink()
    let pipeline = PreviewPipeline(themeManager: ThemeManager())
    pipeline.attach(sink: sink)
    let request = PreviewRenderRequest(
      markdown: "# hi",
      fontSize: 14,
      theme: .markdown,
      documentURL: nil
    )

    pipeline.submit(request, initial: true)

    XCTAssertEqual(sink.received.count, 1, "initial submit must apply synchronously")
    XCTAssertEqual(pipeline.lastApplied, request)
    XCTAssertNotNil(pipeline.lastDocument)
  }

  @MainActor
  func testPipelineDedupesIdenticalRequests() {
    let sink = RecordingPreviewSink()
    let pipeline = PreviewPipeline(themeManager: ThemeManager())
    pipeline.attach(sink: sink)
    let request = PreviewRenderRequest(
      markdown: "# hi",
      fontSize: 14,
      theme: .markdown,
      documentURL: nil
    )

    pipeline.submit(request, initial: true)
    pipeline.submit(request, initial: true)
    pipeline.submit(request, initial: true)

    XCTAssertEqual(sink.received.count, 1, "duplicate requests must not re-render the sink")
  }

  @MainActor
  func testPipelineAppliesChangedRequest() {
    let sink = RecordingPreviewSink()
    let pipeline = PreviewPipeline(themeManager: ThemeManager())
    pipeline.attach(sink: sink)

    let first = PreviewRenderRequest(
      markdown: "# first", fontSize: 14, theme: .markdown, documentURL: nil)
    let second = PreviewRenderRequest(
      markdown: "# second", fontSize: 14, theme: .markdown, documentURL: nil)

    pipeline.submit(first, initial: true)
    pipeline.submit(second, initial: true)

    XCTAssertEqual(sink.received.count, 2)
    XCTAssertEqual(pipeline.lastApplied, second)
    XCTAssertTrue(pipeline.lastDocument?.html.contains("second") == true)
  }

  @MainActor
  func testPipelineMakeDocumentRendersMarkdownThroughHTMLEmitter() {
    let pipeline = PreviewPipeline(themeManager: ThemeManager())
    let request = PreviewRenderRequest(
      markdown: "# Heading\n\nBody.",
      fontSize: 16,
      theme: .markdown,
      documentURL: nil
    )

    let document = pipeline.makeDocument(for: request)

    XCTAssertTrue(document.html.contains("<h1 data-vc-block=\"0\">Heading</h1>"))
    XCTAssertTrue(document.html.contains("<p data-vc-block=\"1\">Body.</p>"))
    XCTAssertTrue(document.html.contains("--vc-font-size: 16px"))
  }

  @MainActor
  func testPipelineMakeDocumentLoadsBundledMermaidForMermaidFence() {
    let pipeline = PreviewPipeline(themeManager: ThemeManager())
    let request = PreviewRenderRequest(
      markdown: "```mermaid\ngraph TD\nA-->B\n```",
      fontSize: 16,
      theme: .markdown,
      documentURL: nil
    )

    let document = pipeline.makeDocument(for: request)

    XCTAssertTrue(document.html.contains("<div class=\"mermaid\""), document.html)
    XCTAssertTrue(document.html.contains("Mermaid v11.15.0"), "bundled runtime missing")
    XCTAssertTrue(document.html.contains("window.mermaid.initialize"))
    XCTAssertTrue(document.html.contains("mermaid.run"))
    XCTAssertFalse(document.html.contains("cdn.jsdelivr"))
    XCTAssertFalse(document.html.contains("unpkg.com"))
  }

  @MainActor
  func testPipelineMakeDocumentRendersMathThroughHTMLEmitter() {
    let pipeline = PreviewPipeline(themeManager: ThemeManager())
    let request = PreviewRenderRequest(
      markdown: "Inline $a^2+b^2=c^2$",
      fontSize: 16,
      theme: .markdown,
      documentURL: nil
    )

    let document = pipeline.makeDocument(for: request)

    XCTAssertTrue(document.html.contains("class=\"vc-math vc-math-inline\""), document.html)
    XCTAssertTrue(document.html.contains("data-vc-tex=\"a^2+b^2=c^2\""), document.html)
    XCTAssertTrue(document.html.contains("window.katex"))

    // The bundled KaTeX runtime + stylesheet must ship with math documents so
    // `window.katex.render` actually exists at bootstrap time.
    XCTAssertNotNil(document.katexJavaScript, "bundled KaTeX runtime missing")
    XCTAssertNotNil(document.katexCSS, "bundled KaTeX stylesheet missing")
    XCTAssertTrue(document.html.contains("e.katex=t()"), "KaTeX runtime not embedded")
    XCTAssertTrue(document.html.contains("font-family:KaTeX_AMS"), "KaTeX CSS not embedded")
    XCTAssertFalse(document.html.contains("cdn.jsdelivr"))
    XCTAssertFalse(document.html.contains("unpkg.com"))
  }

  @MainActor
  func testPipelineMakeDocumentOmitsKatexForPlainDocument() {
    let pipeline = PreviewPipeline(themeManager: ThemeManager())
    let request = PreviewRenderRequest(
      markdown: "# Heading\n\nNo math here.",
      fontSize: 16,
      theme: .markdown,
      documentURL: nil
    )

    let document = pipeline.makeDocument(for: request)

    XCTAssertNil(document.katexJavaScript, "plain document must not carry the ~270KB runtime")
    XCTAssertNil(document.katexCSS, "plain document must not carry the ~370KB stylesheet")
    XCTAssertFalse(document.html.contains("e.katex=t()"))
    XCTAssertFalse(document.html.contains("font-family:KaTeX_AMS"))
    XCTAssertFalse(document.html.contains("vc-katex-style"))
  }

  @MainActor
  func testPipelineMakeDocumentUsesDocumentFolderAsBaseURL() {
    let pipeline = PreviewPipeline(themeManager: ThemeManager())
    let docURL = URL(fileURLWithPath: "/tmp/notes/nested/entry.md")
    let request = PreviewRenderRequest(
      markdown: "body",
      fontSize: 14,
      theme: .markdown,
      documentURL: docURL
    )

    let document = pipeline.makeDocument(for: request)

    XCTAssertEqual(
      document.baseURL?.path,
      URL(fileURLWithPath: "/tmp/notes/nested").path
    )
  }

  @MainActor
  func testPipelineDetachStopsApplying() {
    let sink = RecordingPreviewSink()
    let pipeline = PreviewPipeline(themeManager: ThemeManager())
    pipeline.attach(sink: sink)
    let request = PreviewRenderRequest(
      markdown: "# x", fontSize: 14, theme: .markdown, documentURL: nil)
    pipeline.submit(request, initial: true)
    XCTAssertEqual(sink.received.count, 1)

    pipeline.detach()

    let nextRequest = PreviewRenderRequest(
      markdown: "# y", fontSize: 14, theme: .markdown, documentURL: nil)
    pipeline.submit(nextRequest, initial: true)

    XCTAssertEqual(sink.received.count, 1, "detached pipeline must not push to a released sink")
  }
}

private final class RecordingPreviewSink: PreviewSink {
  var received: [PreviewDocument] = []

  func load(document: PreviewDocument) {
    received.append(document)
  }
}
