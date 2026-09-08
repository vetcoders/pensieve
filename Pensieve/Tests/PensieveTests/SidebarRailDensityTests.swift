import XCTest

@testable import Pensieve

/// KT-6: with a few levels of subfolders the workspace tree truncated filenames
/// so hard that even at the widest sidebar the distinguishing part was gone
/// (`2026-06-04_t…`). Two causes, both in the row's leading budget:
///
/// 1. every nesting level ate 22 pt of a column whose minimum is 180 pt, so a
///    depth-5 row had ~13 pt left for its title;
/// 2. the titles elided from the TAIL, which for date-prefixed names throws
///    away the only part that differs between siblings.
///
/// A laid-out SwiftUI sidebar is not reachable from the test target (no window,
/// no `NSHostingView` geometry to measure), so these are source-reading
/// structural pins in the style of `BuildIdentityTests`: they read the shipped
/// declarations and assert the decision points, not the pixels.
final class SidebarRailDensityTests: XCTestCase {

  // MARK: - The pins

  /// Every row title in the sidebar tree elides from the middle, so a name keeps
  /// both its head (the date) and its tail (the part that identifies it).
  func testEveryTreeRowTitleElidesFromTheMiddle() throws {
    let source = try sidebarSource()

    assertMiddleTruncated(
      "Text(title)",
      in: try body(of: "private func renameableTitle(", in: source),
      because: "the shared title of folder, document and Open Files rows")
    assertMiddleTruncated(
      "Text(node.name)",
      in: try body(of: "private func foreignFileRow(", in: source),
      because: "a non-markdown file is named on exactly the same conventions")

    let searchRow = try body(of: "private func searchResultRow(", in: source)
    assertMiddleTruncated(
      "Text(result.title)", in: searchRow, because: "a search hit is a row title too")
    assertMiddleTruncated(
      "Text(result.displayPath)", in: searchRow,
      because: "a path's informative ends are its first and last segments")

    // The counterweight: this is elision for identifiers, not a house style.
    // Prose still reads from the head, so the snippet must NOT be middle-elided
    // — otherwise the pins above would pass for a blanket sweep that broke it.
    XCTAssertFalse(
      modifierChain(after: "Text(snippet)", in: searchRow).contains(".truncationMode(.middle)"),
      "a match snippet reads from its head; middle elision would gut the sentence")
  }

  /// The foreign-file row is laid out on the shared indent path, not on a
  /// private copy of the depth math. Its old `depth * 14 + 15` drifted from
  /// `indentStep`, so a non-markdown file sat at a different x than the
  /// documents directly above and below it, and it drew no guides at all.
  func testForeignFileRowIsBuiltOnTheSharedIndentPath() throws {
    let source = try sidebarSource()
    let foreignRow = try body(of: "private func foreignFileRow(", in: source)

    XCTAssertFalse(
      foreignRow.contains("padding(.leading"),
      "a hand-rolled leading pad is exactly the drift this row is supposed to have lost")
    XCTAssertFalse(
      foreignRow.contains("CGFloat(depth)"),
      "per-level width belongs to indentStep, not to this row")

    // Visual parity is a structural claim here: identical leading recipe ⇒ a
    // foreign file at depth N left-aligns its icon with a document at depth N.
    let leadingRecipe = [
      "HStack(spacing: 5)",
      "indentGuides(depth: depth)",
      "Color.clear.frame(width: Self.disclosureWidth)",
      "Image(systemName: \"doc.text\")",
    ]
    let documentRow = try body(of: "private func nodeRow(", in: source)
    for step in leadingRecipe {
      XCTAssertTrue(
        documentRow.contains(step),
        "the document row is the reference layout; it lost \(step)")
      XCTAssertTrue(
        foreignRow.contains(step),
        "a foreign file must reach its icon the same way a document does; missing \(step)")
    }
    for row in [documentRow, foreignRow] {
      XCTAssertTrue(
        row.contains(".padding(.horizontal, 6)"),
        "both rows must start from the same row inset or the shared recipe still misaligns")
    }
  }

  /// `indentStep` is the single source of per-level indent: no other depth-scaled
  /// literal survives anywhere in the file, and only the guide builder spends it.
  func testIndentStepIsTheSoleSourceOfPerLevelIndent() throws {
    let source = try sidebarSource()

    let depthMath = "(depth[^\\n]{0,12}\\*)|(\\*[^\\n]{0,12}depth)"
    for line in code(of: source)
    where line.range(of: depthMath, options: [.regularExpression]) != nil {
      XCTFail(
        "depth-scaled arithmetic outside indentGuides: \(line.trimmingCharacters(in: .whitespaces))"
      )
    }

    XCTAssertEqual(
      source.components(separatedBy: "Self.indentStep").count - 1, 1,
      "exactly one consumer — the guide column in indentGuides(depth:)")
    XCTAssertTrue(
      try body(of: "private func indentGuides(", in: source).contains("Self.indentStep"),
      "…and that one consumer is the guide builder")
  }

