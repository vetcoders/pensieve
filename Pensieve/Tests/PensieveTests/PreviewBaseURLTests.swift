import XCTest

@testable import Pensieve

final class PreviewBaseURLTests: XCTestCase {
  func testDocumentFolderBecomesBaseURL() {
    let docURL = URL(fileURLWithPath: "/tmp/pensieve-notes/alpha.md")
    let base = PreviewRepresentable.resolveBaseURL(for: docURL)
    XCTAssertEqual(
      base?.resolvingSymlinksInPath().path,
      URL(fileURLWithPath: "/tmp/pensieve-notes").resolvingSymlinksInPath().path
    )
  }

  func testNilDocumentFallsBackToPreviewResourceLocation() {
    let base = PreviewRepresentable.resolveBaseURL(for: nil)
    XCTAssertNotNil(base)
    XCTAssertTrue(FileManager.default.fileExists(atPath: base?.path ?? ""))
  }

  func testNestedDocumentFolderIsPreserved() {
    let docURL = URL(fileURLWithPath: "/Users/x/Notes/2026/05/entry.md")
    let base = PreviewRepresentable.resolveBaseURL(for: docURL)
    XCTAssertEqual(base?.lastPathComponent, "05")
    XCTAssertEqual(
      base?.path,
      URL(fileURLWithPath: "/Users/x/Notes/2026/05").path
    )
  }

  func testPreviewAppearanceCSSRespondsToSystemScheme() {
    let css = PreviewWebView.appearanceCSS(fontSize: 17)

    XCTAssertTrue(css.contains("color-scheme: light dark"))
    XCTAssertTrue(css.contains("@media (prefers-color-scheme: dark)"))
    XCTAssertTrue(css.contains("--vc-font-size: 17px"))
    XCTAssertTrue(css.contains("background: transparent !important"))
    XCTAssertTrue(css.contains("color: var(--vc-preview-text) !important"))
  }

  func testPreviewAppearanceCSSIsResponsive() {
    let css = PreviewWebView.appearanceCSS(fontSize: 14)

    // Top padding is chrome-recipe pinned; horizontal/bottom padding stays
    // fluid so narrow windows do not bleed content under the side gutters.
    XCTAssertTrue(
      css.contains(
        "padding: calc(var(--vc-preview-titlebar-glass-height) + \(Int(WindowChromeRecipe.previewContentTopInset))px)"
      ))
    XCTAssertTrue(css.contains("clamp(12px, 3vw, 28px)"))
    XCTAssertTrue(css.contains("margin: 0 !important"))

    // Long headings, links, and inline tokens must wrap, not clip.
    XCTAssertTrue(css.contains("overflow-wrap: anywhere"))

    // Tables collapse to scrollable blocks so they do not blow up the
    // whole preview width.
    XCTAssertTrue(css.contains(".markdown-body table"))
    XCTAssertTrue(css.contains("overflow-x: auto"))

    // Code blocks keep their fixed-pitch layout but the container scrolls.
    XCTAssertTrue(css.contains(".markdown-body pre"))
    XCTAssertTrue(css.contains("white-space: pre !important"))

    // Images cap at container width so screenshots never overflow.
    XCTAssertTrue(css.contains(".markdown-body img"))
    XCTAssertTrue(css.contains("max-width: 100%"))
  }

  @MainActor
  func testEditorPreviewSplitThresholdsAreSane() {
    // The narrow-collapse threshold must be large enough to fit two panes
    // at their minimum + dividers, and small enough that the app still
    // honors split mode at the default window width.
    XCTAssertGreaterThanOrEqual(
      EditorPreviewSplit.narrowSplitThreshold,
      EditorPreviewSplit.paneMinWidth * 2
    )
    XCTAssertLessThan(EditorPreviewSplit.narrowSplitThreshold, 900)
    XCTAssertGreaterThanOrEqual(EditorPreviewSplit.paneMinWidth, 240)
  }
}
