import WebKit
import XCTest

@testable import Pensieve

/// Recovery contract for the terminal preview stage: a dead WebContent process
/// or a failed in-place update must converge back to a full page load of the
/// newest document — and a stale failure must never overwrite a newer page.
final class PreviewWebViewProcessRecoveryTests: XCTestCase {

  @MainActor
  func testRepeatedProcessDeathsPauseUntilExplicitResumeWithNewestContent() {
    let view = PreviewWebView(frame: .zero, createsWebContent: false)
    var loads: [PreviewDocument] = []
    view.fullPageLoadObserver = { loads.append($0) }
    view.load(document: makeDocument())
    for _ in 0..<20 { view.handleWebContentProcessTermination() }
    XCTAssertEqual(loads.count, 3, "initial load and two automatic retries only")
    XCTAssertTrue(view.isRecoveryPaused)

    let newest = makeDocument(body: "<p>edited while paused</p>")
    view.load(document: newest)
    XCTAssertEqual(loads.count, 3, "typing must not restart a crashing renderer")
    view.resumePreview()
    XCTAssertFalse(view.isRecoveryPaused)
    XCTAssertEqual(loads.count, 4)
    XCTAssertEqual(loads.last, newest)
  }

  @MainActor
  func testManualRefreshResetsTheRecoveryBudget() {
    let view = PreviewWebView(frame: .zero, createsWebContent: false)
    var loads = 0
    view.fullPageLoadObserver = { _ in loads += 1 }
    view.load(document: makeDocument())
    for _ in 0..<3 { view.handleWebContentProcessTermination() }
    XCTAssertTrue(view.isRecoveryPaused)
    view.load(document: makeDocument(refreshToken: 1))
    XCTAssertFalse(view.isRecoveryPaused)
    view.handleWebContentProcessTermination()
    XCTAssertEqual(loads, 5)
  }

  @MainActor
  func testUpdatesCoalesceToOneInFlightAndNewestSuccessor() {
    let view = PreviewWebView(frame: .zero, createsWebContent: false)
    var scripts: [String] = []
    var completions: [(Any?, Error?) -> Void] = []
    view.updateScriptEvaluator = { script, completion in
      scripts.append(script)
      completions.append(completion)
    }
    view.load(document: makeDocument())
    view.load(document: makeDocument(body: "<p>first</p>"))
    for value in 0..<100 {
      view.load(document: makeDocument(body: "<p>queued-\(value)</p>"))
    }
    XCTAssertEqual(scripts.count, 1)
    completions[0](true, nil)
    XCTAssertEqual(scripts.count, 2)
    XCTAssertTrue(scripts[1].contains("queued-99"))
    completions[1](true, nil)
    XCTAssertEqual(scripts.count, 2)
  }

  @MainActor
  func testOldCompletionCannotReloadOrUnlatchANewerGeneration() {
    let view = PreviewWebView(frame: .zero, createsWebContent: false)
    var loads = 0
    var completions: [(Any?, Error?) -> Void] = []
    view.fullPageLoadObserver = { _ in loads += 1 }
    view.updateScriptEvaluator = { _, completion in completions.append(completion) }
    view.load(document: makeDocument())
    view.load(document: makeDocument(body: "<p>old update</p>"))
    view.handleWebContentProcessTermination()
    view.load(document: makeDocument(body: "<p>new update</p>"))
    XCTAssertEqual(completions.count, 2)

    completions[0](false, nil)
    XCTAssertEqual(loads, 2, "same-identity stale failures cannot start a reload storm")
    view.load(document: makeDocument(body: "<p>newest</p>"))
    XCTAssertEqual(completions.count, 2, "stale completion cannot clear the new in-flight latch")
    completions[1](true, nil)
    XCTAssertEqual(completions.count, 3)
  }

  @MainActor
  func testProcessDeathsAndScriptFailuresShareOneBudget() {
    let view = PreviewWebView(frame: .zero, createsWebContent: false)
    var loads = 0
    view.fullPageLoadObserver = { _ in loads += 1 }
    let document = makeDocument()
    view.load(document: document)
    view.handleWebContentProcessTermination()
    view.handleUpdateScriptResult(false, error: nil, for: document)
    view.handleWebContentProcessTermination()
    XCTAssertEqual(loads, 3)
    XCTAssertTrue(view.isRecoveryPaused)
  }

  @MainActor
  func testDismantleInvalidatesLateCallbacksAndFurtherLoads() {
    let view = PreviewWebView(frame: .zero, createsWebContent: false)
    let coordinator = PreviewRepresentable.Coordinator(themeManager: ThemeManager())
    coordinator.attach(view: view)
    var loads = 0
    var completions: [(Any?, Error?) -> Void] = []
    view.fullPageLoadObserver = { _ in loads += 1 }
    view.updateScriptEvaluator = { _, completion in completions.append(completion) }
    view.load(document: makeDocument())
    view.load(document: makeDocument(body: "<p>pending</p>"))
    PreviewRepresentable.dismantleNSView(view, coordinator: coordinator)
    view.invalidate()
    completions[0](false, nil)
    view.handleWebContentProcessTermination()
    view.resumePreview()
    view.load(document: makeDocument(refreshToken: 1))
    XCTAssertEqual(loads, 1)
    XCTAssertEqual(completions.count, 1)
  }

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
    let view = PreviewWebView(frame: .zero, createsWebContent: false)
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
    let view = PreviewWebView(frame: .zero, createsWebContent: false)
    var fullLoadCount = 0
    view.fullPageLoadObserver = { _ in fullLoadCount += 1 }

