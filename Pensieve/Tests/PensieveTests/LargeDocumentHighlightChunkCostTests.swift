import AppKit
import XCTest

@testable import Pensieve

/// PINS for the SECOND head of the large-document freeze: the debounced pass a
/// fence-touching edit schedules.
///
/// The chunked sweep already bounded a skin switch and a wholesale text
/// replacement. It never saw this one. `processEditing` reports a fence-touching
/// edit, `scheduleHighlightingRefresh` sets `pendingRequiresFullRefresh`, and
/// 70 ms later `applyScheduledHighlightingRefresh` ran a bare
/// `refreshHighlighting()` — reset, twelve markdown regexes and the fence regex
/// over the WHOLE document, in one run-loop turn.
///
/// Two samples of the shipped app (build 617, 17 MB markdown extract of an agent
/// log) caught the main thread inside exactly that call, with the neighbouring
/// samples idle:
///
/// - open:    2437/2437 in `CodeBlockHighlighter.highlight(_:range:)`
/// - restore: 2410/2410 in `SyntaxHighlighter.applyMarkdownAttributes`
///
/// Both under `closure #2 in scheduleHighlightingRefresh` →
/// `refreshHighlighting()`. Two different highlighters, one unbounded pass — so
/// the bound has to be on the PASS, not on either highlighter, and these pins
/// come in both flavours for that reason: a document that is one huge fenced
/// block, and a document that is huge plain markdown.
///
/// The invariant is stated in CHARACTERS, not milliseconds, for the reason the
/// existing chunking pin already documents: a wall-clock bound loose enough to
/// survive a slow CI box no longer distinguishes the bug from the fix.
@MainActor
final class LargeDocumentHighlightChunkCostTests: XCTestCase {

  // MARK: - Fixtures

  /// One ```swift fence, comfortably past `LargeDocument.sizeBudget`. This is the
  /// operator's file in miniature: an extract of agent logs is, in practice,
  /// enormous fenced code blocks.
  private func makeHugeFencedDocument() -> String {
    let text =
      "```swift\n"
      + String(repeating: "func greet() { let s = \"hi\" } // note\n", count: 34_000)
      + "```\n\nbody text paragraph\n"
    XCTAssertTrue(LargeDocument.isLarge(text.utf16.count))
    return text
  }

  /// The other flavour: almost no code, a megabyte of prose the markdown regexes
  /// have to walk. The leading fence is what makes the edit a fence-touching one
  /// — without it the debounce takes the scoped path, which was never the bug.
  private func makeHugeProseDocument() -> String {
    let text =
      "```text\nplaceholder\n```\n\n"
      + String(
        repeating:
          "## Heading\n\nSome **bold** and _italic_ prose with `code` and a [link](https://x.dev).\n\n",
        count: 14_000)
    XCTAssertTrue(LargeDocument.isLarge(text.utf16.count))
    return text
  }

  /// Below the gate, and still fenced, so the control leg differs from the pins
  /// in exactly one property: size.
  private func makeOrdinaryFencedDocument() -> String {
    let text =
      "```swift\n"
      + String(repeating: "func greet() { let s = \"hi\" }\n", count: 200)
      + "```\n\nbody text paragraph\n"
    XCTAssertFalse(LargeDocument.isLarge(text.utf16.count))
    return text
  }

  // MARK: - Harness

  /// Sweep chunks the storage scheduled, held here rather than in the helper that
  /// installs the scheduler: a chunk schedules its SUCCESSOR from inside itself,
  /// so the sink has to outlive the call that started the sweep.
  private var queued: [DispatchWorkItem] = []

  private func makeStorage() -> (MarkdownTextStorage, NSTextStorage) {
    let content = MarkdownTextStorage()
    let storage = NSTextStorage()
    content.textStorage = storage
    content.tokens = PensieveTheme.parchment.tokens
    // Deliberately NOT pre-refreshed with text in place: `refreshHighlighting()`
    // is an honest whole-document pass and would put the document's own length
    // into `longestSynchronousHighlightLength` before the pin measured anything.
    XCTAssertEqual(content.longestSynchronousHighlightLength, 0)
    return (content, storage)
  }

  /// Applies a loaded file the way `MarkdownEditorSurface.update` does — the
  /// wholesale `replaceCharacters` first, then the viewport-first entry point —
  /// and lets the 70 ms debounce the edit scheduled fire, without running a
  /// single sweep chunk.
  ///
  /// Hijacking the chunk scheduler keeps the pin off the sweep's real timers.
  /// The pass under test is the DEBOUNCED one, which rides its own 70 ms timer
  /// and is not injectable, so that one is waited out; nothing else is.
  private func loadWithoutSweeping(
    _ text: String, into content: MarkdownTextStorage, _ storage: NSTextStorage
  ) {
    content.scheduleRethemeChunk = { [weak self] _, work in self?.queued.append(work) }
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
    content.refreshHighlightingAfterFullTextReplacement()
    settleTypingDebounce()
  }

