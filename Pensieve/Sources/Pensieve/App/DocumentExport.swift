import AppKit
import UniformTypeIdentifiers
import WebKit

enum DocumentExportError: Error, LocalizedError {
  case pdfPaginationFailed

  var errorDescription: String? {
    switch self {
    case .pdfPaginationFailed:
      return "The PDF could not be paginated for export."
    }
  }
}

@MainActor
enum DocumentExport {
  static func exportHTML(
    session: DocumentSession,
    theme: ThemeManager.Theme,
    fontSize: CGFloat,
    themeManager: ThemeManager
  ) {
    guard
      let document = renderDocument(
        session: session,
        theme: theme,
        fontSize: fontSize,
        themeManager: themeManager
      )
    else { return }

    let panel = NSSavePanel()
    panel.allowedContentTypes = [.html]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = defaultExportFileName(for: session, fileExtension: "html")
    panel.prompt = "Export"

    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      try document.html.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      showExportFailure(title: "HTML Export Failed", error: error)
    }
  }

  static func exportPDF(
    session: DocumentSession,
    theme: ThemeManager.Theme,
    fontSize: CGFloat,
    themeManager: ThemeManager
  ) {
    guard
      let document = renderDocument(
        session: session,
        theme: theme,
        fontSize: fontSize,
        themeManager: themeManager
      )
    else { return }

    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = defaultExportFileName(for: session, fileExtension: "pdf")
    panel.prompt = "Export"

    guard panel.runModal() == .OK, let url = panel.url else { return }

    writePDF(document: document, to: url) { result in
      if case .failure(let error) = result {
        showExportFailure(title: "PDF Export Failed", error: error)
      }
    }
  }

  static func exportDOCX(
    session: DocumentSession,
    theme: ThemeManager.Theme,
    fontSize: CGFloat,
    themeManager: ThemeManager
  ) {
    guard
      let document = renderDocument(
        session: session,
        theme: theme,
        fontSize: fontSize,
        themeManager: themeManager
      )
    else { return }

    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = defaultExportFileName(for: session, fileExtension: "docx")
    panel.prompt = "Export"

    guard panel.runModal() == .OK, let outputURL = panel.url else { return }
    let html = document.html
    let baseURL = document.baseURL

    Task.detached(priority: .userInitiated) {
      let scopedAccess = outputURL.startAccessingSecurityScopedResource()
      defer {
        if scopedAccess { outputURL.stopAccessingSecurityScopedResource() }
      }
      do {
        let data = try DocumentTransfer.docxData(fromHTML: html, baseURL: baseURL)
        try data.write(to: outputURL, options: .atomic)
      } catch {
        await MainActor.run {
          showExportFailure(title: "Word Export Failed", error: error)
        }
      }
    }
  }

  static func renderDocument(
    session: DocumentSession,
    theme: ThemeManager.Theme,
    fontSize: CGFloat,
    themeManager: ThemeManager
  ) -> PreviewDocument? {
    guard session.hasEditableBuffer else { return nil }

    let request = PreviewRenderRequest(
      markdown: session.text,
      fontSize: fontSize,
      theme: theme,
      documentURL: session.url
    )
    return PreviewPipeline(themeManager: themeManager).makeDocument(for: request)
  }

  nonisolated static func defaultExportFileName(
    for session: DocumentSession,
    fileExtension: String
  ) -> String {
    let rawBase =
      session.url?.deletingPathExtension().lastPathComponent
      ?? (session.displayTitle as NSString).deletingPathExtension
    let trimmed = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = trimmed.isEmpty ? "Untitled" : trimmed
    let sanitized =
      fallback
      .components(separatedBy: CharacterSet(charactersIn: "/:"))
      .joined(separator: "-")
    return "\(sanitized).\(fileExtension)"
  }

  static func writePDF(
    document: PreviewDocument,
    to outputURL: URL,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    let job = PDFExportJob(document: document, outputURL: outputURL)
    activePDFJobs.append(job)
    job.start { result in
      activePDFJobs.removeAll { $0 === job }
      completion(result)
    }
  }

  private static var activePDFJobs: [PDFExportJob] = []

  /// Paper the print pipeline lays the export out on. Regions on US Letter get
  /// Letter; everyone else — Poland included — gets ISO A4.
  nonisolated static func defaultPaperSize(for locale: Locale = .current) -> NSSize {
    let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "CR", "GT", "DO", "VE"]
    let region = locale.region?.identifier ?? ""
    return letterRegions.contains(region)
      ? NSSize(width: 612, height: 792)  // 8.5×11in in points
      : NSSize(width: 595, height: 842)  // A4 in points
  }

  /// Print settings for a paginated PDF export: no panels, PDF-to-disk
  /// disposition, and 0.75in margins on every edge.
  nonisolated static func printInfo(paperSize: NSSize, savingTo outputURL: URL) -> NSPrintInfo {
    let margin: CGFloat = 54  // 0.75in
    let info = NSPrintInfo(
      dictionary: [
        .jobDisposition: NSPrintInfo.JobDisposition.save,
        .jobSavingURL: outputURL,
      ]
    )
    info.paperSize = paperSize
    info.topMargin = margin
    info.bottomMargin = margin
    info.leftMargin = margin
    info.rightMargin = margin
    info.horizontalPagination = .fit
    info.verticalPagination = .automatic
    info.isHorizontallyCentered = false
    info.isVerticallyCentered = false
    return info
  }

  private static func showExportFailure(title: String, error: Error) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }
}