  /// The budget the whole cut exists for: at the sidebar's MINIMUM column width,
  /// a depth-5 row must still leave a usable strip for the filename. Constants
  /// are read from the two files that own them so this cannot pass against a
  /// stale copy of the numbers.
  func testDepthFiveRowKeepsAReadableTitleBudgetAtMinimumSidebarWidth() throws {
    let source = try sidebarSource()
    let indentStep = try constant("indentStep", in: source)
    let disclosureWidth = try constant("disclosureWidth", in: source)
    let minimumColumnWidth = try minimumSidebarWidth()

    // Row chrome ahead of and behind the title: 6 pt inset on each side, three
    // 5 pt HStack gaps (guides|chevron|icon|title) and the icon itself. The
    // glyph is an SF Symbol with no source-side width; 16 pt is its rendered
    // size at this row's font and is the only estimate in the sum.
    let iconWidth: Double = 16
    let chrome = 6 + 5 + disclosureWidth + 5 + iconWidth + 5 + 6
    let rail = 5 * indentStep
    let titleBudget = minimumColumnWidth - rail - chrome

    XCTAssertGreaterThanOrEqual(
      titleBudget, 60,
      """
      depth 5 at the minimum column width leaves \(titleBudget) pt for the filename \
      (rail \(rail) pt + chrome \(chrome) pt of \(minimumColumnWidth) pt) — under ~60 pt \
      a date-prefixed name has nothing left to distinguish it
      """)
    XCTAssertGreaterThanOrEqual(
      indentStep, 8,
      "the guides are the depth cue; a column this narrow stops reading as a rail")
  }

  // MARK: - Source access

  private var packageRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private func sidebarSource() throws -> String {
    try String(
      contentsOf: packageRoot.appendingPathComponent("Sources/Pensieve/Sidebar/SidebarView.swift"),
      encoding: .utf8)
  }

  private func minimumSidebarWidth() throws -> Double {
    let contentView = try String(
      contentsOf: packageRoot.appendingPathComponent("Sources/Pensieve/App/ContentView.swift"),
      encoding: .utf8)
    guard
      let match = contentView.range(
        of: "navigationSplitViewColumnWidth\\(min: [0-9]+", options: [.regularExpression]),
      let width = Double(
        contentView[match].components(separatedBy: " ").last ?? "")
    else {
      XCTFail("ContentView no longer declares a minimum sidebar column width")
      throw CocoaError(.fileReadUnknown)
    }
    return width
  }

  private func constant(_ name: String, in source: String) throws -> Double {
    guard
      let match = source.range(
        of: "let \(name): CGFloat = [0-9.]+", options: [.regularExpression]),
      let value = Double(source[match].components(separatedBy: " ").last ?? "")
    else {
      XCTFail("SidebarView no longer declares \(name) as a CGFloat constant")
      throw CocoaError(.fileReadUnknown)
    }
    return value
  }

  /// The source of one declaration, from its signature down to the closing brace
  /// at type-member indentation.
  private func body(of declaration: String, in source: String) throws -> String {
    let lines = source.components(separatedBy: "\n")
    guard let start = lines.firstIndex(where: { $0.contains(declaration) }) else {
      XCTFail("SidebarView no longer declares `\(declaration)`")
      throw CocoaError(.fileReadUnknown)
    }
    guard let end = lines[start...].firstIndex(of: "  }") else {
      XCTFail("could not find the end of `\(declaration)`")
      throw CocoaError(.fileReadUnknown)
    }
    return lines[start...end].joined(separator: "\n")
  }

  /// The modifier lines applied to `expression`, i.e. the run of `.foo(…)` lines
  /// directly beneath it.
  private func modifierChain(after expression: String, in body: String) -> [String] {
    let lines = body.components(separatedBy: "\n").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    guard let start = lines.firstIndex(of: expression) else { return [] }
    return Array(lines[(start + 1)...].prefix { $0.hasPrefix(".") })
  }

  /// The source lines with `//` commentary stripped — a pin about the code must
  /// not be satisfied (or tripped) by prose that merely quotes it.
  private func code(of source: String) -> [String] {
    source.components(separatedBy: "\n").map { line in
      guard let comment = line.range(of: "//") else { return line }
      return String(line[line.startIndex..<comment.lowerBound])
    }
  }

  private func assertMiddleTruncated(
    _ expression: String, in body: String, because reason: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let chain = modifierChain(after: expression, in: body)
    XCTAssertFalse(
      chain.isEmpty, "\(expression) not found (or carries no modifiers) — \(reason)",
      file: file, line: line)
    XCTAssertTrue(
      chain.contains(".lineLimit(1)"),
      "\(expression) must stay a single line for middle elision to mean anything — \(reason)",
      file: file, line: line)
    XCTAssertTrue(
      chain.contains(".truncationMode(.middle)"),
      "\(expression) still elides from the tail, which drops the distinguishing suffix — \(reason)",
      file: file, line: line)
  }
}