  /// Lets the 70 ms typing debounce fire. Timeout is generous on purpose: against
  /// the pre-fix code the debounced pass IS a multi-second block, and a pin that
  /// timed out there would fail for the wrong reason instead of reporting the
  /// number it measured.
  private func settleTypingDebounce() {
    let settled = expectation(description: "typing debounce settled")
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
    wait(for: [settled], timeout: 60.0)
  }

  /// Runs every queued chunk, and every chunk they queue in turn, without waiting
  /// on a timer — the same deterministic pump `EditorThemeRepaintTests` uses.
  private func pump(_ content: MarkdownTextStorage) {
    let ceiling = (content.textStorage?.length ?? 0) + 2
    var turns = 0
    while !queued.isEmpty {
      let work = queued.removeFirst()
      turns += 1
      guard turns <= ceiling else {
        return XCTFail("the deferred sweep scheduled \(turns) chunks without finishing")
      }
      guard !work.isCancelled else { continue }
      work.perform()
    }
  }

  private func srgb(_ color: NSColor) -> NSColor {
    color.usingColorSpace(.sRGB) ?? color
  }

  // MARK: - The cost invariant

  /// THE pin, code-block flavour. RED-FIRST against the pre-cut code: the
  /// debounced refresh painted all ~1.3 MB in one turn, five times the ceiling
  /// the chunking is allowed to plan.
  func testFenceTouchingRefreshOnAHugeCodeBlockDocumentStaysWithinAChunk() {
    let (content, storage) = makeStorage()
    let fullPassesBefore = content.fullRefreshCount
    loadWithoutSweeping(makeHugeFencedDocument(), into: content, storage)
    defer { content.scheduleRethemeChunk = MarkdownTextStorage.timerRethemeChunkScheduler }

    XCTAssertGreaterThan(
      content.longestSynchronousHighlightLength, 0,
      "no pass ran at all — the pin would be vacuous")
    XCTAssertLessThanOrEqual(
      content.longestSynchronousHighlightLength,
      MarkdownTextStorage.maximumRethemeChunkLength,
      "one run-loop turn highlighted \(content.longestSynchronousHighlightLength)"
        + " characters of a \(storage.length)-character document —"
        + " the debounced full refresh is unbounded again")
    XCTAssertEqual(
      content.fullRefreshCount, fullPassesBefore,
      "a large document may not be re-coloured by a whole-document pass at all")
    XCTAssertTrue(
      content.isRethemeSweepInFlight,
      "the rest of the document still has to be swept — deferred, not dropped")

    pump(content)
    XCTAssertLessThanOrEqual(
      content.longestSynchronousHighlightLength,
      MarkdownTextStorage.maximumRethemeChunkLength,
      "a chunk of the sweep the debounced pass started blew the same bound")
  }

  /// THE pin, prose flavour. The restore sample sat in
  /// `SyntaxHighlighter.applyMarkdownAttributes`, not in the code-block
  /// highlighter: a bound that only clamped fenced blocks would leave this one
  /// exactly as slow as it was.
  func testFenceTouchingRefreshOnAHugeProseDocumentStaysWithinAChunk() {
    let (content, storage) = makeStorage()
    let fullPassesBefore = content.fullRefreshCount
    loadWithoutSweeping(makeHugeProseDocument(), into: content, storage)
    defer { content.scheduleRethemeChunk = MarkdownTextStorage.timerRethemeChunkScheduler }

    XCTAssertGreaterThan(content.longestSynchronousHighlightLength, 0)
    XCTAssertLessThanOrEqual(
      content.longestSynchronousHighlightLength,
      MarkdownTextStorage.maximumRethemeChunkLength,
      "one run-loop turn highlighted \(content.longestSynchronousHighlightLength)"
        + " characters of a \(storage.length)-character document —"
        + " markdown attributes are still applied document-wide in one go")
    XCTAssertEqual(content.fullRefreshCount, fullPassesBefore)

    pump(content)
    XCTAssertLessThanOrEqual(
      content.longestSynchronousHighlightLength,
      MarkdownTextStorage.maximumRethemeChunkLength)
  }

