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

  /// Big enough that the sweep is many chunks wide at the PRODUCTION budget, so
  /// the chunking pins do not have to shrink the budget to prove anything.
  private func makeHugeDocument() -> String {
    String(repeating: "body text paragraph\n\n", count: 10_000)
  }

  /// One ```swift fence far larger than a chunk. The whole point is that the
  /// block cannot be repainted inside a frame, so the expansion has to stop at
  /// the ceiling instead of swallowing it.
  private func makeHugeFencedDocument() -> String {
    "```swift\n"
      + String(repeating: "func greet() { let s = \"hi\" } // note\n", count: 16_000)
      + "```\n\nbody text paragraph\n"
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

  /// Lets the deferred sweep run to completion. Each chunk rides a timer, not a
  /// bare `main.async`, precisely so it lands in a LATER run-loop iteration than
  /// the frame it is deferring behind — so the drain has to be a timed one too,
  /// and it has to wait for the LAST chunk rather than a fixed interval.
  private func drainDeferredRefresh(
    _ content: MarkdownTextStorage, timeout: TimeInterval = 20.0
  ) {
    // A sweep that already finished has nothing to drain — waiting for a
    // callback that has already fired would hang until the timeout.
    guard content.isRethemeSweepInFlight else { return }
    let drained = expectation(description: "deferred retheme sweep finished")
    let previous = content.onRethemeCompleted
    content.onRethemeCompleted = {
      previous?()
      drained.fulfill()
    }
    wait(for: [drained], timeout: timeout)
    content.onRethemeCompleted = previous
  }

  /// First offset still carrying `skin`'s text colour, walking EVERY attribute
  /// run rather than sampling. A strided spot check steps straight over a
  /// one-character gap, which is precisely what an off-by-one in the sweep's
  /// cursor advance leaves behind — so coverage has to be checked exhaustively
  /// or it is not checked at all.
  private func firstOffsetStillOn(_ skin: PensieveTheme, in storage: NSTextStorage) -> Int? {
    let stale = srgb(skin.tokens.text.nsColor)
    let document = NSRange(location: 0, length: storage.length)
    var location = 0
    while location < storage.length {
      var effective = NSRange(location: 0, length: 0)
      let color =
        storage.attribute(
          .foregroundColor, at: location, longestEffectiveRange: &effective, in: document)
        as? NSColor
      if let color, srgb(color) == stale { return location }
      location = max(NSMaxRange(effective), location + 1)
    }
    return nil
  }

  /// Runs `body` on the main queue at the first run-loop turn where `condition`
  /// holds, polling in between so the sweep's own timers keep firing. Returns an
  /// expectation that fails the test if the moment never arrives — a pin that
  /// silently missed its window would assert nothing.
  @MainActor
  private func whenOnMain(
    _ description: String,
    _ condition: @escaping () -> Bool,
    _ body: @escaping () -> Void
  ) -> XCTestExpectation {
    let met = expectation(description: description)
    // Bounded, so a condition that never holds fails the test through the
    // expectation instead of leaving a 1 ms poll running into the next one.
    let deadline = Date().addingTimeInterval(10.0)
    var poll: (() -> Void)?
    poll = {
      if condition() {
        body()
        met.fulfill()
        poll = nil
        return
      }
      guard Date() < deadline else {
        poll = nil
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { poll?() }
    }
    DispatchQueue.main.async { poll?() }
    return met
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
  ///
  /// The sweep now paints in chunks, so the mechanism assertion is "no
  /// full-document pass ran at all" rather than "exactly one did": the property
  /// under test — every offset carries the new palette — is unchanged.
  @MainActor
  func testDeferredSweepStillRecoloursTheWholeDocument() {
    let text = makeLargeDocument()
    let (content, storage) = makeStorage(text: text, skin: .parchment)
    content.visibleRangeProvider = { NSRange(location: 0, length: 400) }
    let passesBefore = content.fullRefreshCount

    content.tokens = PensieveTheme.ink.tokens
    drainDeferredRefresh(content)

    let ink = srgb(PensieveTheme.ink.tokens.text.nsColor)
    for location in [0, storage.length / 4, storage.length / 2, storage.length - 2] {
      XCTAssertEqual(
        textColor(in: storage, at: location), ink,
        "offset \(location) was left on the previous skin")
    }
    XCTAssertEqual(
      content.fullRefreshCount, passesBefore,
      "the sweep must paint in chunks, never fall back to one blocking pass")
    XCTAssertGreaterThan(content.rethemeChunkCount, 0)
  }

  /// Clicking through the picker used to queue one full document pass per click,
  /// which is how 860 ms became the 3.5–4.5 s the operator measured. The sweep is
  /// cancellable, so a burst leaves exactly one.
  @MainActor
  func testBurstOfSkinSwitchesCoalescesIntoASingleSweep() {
    let text = makeLargeDocument()
    let (content, storage) = makeStorage(text: text, skin: .parchment)
    content.visibleRangeProvider = { NSRange(location: 0, length: 400) }
    var completions = 0
    content.onRethemeCompleted = { completions += 1 }

    for skin in [PensieveTheme.ink, .porcelain, .typewriter, .parchment, .ink] {
      content.tokens = skin.tokens
    }
    drainDeferredRefresh(content)

    XCTAssertEqual(
      completions, 1,
      "five switches must leave ONE sweep behind, not five")
    XCTAssertEqual(
      textColor(in: storage, at: storage.length - 2),
      srgb(PensieveTheme.ink.tokens.text.nsColor),
      "and the surviving sweep must be the LAST skin's")
  }

  /// The same coalescing requirement in its TIMED form, which the burst above
  /// cannot reach: there every switch lands before the first chunk runs, so the
  /// sweep is only ever restarted from a clean slate. A click that arrives while
  /// chunks are already going out has to restart the sweep from the top —
  /// resuming from the cursor would leave everything the abandoned sweep had
  /// already painted stranded on the intermediate palette, with no later pass to
  /// correct it.
  @MainActor
  func testSkinSwitchDuringASweepRestartsItFromTheTop() {
    let (content, storage) = makeStorage(text: makeHugeDocument(), skin: .parchment)
    content.visibleRangeProvider = { NSRange(location: 0, length: 400) }
    content.rethemeChunkTimeBudget = 0.0005
    var completions = 0
    content.onRethemeCompleted = { completions += 1 }

    let switched = whenOnMain(
      "second skin picked mid-sweep",
      { content.isRethemeSweepInFlight && content.rethemeChunkCount >= 3 },
      { content.tokens = PensieveTheme.typewriter.tokens })

    content.tokens = PensieveTheme.ink.tokens
    wait(for: [switched], timeout: 10.0)
    drainDeferredRefresh(content)

    XCTAssertNil(firstOffsetStillOn(.parchment, in: storage))
    XCTAssertNil(
      firstOffsetStillOn(.ink, in: storage),
      "the abandoned sweep's palette must not survive anywhere")
    XCTAssertEqual(
      completions, 1,
      "the abandoned sweep owes no completion — only the surviving one does")
  }

  // MARK: - Chunking

  /// THE chunking pin. The first cut of this fix deferred the rest of the
  /// document as ONE pass: `applyTheme` fell from 860 ms to 150 ms, but the
  /// remaining ~700 ms still landed as a single main-thread block one tick
  /// later, and click→pixels only came down from 3.5–4.5 s to 2.2 s. No single
  /// chunk may hold the main thread longer than the frame it rides.
  ///
  /// Restoring the single deferred pass fails this outright: one chunk covering
  /// the whole document blows the budget by an order of magnitude.
  @MainActor
  func testNoSingleChunkHoldsTheMainThreadLongerThanItsBudget() {
    let (content, _) = makeStorage(text: makeHugeDocument(), skin: .parchment)
    content.visibleRangeProvider = { NSRange(location: 0, length: 400) }

    content.tokens = PensieveTheme.ink.tokens
    drainDeferredRefresh(content)

    XCTAssertGreaterThan(content.rethemeChunkCount, 2, "the sweep must actually be cut up")
    // Slack for scheduler noise on a loaded CI box; the point is orders of
    // magnitude, not milliseconds — the pre-chunking block was ~700 ms, which is
    // 40 frames.
    XCTAssertLessThan(
      content.longestRethemeChunkDuration, content.rethemeChunkTimeBudget * 4,
      "a chunk that outgrows its budget is the blocking pass again, just smaller")
  }

  /// A large fenced block must not smuggle the blocking pass back in.
  ///
  /// `codeBlockAwareRange` used to union the WHOLE fence onto a chunk that had
  /// already been sized to the time budget, with no cap, and then run
  /// `refreshHighlighting` over the result synchronously — a reset, twelve
  /// markdown regexes, the fence regex, the per-language rules and a substring
  /// copy of the entire block, all in one frame. The existing budget pin above
  /// cannot see it: its filler is fence-free.
  ///
  /// Measured on THIS fixture (608 KB fence, debug build): unbounded, the sweep
  /// is TWO chunks and the worst holds the main thread for 2315 ms — the whole
  /// document in one block, which is precisely what the chunking replaced.
  /// Clamped, the worst chunk is 223 ms and the steady state ~18 ms.
  ///
  /// The residual 223 ms is the FIRST chunk, sized from `seedSecondsPerCharacter`
  /// before any measurement of this document exists, and it is dominated by a
  /// per-chunk cost that is O(document) rather than O(chunk) — each pass bridges
  /// the whole `NSString` to a `String` and re-copies `lastProcessedString`. That
  /// is a separate finding, not this one, so the duration bound here is set from
  /// the measurement rather than from the frame budget; the LENGTH assertion
  /// below states the same contract deterministically.
  @MainActor
  func testALargeFencedBlockCannotWidenAChunkPastItsBudget() {
    let (content, storage) = makeStorage(text: makeHugeFencedDocument(), skin: .parchment)
    content.visibleRangeProvider = { NSRange(location: 0, length: 400) }

    content.tokens = PensieveTheme.ink.tokens
    drainDeferredRefresh(content)

    XCTAssertGreaterThan(content.rethemeChunkCount, 2, "the sweep must actually be cut up")
    XCTAssertLessThanOrEqual(
      content.longestRethemeChunkLength, MarkdownTextStorage.maximumRethemeChunkLength,
      "the fenced block handed one chunk \(content.longestRethemeChunkLength) characters —"
        + " the expansion is unbounded again")
    XCTAssertLessThan(
      content.longestRethemeChunkDuration, content.rethemeChunkTimeBudget * 20,
      "a fenced block widened a chunk into the blocking pass the sweep replaced"
        + " — measured \(Int(content.longestRethemeChunkDuration * 1000)) ms")

    // Control leg: bounding the chunk must not cost the CODE PALETTE. Sampled
    // deep inside the fence, well past any chunk boundary the sweep could have
    // aligned with by luck.
    let ns = storage.string as NSString
    let deepKeyword = ns.range(
      of: "func", options: .backwards, range: NSRange(location: 0, length: ns.length))
    XCTAssertNotEqual(deepKeyword.location, NSNotFound)
    XCTAssertEqual(
      textColor(in: storage, at: deepKeyword.location),
      srgb(PensieveTheme.ink.tokens.accent.nsColor),
      "code inside the fence came out on the prose palette after the sweep")
  }

  /// Decision (d), settled by measurement rather than taste: the first chunk
  /// rides the chunk budget, not the 70 ms typing debounce the previous cut
  /// reused. The viewport is already repainted synchronously by then, so nothing
  /// perceptible rides on the first chunk — but every millisecond it waits is a
  /// millisecond added to the tail, which is what the operator hits when
  /// scrolling straight after a switch.
  @MainActor
  func testTheSweepStartsOnTheFrameBudgetNotTheTypingDebounce() {
    let (content, _) = makeStorage(text: makeLargeDocument(), skin: .parchment)
    content.visibleRangeProvider = { NSRange(location: 0, length: 400) }

    let started = Date()
    var firstChunkLatency: TimeInterval = .infinity
    let sawFirstChunk = whenOnMain(
      "first chunk ran",
      { content.rethemeChunkCount >= 1 },
      { firstChunkLatency = Date().timeIntervalSince(started) })

    content.tokens = PensieveTheme.ink.tokens
    wait(for: [sawFirstChunk], timeout: 5.0)
    drainDeferredRefresh(content)

    XCTAssertLessThan(
      firstChunkLatency, 0.05,
      "the sweep must start on the frame budget (~16 ms), not on the 70 ms"
        + " typing debounce — measured \(Int(firstChunkLatency * 1000)) ms")
  }

  /// Coverage under many chunks: with a tight budget the sweep is cut into a
  /// long chain of small chunks, and EVERY offset must still end up repainted.
  /// This is where an off-by-one in the cursor arithmetic would leave a striped
  /// document.
  @MainActor
  func testManyChunkSweepLeavesNoGaps() {
    let text = makeLargeDocument()
    let (content, storage) = makeStorage(text: text, skin: .parchment)
    content.visibleRangeProvider = { NSRange(location: 0, length: 400) }
    content.rethemeChunkTimeBudget = 0.0005

    content.tokens = PensieveTheme.ink.tokens
    drainDeferredRefresh(content)

    XCTAssertGreaterThan(content.rethemeChunkCount, 4)
    XCTAssertNil(
      firstOffsetStillOn(.parchment, in: storage),
      "an offset was skipped by the chunked sweep and kept the previous skin")
  }

  /// The document is allowed to move under a sweep. Both directions are covered:
  /// an insert AHEAD of the cursor (which shifts every remaining offset) and a
  /// delete that shortens the document below the cursor. Neither may raise, and
  /// neither may leave a half-painted document behind.
  @MainActor
  func testEditDuringSweepLeavesNoHalfPaintedDocument() {
    let (content, storage) = makeStorage(text: makeHugeDocument(), skin: .parchment)
    content.visibleRangeProvider = { NSRange(location: 0, length: 400) }
    content.rethemeChunkTimeBudget = 0.0005

    // Both directions, and both BEFORE the cursor — that is the only place an
    // edit can break a sweep. An insert shifts the unpainted tail forward, so a
    // sweep that ignored it merely repaints ground it already covered. A DELETE
    // shifts the tail backwards, and a sweep that ignored it resumes past the
    // text that moved down into the gap: exactly `delta` characters left on the
    // previous skin, with nothing to trigger a repaint of them ever again.
    let edited = whenOnMain(
      "document mutated mid-sweep",
      { content.isRethemeSweepInFlight && content.rethemeChunkCount >= 3 },
      {
        storage.replaceCharacters(
          in: NSRange(location: 0, length: 0), with: "inserted ahead of the cursor\n\n")
        storage.replaceCharacters(in: NSRange(location: 40, length: 3_000), with: "")
      })

    content.tokens = PensieveTheme.ink.tokens
    wait(for: [edited], timeout: 10.0)

    drainDeferredRefresh(content)
    // The edit's own debounced pass is scheduled behind the sweep; let it land.
    let settled = expectation(description: "edit debounce settled")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
    wait(for: [settled], timeout: 5.0)

    XCTAssertNil(
      firstOffsetStillOn(.parchment, in: storage),
      "an offset survived the mid-sweep edit on the previous skin")
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

    drainDeferredRefresh(content)

    XCTAssertEqual(callbacks, 1)
  }
}
