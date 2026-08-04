import AppKit
import XCTest

@testable import Pensieve

/// PINS for the cost of asking "did the document text change?" on a SwiftUI pass.
///
/// The operator's 17 MB file froze the app at 100% CPU with no end condition. The
/// sample landed on `EditorRepresentable.updateNSView` twice per pass — once at
/// the scroll-pin guard, once inside `MarkdownEditorSurface.update` — and both
/// frames sat directly in `_stringCompareSlow`, normalising a bridged
/// `NSBigMutableString` to NFC one scalar at a time through `characterAtIndex:`.
///
/// The bug was not the size of the document. It was that a question SwiftUI asks
/// on every pass was answered by reading the whole document, so the answer
/// "nothing changed" cost as much as changing everything. These pins state the
/// cost as an INVARIANT — zero whole-buffer comparisons on a steady pass — rather
/// than as a stopwatch, so they hold on any machine and at any document size.
@MainActor
final class EditorTextSyncCostTests: XCTestCase {

  private func document(lines: Int = 400) -> String {
    (1...lines)
      .map { "Line \($0): the quick brown fox jumps over the lazy dog." }
      .joined(separator: "\n")
  }

  /// One `updateNSView` pass, in its real shape: the scroll-pin guard asks first,
  /// then `update` asks again on its way to the buffer. Both go through the same
  /// primitive, so a pass that regresses either call site moves the counter.
  private func renderPass(_ surface: MarkdownEditorSurface, text: String) {
    _ = surface.bufferHoldsText(text)
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

  // MARK: - The cost invariant

  /// The passes that hung: text untouched, SwiftUI re-laying the representable
  /// out over and over. Nothing about the document may be read.
  func testSteadyRenderPassNeverComparesTheWholeBuffer() {
    let text = document()
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    let before = surface.wholeBufferComparisonCount

    for _ in 0..<50 {
      renderPass(surface, text: text)
    }

    XCTAssertEqual(
      surface.wholeBufferComparisonCount, before,
      "a re-render that changes no text must not read the document to find that out")
  }

  /// The live steady state, not a synthetic one: the model's text is whatever the
  /// surface last handed up through `onTextChanged`, and that is the value coming
  /// back down the binding on every subsequent pass.
  func testKeystrokeEchoIsAnsweredWithoutComparingTheWholeBuffer() throws {
    let surface = MarkdownEditorSurface(text: document(), fontSize: 14)
    var echoed: String?
    surface.onTextChanged = { echoed = $0 }

    let caret = surface.textStorage.length / 2
    surface.textView.setSelectedRange(NSRange(location: caret, length: 0))
    surface.textView.insertText("x", replacementRange: NSRange(location: caret, length: 0))

    let typed = try XCTUnwrap(echoed, "the edit must reach the model")
    let before = surface.wholeBufferComparisonCount

    for _ in 0..<50 {
      renderPass(surface, text: typed)
    }

    XCTAssertEqual(
      surface.wholeBufferComparisonCount, before,
      "the value the surface itself published must be recognised without a scan")
  }

  /// A value the surface never published — a reload handing back byte-identical
  /// text, say — cannot be recognised for free the first time. It must be
  /// recognised for free every time AFTER that, or a re-render loop is back.
  func testUnfamiliarButEqualTextIsComparedOnceAndThenRemembered() {
    let text = document()
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    // Equal characters in storage of its own — what re-reading the file yields.
    // Round-tripping the bytes is deliberate: anything the compiler can fold back
    // into `text` would share storage and answer from identity for free, which is
    // the opposite of what this pin is for.
    let reread = String(decoding: Array(text.utf8), as: UTF8.self)
    XCTAssertFalse(
      (reread as NSString) === (text as NSString), "the pin needs a genuinely unfamiliar value")
    let before = surface.wholeBufferComparisonCount

    for _ in 0..<50 {
      renderPass(surface, text: reread)
    }

    XCTAssertEqual(
      surface.wholeBufferComparisonCount, before + 1,
      "the scan must be memoised, so an unfamiliar value pays for itself once")
  }

  // MARK: - Semantics the cheap answer may not change

  /// Control: the echo must not rewrite the buffer. This is the guard's original
  /// job — a SwiftUI pass carrying the user's own text back down must be a no-op,
  /// or every keystroke would re-apply the document under the caret.
  func testEchoedTextDoesNotRewriteTheBuffer() throws {
    let surface = MarkdownEditorSurface(text: document(), fontSize: 14)
    var echoed: String?
    surface.onTextChanged = { echoed = $0 }

    let caret = surface.textStorage.length / 2
    surface.textView.setSelectedRange(NSRange(location: caret, length: 0))
    surface.textView.insertText("x", replacementRange: NSRange(location: caret, length: 0))
    let typed = try XCTUnwrap(echoed)

    var edits = 0
    let previous = surface.textContentStorage.onCharactersEdited
    surface.textContentStorage.onCharactersEdited = { location, delta in
      previous?(location, delta)
      edits += 1
    }
    defer { surface.textContentStorage.onCharactersEdited = previous }

    let selectionBefore = surface.textView.selectedRange()
    for _ in 0..<10 {
      renderPass(surface, text: typed)
    }

    XCTAssertEqual(edits, 0, "an echo re-applied the document the user is typing into")
    XCTAssertEqual(surface.textView.selectedRange(), selectionBefore)
  }

  /// Control: a real change from outside the view — reload from disk, restore,
  /// dictation — still has to land in the buffer.
  func testExternalTextChangeStillReachesTheBuffer() {
    let surface = MarkdownEditorSurface(text: document(), fontSize: 14)
    let replacement = "a completely different document\n"

    renderPass(surface, text: replacement)

    XCTAssertEqual(surface.textStorage.string, replacement)
  }

  /// The same control at equal length, which is the one case the cheap
  /// length-disagreement reject cannot answer. It must fall through to the
  /// comparison, not be waved past.
  func testSameLengthExternalChangeStillReachesTheBuffer() {
    let original = document(lines: 40)
    let surface = MarkdownEditorSurface(text: original, fontSize: 14)
    let edited = original.replacingOccurrences(of: "quick brown fox", with: "slow yellow cat")
    XCTAssertEqual(
      (edited as NSString).length, (original as NSString).length,
      "the point of this pin is a change the length check cannot see")

    renderPass(surface, text: edited)

    XCTAssertEqual(surface.textStorage.string, edited)
  }

  /// RED-FIRST against the pre-cut code, and it needs no instrumentation to be:
  /// the old guard was `String ==`, which is CANONICAL equivalence, so text that
  /// differs from the buffer only in composition read as "unchanged" and never
  /// reached the view. Model and buffer then held different code units with
  /// nothing to reconcile them. Exact comparison closes that.
  func testCanonicallyEquivalentButDistinctTextStillReachesTheBuffer() {
    let decomposed = "e\u{0301}cole normale\n"  // e + combining acute
    let composed = "\u{00E9}cole normale\n"  // precomposed é
    XCTAssertEqual(decomposed, composed, "Swift reads these as the same string — that is the trap")
    XCTAssertNotEqual(
      Array(decomposed.unicodeScalars), Array(composed.unicodeScalars),
      "…while the buffer stores code units, where they differ")

    let surface = MarkdownEditorSurface(text: decomposed, fontSize: 14)
    renderPass(surface, text: composed)

    XCTAssertTrue(
      (surface.textStorage.string as NSString).isEqual(to: composed),
      "text the model holds must reach the buffer even when Swift calls it equal")
  }

  /// The memo is only ever an assertion about the buffer, so the buffer moving
  /// under it has to retire it. Mutating the storage directly is exactly the path
  /// the markdown commands, find-replace and autocomplete take.
  ///
  /// Deliberately a SAME-LENGTH mutation: a length change is caught by the cheap
  /// reject even with a stale memo, so only an equal-length edit actually pins the
  /// invalidation hook.
  func testSameLengthDirectBufferMutationRetiresTheSyncMemo() {
    let text = document(lines: 10)
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    XCTAssertTrue(surface.bufferHoldsText(text))

    surface.textStorage.replaceCharacters(in: NSRange(location: 0, length: 4), with: "ZZZZ")
    XCTAssertEqual(surface.textStorage.length, (text as NSString).length)

    XCTAssertFalse(
      surface.bufferHoldsText(text),
      "the buffer changed behind the memo and the memo answered for it anyway")
  }
}
