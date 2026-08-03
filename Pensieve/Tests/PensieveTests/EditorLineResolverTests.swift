import AppKit
import XCTest

@testable import Pensieve

/// What the caret→line resolver owes the gutter.
///
/// It answers two questions that used to have one wrong answer each. WHICH line
/// the caret is on — the gutter numbers one row per `NSTextLayoutFragment`, and
/// the resolver counted `0x0A` alone, so a CR-only or U+2029 document reported
/// line 1 for the whole file. And HOW MUCH that answer costs — it walked from
/// offset 0 on every call, twice per keystroke, three times in Focus mode.
final class EditorLineResolverTests: XCTestCase {
  @MainActor
  private func makeSurface(text: String) -> MarkdownEditorSurface {
    MarkdownEditorSurface(text: text, fontSize: 14)
  }

  /// One layout fragment per visual row, straight off a real TextKit 2 stack.
  /// This is the ORACLE: the gutter numbers fragments, so "which line" means
  /// whatever this says, not whatever a list of separator code points says.
  ///
  /// The container is deliberately very wide — a fragment is a row, and a
  /// WRAPPED long line is several rows. Every fixture here is short enough that
  /// rows and logical lines coincide.
  @MainActor
  private func fragmentCount(_ text: String) -> Int {
    let content = MarkdownTextStorage()
    let storage = NSTextStorage()
    content.textStorage = storage
    let layout = NSTextLayoutManager()
    content.addTextLayoutManager(layout)
    layout.textContainer = NSTextContainer(
      size: NSSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude))
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
    layout.ensureLayout(for: layout.documentRange)

