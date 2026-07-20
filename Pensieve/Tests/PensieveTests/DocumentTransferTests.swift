import AppKit
import CoreText
import XCTest

@testable import Pensieve

final class DocumentTransferTests: XCTestCase {
  func testOnlyWordAndPDFSourcesAreClassifiedAsImportable() {
    XCTAssertTrue(DocumentTransfer.isImportable(URL(fileURLWithPath: "/tmp/brief.DOCX")))
    XCTAssertTrue(DocumentTransfer.isImportable(URL(fileURLWithPath: "/tmp/brief.pdf")))
    XCTAssertFalse(DocumentTransfer.isImportable(URL(fileURLWithPath: "/tmp/brief.md")))
    XCTAssertFalse(DocumentTransfer.isImportable(URL(fileURLWithPath: "/tmp/brief.pages")))
  }

  func testDOCXRoundTripPreservesUsefulMarkdownStructure() throws {
    let html = """
      <!doctype html>
      <html><body>
        <h1>Counsel Brief</h1>
        <p>Keep this <strong>confidential</strong> and review the
          <a href="https://example.com/statute">statute</a>.</p>
        <ul><li>First duty</li><li>Second duty</li></ul>
      </body></html>
      """
    let data = try DocumentTransfer.docxData(fromHTML: html, baseURL: nil)
    XCTAssertEqual(Array(data.prefix(2)), [0x50, 0x4B], "DOCX must be an OOXML ZIP package")

    let url = temporaryURL(named: "Counsel Brief.docx")
    try data.write(to: url, options: .atomic)
    defer { try? FileManager.default.removeItem(at: url) }

    let appKitDocument = try NSAttributedString(
      url: url,
      options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
      documentAttributes: nil
    )
    XCTAssertTrue(appKitDocument.string.contains("Counsel Brief"))

    let imported = try DocumentTransfer.importMarkdown(from: url)

    XCTAssertEqual(imported.suggestedFileName, "Counsel Brief.md")
    XCTAssertTrue(imported.markdown.contains("# Counsel Brief"), imported.markdown)
    XCTAssertTrue(imported.markdown.contains("**confidential**"), imported.markdown)
    XCTAssertTrue(
      imported.markdown.contains("[statute](https://example.com/statute)"),
      imported.markdown
    )
    XCTAssertTrue(imported.markdown.contains("- First duty"), imported.markdown)
    XCTAssertTrue(imported.markdown.contains("- Second duty"), imported.markdown)
  }

  func testDOCXImportReadsStandardDeflatedOfficePackage() throws {
    let source = NSAttributedString(
      string: "Standard Word package",
      attributes: [.font: NSFont.systemFont(ofSize: 12)]
    )
    let data = try source.data(
      from: NSRange(location: 0, length: source.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
    )
    let url = temporaryURL(named: "External.docx")
    try data.write(to: url, options: .atomic)
    defer { try? FileManager.default.removeItem(at: url) }

    let imported = try DocumentTransfer.importMarkdown(from: url)

    XCTAssertEqual(imported.suggestedFileName, "External.md")
    XCTAssertTrue(imported.markdown.contains("Standard Word package"), imported.markdown)
  }

  func testDOCXReaderAcceptsDataSliceWithNonzeroStartIndex() throws {
    let archive = try DocumentTransfer.docxData(
      fromHTML: "<h1>Sliced archive</h1><p>Offsets stay relative.</p>", baseURL: nil)
    var padded = Data(repeating: 0xAA, count: 7)
    padded.append(archive)
    let slice = padded.dropFirst(7)

    XCTAssertEqual(slice.startIndex, 7)
    let markdown = try OfficeOpenXMLDocument.readMarkdown(slice)

    XCTAssertTrue(markdown.contains("# Sliced archive"), markdown)
    XCTAssertTrue(markdown.contains("Offsets stay relative."), markdown)
  }

  func testDOCXReaderRejectsPartWhoseChecksumDoesNotMatch() throws {
    var archive = try DocumentTransfer.docxData(
      fromHTML: "<p>Checksum sentinel</p>", baseURL: nil)
    let sentinel = Data("Checksum sentinel".utf8)
    let range = try XCTUnwrap(archive.range(of: sentinel))
    archive[range.lowerBound] ^= 0x01

    XCTAssertThrowsError(try OfficeOpenXMLDocument.readMarkdown(archive)) { error in
      guard case OfficeOpenXMLDocument.Error.invalidArchive = error else {
        return XCTFail("Expected invalidArchive, got \(error)")
      }
    }
  }

  func testPDFImportExtractsTextIntoMarkdownDraft() throws {
    let url = temporaryURL(named: "Board Resolution.pdf")
    try makeTextPDF("Prokurent approval is required.").write(to: url, options: .atomic)
    defer { try? FileManager.default.removeItem(at: url) }

    let imported = try DocumentTransfer.importMarkdown(from: url)

    XCTAssertEqual(imported.suggestedFileName, "Board Resolution.md")
    XCTAssertTrue(imported.markdown.contains("Prokurent approval is required."))
    XCTAssertTrue(imported.markdown.hasSuffix("\n"))
  }

  func testPDFWithoutTextLayerIsRejectedInsteadOfOpeningBlankDraft() throws {
    let url = temporaryURL(named: "Scan.pdf")
    try makeTextPDF("").write(to: url, options: .atomic)
    defer { try? FileManager.default.removeItem(at: url) }

    XCTAssertThrowsError(try DocumentTransfer.importMarkdown(from: url)) { error in
      XCTAssertEqual(error as? DocumentTransferError, .pdfHasNoTextLayer)
    }
  }

  private func temporaryURL(named name: String) -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(name)
  }

  private func makeTextPDF(_ text: String) throws -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
      throw CocoaError(.fileWriteUnknown)
    }
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
      throw CocoaError(.fileWriteUnknown)
    }

    context.beginPDFPage(nil)
    if !text.isEmpty {
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(
          string: text,
          attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
      )
      context.textPosition = CGPoint(x: 72, y: 720)
      CTLineDraw(line, context)
    }
    context.endPDFPage()
    context.closePDF()
    return data as Data
  }
}
