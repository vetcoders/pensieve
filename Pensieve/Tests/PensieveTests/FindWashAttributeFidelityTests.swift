import AppKit
import XCTest

@testable import Pensieve

/// A find session must leave the document exactly as coloured as it found it.
///
/// The washes are painted over the highlighter's own work, so every wash records
/// what it covered and gives it back on teardown. Two ways that record can lie:
///
///  1. it captures only the FOREGROUND, while the wash overwrites the background
///     too — and the highlighter uses `.backgroundColor` for meaning of its own
///     (inline code, `==highlight==`). Restoring half of it strips those
///     backgrounds for good;
///  2. it is keyed on OFFSETS, so an insert or delete above a wash leaves every
///     record naming text that has moved — the teardown then clears the
///     background off innocent characters and hands the captured colouring to
///     the wrong ones.
///
/// The oracle here is a full attribute census of the document, never a sample:
/// both failures are a handful of characters wide and a spot check walks past
/// them. The fixture is deliberately FORMATTED — a plain-prose fixture cannot
/// fail either way, which is exactly how these gaps survived the first cut.
final class FindWashAttributeFidelityTests: XCTestCase {

  // MARK: - Fixture

  /// One query, three different kinds of ground underneath it: plain prose,
  /// inline code, and a `==highlight==` — the two constructs the highlighter
  /// gives a background of its own.
  private func formattedDocument(tailParagraphs: Int = 40) -> String {
    var lines = [
      "Alfa target beta w zwyklym akapicie.",
      "Kod `target inside` w linii kodu.",
      "Mark ==target marked== na koncu.",
    ]
    for index in 1...tailParagraphs {
      lines.append("Akapit \(index): dalsza tresc dokumentu bez trafien.")
    }
    return lines.joined(separator: "\n")
  }

  @MainActor
  private func makeSurface(text: String) -> MarkdownEditorSurface {
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    surface.textContentStorage.refreshHighlighting()
    return surface
  }

  // MARK: - Oracle

  /// One run of the document's colouring.
  private struct ColourRun: Equatable, CustomStringConvertible {
    let range: NSRange
    let foreground: NSColor?
    let background: NSColor?

    var description: String {
      "\(NSStringFromRange(range)) fg=\(Self.name(foreground)) bg=\(Self.name(background))"
    }

    private static func name(_ colour: NSColor?) -> String {
      guard let colour else { return "-" }
      guard let rgb = colour.usingColorSpace(.sRGB) else { return "\(colour)" }
      return String(
        format: "#%02X%02X%02X@%.2f", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
        Int(rgb.blueComponent * 255), rgb.alphaComponent)
    }
  }

  /// EVERY colour run in the document, coalesced so two runs that look the same
  /// never register as a difference. This is the census, not a sample.
  @MainActor
  private func colourCensus(_ surface: MarkdownEditorSurface) -> [ColourRun] {
    let storage = surface.textStorage
    var runs: [ColourRun] = []
    storage.enumerateAttributes(
      in: NSRange(location: 0, length: storage.length), options: []
    ) { attributes, range, _ in
      let run = ColourRun(
        range: range,
        foreground: attributes[.foregroundColor] as? NSColor,
        background: attributes[.backgroundColor] as? NSColor)
      if let last = runs.last, last.foreground == run.foreground,
        last.background == run.background, NSMaxRange(last.range) == range.location
      {
        runs[runs.count - 1] = ColourRun(
          range: NSRange(location: last.range.location, length: last.range.length + range.length),
          foreground: last.foreground, background: last.background)
      } else {
        runs.append(run)
      }
    }
    return runs
  }

  @MainActor
  private func assertCensusMatches(
    _ actual: [ColourRun], _ expected: [ColourRun], _ context: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    guard actual != expected else { return }
    let differences = zip(actual, expected).enumerated()
      .filter { $0.element.0 != $0.element.1 }
      .prefix(6)
      .map { "  run \($0.offset): got \($0.element.0)\n        want \($0.element.1)" }
      .joined(separator: "\n")
    XCTFail(
      "\(context): the document's colouring is not what it was.\n"
        + "runs now=\(actual.count) before=\(expected.count)\n\(differences)",
      file: file, line: line)
  }

  /// Runs that carry a background, which is what inline code and `==highlight==`
  /// are drawn with — and what a find wash overwrites.
  private func backgroundRuns(_ census: [ColourRun]) -> [ColourRun] {
    census.filter { $0.background != nil }
  }