    view.handleWebContentProcessTermination()
    XCTAssertEqual(fullLoadCount, 0)
  }

  @MainActor
  func testRecoveryRestoresInPlaceUpdatePathForSameIdentity() {
    let view = PreviewWebView(frame: .zero, createsWebContent: false)
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
    let view = PreviewWebView(frame: .zero, createsWebContent: false)
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
    let view = PreviewWebView(frame: .zero, createsWebContent: false)
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

    view.handleUpdateScriptResult(
      true, error: nil, for: makeDocument(body: "<p>v2</p>", styleHTML: "article { color: red; }"))
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
    let view = PreviewWebView(frame: .zero, createsWebContent: false)
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
    let view = PreviewWebView(frame: .zero, createsWebContent: false)
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

  @MainActor
  func testUnselectedTabDefersLoadsAndBackgroundTerminationUntilSelected() {
    let view = PreviewWebView(frame: .zero, createsWebContent: false)
    var fullLoads: [PreviewDocument] = []
    view.fullPageLoadObserver = { fullLoads.append($0) }

    view.unselectedTabWindowOverride = true
    view.syncWebViewVisibility()

    let initial = makeDocument(body: "<p>tab-1</p>")
    let updated = makeDocument(body: "<p>tab-2</p>")
    view.load(document: initial)
    view.load(document: updated)
    XCTAssertTrue(
      fullLoads.isEmpty,
      "unselected background tabs must defer WebKit HTML loads until selected")

    // Process terminations while unselected must not reload in the background
    // or consume the automatic recovery budget.
    for _ in 0..<5 {
      view.handleWebContentProcessTermination()
    }
    XCTAssertFalse(view.isRecoveryPaused)
    XCTAssertTrue(fullLoads.isEmpty)

    // Selecting the tab flushes the newest deferred document exactly once.
    view.unselectedTabWindowOverride = false
    view.syncWebViewVisibility()
    XCTAssertEqual(fullLoads, [updated])
  }

  @MainActor
  func testUnselectedTabDetachesAndReattachesLiveWebView() {
    let view = PreviewWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let webView = view.subviews.compactMap { $0 as? WKWebView }.first
    XCTAssertNotNil(webView)
    XCTAssertTrue(webView?.superview === view)

    view.unselectedTabWindowOverride = true
    view.syncWebViewVisibility()
    XCTAssertNil(
      webView?.superview,
      "unselected tab must detach WKWebView from superview so Auto Layout setFrame and display links stop"
    )
    XCTAssertEqual(webView?.isHidden, true)

    view.unselectedTabWindowOverride = false
    view.syncWebViewVisibility()
    XCTAssertTrue(webView?.superview === view)
    XCTAssertEqual(webView?.isHidden, false)
  }

  @MainActor
  func testInFlightUpdateCompletingAfterTabBecomesUnselectedDoesNotEvaluateSuccessorUntilSelected()
  {
    let view = PreviewWebView(frame: .zero, createsWebContent: false)
    var evaluatedScripts: [String] = []
    var pendingCompletion: ((Any?, Error?) -> Void)?
    view.updateScriptEvaluator = { script, completion in
      evaluatedScripts.append(script)
      pendingCompletion = completion
    }

    let doc1 = makeDocument(body: "<p>v1</p>")
    let doc2 = makeDocument(body: "<p>v2</p>")
    let doc3 = makeDocument(body: "<p>v3</p>")
    view.load(document: doc1)
    view.load(document: doc2)
    XCTAssertEqual(evaluatedScripts.count, 1)

    // Tab becomes unselected while the in-place update for doc2 is still in flight,
    // and a newer edit (doc3) arrives while unselected.
    view.unselectedTabWindowOverride = true
    view.syncWebViewVisibility()
    view.load(document: doc3)

    // Late completion of doc2's in-place update must NOT evaluate doc3 while unselected.
    pendingCompletion?(true, nil)
    XCTAssertEqual(
      evaluatedScripts.count, 1,
      "completing an in-flight update after a tab becomes unselected must not evaluate JS in the background"
    )

    // Also pin direct handleUpdateScriptResult when unselected without generation.
    view.handleUpdateScriptResult(true, error: nil, for: doc2)
    XCTAssertEqual(evaluatedScripts.count, 1)

    // Re-selecting the tab flushes the deferred update for doc3.
    view.unselectedTabWindowOverride = false
    view.syncWebViewVisibility()
    XCTAssertEqual(evaluatedScripts.count, 2)
    XCTAssertTrue(evaluatedScripts[1].contains("v3"))
  }
}
