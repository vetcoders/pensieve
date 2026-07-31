import AppKit
import PDFKit
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

  // MARK: - PDF pagination

  @MainActor
  func testPDFExportPaginatesALongDocumentAcrossPages() throws {
    let markdown = (1...120)
      .map { "## Rozdział \($0)\n\nZażółć gęślą jaźń — akapit numer \($0) w długim dokumencie.\n" }
      .joined(separator: "\n")
    let session = DocumentSession(
      document: DocumentRef(id: URL(fileURLWithPath: "/tmp/pensieve-export/Long.md")),
      text: markdown,
      isDirty: false
    )
    let document = try XCTUnwrap(
      DocumentExport.renderDocument(
        session: session,
        theme: .markdown,
        fontSize: 16,
        themeManager: ThemeManager()
      )
    )

    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensievePDFExport-\(UUID().uuidString).pdf")
    addTeardownBlock { try? FileManager.default.removeItem(at: output) }

    let written = expectation(description: "PDF written")
    var outcome: Result<Void, Error>?
    DocumentExport.writePDF(document: document, to: output) { result in
      outcome = result
      written.fulfill()
    }
    wait(for: [written], timeout: 120)

    guard case .success = try XCTUnwrap(outcome) else {
      return XCTFail("PDF export failed: \(String(describing: outcome))")
    }
    let pdf = try XCTUnwrap(PDFDocument(url: output))
    XCTAssertGreaterThan(
      pdf.pageCount, 1,
      "createPDF rendered every document onto one endless page; the print pipeline must paginate"
    )
    // AppKit snaps the requested size to the closest known paper (A4 is
    // 595.2755×841.8898pt), so compare within a point.
    let page = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
    let expected = DocumentExport.defaultPaperSize()
    XCTAssertEqual(page.size.width, expected.width, accuracy: 1)
    XCTAssertEqual(page.size.height, expected.height, accuracy: 1)
  }

  func testDefaultPaperSizeFollowsTheRegionsPaperStandard() {
    XCTAssertEqual(
      DocumentExport.defaultPaperSize(for: Locale(identifier: "en_US")),
      NSSize(width: 612, height: 792)
    )
    XCTAssertEqual(
      DocumentExport.defaultPaperSize(for: Locale(identifier: "pl_PL")),
      NSSize(width: 595, height: 842)
    )
  }

  func testPrintInfoRunsHeadlessStraightToTheChosenPDFFile() {
    let output = URL(fileURLWithPath: "/tmp/pensieve-export/Report.pdf")
    let info = DocumentExport.printInfo(
      paperSize: NSSize(width: 595, height: 842), savingTo: output)

    XCTAssertEqual(info.jobDisposition, .save)
    XCTAssertEqual(info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] as? URL, output)
    XCTAssertEqual(info.paperSize.width, 595, accuracy: 1)
    XCTAssertEqual(info.paperSize.height, 842, accuracy: 1)
    XCTAssertEqual(info.topMargin, 54)
    XCTAssertEqual(info.bottomMargin, 54)
    XCTAssertEqual(info.leftMargin, 54)
    XCTAssertEqual(info.rightMargin, 54)
    XCTAssertEqual(info.verticalPagination, .automatic)
  }

  // MARK: - Export palette

  /// Export is WYSIWYG relative to the preview pane, so the exported PDF must
  /// carry the skin the pane is showing — not the `.default` fallback.
  @MainActor
  func testRenderDocumentCarriesTheSkinThePreviewPaneIsShowing() throws {
    let session = DocumentSession(
      document: DocumentRef(id: URL(fileURLWithPath: "/tmp/pensieve-export/Skin.md")),
      text: "# Skin",
      isDirty: false
    )
    let themeManager = ThemeManager()
    themeManager.skin = .parchment

    let document = try XCTUnwrap(
      DocumentExport.renderDocument(
        session: session,
        theme: .markdown,
        fontSize: 16,
        themeManager: themeManager
      )
    )

    XCTAssertTrue(
      document.html.contains("vc-skin:parchment"), "export must not fall back to .default")
  }

  /// WebKit renders print jobs with `prefers-color-scheme` forced to light, so
  /// the variant has to be resolved into the stylesheet before printing.
  func testPDFExportHTMLResolvesTheColourSchemeQueriesForThePinnedVariant() {
    let css = """
      :root { --vc-preview-text: #111; }
      @media (prefers-color-scheme: dark) { :root { --vc-preview-text: #eee; } }
      @media (prefers-color-scheme: light) { :root { --vc-preview-text: #000; } }
      """
    let dark = PreviewColorVariant.pinning(css, to: .dark)
    XCTAssertTrue(dark.contains("@media all { :root { --vc-preview-text: #eee; } }"))
    XCTAssertTrue(dark.contains("@media not all { :root { --vc-preview-text: #000; } }"))

    let light = PreviewColorVariant.pinning(css, to: .light)
    XCTAssertTrue(light.contains("@media not all { :root { --vc-preview-text: #eee; } }"))
    XCTAssertTrue(light.contains("@media all { :root { --vc-preview-text: #000; } }"))
    XCTAssertFalse(
      light.contains("prefers-color-scheme"),
      "no colour-scheme query may survive into a print job"
    )
  }

  @MainActor
  func testPDFExportPagePaintsThePaneBackgroundForTheResolvedAppearance() throws {
    let session = DocumentSession(
      document: DocumentRef(id: URL(fileURLWithPath: "/tmp/pensieve-export/Palette.md")),
      text: "# Palette",
      isDirty: false
    )
    let document = try XCTUnwrap(
      DocumentExport.renderDocument(
        session: session,
        theme: .markdown,
        fontSize: 16,
        themeManager: ThemeManager()
      )
    )
    let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))
    let aqua = try XCTUnwrap(NSAppearance(named: .aqua))

    XCTAssertEqual(DocumentExport.colorVariant(for: darkAqua), .dark)
    XCTAssertEqual(DocumentExport.colorVariant(for: aqua), .light)

    let darkBase = DocumentExport.pageBaseColor(for: darkAqua)
    let lightBase = DocumentExport.pageBaseColor(for: aqua)
    XCTAssertNotEqual(
      darkBase, lightBase, "the page base must follow the appearance, not a constant")

    let html = DocumentExport.pdfExportHTML(for: document, variant: .dark, pageBase: darkBase)
    XCTAssertTrue(
      html.contains("background: var(--vc-preview-page-background, \(darkBase)) !important"),
      "the sheet must carry the skin's page background, falling back to the pane's base"
    )
    XCTAssertTrue(
      html.contains("body::before { display: none !important; }"),
      "the fixed preview surface layer would only stamp the first page"
    )
    XCTAssertTrue(html.contains("print-color-adjust: exact"))
  }

  func testSheetColourReadsTheComputedStyleNotationWebKitReports() throws {
    let opaque = try XCTUnwrap(DocumentExport.sheetColor(fromCSS: "rgb(30, 30, 30)"))
    XCTAssertEqual(opaque.redComponent, 30.0 / 255, accuracy: 0.001)
    XCTAssertEqual(opaque.blueComponent, 30.0 / 255, accuracy: 0.001)

    let translucent = try XCTUnwrap(DocumentExport.sheetColor(fromCSS: "rgba(20, 24, 33, 0.5)"))
    XCTAssertEqual(translucent.alphaComponent, 0.5, accuracy: 0.001)

    XCTAssertNil(
      DocumentExport.sheetColor(fromCSS: "rgba(0, 0, 0, 0)"),
      "a transparent surface must fall back to the page base, not print black"
    )
    XCTAssertNil(DocumentExport.sheetColor(fromCSS: "transparent"))
  }

  /// The print pipeline paints the reading surface inside the printable
  /// rectangle only, so a dark skin came out as a dark block floating on white:
  /// a bare paper frame around every page and a bare tail under the last one.
  /// Export is WYSIWYG against the pane, so the whole sheet carries the surface.
  @MainActor
  func testPDFExportPaintsTheWholeSheetWithTheReadingSurface() throws {
    let letter = NSSize(width: 612, height: 792)

    let dark = try exportPDF(try longExportDocument(skin: .ink), paperSize: letter)
    XCTAssertGreaterThan(dark.pageCount, 1, "the export must still paginate")
    for index in 0..<dark.pageCount {
      let page = try XCTUnwrap(dark.page(at: index))
      XCTAssertEqual(page.bounds(for: .mediaBox).width, letter.width, accuracy: 1)
      let corners = try sheetCorners(of: page)
      for (name, color) in corners {
        XCTAssertLessThan(
          luminance(color), 0.35,
          "page \(index + 1) corner \(name) is bare paper (\(color)) under a dark surface"
        )
      }
      let spread = corners.map { luminance($0.1) }
      XCTAssertLessThan(
        (spread.max() ?? 0) - (spread.min() ?? 0), 0.02,
        "page \(index + 1) must be one uniform sheet, not a block on a frame"
      )
    }

    // The same pass must leave a light surface light — the fix cannot darken the
    // half of the theme that was already correct.
    let light = try exportPDF(try longExportDocument(skin: .parchment), paperSize: letter)
    XCTAssertGreaterThan(light.pageCount, 1)
    for index in 0..<light.pageCount {
      let page = try XCTUnwrap(light.page(at: index))
      for (name, color) in try sheetCorners(of: page) {
        XCTAssertGreaterThan(
          luminance(color), 0.85,
          "page \(index + 1) corner \(name) darkened (\(color)) under a light surface"
        )
      }
    }
  }

  // MARK: - PDF sheet probes

  @MainActor
  private func longExportDocument(skin: PensieveTheme) throws -> PreviewDocument {
    let markdown = (1...60)
      .map { "## Rozdział \($0)\n\nZażółć gęślą jaźń — akapit numer \($0) w eksporcie.\n" }
      .joined(separator: "\n")
    let session = DocumentSession(
      document: DocumentRef(id: URL(fileURLWithPath: "/tmp/pensieve-export/Sheet.md")),
      text: markdown,
      isDirty: false
    )
    let themeManager = ThemeManager()
    themeManager.skin = skin
    return try XCTUnwrap(
      DocumentExport.renderDocument(
        session: session,
        theme: .markdown,
        fontSize: 16,
        themeManager: themeManager
      )
    )
  }

  /// Exports through the real print pipeline, under the appearance the skin
  /// pins — the same resolution the preview pane performs.
  @MainActor
  private func exportPDF(_ document: PreviewDocument, paperSize: NSSize) throws -> PDFDocument {
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveSheet-\(UUID().uuidString).pdf")
    addTeardownBlock { try? FileManager.default.removeItem(at: output) }

    let job = PDFExportJob(document: document, outputURL: output, paperSize: paperSize)
    let written = expectation(description: "PDF written for \(document.skin)")
    var outcome: Result<Void, Error>?
    job.start { result in
      outcome = result
      written.fulfill()
    }
    wait(for: [written], timeout: 120)

    guard case .success = try XCTUnwrap(outcome) else {
      throw XCTSkip("PDF export failed: \(String(describing: outcome))")
    }
    return try XCTUnwrap(PDFDocument(url: output))
  }

  /// Colours in the four corners of a rasterised page — the paper the reader
  /// sees around the text column.
  private func sheetCorners(of page: PDFPage) throws -> [(String, NSColor)] {
    let bounds = page.bounds(for: .mediaBox)
    let image = page.thumbnail(
      of: NSSize(width: bounds.width, height: bounds.height), for: .mediaBox)
    let data = try XCTUnwrap(image.tiffRepresentation)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
    let inset = 4
    let samples = [
      ("top-left", inset, inset),
      ("top-right", bitmap.pixelsWide - 1 - inset, inset),
      ("bottom-left", inset, bitmap.pixelsHigh - 1 - inset),
      ("bottom-right", bitmap.pixelsWide - 1 - inset, bitmap.pixelsHigh - 1 - inset),
    ]
    return try samples.map { name, x, y in
      (name, try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)))
    }
  }

  private func luminance(_ color: NSColor) -> CGFloat {
    0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
  }

  /// A single-mode skin pins its own appearance on the preview pane regardless
  /// of the system setting, so the export must resolve the appearance from the
  /// skin — not from `NSApp.effectiveAppearance`. Otherwise Parchment on a dark
  /// Mac (or Ink on a light one) prints the half of the theme nobody is looking
  /// at, which is the very WYSIWYG break this export path exists to close.
  @MainActor
  func testExportAppearanceFollowsASingleModeSkinRatherThanTheSystem() throws {
    XCTAssertEqual(
      DocumentExport.colorVariant(for: DocumentExport.exportAppearance(for: .parchment)),
      .light,
      "a light-only skin must export light whatever the system appearance is"
    )
    XCTAssertEqual(
      DocumentExport.colorVariant(for: DocumentExport.exportAppearance(for: .ink)),
      .dark,
      "a dark-only skin must export dark whatever the system appearance is"
    )

    // Adaptive skins carry no fixed appearance and keep following the app.
    let adaptive = DocumentExport.exportAppearance(for: .default)
    XCTAssertEqual(
      DocumentExport.colorVariant(for: adaptive),
      DocumentExport.colorVariant(for: NSApplication.shared.effectiveAppearance)
    )
  }

  /// The offscreen export view must not resolve `prefers-color-scheme` from
  /// ambient state — it renders under the appearance the reader is looking at.
  @MainActor
  func testPDFExportJobPinsTheAppearanceItRendersUnder() throws {
    let session = DocumentSession(
      document: DocumentRef(id: URL(fileURLWithPath: "/tmp/pensieve-export/Pin.md")),
      text: "# Pin",
      isDirty: false
    )
    let document = try XCTUnwrap(
      DocumentExport.renderDocument(
        session: session,
        theme: .markdown,
        fontSize: 16,
        themeManager: ThemeManager()
      )
    )
    let job = PDFExportJob(
      document: document,
      outputURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused.pdf"),
      appearance: NSAppearance(named: .darkAqua)
    )

    XCTAssertEqual(job.webView.appearance?.name, .darkAqua)
    XCTAssertEqual(job.variant, .dark)
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
