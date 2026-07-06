import AppKit
import XCTest

@testable import Pensieve

/// Pins the floating-format-bar positioning seam: `accessoryOrigin` /
/// `clampedAccessoryOrigin` were made pure precisely so this contract could be
/// tested, and `accessoryAllowedRect` is the chrome boundary that keeps the
/// bar from ghosting through the translucent titlebar (same
/// `contentLayoutRect` rule as the preview glass strip).
@MainActor
final class FormattingAccessoryPlacementTests: XCTestCase {
  private let barSize = NSSize(width: 200, height: 32)

  // MARK: - accessoryOrigin (flipped — NSTextView coordinate space)

  func testFlippedPlacementPrefersAboveSelection() {
    let allowed = NSRect(x: 0, y: 30, width: 800, height: 600)
    let selection = NSRect(x: 100, y: 200, width: 120, height: 18)

    let origin = MarkdownTextView.accessoryOrigin(
      for: selection, size: barSize, allowed: allowed, isFlipped: true)

    // minY(200) - height(32) - gap(6) = 162, comfortably inside `allowed`.
    XCTAssertEqual(origin, NSPoint(x: 100, y: 162))
  }

  func testFlippedPlacementDropsBelowWhenAnchorHugsChromeEdge() {
    let allowed = NSRect(x: 0, y: 30, width: 800, height: 600)
    let selection = NSRect(x: 100, y: 40, width: 120, height: 18)

    let origin = MarkdownTextView.accessoryOrigin(
      for: selection, size: barSize, allowed: allowed, isFlipped: true)

    // Above would land at 40-32-6 = 2 < allowed.minY(30) → drop below:
    // maxY(58) + gap(6) = 64.
    XCTAssertEqual(origin, NSPoint(x: 100, y: 64))
  }

  func testFlippedPlacementIsPinnedIntoAllowedWhenSelectionSitsUnderChrome() {
    let allowed = NSRect(x: 0, y: 30, width: 800, height: 600)
    // A selection that scrolled under the toolbar: both above (−38) and
    // below (24) land in chrome; the final pin must hold the line at 30.
    let selection = NSRect(x: 100, y: 0, width: 120, height: 18)

    let origin = MarkdownTextView.accessoryOrigin(
      for: selection, size: barSize, allowed: allowed, isFlipped: true)

    XCTAssertEqual(origin.y, allowed.minY)
  }

  // MARK: - accessoryOrigin (unflipped)

  func testUnflippedPlacementPrefersBelowSelection() {
    let allowed = NSRect(x: 0, y: 0, width: 800, height: 600)
    let selection = NSRect(x: 100, y: 100, width: 120, height: 18)

    let origin = MarkdownTextView.accessoryOrigin(
      for: selection, size: barSize, allowed: allowed, isFlipped: false)

    // maxY(118) + gap(6) = 124.
    XCTAssertEqual(origin, NSPoint(x: 100, y: 124))
  }

  func testUnflippedPlacementFlipsAboveAtBottomEdge() {
    let allowed = NSRect(x: 0, y: 0, width: 800, height: 600)
    let selection = NSRect(x: 100, y: 550, width: 120, height: 18)

    let origin = MarkdownTextView.accessoryOrigin(
      for: selection, size: barSize, allowed: allowed, isFlipped: false)

    // Below would end at 574+32 = 606 > 600 → above: 550-32-6 = 512.
    XCTAssertEqual(origin, NSPoint(x: 100, y: 512))
  }

  // MARK: - clampedAccessoryOrigin

  func testClampPinsRunawayOriginInsideAllowedRect() {
    let allowed = NSRect(x: 0, y: 0, width: 800, height: 600)

    let clamped = MarkdownTextView.clampedAccessoryOrigin(
      NSPoint(x: 900, y: 700), size: barSize, allowed: allowed)

    XCTAssertEqual(clamped, NSPoint(x: 800 - 200 - 4, y: 600 - 32))
  }

  func testClampRespectsLeadingAndTopMinimums() {
    let allowed = NSRect(x: 50, y: 30, width: 800, height: 600)

    let clamped = MarkdownTextView.clampedAccessoryOrigin(
      NSPoint(x: -500, y: -500), size: barSize, allowed: allowed)

    XCTAssertEqual(clamped, NSPoint(x: allowed.minX + 4, y: allowed.minY))
  }

  func testClampDegeneratesToLeadingEdgeWhenBarOutgrowsAllowedRect() {
    // A window narrower/shorter than the bar must not produce inverted
    // min/max bounds — the bar pins to the leading/top edge instead.
    let allowed = NSRect(x: 10, y: 20, width: 100, height: 20)

    let clamped = MarkdownTextView.clampedAccessoryOrigin(
      NSPoint(x: 500, y: 500), size: barSize, allowed: allowed)

    XCTAssertEqual(clamped, NSPoint(x: allowed.minX + 4, y: allowed.minY))
  }

  // MARK: - accessoryAllowedRect (chrome truth)

  func testAllowedRectWithoutWindowFallsBackToVisibleRect() {
    let surface = MarkdownEditorSurface(text: "hello chrome", fontSize: 14)
    surface.scrollView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
    surface.scrollView.layoutSubtreeIfNeeded()

    XCTAssertEqual(
      surface.textView.accessoryAllowedRect(), surface.textView.visibleRect)
  }

  func testAllowedRectExcludesTitlebarChromeInFullSizeContentWindow() {
    let surface = MarkdownEditorSurface(text: "hello chrome", fontSize: 14)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = surface.scrollView
    surface.scrollView.frame = window.contentView?.bounds ?? .zero
    surface.scrollView.layoutSubtreeIfNeeded()

    let textView = surface.textView
    let visible = textView.visibleRect
    let allowed = textView.accessoryAllowedRect()

    // With a full-size content view the text view underlaps the titlebar, so
    // the allowed region must start BELOW the chrome edge (flipped coords:
    // larger minY), not at the raw visible-rect top.
    XCTAssertGreaterThan(
      allowed.minY, visible.minY,
      "allowed rect must exclude the titlebar band the visible rect underlaps")
    XCTAssertEqual(allowed.maxY, visible.maxY, accuracy: 0.5)
    XCTAssertFalse(allowed.isEmpty)

    // And the chrome edge it found is exactly the window's contentLayoutRect.
    let contentTop = textView.convert(window.contentLayoutRect, from: nil).minY
    XCTAssertEqual(allowed.minY, contentTop, accuracy: 0.5)
  }
}