    var rows = 0
    layout.enumerateTextLayoutFragments(
      from: layout.documentRange.location, options: [.ensuresLayout]
    ) { _ in
      rows += 1
      return true
    }
    return rows
  }

  /// Reference implementation: a fresh full scan, no anchor, same separator set.
  private func naiveLineIndex(_ text: NSString, offset: Int) -> Int {
    let clamped = min(max(offset, 0), text.length)
    var line = 0
    var index = 0
    while index < clamped {
      let unit = text.character(at: index)
      if unit == 0x0D {
        line += 1
        if index + 1 < text.length, text.character(at: index + 1) == 0x0A { index += 1 }
      } else if unit == 0x0A || unit == 0x2029 {
        line += 1
      }
      index += 1
    }
    return line
  }

  // MARK: - T20: which line

  /// The separator set is DERIVED, not asserted from a list. For each fixture
  /// the resolver's line count at end-of-document must equal the number of rows
  /// the layout manager actually produced.
  ///
  /// This is where the reviewer's proposed set and the measured one part company.
  /// CR, CRLF and U+2029 each split a row and must count. U+2028, U+0085,
  /// U+000B and U+000C do NOT split one on this stack — a resolver that counted
  /// them would number rows that do not exist.
  @MainActor
  func testResolverAgreesWithTheLayoutManagerAboutWhatStartsARow() {
    let fixtures: [(String, String)] = [
      ("LF", "alpha\nbeta\ngamma"),
      ("CR", "alpha\rbeta\rgamma"),
      ("CRLF", "alpha\r\nbeta\r\ngamma"),
      ("U+2029 PS", "alpha\u{2029}beta\u{2029}gamma"),
      ("U+2028 LS", "alpha\u{2028}beta\u{2028}gamma"),
      ("U+0085 NEL", "alpha\u{0085}beta\u{0085}gamma"),
      ("U+000B VT", "alpha\u{000B}beta\u{000B}gamma"),
      ("U+000C FF", "alpha\u{000C}beta\u{000C}gamma"),
      ("mixed", "alpha\rbeta\r\ngamma\ndelta\u{2029}epsilon"),
    ]
    for (name, text) in fixtures {
      let rows = fragmentCount(text)
      let surface = makeSurface(text: text)
      let resolved = surface.lineIndex(forUTF16Offset: (text as NSString).length) + 1
      XCTAssertEqual(
        resolved, rows,
        "\(name): the gutter would number \(rows) rows and the resolver says \(resolved)")
    }
  }

  /// The operator-facing statement of the same thing, on the surface the gutter
  /// actually reads: caret on the last line of a three-line CR-only document
  /// must light up gutter row 3.
  @MainActor
  func testCaretOnTheLastLineOfACarriageReturnDocumentLightsTheThirdRow() {
    for (name, text) in [("CR", "alpha\rbeta\rgamma"), ("PS", "alpha\u{2029}beta\u{2029}gamma")] {
      let surface = makeSurface(text: text)
      let caret = (text as NSString).range(of: "gamma").location + 2
      surface.textView.setSelectedRange(NSRange(location: caret, length: 0))
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
      XCTAssertEqual(surface.textView.gutter?.currentLineNumber, 3, name)
    }
  }

  // MARK: - T15: what it costs

  /// Equivalence under the anchor. The anchored resolver walks a SPAN between
  /// the last position and this one; a fresh full scan walks from zero. Over a
  /// long random sequence of offsets on a mixed-line-ending document — forwards,
  /// backwards, repeats, both ends — they must never disagree.
  @MainActor
  func testAnchoredResolverMatchesAFullScanAtEveryOffset() {
    let text =
      (0..<400)
      .map { index -> String in
        let separator = ["\n", "\r", "\r\n", "\u{2029}"][index % 4]
        return "line \(index) of the mixed-ending fixture\(separator)"
      }
      .joined()
    let ns = text as NSString
    let surface = makeSurface(text: text)

    // Deterministic pseudo-random walk: reproducible, and it hits the pattern an
    // anchor is most likely to get wrong — a jump back followed by a jump
    // forward past where it started.
    var seed: UInt64 = 0x5DEE_CE66
    func nextOffset() -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int(seed >> 33) % (ns.length + 1)
    }

    for _ in 0..<2_000 {
      let offset = nextOffset()
      XCTAssertEqual(
        surface.lineIndex(forUTF16Offset: offset),
        naiveLineIndex(ns, offset: offset),
        "anchored resolver disagreed with a full scan at offset \(offset)")
    }
  }

  /// Edits must not strand the anchor. The same equivalence, with the document
  /// mutating underneath — inserts and deletes, before and after the caret.
  @MainActor
  func testAnchorSurvivesEditsUnderneathIt() {
    let text = String(repeating: "a line of text\n", count: 300)
    let surface = makeSurface(text: text)

    for round in 0..<60 {
      let ns = surface.textStorage.string as NSString
      _ = surface.lineIndex(forUTF16Offset: ns.length / 2)

      if round.isMultiple(of: 3) {
        surface.textStorage.replaceCharacters(
          in: NSRange(location: 0, length: 0), with: "inserted\n")
      } else if round.isMultiple(of: 3 + 1) {
        surface.textStorage.replaceCharacters(in: NSRange(location: 0, length: 9), with: "")
      } else {
        surface.textStorage.replaceCharacters(
          in: NSRange(location: ns.length, length: 0), with: "tail\n")
      }

      let mutated = surface.textStorage.string as NSString
      for offset in [0, mutated.length / 3, mutated.length / 2, mutated.length] {
        XCTAssertEqual(
          surface.lineIndex(forUTF16Offset: offset),
          naiveLineIndex(mutated, offset: offset),
          "round \(round), offset \(offset)")
      }
    }
  }

  /// THE cost pin, in the style of the retheme perf pins: a wall-clock budget on
  /// the work one keystroke's worth of caret movement is allowed to do.
  ///
  /// Measured in this debug test build, ONE full scan of this 1.08 MB document
  /// costs ~4.1 ms, and the surface runs the resolver two or three times per
  /// keystroke — so 200 sequential caret moves cost the old walk well over 800 ms
  /// of main thread purely to move a gutter marker. Anchored, the same 200 moves
  /// touch a handful of characters each.
  ///
  /// The budget is a MEASURED one, taken on the machine running the test rather
  /// than written down in milliseconds. One full scan of this fixture is timed
  /// here and the 200 anchored moves must together cost less than that single
  /// scan. The old walk did 200 of them, so it fails by more than two orders of
  /// magnitude on any hardware; an absolute bound instead asserts how fast the
  /// runner is, and reads as passing for a regression that merely halved the
  /// scan rather than removing it.
  @MainActor
  func testTwoHundredCaretMovesDoNotRescanTheDocument() {
    let text = String(repeating: "body text paragraph line here\n", count: 36_000)
    let ns = text as NSString
    XCTAssertGreaterThan(ns.length, 1_000_000, "the fixture has to be big enough to hurt")

    let surface = makeSurface(text: text)
    // Warm the anchor at the far end, which is where the old walk was slowest
    // and where a document is typically being typed into.
    _ = surface.lineIndex(forUTF16Offset: ns.length)

    let started = Date()
    for step in 0..<200 {
      _ = surface.lineIndex(forUTF16Offset: ns.length - (step % 40))
    }
    let elapsed = Date().timeIntervalSince(started)

    // The baseline: exactly the work ONE unanchored call had to do. Timed after
    // the loop so a cold cache cannot flatter the thing under test.
    let scanStarted = Date()
    _ = naiveLineIndex(ns, offset: ns.length)
    let oneFullScan = Date().timeIntervalSince(scanStarted)

    XCTAssertLessThan(
      elapsed, oneFullScan,
      "200 caret moves cost \(Int(elapsed * 1000)) ms against \(Int(oneFullScan * 1000)) ms"
        + " for a SINGLE full scan — the resolver is rescanning the document"
        + " instead of the span it moved across")
  }
}
