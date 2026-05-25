import XCTest
@testable import Pensieve

final class PreviewResourceLocatorTests: XCTestCase {
    func testLoadsCSSFromPackagedAppResourceBundleLayout() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PensieveResourceLocatorTests-\(UUID().uuidString)")
        let bundleURL = tempRoot
            .appendingPathComponent("Contents")
            .appendingPathComponent("Resources")
            .appendingPathComponent(PreviewResourceLocator.resourceBundleName)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try ".markdown-body { color: rebeccapurple; }"
            .write(to: bundleURL.appendingPathComponent("markdown.css"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let css = PreviewResourceLocator.css(named: "markdown", candidateDirectories: [bundleURL])

        XCTAssertEqual(css, ".markdown-body { color: rebeccapurple; }")
    }

    func testProductionThemesLoadWithoutBundleModuleAccessor() {
        let markdown = ThemeManager().css(for: .markdown)
        let gfm = ThemeManager().css(for: .gfm)

        XCTAssertTrue(markdown.contains("normalize.css"))
        XCTAssertTrue(gfm.contains("font-family"))
    }
}
