import AppKit
import XCTest

@testable import Pensieve

final class DocumentExportTests: XCTestCase {
  // MARK: - DOCX geometry

  /// A `w:lvl` without `w:pPr/w:ind` leaves the list paragraph's text indent
  /// undefined; Pages — the default .docx handler on a Mac without Office —
  /// resolved it to nearly the whole text column, collapsing every list
  /// paragraph into a two-character sliver against the right margin and pushing
  /// the document across dozens of near-empty pages.
  func testDOCXNumberingLevelsDefineParagraphIndentGeometry() throws {
    let data = try DocumentTransfer.docxData(
      fromHTML: "<ul><li>Bullet</li></ul><ol><li>Ordered</li></ol>",
      baseURL: nil
    )
    let part = try XCTUnwrap(
      try OfficeOpenXMLDocument.part(named: "word/numbering.xml", in: data))
    let numbering = try XCTUnwrap(String(data: part, encoding: .utf8))

    let levels = numbering.components(separatedBy: "<w:lvl ").dropFirst()
    XCTAssertEqual(levels.count, 2, "one level per abstract numbering definition")
    for level in levels {
      XCTAssertTrue(
        level.contains("<w:ind w:left=\"720\" w:hanging=\"360\"/>"),
        "every numbering level must define its own indent geometry: \(level)"
      )
      XCTAssertTrue(level.contains("<w:lvlJc w:val=\"left\"/>"), level)
    }
  }

  func testDOCXBodyDeclaresLetterPageGeometry() throws {
    let data = try DocumentTransfer.docxData(fromHTML: "<p>Body</p>", baseURL: nil)
    let part = try XCTUnwrap(
      try OfficeOpenXMLDocument.part(named: "word/document.xml", in: data))
    let document = try XCTUnwrap(String(data: part, encoding: .utf8))

    XCTAssertTrue(document.contains("<w:pgSz w:w=\"12240\" w:h=\"15840\"/>"), document)
    XCTAssertTrue(
      document.contains(
        "<w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\"/>"),
      document
    )
  }

  /// The preview's base size is a user setting, so absolute point thresholds
  /// misfired: 16pt body text containing one bold phrase shipped as a Heading3
  /// and Word rendered whole paragraphs as bold headings.
  func testDOCXKeepsBodyParagraphsWithBoldPhrasesOutOfHeadingStyles() throws {
    let html = """
      <html><body style="font-size: 16px">
        <h1 style="font-size: 32px">Tytuł</h1>
        <h2 style="font-size: 24px">Sekcja</h2>
        <p style="font-size: 16px">Akapit z <strong>pogrubieniem</strong> w środku.</p>
      </body></html>
      """
    let data = try DocumentTransfer.docxData(fromHTML: html, baseURL: nil)
    let part = try XCTUnwrap(
      try OfficeOpenXMLDocument.part(named: "word/document.xml", in: data))
    let document = try XCTUnwrap(String(data: part, encoding: .utf8))

    let paragraphs = document.components(separatedBy: "<w:p>").dropFirst()
    let body = try XCTUnwrap(paragraphs.first { $0.contains("Akapit z ") })
    XCTAssertFalse(body.contains("<w:pStyle"), "body text must not be styled as a heading: \(body)")

    XCTAssertTrue(
      paragraphs.contains { $0.contains("Tytuł") && $0.contains("w:val=\"Heading1\"") },
      document
    )
    XCTAssertTrue(
      paragraphs.contains { $0.contains("Sekcja") && $0.contains("w:val=\"Heading2\"") },
      document
    )
  }

  /// AppKit's HTML importer writes ordered markers as "\t1\t"; leaving them in
  /// the run text printed them next to the numbering Word draws itself.
  func testDOCXDropsTheImportersOrderedListMarkerText() throws {
    let data = try DocumentTransfer.docxData(
      fromHTML: "<ol><li>Pierwszy krok</li><li>Drugi krok</li></ol>",
      baseURL: nil
    )
    let part = try XCTUnwrap(
      try OfficeOpenXMLDocument.part(named: "word/document.xml", in: data))
    let document = try XCTUnwrap(String(data: part, encoding: .utf8))

    XCTAssertTrue(document.contains("<w:numId w:val=\"2\"/>"), "ordered list keeps its numbering")
    XCTAssertFalse(
      document.contains("<w:t xml:space=\"preserve\"> 1 </w:t>"),
      "the importer's marker must not survive as body text: \(document)"
    )
    XCTAssertTrue(document.contains("Pierwszy krok"), document)

    let markdown = try OfficeOpenXMLDocument.readMarkdown(data)
    XCTAssertTrue(markdown.contains("1. Pierwszy krok"), markdown)
    XCTAssertFalse(markdown.contains("1. 1 Pierwszy"), markdown)
  }

  @MainActor
  func testRenderDocumentBuildsStandalonePreviewHTMLForActiveSession() {
    let sourceURL = URL(fileURLWithPath: "/tmp/pensieve-export/Daily.md")
    let session = DocumentSession(
      document: DocumentRef(id: sourceURL),
      text: "# Daily\n\nSee [[Index]] and $x+y$.",
      isDirty: false
    )

    let document = DocumentExport.renderDocument(
      session: session,
      theme: .markdown,
      fontSize: 16,
      themeManager: ThemeManager()
    )

    XCTAssertNotNil(document)
    XCTAssertTrue(document?.html.contains("<base href=\"file:///tmp/pensieve-export/\">") == true)
    XCTAssertTrue(document?.html.contains("<h1") == true)
    XCTAssertTrue(document?.html.contains("class=\"wikilink\"") == true)
    XCTAssertTrue(document?.html.contains("data-vc-math=\"inline\"") == true)
    XCTAssertTrue(document?.html.contains("--vc-font-size: 16px") == true)
  }

  func testDefaultExportFileNameReplacesMarkdownExtension() {
    let sourceURL = URL(fileURLWithPath: "/tmp/My Note.md")
    let session = DocumentSession(document: DocumentRef(id: sourceURL), text: "", isDirty: false)

    XCTAssertEqual(
      DocumentExport.defaultExportFileName(for: session, fileExtension: "html"),
      "My Note.html"
    )
    XCTAssertEqual(
      DocumentExport.defaultExportFileName(for: session, fileExtension: "pdf"),
      "My Note.pdf"
    )
    XCTAssertEqual(
      DocumentExport.defaultExportFileName(for: session, fileExtension: "docx"),
      "My Note.docx"
    )
  }

  func testDefaultExportFileNameFallsBackForUntitledBuffers() {
    let session = DocumentSession.untitled(title: "Scratch/Today.md")

    XCTAssertEqual(
      DocumentExport.defaultExportFileName(for: session, fileExtension: "html"),
      "Scratch-Today.html"
    )
  }
}
