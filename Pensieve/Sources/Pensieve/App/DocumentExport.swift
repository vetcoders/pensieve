import AppKit
import UniformTypeIdentifiers
import WebKit

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

    // `skin` carries a default so the pre-skin constructors kept compiling —
    // which silently made EVERY export a `.default` one. Two things followed
    // from that single omitted argument: the exported HTML carried the default
    // skin's CSS block (so Typewriter, Ink and Parchment reached no export path
    // at all — not PDF, not HTML, not DOCX), and `PreviewDocument.skin` came
    // back `.default`, whose `exportAppearanceName` is nil, so `PDFExportJob`
    // pinned nothing and the PDF followed the EXPORTING MAC's light/dark
    // setting. The skin the operator is reading is the skin she exports.
    let request = PreviewRenderRequest(
      markdown: session.text,
      fontSize: fontSize,
      theme: theme,
      skin: themeManager.skin,
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

  private static func writePDF(
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
private final class PDFExportJob: NSObject, WKNavigationDelegate {
  private let document: PreviewDocument
  private let outputURL: URL
  private let webView: WKWebView
  private var completion: ((Result<Void, Error>) -> Void)?
  private var didFinish = false

  init(document: PreviewDocument, outputURL: URL) {
    self.document = document
    self.outputURL = outputURL
    self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123))
    super.init()
    // An export is a sheet of paper, not a window. Left unpinned this offscreen
    // WebView follows the exporting MACHINE's setting, so the same document
    // printed from a dark Mac and a light one came out differently — and a
    // paired skin, whose page is white on both sides, would export a dark PDF
    // purely because of where it was exported from.
    webView.appearance = WindowChromeRecipe.exportAppearance(for: document.skin)
    webView.navigationDelegate = self
  }

  func start(completion: @escaping (Result<Void, Error>) -> Void) {
    self.completion = completion
    webView.loadHTMLString(document.html, baseURL: document.baseURL)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !didFinish else { return }
    didFinish = true

    // Leave WKPDFConfiguration.rect nil so createPDF captures the full
    // content bounds; assigning webView.bounds cropped long documents
    // to the first viewport.
    let configuration = WKPDFConfiguration()
    webView.createPDF(configuration: configuration) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let data):
        do {
          try data.write(to: outputURL, options: .atomic)
          finish(.success(()))
        } catch {
          finish(.failure(error))
        }
      case .failure(let error):
        finish(.failure(error))
      }
    }
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
