import AppKit
import XCTest

@testable import Pensieve

/// Deterministic probe for the "beachball while typing in the find bar" hang.
///
/// Root cause under test: on a large document a common query yields thousands
/// of matches, and the highlight pass used to issue one unbatched
/// `textStorage.addAttribute` per match (plus a full-range remove) — each a
/// separate TextKit edit transaction with its own layout invalidation, all on
/// the main thread. The oracle is the number of `didProcessEditing`
/// transactions, not wall-clock time, so the probe stays deterministic.
final class FindHighlightBatchingTests: XCTestCase {

  private static let matchCount = 2000

  /// A document with `matchCount` occurrences of the query "needle".
  private func haystackDocument() -> String {
    Array(repeating: "needle in the hay.", count: Self.matchCount)
      .joined(separator: "\n")
  }

  @MainActor
  private func makeHostedSurface(text: String) -> (MarkdownEditorSurface, NSWindow) {
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.contentView = surface.scrollView
    surface.scrollView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
    surface.scrollView.layoutSubtreeIfNeeded()
    return (surface, window)
  }

  @MainActor
  private func countEditTransactions(
    of textStorage: NSTextStorage, during work: () -> Void
  ) -> Int {
    var count = 0
    let observer = NotificationCenter.default.addObserver(
      forName: NSTextStorage.didProcessEditingNotification,
      object: textStorage,
      queue: nil
    ) { _ in count += 1 }
    defer { NotificationCenter.default.removeObserver(observer) }
    work()
    return count
  }

  /// One keystroke in the find field must cost O(1) edit transactions, not
  /// O(matches): every transaction invalidates layout on the main thread, and
  /// thousands of them per keystroke are the beachball.
  @MainActor
  func test_find_highlighting_batches_attribute_edits() throws {
    let (surface, window) = makeHostedSurface(text: haystackDocument())
    defer { window.contentView = nil }

    let transactions = countEditTransactions(of: surface.textStorage) {
      surface.updateFind(query: "needle", visible: true)
    }

    XCTAssertLessThanOrEqual(
      transactions, 2,
      "find highlighting issued \(transactions) text-storage edit transactions "
        + "for \(Self.matchCount) matches — unbatched per-match attribute edits "
        + "relayout the document once per match (the find-bar beachball)"
    )
    // The batching must not lose the highlight itself.
    var effective = NSRange()
    let attr = surface.textStorage.attribute(
      .backgroundColor, at: 0, effectiveRange: &effective)
    XCTAssertNotNil(attr, "batched find pass no longer applies match highlights")
  }

  /// SwiftUI re-renders call `updateFind` with an unchanged query on every
  /// pass (focus changes, published churn). An unchanged find state must not
  /// touch the text storage at all — re-applying thousands of attributes per
  /// render pass is the same hang through a second door.
  @MainActor
  func test_unchanged_find_rerender_does_not_touch_text_storage() throws {
    let (surface, window) = makeHostedSurface(text: haystackDocument())
    defer { window.contentView = nil }

    surface.updateFind(query: "needle", visible: true)

    let transactions = countEditTransactions(of: surface.textStorage) {
      surface.updateFind(query: "needle", visible: true)
      surface.updateFind(query: "needle", visible: true)
    }

    XCTAssertEqual(
      transactions, 0,
      "re-render with an unchanged find query issued \(transactions) "
        + "text-storage edits — highlights are already on screen and must not "
        + "be re-applied per SwiftUI render pass"
    )
  }
}
