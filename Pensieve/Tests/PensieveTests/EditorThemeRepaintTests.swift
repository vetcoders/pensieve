import AppKit
import XCTest

@testable import Pensieve

/// PERF PINS — what a live skin switch is allowed to cost the source panel.
///
/// Measured on the running app (instrumented debug build, real NSMenu click,
/// 1.27 MB draft): `ThemeManager.skin` fired at once, `updateNSView` got the new
/// skin 314 ms later, and then `applyTheme` sat on the main thread for 860 ms
/// re-colouring the WHOLE document. The pane's pixels trailed the click by
/// 3.5–4.5 s while the preview — a `WKWebView` rendered out of process —
/// repainted immediately. That asymmetry is the entire "the preview switches but
/// the source panel stays on the old dark skin" report.
///
/// The contract these pins hold: a skin switch on a document too large to
/// re-colour inside a frame repaints the VIEWPORT synchronously and defers the
/// rest, the deferred pass still reaches the whole document, and a burst of
/// switches collapses into one full pass instead of one per click.
final class EditorThemeRepaintTests: XCTestCase {
  /// Comfortably past `synchronousRethemeCharacterBudget` so the deferral is the
  /// path under test, and made of plain paragraphs so `.foregroundColor` at any
  /// offset is the theme's base text colour.
  private func makeLargeDocument() -> String {
    String(repeating: "body text paragraph\n\n", count: 2_000)
  }

  private func makeStorage(text: String, skin: PensieveTheme)
    -> (MarkdownTextStorage, NSTextStorage)
  {
    let content = MarkdownTextStorage()
    let storage = NSTextStorage()
    content.textStorage = storage
    content.tokens = skin.tokens
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
    content.refreshHighlighting()
    return (content, storage)
  }

  private func srgb(_ color: NSColor) -> NSColor {
    color.usingColorSpace(.sRGB) ?? color
  }

  private func textColor(in storage: NSTextStorage, at location: Int) -> NSColor? {
    guard
      let color = storage.attribute(.foregroundColor, at: location, effectiveRange: nil)
        as? NSColor
    else { return nil }
    return srgb(color)
  }

  /// Lets the deferred pass run. The retheme rides a timer, not a bare
  /// `main.async`, precisely so it lands in a LATER run-loop iteration than the
  /// frame it is deferring behind — so the drain has to be a timed one too.
  private func drainDeferredRefresh() {
    let drained = expectation(description: "deferred retheme pass ran")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { drained.fulfill() }
    wait(for: [drained], timeout: 2.0)
  }

  /// THE pin. A skin switch on a large document must repaint the visible range
  /// and nothing more before returning; running the full document synchronously
  /// (the pre-fix `tokens.didSet → refreshHighlighting()`) fails the tail
  /// assertion outright.
  @MainActor
  func testLargeDocumentSkinSwitchRepaintsTheViewportWithoutAFullSynchronousPass() {
    let text = makeLargeDocument()
    let (content, storage) = makeStorage(text: text, skin: .parchment)
    content.visibleRangeProvider = { NSRange(location: 0, length: 400) }
    let passesBefore = content.fullRefreshCount

    content.tokens = PensieveTheme.ink.tokens

    XCTAssertEqual(
      textColor(in: storage, at: 0), srgb(PensieveTheme.ink.tokens.text.nsColor),
      "the range the operator is looking at must carry the new skin on return")
    XCTAssertEqual(
      textColor(in: storage, at: storage.length - 2),
      srgb(PensieveTheme.parchment.tokens.text.nsColor),
      "the far end of the document must NOT have been re-coloured synchronously:"
        + " that pass is the 860 ms the pane's pixels used to wait on")
    XCTAssertEqual(
      content.fullRefreshCount, passesBefore,
      "no full-document pass may run inside the switch")
  }

  /// The other half: deferring must not LOSE the rest of the document. No
  /// known-issue tail — the whole document ends up on the new skin.
  @MainActor
  func testDeferredPassStillRecoloursTheWholeDocument() {
    let text = makeLargeDocument()
    let (content, storage) = makeStorage(text: text, skin: .parchment)
    content.visibleRangeProvider = { NSRange(location: 0, length: 400) }
    let passesBefore = content.fullRefreshCount

    content.tokens = PensieveTheme.ink.tokens
    drainDeferredRefresh()

    let ink = srgb(PensieveTheme.ink.tokens.text.nsColor)
    XCTAssertEqual(textColor(in: storage, at: 0), ink)
    XCTAssertEqual(textColor(in: storage, at: storage.length / 2), ink)
    XCTAssertEqual(textColor(in: storage, at: storage.length - 2), ink)
    XCTAssertEqual(
      content.fullRefreshCount, passesBefore + 1,
      "exactly one deferred full pass must have run")
  }