@MainActor
final class PDFExportJob: NSObject, WKNavigationDelegate {
  private let document: PreviewDocument
  private let outputURL: URL
  private let paperSize: NSSize
  let webView: WKWebView
  /// The print pipeline needs the web view inside a window; keep our own
  /// offscreen one so no sheet can ever surface on the user's document window.
  private let host: NSWindow
  private var completion: ((Result<Void, Error>) -> Void)?
  private var didFinish = false

  init(
    document: PreviewDocument,
    outputURL: URL,
    paperSize: NSSize = DocumentExport.defaultPaperSize()
  ) {
    self.document = document
    self.outputURL = outputURL
    self.paperSize = paperSize
    // Lay the content out at the printable width so the print pipeline scales
    // 1:1 instead of shrinking a 794pt viewport onto the page.
    let frame = NSRect(
      x: 0,
      y: 0,
      width: paperSize.width - 108,
      height: paperSize.height - 108
    )
    self.webView = WKWebView(frame: frame)
    self.host = NSWindow(
      contentRect: frame,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    super.init()
    host.contentView = webView
    webView.navigationDelegate = self
  }

  func start(completion: @escaping (Result<Void, Error>) -> Void) {
    self.completion = completion
    webView.loadHTMLString(document.html, baseURL: document.baseURL)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !didFinish else { return }
    didFinish = true

    // `createPDF` renders the whole document onto ONE page whose height is the
    // full content height — a single endless page, by design. The print
    // pipeline is the only WKWebView path that paginates, so drive that
    // instead, headless (no print or progress panel) and straight to disk.
    let operation = webView.printOperation(
      with: DocumentExport.printInfo(paperSize: paperSize, savingTo: outputURL)
    )
    operation.showsPrintPanel = false
    operation.showsProgressPanel = false
    operation.view?.frame = NSRect(origin: .zero, size: webView.bounds.size)

    // `run()` blocks the main run loop, which is exactly what WKPrintingView
    // needs to service its web content process — the job then never converges
    // and streams pages until the disk fills (measured: 2 GB and climbing on a
    // two-page document). `runModal` keeps the loop alive and terminates.
    operation.runModal(
      for: host,
      delegate: self,
      didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
      contextInfo: nil
    )
  }

  @objc private func printOperationDidRun(
    _ operation: NSPrintOperation,
    success: Bool,
    contextInfo: UnsafeMutableRawPointer?
  ) {
    finish(success ? .success(()) : .failure(DocumentExportError.pdfPaginationFailed))
  }

  func webView(
    _ webView: WKWebView,
    didFail navigation: WKNavigation!,
    withError error: Error
  ) {
    finish(.failure(error))
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    finish(.failure(error))
  }

  private func finish(_ result: Result<Void, Error>) {
    webView.navigationDelegate = nil
    let callback = completion
    completion = nil
    callback?(result)
  }
}
