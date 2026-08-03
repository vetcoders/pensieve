import WebKit
import XCTest

@testable import Pensieve

/// Recovery contract for the terminal preview stage: a dead WebContent process
/// or a failed in-place update must converge back to a full page load of the
/// newest document — and a stale failure must never overwrite a newer page.
final class PreviewWebViewProcessRecoveryTests: XCTestCase {

  private func makeDocument(
    body: String = "<p>hello</p>", styleHTML: String = "", refreshToken: Int = 0
  )
    -> PreviewDocument
  {
    PreviewDocument(
      html: "<html><body><article class=\"markdown-body\">\(body)</article></body></html>",
      baseURL: nil,
      bodyHTML: body,
      styleHTML: styleHTML,
      mermaidJavaScript: nil,
      katexJavaScript: nil,
      katexCSS: nil,
      containsMath: false,
      sourceURL: nil,
      refreshToken: refreshToken)
  }

  @MainActor
  func testProcessTerminationReloadsLastDocument() {
    let view = PreviewWebView(frame: .zero)
    var fullLoads: [PreviewDocument] = []
    view.fullPageLoadObserver = { fullLoads.append($0) }

    let document = makeDocument()
    view.load(document: document)
    XCTAssertEqual(fullLoads.count, 1)

    view.handleWebContentProcessTermination()
    XCTAssertEqual(fullLoads.count, 2)
    XCTAssertEqual(fullLoads.last, document)
  }

  @MainActor
  func testProcessTerminationBeforeAnyLoadIsInert() {
    let view = PreviewWebView(frame: .zero)
    var fullLoadCount = 0
    view.fullPageLoadObserver = { _ in fullLoadCount += 1 }

    view.handleWebContentProcessTermination()
    XCTAssertEqual(fullLoadCount, 0)
  }

  @MainActor
  func testRecoveryRestoresInPlaceUpdatePathForSameIdentity() {
    let view = PreviewWebView(frame: .zero)
    var fullLoadCount = 0
    view.fullPageLoadObserver = { _ in fullLoadCount += 1 }

    let document = makeDocument()
    view.load(document: document)
    view.load(document: document)
    XCTAssertEqual(fullLoadCount, 1, "same identity should stay on the in-place update path")

    view.handleWebContentProcessTermination()
    XCTAssertEqual(fullLoadCount, 2)

    view.load(document: document)
    XCTAssertEqual(fullLoadCount, 2, "recovery must restore the in-place update path")
  }

  @MainActor
  func testStaleUpdateFailureCannotOverwriteNewerPage() {
    let view = PreviewWebView(frame: .zero)
    var fullLoads: [PreviewDocument] = []
    view.fullPageLoadObserver = { fullLoads.append($0) }

    let older = makeDocument(body: "<p>a</p>", refreshToken: 1)
    let newer = makeDocument(body: "<p>b</p>", refreshToken: 2)
    view.load(document: older)
    view.load(document: newer)
    XCTAssertEqual(fullLoads.count, 2)

    view.handleUpdateScriptResult(false, error: nil, for: older)
    XCTAssertEqual(fullLoads.count, 2, "a stale failed update must not reload an older document")

    view.handleUpdateScriptResult(false, error: nil, for: newer)
    XCTAssertEqual(fullLoads.count, 3, "an on-screen failed update must fall back to a full load")
    XCTAssertEqual(fullLoads.last, newer)
  }

  /// The composed stylesheet carries the skin's inlined `@font-face` payload —
  /// hundreds of kilobytes of base64 for a bundled-font theme. A same-identity
  /// edit whose stylesheet is byte-identical must not re-escape and re-marshal
  /// that blob across the JS bridge; a genuinely new stylesheet (skin switch)
  /// still must.
  @MainActor
  func testUnchangedStylesheetIsNotReshippedOnEveryInPlaceUpdate() {
    let view = PreviewWebView(frame: .zero)
    var scripts: [String] = []
    view.inPlaceUpdateObserver = { scripts.append($0) }

    // Full page load: the HTML embeds the stylesheet, so the page has it already.
    view.load(document: makeDocument(body: "<p>v1</p>", styleHTML: "article { color: red; }"))
    XCTAssertTrue(scripts.isEmpty, "the first load is a full page load, not an in-place update")

    view.load(document: makeDocument(body: "<p>v2</p>", styleHTML: "article { color: red; }"))
    XCTAssertEqual(scripts.count, 1)
    XCTAssertTrue(scripts[0].contains("v2"), "the body still updates")
    XCTAssertFalse(
      scripts[0].contains("vc-preview-style"),
      "an unchanged stylesheet must not cross the bridge again")
    XCTAssertFalse(scripts[0].contains("color: red"), scripts[0])

    view.load(document: makeDocument(body: "<p>v3</p>", styleHTML: "article { color: blue; }"))
    XCTAssertEqual(scripts.count, 2)
    XCTAssertTrue(
      scripts[1].contains("vc-preview-style"),
      "a changed stylesheet (skin switch) must still be shipped")
    XCTAssertTrue(scripts[1].contains("color: blue"), scripts[1])
  }

  /// A full page load re-embeds the stylesheet inline, so the bookkeeping must
  /// follow it — otherwise the recovered page and this side disagree and the next
  /// edit re-ships a stylesheet the page already has (or, worse, the reverse).
  @MainActor
  func testStylesheetBookkeepingFollowsAFullReload() {
    let view = PreviewWebView(frame: .zero)
    var scripts: [String] = []
    view.inPlaceUpdateObserver = { scripts.append($0) }

    let style = "article { color: red; }"
    view.load(document: makeDocument(body: "<p>v1</p>", styleHTML: style))
    view.handleWebContentProcessTermination()

    view.load(document: makeDocument(body: "<p>v2</p>", styleHTML: style))
    XCTAssertEqual(scripts.count, 1)
    XCTAssertFalse(
      scripts[0].contains("vc-preview-style"),
      "the reloaded page already carries this stylesheet inline")
  }

  @MainActor
  func testUpdateFailureReloadsNewestSameIdentityContent() {
    let view = PreviewWebView(frame: .zero)
    var fullLoads: [PreviewDocument] = []
    view.fullPageLoadObserver = { fullLoads.append($0) }

    let firstEdit = makeDocument(body: "<p>v1</p>")
    let secondEdit = makeDocument(body: "<p>v2</p>")
    view.load(document: firstEdit)
    view.load(document: secondEdit)
    XCTAssertEqual(fullLoads.count, 1, "same-identity edits ride the in-place update path")

    view.handleUpdateScriptResult(false, error: nil, for: firstEdit)
    XCTAssertEqual(fullLoads.count, 2)
    XCTAssertEqual(
      fullLoads.last, secondEdit,
      "fallback must reload the newest content, not the failed snapshot")
  }
}
