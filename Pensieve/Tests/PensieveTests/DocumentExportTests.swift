import XCTest

@testable import Pensieve

final class DocumentExportTests: XCTestCase {
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

  /// THE PIN. `renderDocument` built its request without `skin:`, and the
  /// parameter carries a default — so every export composed the `.default`
  /// surface no matter what the operator was reading. That one omission is the
  /// whole of "Typewriter/Ink/Parchment never reach ANY export path": the HTML
  /// carries the wrong skin block, and `PreviewDocument.skin` comes back
  /// `.default`, whose `exportAppearanceName` is nil — so `PDFExportJob` pins
  /// no appearance and the PDF follows whichever Mac ran the export.
  @MainActor
  func testExportComposesTheSkinTheOperatorIsReading() throws {
    let session = DocumentSession(
      document: DocumentRef(id: URL(fileURLWithPath: "/tmp/pensieve-export/Skinned.md")),
      text: "# Skinned",
      isDirty: false
    )
    let themeManager = ThemeManager(
      defaults: makeEphemeralDefaults(prefix: "DocumentExportSkin"))
    themeManager.skin = .typewriter

    let document = DocumentExport.renderDocument(
      session: session,
      theme: .markdown,
      fontSize: 16,
      themeManager: themeManager
    )

    XCTAssertEqual(
      document?.skin, .typewriter,
      "the export was composed for the default surface while the operator was reading"
        + " Typewriter — the skin never reached the exported bytes")
    // The consequence the reader can hold in her hand: Typewriter is a PAIRED
    // skin, whose page is white on both sides, so the export must be pinned to
    // Aqua rather than inheriting the exporting Mac's dark setting.
    XCTAssertEqual(
      WindowChromeRecipe.exportAppearance(for: try XCTUnwrap(document?.skin))?.name, .aqua,
      "a paired skin must pin the export appearance; nil here means the PDF follows the"
        + " machine it was exported from")
  }

  /// THE CONTROL LEG. The unpinned surface must STAY unpinned: `.default` is
  /// deliberately appearance-following, and a fix that pinned every export would
  /// break the established look instead of extending it.
  @MainActor
  func testTheDefaultSurfaceStillFollowsTheExportingMac() throws {
    let session = DocumentSession(
      document: DocumentRef(id: URL(fileURLWithPath: "/tmp/pensieve-export/Plain.md")),
      text: "# Plain",
      isDirty: false
    )
    let themeManager = ThemeManager(
      defaults: makeEphemeralDefaults(prefix: "DocumentExportSkinControl"))
    themeManager.skin = .default

    let document = DocumentExport.renderDocument(
      session: session,
      theme: .markdown,
      fontSize: 16,
      themeManager: themeManager
    )

    XCTAssertEqual(document?.skin, .default)
    XCTAssertNil(
      WindowChromeRecipe.exportAppearance(for: try XCTUnwrap(document?.skin)),
      "the default surface must keep following the system appearance")
  }
}
