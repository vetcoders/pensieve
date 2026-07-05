import WebKit
import XCTest

@testable import Pensieve

/// Recovery contract for the terminal preview stage: a dead WebContent process
/// or a failed in-place update must converge back to a full page load of the
/// newest document — and a stale failure must never overwrite a newer page.
final class PreviewWebViewProcessRecoveryTests: XCTestCase {

  private func makeDocument(body: String = "<p>hello</p>", refreshToken: Int = 0)
    -> PreviewDocument
  {
    PreviewDocument(
      html: "<html><body><article class=\"markdown-body\">\(body)</article></body></html>",
      baseURL: nil,
      bodyHTML: body,
      styleHTML: "",
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
