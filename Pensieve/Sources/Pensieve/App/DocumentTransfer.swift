import AppKit
import PDFKit

struct ImportedMarkdownDocument: Equatable, Sendable {
  let suggestedFileName: String
  let markdown: String
}

enum DocumentTransferError: Error, Equatable, LocalizedError {
  case unsupportedFileType(String)
  case unreadableWordDocument
  case unreadablePDF
  case pdfHasNoTextLayer

  var errorDescription: String? {
    switch self {
    case .unsupportedFileType(let fileExtension):
      return
        "Pensieve cannot import .\(fileExtension) files. Choose a Word (.docx) or PDF document."
    case .unreadableWordDocument:
      return "The Word document could not be read or did not contain importable text."
    case .unreadablePDF:
      return "The PDF document could not be read."
    case .pdfHasNoTextLayer:
      return
        "This PDF has no extractable text layer. OCR is required before Pensieve can import it."
    }
  }
}

enum DocumentTransfer {
  static let importableExtensions: Set<String> = ["docx", "pdf"]

  static func isImportable(_ url: URL) -> Bool {
    importableExtensions.contains(url.pathExtension.lowercased())
  }

  static func docxData(fromHTML html: String, baseURL: URL?) throws -> Data {
    guard let htmlData = html.data(using: .utf8) else {
      throw DocumentTransferError.unreadableWordDocument
    }

    var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
      .documentType: NSAttributedString.DocumentType.html,
      .characterEncoding: String.Encoding.utf8.rawValue,
    ]
    if let baseURL {
      options[.baseURL] = baseURL
    }

    let attributed = try NSAttributedString(
      data: htmlData,
      options: options,
      documentAttributes: nil
    )
    return try OfficeOpenXMLDocument.write(attributed)
  }

  static func importMarkdown(from url: URL) throws -> ImportedMarkdownDocument {
    let fileExtension = url.pathExtension.lowercased()
    let markdown: String

    switch fileExtension {
    case "docx":
      markdown = try importDOCX(from: url)
    case "pdf":
      markdown = try importPDF(from: url)
    default:
      throw DocumentTransferError.unsupportedFileType(fileExtension)
    }

    let baseName = url.deletingPathExtension().lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let safeName = baseName.isEmpty ? "Imported" : baseName
    return ImportedMarkdownDocument(
      suggestedFileName: "\(safeName).md",
      markdown: markdown
    )
  }

  private static func importDOCX(from url: URL) throws -> String {
    do {
      let markdown = try OfficeOpenXMLDocument.readMarkdown(Data(contentsOf: url))
      guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw DocumentTransferError.unreadableWordDocument
      }
      return markdown
    } catch {
      throw DocumentTransferError.unreadableWordDocument
    }
  }

  private static func importPDF(from url: URL) throws -> String {
    guard let document = PDFDocument(url: url) else {
      throw DocumentTransferError.unreadablePDF
    }

    let text = (0..<document.pageCount)
      .compactMap { document.page(at: $0)?.string }
      .joined(separator: "\n\n")
    let markdown = normalizedPDFText(text)
    guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DocumentTransferError.pdfHasNoTextLayer
    }
    return markdown
  }

  private static func normalizedPDFText(_ text: String) -> String {
    let normalized =
      text
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .replacingOccurrences(of: "\u{0}", with: "")
    let sourceLines = normalized.components(separatedBy: "\n")
    var lines: [String] = []

    for sourceLine in sourceLines {
      let line = sourceLine.trimmingCharacters(in: .whitespaces)
      if line.isEmpty {
        if lines.last?.isEmpty == false { lines.append("") }
      } else {
        lines.append(line)
      }
    }

    while lines.first?.isEmpty == true { lines.removeFirst() }
    while lines.last?.isEmpty == true { lines.removeLast() }
    return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
  }
}
