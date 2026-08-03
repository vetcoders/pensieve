import AppKit
import XCTest

@testable import Pensieve

/// PINS for the two costs a staged open still had to pay on the MAIN thread
/// after the file read moved off it: the first syntax-highlight pass and the
/// first preview render.
///
/// Moving only the read would have been a half fix. The read of a 17 MB file is
/// ~100 ms; the full-document highlight of it, at the repo's own measured
/// ~0.7 µs per character, is tens of seconds — and it ran in the same run-loop
/// turn as the wholesale `replaceCharacters` and the initial cmark parse. The
/// viewport-first sweep already existed for skin switches and was wired to
/// nothing else; the load path called the blocking full pass unconditionally.
/// That was the gap.
@MainActor
final class LargeDocumentOpenCostTests: XCTestCase {

  /// Just past the gate, so the pins exercise the staged branch without making
  /// the sweep take longer than the assertion it supports.
  private func makeLargeDocument() -> String {
    let text = String(repeating: "body text paragraph for the load pass\n\n", count: 30_000)
    XCTAssertTrue(LargeDocument.isLarge(text.utf16.count))
    return text
  }

  private func makeOrdinaryDocument() -> String {
    let text = String(repeating: "body text paragraph\n\n", count: 200)
    XCTAssertFalse(LargeDocument.isLarge(text.utf16.count))
    return text
  }

  private func applyLoadedText(_ text: String, to surface: MarkdownEditorSurface) {
    surface.update(
      text: text,
      fontSize: 14,
      syntaxHighlightingEnabled: true,
      tableTidyOnPaste: true,
      asciiSafeTables: false,
      aiAutocompleteEnabled: false,
      findQuery: "",
      findBarVisible: false
    )
  }

  /// Each chunk of the deferred sweep rides its own timer, so draining it has to
  /// be timed too — and has to wait for the LAST chunk, not a fixed interval.
  private func drainSweep(_ storage: MarkdownTextStorage, timeout: TimeInterval = 30) {
    guard storage.isRethemeSweepInFlight else { return }
    let drained = expectation(description: "deferred load sweep finished")
    let previous = storage.onRethemeCompleted
    storage.onRethemeCompleted = {
      previous?()
      drained.fulfill()
    }
    wait(for: [drained], timeout: timeout)
    storage.onRethemeCompleted = previous
  }

  // MARK: - Initial highlight

  /// RED-FIRST against the pre-cut code: `update` called `refreshHighlighting()`
  /// unconditionally, which is one full-document pass over the whole file, on the
  /// main thread, in the turn that applied the text.
  func testLargeDocumentLoadRunsNoFullDocumentHighlightPass() {
    let surface = MarkdownEditorSurface(text: "", fontSize: 14)
    let storage = surface.textContentStorage
    let before = storage.fullRefreshCount

    applyLoadedText(makeLargeDocument(), to: surface)

    XCTAssertEqual(
      storage.fullRefreshCount, before,
      "opening a large document must not re-colour the whole file synchronously")
    XCTAssertTrue(
      storage.isRethemeSweepInFlight,
      "the rest of the document still has to be swept — deferred, not dropped")

    drainSweep(storage)
    XCTAssertEqual(
      storage.fullRefreshCount, before,
      "and the sweep must carry it in chunks, never by falling back to a full pass")
    XCTAssertGreaterThan(storage.rethemeChunkCount, 1)
  }

  /// The other half of the contract: below the gate nothing changed at all.
  func testOrdinaryDocumentLoadStillRunsExactlyOneSynchronousFullPass() {
    let surface = MarkdownEditorSurface(text: "", fontSize: 14)
    let storage = surface.textContentStorage
    let before = storage.fullRefreshCount

    applyLoadedText(makeOrdinaryDocument(), to: surface)

    XCTAssertEqual(storage.fullRefreshCount, before + 1)
    XCTAssertFalse(
      storage.isRethemeSweepInFlight,
      "an ordinary document must not pay for a chunked sweep it does not need")
  }

  /// At load time layout has usually not established a viewport yet, which is the
  /// condition under which a retheme deliberately falls back to the full
  /// synchronous pass. The load path may not: a freshly opened file is read from
  /// the top, so the head of the document IS the viewport.
  func testLoadWithNoLaidOutViewportStillDefersInsteadOfPaintingEverything() {
    let content = MarkdownTextStorage()
    let storage = NSTextStorage()
    content.textStorage = storage
    XCTAssertNil(content.visibleRangeProvider?(), "no host surface — no viewport by construction")

    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: makeLargeDocument())
    let before = content.fullRefreshCount
    content.refreshHighlightingAfterFullTextReplacement()

    XCTAssertEqual(content.fullRefreshCount, before)
    XCTAssertTrue(content.isRethemeSweepInFlight)
    drainSweep(content)
  }

  // MARK: - Initial preview render

  private func request(markdown: String) -> PreviewRenderRequest {
    PreviewRenderRequest(markdown: markdown, fontSize: 14, theme: .gfm, documentURL: nil)
  }

  /// Drives the REAL coordinator — the seam the mount goes through — rather than
  /// a helper beside it, so the pin fails if the gate is ever unwired.
  ///
  /// RED-FIRST against the pre-cut code: the coordinator forwarded `initial`
  /// straight to the pipeline, so mounting the preview parsed the whole document
  /// synchronously in the turn the pane appeared.
  func testLargeDocumentDoesNotRenderItsFirstPreviewPassSynchronously() {
    let coordinator = PreviewRepresentable.Coordinator(themeManager: ThemeManager())
    let sink = CountingSink()
    coordinator.pipeline.attach(sink: sink)

    coordinator.submit(
      request: request(markdown: makeLargeDocument()), autoReload: true, initial: true)

    XCTAssertEqual(
      sink.loads, 0,
      "a full cmark parse of a multi-megabyte document must not ride the mount turn")
    XCTAssertNil(coordinator.pipeline.lastApplied)
  }

  func testOrdinaryDocumentStillRendersItsFirstPreviewPassSynchronously() {
    let coordinator = PreviewRepresentable.Coordinator(themeManager: ThemeManager())
    let sink = CountingSink()
    coordinator.pipeline.attach(sink: sink)

    coordinator.submit(
      request: request(markdown: makeOrdinaryDocument()), autoReload: true, initial: true)

    XCTAssertEqual(
      sink.loads, 1,
      "the debounce exists for typing; a small document must not stare at an empty pane")
  }

  /// An empty pane is the commonest first mount of all — it must stay immediate.
  func testEmptyDocumentStillRendersItsFirstPreviewPassSynchronously() {
    XCTAssertTrue(
      PreviewRepresentable.Coordinator.rendersFirstPassSynchronously(request(markdown: "")))
  }

  // MARK: - The gate itself

  func testSizeGateIsExclusiveAtTheBudget() {
    XCTAssertFalse(LargeDocument.isLarge(LargeDocument.sizeBudget))
    XCTAssertTrue(LargeDocument.isLarge(LargeDocument.sizeBudget + 1))
    XCTAssertFalse(LargeDocument.isLarge(0))
  }

  func testUnmeasurableFileReadsAsOrdinary() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("PensieveMissing-\(UUID().uuidString).md")
    XCTAssertNil(LargeDocument.fileSize(of: missing))
    XCTAssertFalse(
      LargeDocument.isLargeFile(at: missing),
      "a file the file system will not measure takes the path it took before the gate existed")
  }
}

/// Counts what actually reached the WebView stage, without one.
private final class CountingSink: PreviewSink {
  private(set) var loads = 0
  func load(document: PreviewDocument) { loads += 1 }
}
