import XCTest

@testable import Pensieve

/// What the two "nothing open yet" surfaces are MADE OF, pinned from the two
/// decisions the empty launcher was click-tested into (KT-2, KT-3):
///
/// - the sidebar and the detail pane were each drawing the same Recent list, so
///   the empty launcher showed one history twice, a column apart;
/// - a shortcut was one key cap holding every glyph, pinned into a fixed 44 pt
///   frame — which fits "⌘O" and wraps "⌘⇧O" onto a second visual row.
///
/// Neither is measurable from a unit test: SwiftUI does not hand back a laid-out
/// tree here, and text wrapping is a rendering outcome. So both are pinned one
/// level below the pixels — at the composition that produces them.
@MainActor
final class EmptyStateCompositionTests: XCTestCase {

  // MARK: - KT-2 — one Recent list, in the launcher

  /// The sidebar's empty state must not construct `EmptyStateRecents`.
  ///
  /// Pinned against the SOURCE because the sidebar block is a `private var` of a
  /// SwiftUI view: there is no runtime handle on its children, and the
  /// accessibility tree only tells the truth about it in a running app (which is
  /// where `scripts/ui-smoke.sh` checks it — but only on a fresh profile, where
  /// the history is empty and both lists render nothing either way).
  func testSidebarEmptyStateDoesNotDrawTheRecentList() throws {
    let sidebar = try Self.source(of: "Sidebar/SidebarView.swift")
    let emptyState = try XCTUnwrap(
      Self.declarationBody(named: "private var emptyState: some View {", in: sidebar),
      "the sidebar's empty-state block has moved; re-point this pin before trusting it")

    XCTAssertTrue(
      emptyState.contains("EmptyStateShortcuts("),
      "the wordmark and the shortcuts stay — the decision named the Recents list only")
    XCTAssertFalse(
      emptyState.contains("EmptyStateRecents"),
      "the sidebar empty state must not draw a second copy of the launcher's Recent list")
  }

  /// …and nothing else picked the list up either: the detail pane is its only
  /// host, so a future surface adding a second copy trips this rather than
  /// shipping the duplicate again.
  func testTheRecentListHasExactlyOneHost() throws {
    let hosts = try Self.sourceFiles()
      .filter { try Self.source(ofFile: $0).contains("EmptyStateRecents(") }
      .map { $0.lastPathComponent }
      .sorted()

    XCTAssertEqual(
      hosts, ["ContentView.swift"],
      "the empty launcher shows one Recent list, drawn by the detail pane")
  }

  // MARK: - KT-3 — one cap per key, no fixed key column

  /// Every shortcut splits into single-key caps, and the split loses nothing.
  ///
  /// `ShortcutKeyCap.glyph` is a `Character`, so "a cap holding two glyphs" is
  /// not expressible; what this guards is the SPLIT that feeds those caps, and
  /// that the fixture still contains the three-key shortcut the fixed frame used
  /// to wrap.
  func testEveryShortcutSplitsIntoItsIndividualKeys() {
    XCTAssertFalse(EmptyStateShortcuts.shortcuts.isEmpty)

    for shortcut in EmptyStateShortcuts.shortcuts {
      let glyphs = EmptyStateShortcuts.keyGlyphs(in: shortcut.symbols)
      XCTAssertEqual(
        String(glyphs), shortcut.symbols,
        "\(shortcut.label): the caps together must still read as the shortcut, in order")
    }

    XCTAssertTrue(
      EmptyStateShortcuts.shortcuts.contains {
        EmptyStateShortcuts.keyGlyphs(in: $0.symbols).count >= 3
      },
      "the pin is only worth having while the block still carries the shortcut that wrapped")
  }

  /// …and the cluster really draws that split: one `ShortcutKeyCap` per key, not
  /// one cap handed the whole symbol string.
  func testTheClusterDrawsOneCapPerKey() throws {
    let chrome = try Self.source(of: "App/EmptyStateChrome.swift")
    let cluster = try XCTUnwrap(
      Self.declarationBody(
        named: "private func keyCapCluster(for symbols: String) -> some View {", in: chrome),
      "the key-cap cluster has moved; re-point this pin before trusting it")

    XCTAssertTrue(
      cluster.contains("keyGlyphs(in: symbols)"),
      "the caps must come from the per-key split, or a longer shortcut overflows one cap again")
    XCTAssertTrue(
      cluster.contains("ForEach") && cluster.contains("ShortcutKeyCap(glyph: glyph"),
      "one cap per key: the cluster iterates the glyphs instead of drawing a single cap")
  }