  // MARK: - Pin 1 — formatted backgrounds survive the whole session

  @MainActor
  func testInlineCodeAndHighlightKeepTheirBackgroundBeforeDuringAndAfterFind() throws {
    let surface = makeSurface(text: formattedDocument())

    let before = colourCensus(surface)
    let formattedBefore = backgroundRuns(before)
    XCTAssertFalse(
      formattedBefore.isEmpty,
      "precondition: the fixture must actually carry highlighter backgrounds — a "
        + "plain-prose fixture cannot detect this bug at all")

    // DURING the session: outside the matches nothing may change. The matches
    // themselves are washed, which is the point of the feature.
    surface.updateFind(query: "target", visible: true)
    let during = colourCensus(surface)
    let matchRanges = (surface.textStorage.string as NSString).ranges(of: "target")
    XCTAssertEqual(matchRanges.count, 3, "precondition: plain, inline-code and highlight matches")

    for run in formattedBefore {
      let untouched = matchRanges.allSatisfy { NSIntersectionRange($0, run.range).length == 0 }
      guard untouched else { continue }
      let survivor = during.first {
        NSIntersectionRange($0.range, run.range).length > 0 && $0.background == run.background
      }
      XCTAssertNotNil(
        survivor,
        "an open find session stripped the background off \(run) even though no match "
          + "touches it")
    }

    // AFTER the session: byte-for-byte the document it started from.
    surface.updateFind(query: "", visible: false)
    assertCensusMatches(colourCensus(surface), before, "after the find session closed")
  }

  // MARK: - Pin 2 — edits before, inside and after a match

  @MainActor
  func testInsertingAboveTheMatchesDoesNotMisplaceTheRestoredColouring() throws {
    try assertColouringSurvives(
      "inserting above every match",
      edit: { surface in
        surface.textStorage.replaceCharacters(
          in: NSRange(location: 0, length: 0), with: "PREFIX WSTAWIONY NA POCZATKU\n")
      })
  }

