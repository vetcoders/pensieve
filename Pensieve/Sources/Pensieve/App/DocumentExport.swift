import AppKit
import PDFKit
import UniformTypeIdentifiers
import WebKit

/// The light/dark half of the preview surface an export must reproduce.
enum PreviewColorVariant: Equatable {
  case light
  case dark

  private static let darkQuery = "@media (prefers-color-scheme: dark) {"
  private static let lightQuery = "@media (prefers-color-scheme: light) {"
  /// Always-true / never-true media conditions. Rewriting the query keeps the
  /// block — and therefore the cascade order inside the sheet — intact.
  private static let alwaysQuery = "@media all {"
  private static let neverQuery = "@media not all {"

  /// Re-emit `css` with every `prefers-color-scheme` query resolved to `variant`
  /// so a renderer that ignores the media feature (WebKit while printing) still
  /// lands on the right half of the theme.
  static func pinning(_ css: String, to variant: PreviewColorVariant) -> String {
    css
      .replacingOccurrences(
        of: darkQuery, with: variant == .dark ? alwaysQuery : neverQuery
      )
      .replacingOccurrences(
        of: lightQuery, with: variant == .light ? alwaysQuery : neverQuery)
  }
}

enum DocumentExportError: Error, LocalizedError {
  case pdfPaginationFailed
  case pdfSheetPaintingFailed

