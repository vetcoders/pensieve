import XCTest

@testable import Pensieve

final class PreviewResourceLocatorTests: XCTestCase {
  func testLoadsCSSFromPackagedAppResourceBundleLayout() throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveResourceLocatorTests-\(UUID().uuidString)")
    let bundleURL =
      tempRoot
      .appendingPathComponent("Contents")
      .appendingPathComponent("Resources")
      .appendingPathComponent(PreviewResourceLocator.resourceBundleName)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    try ".markdown-body { color: rebeccapurple; }"
      .write(
        to: bundleURL.appendingPathComponent("markdown.css"), atomically: true, encoding: .utf8)
    try "window.mermaid = {};"
      .write(
        to: bundleURL.appendingPathComponent("mermaid.min.js"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempRoot) }

    let css = PreviewResourceLocator.css(named: "markdown", candidateDirectories: [bundleURL])
    let javascript = PreviewResourceLocator.javascript(
      named: "mermaid.min", candidateDirectories: [bundleURL])

    XCTAssertEqual(css, ".markdown-body { color: rebeccapurple; }")
    XCTAssertEqual(javascript, "window.mermaid = {};")
  }

  func testProductionThemesLoadWithoutBundleModuleAccessor() {
    let markdown = ThemeManager().css(for: .markdown)
    let gfm = ThemeManager().css(for: .gfm)

    XCTAssertTrue(markdown.contains("normalize.css"))
    XCTAssertTrue(gfm.contains("font-family"))
  }
}
