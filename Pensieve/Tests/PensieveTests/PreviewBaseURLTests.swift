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

    func testNilDocumentFallsBackToModuleBundle() {
        let base = PreviewRepresentable.resolveBaseURL(for: nil)
        XCTAssertEqual(base, Bundle.module.resourceURL)
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
}