  var errorDescription: String? {
    switch self {
    case .pdfPaginationFailed:
      return "The PDF could not be paginated for export."
    case .pdfSheetPaintingFailed:
      return "The exported PDF could not be given the reading surface's background."
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

    // The skin is the reading surface the preview pane is actually showing.
    // Leaving it at the `.default` fallback silently exported a different
    // surface than the one on screen — including its light/dark variant, which
    // is how a light preview turned into a dark PDF.
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

  /// Appearance the export renders under. Export is WYSIWYG relative to the
  /// preview pane, so it must resolve the appearance exactly the way the pane
  /// does (`PreviewWebView.applyThemeChrome`): a single-mode skin pins its own
  /// appearance regardless of the system setting — Parchment reads light on a
  /// dark Mac, Ink reads dark on a light one — and only the adaptive skins
  /// (`default`/`raw`) follow the app's effective appearance. Taking
  /// `NSApp.effectiveAppearance` unconditionally would print the half of the
  /// theme the reader is *not* looking at whenever the two disagree.
  static func exportAppearance(for skin: PensieveTheme = .default) -> NSAppearance {
    WindowChromeRecipe.readingSurfaceAppearance(for: skin)
      ?? NSApplication.shared.effectiveAppearance
  }

  nonisolated static func colorVariant(for appearance: NSAppearance) -> PreviewColorVariant {
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
  }

  /// The colour the preview pane shows behind a theme whose page background is
  /// transparent — i.e. `NSColor.textBackgroundColor` resolved under the pinned
  /// appearance.
  static func pageBaseSurface(for appearance: NSAppearance) -> NSColor {
    var color = NSColor.white
    appearance.performAsCurrentDrawingAppearance {
      color = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .white
    }
    return color
  }

  /// `pageBaseSurface` as a CSS hex literal.
  static func pageBaseColor(for appearance: NSAppearance) -> String {
    let color = pageBaseSurface(for: appearance)
    return String(
      format: "#%02x%02x%02x",
      Int((color.redComponent * 255).rounded()),
      Int((color.greenComponent * 255).rounded()),
      Int((color.blueComponent * 255).rounded())
    )
  }

  /// Reads back the surface the export actually renders on: the skin's page
  /// background where the skin defines one, the page base otherwise. Asking the
  /// rendered document beats re-deriving the cascade in Swift — the CSS custom
  /// property is the only place that colour is defined.
  static let sheetColorProbeScript = "getComputedStyle(document.documentElement).backgroundColor"

  /// Parse a colour the way `getComputedStyle` reports one — legacy
  /// `rgb()`/`rgba()` notation. A fully transparent surface yields no colour, so
  /// the caller can fall back to the page base.
  nonisolated static func sheetColor(fromCSS css: String) -> NSColor? {
    let scalars =
      css
      .replacingOccurrences(of: "rgba", with: "")
      .replacingOccurrences(of: "rgb", with: "")
      .trimmingCharacters(in: CharacterSet(charactersIn: "() "))
      .components(separatedBy: CharacterSet(charactersIn: ",/"))
      .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard scalars.count >= 3 else { return nil }
    let alpha = scalars.count > 3 ? scalars[3] : 1
    guard alpha > 0 else { return nil }
    return NSColor(
      srgbRed: scalars[0] / 255,
      green: scalars[1] / 255,
      blue: scalars[2] / 255,
      alpha: alpha
    )
  }

  /// Lay `color` under every page of the PDF at `url`.
  ///
  /// WebKit paints the export surface inside the printable rectangle only — the
  /// sheet margins are bare paper by construction, and the tail of the last page
  /// stops where the content does — so a dark reading surface printed as a dark
  /// block floating on white. The paginated content is redrawn on top of a
  /// full-bleed fill instead, which keeps the text vector (selectable,
  /// searchable) and carries the link annotations across.
  nonisolated static func paintSheetBackground(_ color: NSColor, inPDFAt url: URL) throws {
    guard
      let source = PDFDocument(url: url),
      source.pageCount > 0,
      var mediaBox = source.page(at: 0)?.bounds(for: .mediaBox),
      let fill = color.usingColorSpace(.sRGB)?.cgColor
    else { throw DocumentExportError.pdfSheetPaintingFailed }

    let data = NSMutableData()
    guard
      let consumer = CGDataConsumer(data: data as CFMutableData),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else { throw DocumentExportError.pdfSheetPaintingFailed }

    for index in 0..<source.pageCount {
      guard let page = source.page(at: index), let pageRef = page.pageRef else { continue }
      var box = page.bounds(for: .mediaBox)
      context.beginPage(mediaBox: &box)
      context.setFillColor(fill)
      context.fill(box)
      context.drawPDFPage(pageRef)
      context.endPage()
    }
    context.closePDF()

    guard
      let painted = PDFDocument(data: data as Data),
      painted.pageCount == source.pageCount
    else { throw DocumentExportError.pdfSheetPaintingFailed }

    painted.documentAttributes = source.documentAttributes
    for index in 0..<source.pageCount {
      guard let original = source.page(at: index), let page = painted.page(at: index) else {
        continue
      }
      for annotation in original.annotations {
        original.removeAnnotation(annotation)
        page.addAnnotation(annotation)
      }
    }

    guard let output = painted.dataRepresentation() else {
      throw DocumentExportError.pdfSheetPaintingFailed
    }
    let scopedAccess = url.startAccessingSecurityScopedResource()
    defer {
      if scopedAccess { url.stopAccessingSecurityScopedResource() }
    }
    try output.write(to: url, options: .atomic)
  }

  /// Export HTML for the PDF pipeline.
  ///
  /// WebKit renders print jobs with `prefers-color-scheme` forced to *light* and
  /// drops backgrounds, no matter what appearance the web view carries — so a
  /// dark reading surface would silently print as a light one. Re-emit the
  /// composed stylesheet with the colour-scheme queries already resolved to the
  /// variant the preview pane is showing, and paint the page background, so the
  /// PDF matches the screen in either direction.
  nonisolated static func pdfExportHTML(
    for document: PreviewDocument,
    variant: PreviewColorVariant,
    pageBase: String
  ) -> String {
    let pinnedStyle = """
      <style id="vc-export-color-scheme">
      \(PreviewColorVariant.pinning(document.styleHTML, to: variant))
      /* The preview paints its surface with a `position: fixed` layer, which a
         paginated renderer would stamp onto the first page only. Drop it and
         paint the same surface on the page box instead: the skin's page
         background where it defines one, the pane's own base otherwise. Both
         boxes carry it so the colour read back off `document.documentElement`
         is the one the sheet is painted with. */
      body::before { display: none !important; }
      html {
        background: var(--vc-preview-page-background, \(pageBase)) !important;
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
      }
      body {
        background: var(--vc-preview-page-background, transparent) !important;
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
        min-height: 0 !important;
      }
      </style>
      """
    guard let head = document.html.range(of: "</head>") else {
      return document.html + pinnedStyle
    }
    return document.html.replacingCharacters(in: head, with: "\(pinnedStyle)</head>")
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
  let variant: PreviewColorVariant
  /// Surface the printed sheet is painted with — the page base until the loaded
  /// document reports the skin's own page background.
  private(set) var sheetColor: NSColor
  private var completion: ((Result<Void, Error>) -> Void)?
  private var didFinish = false

  init(
    document: PreviewDocument,
    outputURL: URL,
    paperSize: NSSize = DocumentExport.defaultPaperSize(),
    appearance: NSAppearance? = nil
  ) {
    // The document carries the skin it was composed for, so the export renders
    // under the same light/dark half the preview pane is showing.
    let resolvedAppearance = appearance ?? DocumentExport.exportAppearance(for: document.skin)
    self.document = document
    self.outputURL = outputURL
    self.paperSize = paperSize
    self.variant = DocumentExport.colorVariant(for: resolvedAppearance)
    self.sheetColor = DocumentExport.pageBaseSurface(for: resolvedAppearance)
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
    webView.appearance = resolvedAppearance
    host.appearance = resolvedAppearance
    host.contentView = webView
    webView.navigationDelegate = self
  }

  func start(completion: @escaping (Result<Void, Error>) -> Void) {
    self.completion = completion
    webView.loadHTMLString(
      DocumentExport.pdfExportHTML(
        for: document,
        variant: variant,
        pageBase: DocumentExport.pageBaseColor(for: webView.appearance ?? .currentDrawing())
      ),
      baseURL: document.baseURL
    )
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard !didFinish else { return }
    didFinish = true

    // Read the surface off the rendered document before printing: the sheet
    // margins are painted from Swift, and they have to carry exactly the colour
    // the skin puts behind the text.
    webView.evaluateJavaScript(DocumentExport.sheetColorProbeScript) { [weak self] value, _ in
      guard let self else { return }
      if let css = value as? String, let color = DocumentExport.sheetColor(fromCSS: css) {
        self.sheetColor = color
      }
      self.printPaginated()
    }
  }

  private func printPaginated() {
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
    guard success else { return finish(.failure(DocumentExportError.pdfPaginationFailed)) }
    do {
      try DocumentExport.paintSheetBackground(sheetColor, inPDFAt: outputURL)
      finish(.success(()))
    } catch {
      finish(.failure(error))
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
