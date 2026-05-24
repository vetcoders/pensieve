import XCTest
@testable import Pensieve

final class PreviewPipelineTests: XCTestCase {

    // MARK: - Render request

    func testRenderRequestIsValueEquality() {
        let url = URL(fileURLWithPath: "/tmp/notes/a.md")
        let a = PreviewRenderRequest(markdown: "# A", fontSize: 14, theme: .markdown, documentURL: url)
        let b = PreviewRenderRequest(markdown: "# A", fontSize: 14, theme: .markdown, documentURL: url)
        XCTAssertEqual(a, b)

        let differentFontSize = PreviewRenderRequest(markdown: "# A", fontSize: 15, theme: .markdown, documentURL: url)
        XCTAssertNotEqual(a, differentFontSize)

        let differentTheme = PreviewRenderRequest(markdown: "# A", fontSize: 14, theme: .gfm, documentURL: url)
        XCTAssertNotEqual(a, differentTheme)
    }

    // MARK: - Document construction

    func testMakeDocumentEmbedsBodyThemeCSSAndFontSize() {
        let document = PreviewDocument.make(
            body: "<p data-vc-block=\"0\">hello</p>",
            css: ".markdown-body { color: tomato; }",
            fontSize: 17,
            baseURL: URL(fileURLWithPath: "/tmp")
        )

        // Body wrapped in the markdown-body article.
        XCTAssertTrue(document.html.contains("<article class=\"markdown-body\">"))
        XCTAssertTrue(document.html.contains("<p data-vc-block=\"0\">hello</p>"))

        // Theme CSS is inlined.
        XCTAssertTrue(document.html.contains(".markdown-body { color: tomato; }"))

        // Responsive appearance CSS is composed in with the requested font size.
        XCTAssertTrue(document.html.contains("--vc-font-size: 17px"))
        XCTAssertTrue(document.html.contains("@media (prefers-color-scheme: dark)"))

        // Viewport bridge script is embedded so block-level scroll sync stays wired.
        XCTAssertTrue(document.html.contains("window.__vcScrollToBlock"))

        XCTAssertEqual(document.baseURL?.path, URL(fileURLWithPath: "/tmp").path)
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

        let first = PreviewRenderRequest(markdown: "# first", fontSize: 14, theme: .markdown, documentURL: nil)
        let second = PreviewRenderRequest(markdown: "# second", fontSize: 14, theme: .markdown, documentURL: nil)

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
        let request = PreviewRenderRequest(markdown: "# x", fontSize: 14, theme: .markdown, documentURL: nil)
        pipeline.submit(request, initial: true)
        XCTAssertEqual(sink.received.count, 1)

        pipeline.detach()

        let nextRequest = PreviewRenderRequest(markdown: "# y", fontSize: 14, theme: .markdown, documentURL: nil)
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