  /// Typing on a fence line, not just opening. Same pass, reached the way the
  /// operator reaches it after the file is already up.
  func testTypingOnAFenceLineOfAHugeDocumentStaysWithinAChunk() {
    let (content, storage) = makeStorage()
    let fullPassesBefore = content.fullRefreshCount
    loadWithoutSweeping(makeHugeFencedDocument(), into: content, storage)
    defer { content.scheduleRethemeChunk = MarkdownTextStorage.timerRethemeChunkScheduler }
    pump(content)

    let measuredAfterLoad = content.longestSynchronousHighlightLength

    // The opening fence line: an edit here is a fence-touching edit by
    // construction, which is what puts the debounce on the full-refresh leg.
    storage.replaceCharacters(in: NSRange(location: 3, length: 0), with: "`")
    settleTypingDebounce()

    XCTAssertEqual(
      content.longestSynchronousHighlightLength, measuredAfterLoad,
      "a keystroke on a fence line re-coloured more of the document in one turn"
        + " than the whole load pass did")
    XCTAssertLessThanOrEqual(
      content.longestSynchronousHighlightLength,
      MarkdownTextStorage.maximumRethemeChunkLength)
    XCTAssertEqual(content.fullRefreshCount, fullPassesBefore)
  }

  // MARK: - Control legs

  /// Below the gate NOTHING changed: the debounced full refresh is still exactly
  /// one synchronous whole-document pass, which is every ordinary note.
  func testOrdinaryFencedDocumentStillTakesTheSynchronousFullRefresh() {
    let (content, storage) = makeStorage()
    content.scheduleRethemeChunk = { _, _ in
      XCTFail("an ordinary document must not pay for a chunked sweep it does not need")
    }
    defer { content.scheduleRethemeChunk = MarkdownTextStorage.timerRethemeChunkScheduler }

    let text = makeOrdinaryFencedDocument()
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
    content.refreshHighlightingAfterFullTextReplacement()
    let afterLoad = content.fullRefreshCount
    settleTypingDebounce()
    XCTAssertEqual(
      content.fullRefreshCount, afterLoad,
      "the load's own full pass absorbs the debounce it queued — unchanged behaviour")

    // The debounce leg itself, reached the only way it can be below the gate:
    // a fence-touching keystroke with no explicit refresh behind it.
    storage.replaceCharacters(in: NSRange(location: 3, length: 0), with: "`")
    settleTypingDebounce()

    XCTAssertEqual(
      content.fullRefreshCount, afterLoad + 1,
      "the debounce still owes an ordinary document its one synchronous full pass")
    XCTAssertEqual(
      content.longestSynchronousHighlightLength, storage.length,
      "and that pass still covers the whole document")
    XCTAssertFalse(content.isRethemeSweepInFlight)
  }

  /// Bounding the pass may not cost the COLOURS. Sampled at the far tail of the
  /// fence, well past any chunk boundary the sweep could have aligned with by
  /// luck: a bound that left the tail on the prose palette would be a different
  /// bug, not a fix.
  func testBoundedRefreshStillColoursTheWholeDocumentOnceTheSweepFinishes() {
    let (content, storage) = makeStorage()
    loadWithoutSweeping(makeHugeFencedDocument(), into: content, storage)
    defer { content.scheduleRethemeChunk = MarkdownTextStorage.timerRethemeChunkScheduler }
    pump(content)

    XCTAssertFalse(
      content.isRethemeSweepInFlight,
      "the pump ran out of chunks while the sweep still had ranges to paint")

    let ns = storage.string as NSString
    let deepKeyword = ns.range(
      of: "func", options: .backwards, range: NSRange(location: 0, length: ns.length))
    XCTAssertNotEqual(deepKeyword.location, NSNotFound)
    let color =
      storage.attribute(.foregroundColor, at: deepKeyword.location, effectiveRange: nil) as? NSColor
    XCTAssertEqual(
      color.map(srgb),
      srgb(PensieveTheme.parchment.tokens.accent.nsColor),
      "code at the tail of the fence came out on the prose palette after the sweep")
  }

  /// The sweep must CONVERGE, not run forever. Each chunk of the bounded pass
  /// schedules its successor, so a cursor that failed to advance would spin the
  /// main thread just as hard as the unbounded pass did — and the completion
  /// callback the find washes hang off must still fire exactly once.
  func testBoundedRefreshConvergesAndSignalsCompletionOnce() {
    let (content, storage) = makeStorage()
    var completions = 0
    content.onRethemeCompleted = { completions += 1 }
    loadWithoutSweeping(makeHugeProseDocument(), into: content, storage)
    defer { content.scheduleRethemeChunk = MarkdownTextStorage.timerRethemeChunkScheduler }

    pump(content)

    XCTAssertFalse(content.isRethemeSweepInFlight)
    XCTAssertGreaterThan(content.rethemeChunkCount, 1, "the sweep must actually be cut up")
    XCTAssertEqual(completions, 1, "one sweep, one completion")
  }
}