  /// Clicking through the picker used to queue one full document pass per click,
  /// which is how 860 ms became the 3.5–4.5 s the operator measured. The
  /// scheduled pass is cancellable, so a burst costs one.
  @MainActor
  func testBurstOfSkinSwitchesCoalescesIntoASingleFullPass() {
    let text = makeLargeDocument()
    let (content, storage) = makeStorage(text: text, skin: .parchment)
    content.visibleRangeProvider = { NSRange(location: 0, length: 400) }
    let passesBefore = content.fullRefreshCount

    for skin in [PensieveTheme.ink, .porcelain, .typewriter, .parchment, .ink] {
      content.tokens = skin.tokens
    }
    drainDeferredRefresh()

    XCTAssertEqual(
      content.fullRefreshCount, passesBefore + 1,
      "five switches must leave ONE full pass behind, not five")
    XCTAssertEqual(
      textColor(in: storage, at: storage.length - 2),
      srgb(PensieveTheme.ink.tokens.text.nsColor),
      "and the surviving pass must be the LAST skin's")
  }

  /// A code block straddling the viewport is re-coloured as code, not as prose,
  /// by the scoped pass — otherwise the visible fence would sit on the wrong
  /// palette for the whole length of the deferral.
  @MainActor
  func testViewportPassKeepsFencedCodeOnTheCodePalette() {
    let filler = String(repeating: "body text paragraph\n\n", count: 2_000)
    let text = "```swift\nfunc greet() {}\n```\n\n" + filler
    let (content, storage) = makeStorage(text: text, skin: .parchment)
    content.visibleRangeProvider = { NSRange(location: 0, length: 400) }

    let keywordAt = (storage.string as NSString).range(of: "func").location
    XCTAssertEqual(
      textColor(in: storage, at: keywordAt),
      srgb(PensieveTheme.parchment.tokens.accent.nsColor))

    content.tokens = PensieveTheme.ink.tokens

    XCTAssertEqual(
      textColor(in: storage, at: keywordAt),
      srgb(PensieveTheme.ink.tokens.accent.nsColor),
      "visible fenced code must move with the skin in the synchronous pass")
  }

  /// Below the one-frame budget there is nothing to win by deferring, so the
  /// switch stays the single synchronous pass it always was — the behaviour the
  /// existing `EditorThemeChromeTests` retint pins read back immediately.
  @MainActor
  func testSmallDocumentSkinSwitchStaysSynchronous() {
    let (content, storage) = makeStorage(
      text: "intro paragraph\n\nbody text\n", skin: .parchment)
    content.visibleRangeProvider = { NSRange(location: 0, length: 10) }
    let passesBefore = content.fullRefreshCount

    content.tokens = PensieveTheme.ink.tokens

    XCTAssertEqual(
      textColor(in: storage, at: storage.length - 2),
      srgb(PensieveTheme.ink.tokens.text.nsColor))
    XCTAssertEqual(content.fullRefreshCount, passesBefore + 1)
  }

  /// Launch ordering: the surface is themed before it is hosted, so there is no
  /// viewport to repaint first. A large document must then fall back to the full
  /// synchronous pass rather than repaint nothing at all.
  @MainActor
  func testRethemeWithoutAViewportFallsBackToTheFullPass() {
    let text = makeLargeDocument()
    let (content, storage) = makeStorage(text: text, skin: .parchment)
    content.visibleRangeProvider = { nil }
    let passesBefore = content.fullRefreshCount

    content.tokens = PensieveTheme.ink.tokens

    XCTAssertEqual(
      textColor(in: storage, at: storage.length - 2),
      srgb(PensieveTheme.ink.tokens.text.nsColor))
    XCTAssertEqual(content.fullRefreshCount, passesBefore + 1)
  }

  /// The find washes live in `.backgroundColor`, which a full refresh strips
  /// document-wide. With the pass deferred it lands after `applyTheme` already
  /// repainted them, so the storage must hand the surface a second chance —
  /// otherwise a skin switch during a find session erases the matches until the
  /// operator retypes the query.
  @MainActor
  func testDeferredPassCallsBackSoFindWashesCanBeRepainted() {
    let text = makeLargeDocument()
    let (content, _) = makeStorage(text: text, skin: .parchment)
    content.visibleRangeProvider = { NSRange(location: 0, length: 400) }
    var callbacks = 0
    content.onRethemeCompleted = { callbacks += 1 }

    content.tokens = PensieveTheme.ink.tokens
    XCTAssertEqual(callbacks, 0, "nothing to repaint yet — the full pass has not run")

    drainDeferredRefresh()

    XCTAssertEqual(callbacks, 1)
  }
}