  /// The key column sizes itself from the widest cluster in the block. A
  /// hardcoded width is exactly the bug this cut removed — the next shortcut one
  /// key longer would overflow it again.
  func testTheKeyColumnIsNotPinnedToAFixedWidth() throws {
    let chrome = try Self.source(of: "App/EmptyStateChrome.swift")
    let shortcutRow = try XCTUnwrap(
      Self.declarationBody(
        named: "private func shortcutRow(_ shortcut: Shortcut) -> some View {", in: chrome),
      "the shortcut row has moved; re-point this pin before trusting it")

    XCTAssertFalse(
      shortcutRow.contains(".frame(width:"),
      "the key column must grow with its widest cluster, not sit in a magic width")
  }

  // MARK: - KT-3, the two rows the fixed frame was hiding

  /// The label cannot wrap at the narrowest sidebar the app allows.
  ///
  /// `ContentView` declares that column's minimum at 180 pt and `SidebarView`
  /// spends 28 of them on padding, so the widest row gets 152 — less than the
  /// three-cap cluster plus "Open Folder" asks for. The caps cannot compress
  /// (each is sized to its glyph), so an unconstrained `Text` takes the only
  /// escape it has and breaks after "Open": the same two-line row KT-3 removed,
  /// one view further along. Pinned at the composition like everything else
  /// here — the wrap itself is a rendering outcome.
  func testTheShortcutLabelCannotWrapInTheNarrowestSidebar() throws {
    let chrome = try Self.source(of: "App/EmptyStateChrome.swift")
    let shortcutRow = try XCTUnwrap(
      Self.declarationBody(
        named: "private func shortcutRow(_ shortcut: Shortcut) -> some View {", in: chrome),
      "the shortcut row has moved; re-point this pin before trusting it")

    XCTAssertTrue(
      shortcutRow.contains(".lineLimit(1)"),
      "one line per row: wrapping is the exact bug this block was rebuilt to remove")
    XCTAssertTrue(
      shortcutRow.contains(".minimumScaleFactor("),
      "…and it shrinks to fit rather than truncating, so the whole word survives 180 pt")
  }

  /// One VoiceOver stop per row, not one per cap.
  ///
  /// The measuring copies are hidden from accessibility already, but that only
  /// silences the copies: the VISIBLE caps are still separate `Text`s, and a row
  /// that lets them compose themselves is announced as "⌘", "⇧", "O" and the
  /// label in four separate stops, each read as a bare symbol.
  func testEachShortcutRowIsAnnouncedAsASingleElement() throws {
    let chrome = try Self.source(of: "App/EmptyStateChrome.swift")
    let shortcutRow = try XCTUnwrap(
      Self.declarationBody(
        named: "private func shortcutRow(_ shortcut: Shortcut) -> some View {", in: chrome),
      "the shortcut row has moved; re-point this pin before trusting it")

    XCTAssertTrue(
      shortcutRow.contains(".accessibilityElement(children: .ignore)"),
      "the row publishes itself, or every cap becomes its own focus stop")
    XCTAssertTrue(
      shortcutRow.contains(".accessibilityLabel(Self.spokenLabel(for: shortcut))"),
      "…carrying the spoken sentence, since ignoring the children drops their text")
  }

  /// And that sentence names the modifiers instead of handing over their glyphs.
  func testTheSpokenLabelNamesEveryModifierAndKeepsTheAction() {
    XCTAssertEqual(
      EmptyStateShortcuts.spokenLabel(
        for: EmptyStateShortcuts.Shortcut(
          symbols: "⌘⇧O", label: "Open Folder", isAction: false)),
      "Command Shift O, Open Folder")

    for shortcut in EmptyStateShortcuts.shortcuts {
      let spoken = EmptyStateShortcuts.spokenLabel(for: shortcut)

      XCTAssertTrue(
        spoken.hasSuffix(shortcut.label),
        "\(shortcut.label): the row still says what the shortcut DOES, last")

      for glyph in EmptyStateShortcuts.keyGlyphs(in: shortcut.symbols)
      where !glyph.isLetter && !glyph.isNumber {
        XCTAssertFalse(
          spoken.contains(glyph),
          "\(shortcut.label): \(glyph) reaches a screen reader as a word, never as the glyph")
      }
    }
  }

  // MARK: - Source access

  private static func packageRoot() -> URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  private static func source(of relativePath: String) throws -> String {
    try source(
      ofFile: packageRoot().appendingPathComponent("Sources/Pensieve/\(relativePath)"))
  }

  private static func source(ofFile url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }

  private static func sourceFiles() throws -> [URL] {
    let root = packageRoot().appendingPathComponent("Sources/Pensieve")
    let enumerator = try XCTUnwrap(
      FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
  }

  /// The brace-balanced body that follows `header`, so a pin reads the ONE
  /// declaration it means rather than the whole file.
  private static func declarationBody(named header: String, in source: String) -> String? {
    guard let headerRange = source.range(of: header) else { return nil }
    var depth = 1
    var body = ""
    for character in source[headerRange.upperBound...] {
      if character == "{" { depth += 1 }
      if character == "}" {
        depth -= 1
        if depth == 0 { return body }
      }
      body.append(character)
    }
    return nil
  }
}