  @MainActor
  func testDeletingAboveTheMatchesDoesNotMisplaceTheRestoredColouring() throws {
    try assertColouringSurvives(
      "deleting above every match",
      edit: { surface in
        // Drop the first word of the document — everything below slides up.
        surface.textStorage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "")
      })
  }

  @MainActor
  func testEditingInsideAMatchDoesNotMisplaceTheRestoredColouring() throws {
    try assertColouringSurvives(
      "typing inside the first match",
      edit: { surface in
        let match = (surface.textStorage.string as NSString).range(of: "target")
        surface.textStorage.replaceCharacters(
          in: NSRange(location: match.location + 3, length: 0), with: "XX")
      })
  }

  @MainActor
  func testEditingAfterEveryMatchDoesNotMisplaceTheRestoredColouring() throws {
    try assertColouringSurvives(
      "appending below every match",
      edit: { surface in
        surface.textStorage.replaceCharacters(
          in: NSRange(location: surface.textStorage.length, length: 0), with: "\nOGON DOPISANY")
      })
  }

  /// Open a find session, edit the document underneath it, close the session —
  /// then demand that the colouring equals a clean highlight of the very same
  /// final text. Anything else means the teardown put the highlighter's captured
  /// colouring back at the wrong offsets, or cleared a background it never
  /// covered.
  @MainActor
  private func assertColouringSurvives(
    _ context: String, edit: (MarkdownEditorSurface) -> Void,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let surface = makeSurface(text: formattedDocument())
    XCTAssertFalse(
      backgroundRuns(colourCensus(surface)).isEmpty,
      "precondition: the fixture must carry highlighter backgrounds", file: file, line: line)

    surface.updateFind(query: "target", visible: true)
    edit(surface)
    surface.textContentStorage.refreshHighlighting()
    surface.updateFind(query: "", visible: false)

    let finalText = surface.textStorage.string
    let reference = makeSurface(text: finalText)

    assertCensusMatches(
      colourCensus(surface), colourCensus(reference),
      "after \(context) with the find bar open", file: file, line: line)
  }

  // MARK: - Pin 3 — the teardown alone, with no rehighlight to hide behind

  /// The pins above let a full `refreshHighlighting()` run after the edit, which
  /// is generous: that pass drops the wash records wholesale and repaints the
  /// document, so it papers over a teardown working from stale offsets. Here the
  /// teardown stands on its own, and the oracle is structural rather than a
  /// comparison against a reference render — it asks the one question a stale
  /// offset cannot survive: is there any background left on text that is not
  /// inline code or a `==highlight==`, and is the background under those spans
  /// still whole?
  @MainActor
  func testTheTeardownAloneLeavesBackgroundOnlyOnTheFormattedSpans() throws {
    for scenario in EditScenario.all {
      let surface = makeSurface(text: formattedDocument())
      surface.updateFind(query: "target", visible: true)
      scenario.apply(surface)
      // Deliberately NO refreshHighlighting() here.
      surface.updateFind(query: "", visible: false)

      let text = surface.textStorage.string as NSString
      let formatted = formattedSpans(in: text)
      XCTAssertFalse(formatted.isEmpty, "precondition: \(scenario.name) keeps formatted spans")

      for run in backgroundRuns(colourCensus(surface)) {
        let inside = formatted.contains {
          NSIntersectionRange($0, run.range).length == run.range.length
        }
        XCTAssertTrue(
          inside,
          "\(scenario.name): background survives at \(run) — on text that is neither inline "
            + "code nor a highlight. The wash was taken off at offsets that no longer "
            + "describe where it was painted, so it was cleared from the wrong characters "
            + "and left behind on these.")
      }

      for span in formatted {
        let covering = colourCensus(surface).filter {
          NSIntersectionRange($0.range, span).length > 0
        }
        let bare = covering.filter { $0.background == nil }
        XCTAssertTrue(
          bare.isEmpty,
          "\(scenario.name): the formatted span \(NSStringFromRange(span)) has a hole in its "
            + "background at \(bare.map(\.description).joined(separator: ", ")) — the wash "
            + "cleared it and never gave it back")
      }
    }
  }

  private struct EditScenario {
    let name: String
    let apply: @MainActor (MarkdownEditorSurface) -> Void

    static var all: [EditScenario] {
      [
        EditScenario(name: "insert above every match") { surface in
          surface.textStorage.replaceCharacters(
            in: NSRange(location: 0, length: 0), with: "PREFIX WSTAWIONY\n")
        },
        EditScenario(name: "delete above every match") { surface in
          surface.textStorage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "")
        },
        EditScenario(name: "append below every match") { surface in
          surface.textStorage.replaceCharacters(
            in: NSRange(location: surface.textStorage.length, length: 0), with: "\nOGON")
        },
      ]
    }
  }

  /// The spans the highlighter gives a background of its own, located in the
  /// text as it stands now: `` `inline code` `` and `==highlight==`.
  private func formattedSpans(in text: NSString) -> [NSRange] {
    var spans: [NSRange] = []
    for pattern in ["`[^`\n]+`", "==[^=\n]+=="] {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let whole = NSRange(location: 0, length: text.length)
      for match in regex.matches(in: text as String, range: whole) {
        spans.append(match.range)
      }
    }
    return spans
  }

  // MARK: - Pin 4 — a query change leaves no trace behind

  /// The refresh path, not the teardown: changing the query retires some washes
  /// and paints others in the same pass. Every retired one has to give back what
  /// it covered, at the offsets it actually covered.
  @MainActor
  func testChangingTheQueryRestoresEveryRetiredWashExactly() throws {
    let surface = makeSurface(text: formattedDocument())
    let before = colourCensus(surface)

    surface.updateFind(query: "target", visible: true)
    surface.updateFind(query: "Akapit", visible: true)
    surface.updateFind(query: "tresc", visible: true)
    surface.updateFind(query: "target", visible: true)
    surface.updateFind(query: "", visible: false)

    assertCensusMatches(colourCensus(surface), before, "after cycling through four queries")
  }
}

extension NSString {
  /// Every occurrence of `needle`, in document order.
  fileprivate func ranges(of needle: String) -> [NSRange] {
    var found: [NSRange] = []
    var searchRange = NSRange(location: 0, length: length)
    while searchRange.length > 0 {
      let hit = range(of: needle, options: [], range: searchRange)
      guard hit.location != NSNotFound, hit.length > 0 else { break }
      found.append(hit)
      let next = NSMaxRange(hit)
      searchRange = NSRange(location: next, length: length - next)
    }
    return found
  }
}
