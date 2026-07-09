import AppKit
import XCTest

@testable import Pensieve

final class WindowChromeRecipeTests: XCTestCase {
  @MainActor
  func testAppKitRecipeAppliesUnifiedDocumentChrome() {
    let window = NSWindow(
      contentRect: WindowChromeRecipe.defaultContentRect,
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false
    )
    defer { window.close() }

    WindowChromeRecipe.apply(to: window, title: "Chrome Probe")

    XCTAssertTrue(window.styleMask.contains(.titled))
    XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
    XCTAssertEqual(window.toolbarStyle, WindowChromeRecipe.toolbarStyle)
    XCTAssertEqual(window.tabbingMode, .preferred)
    XCTAssertEqual(window.tabbingIdentifier, WindowChromeRecipe.documentTabbingIdentifier)
    XCTAssertEqual(window.title, "Chrome Probe")
    XCTAssertFalse(window.isReleasedWhenClosed)
    XCTAssertEqual(window.contentMinSize.width, WindowChromeRecipe.minimumContentSize.width)
    XCTAssertEqual(window.contentMinSize.height, WindowChromeRecipe.minimumContentSize.height)
  }

  func testRecipePinsSharedDocumentWindowGeometry() {
    XCTAssertEqual(WindowChromeRecipe.defaultContentSize.width, 1180)
    XCTAssertEqual(WindowChromeRecipe.defaultContentSize.height, 760)
    XCTAssertEqual(WindowChromeRecipe.minimumContentSize.width, 720)
    XCTAssertEqual(WindowChromeRecipe.minimumContentSize.height, 480)
    XCTAssertEqual(WindowChromeRecipe.documentContentTopInset, 10)
    XCTAssertEqual(WindowChromeRecipe.previewContentTopInset, 8)
  }

  func testTitlebarGlassHeightComesFromWindowContentLayoutDelta() {
    XCTAssertEqual(
      WindowChromeRecipe.titlebarGlassHeight(
        frameHeight: 800, contentLayoutHeight: 736),
      64)
    XCTAssertEqual(
      WindowChromeRecipe.titlebarGlassHeight(
        frameHeight: 800, contentLayoutHeight: 800),
      0)
    XCTAssertEqual(
      WindowChromeRecipe.titlebarGlassHeight(
        frameHeight: 799.5, contentLayoutHeight: 735.25),
      65)
    XCTAssertEqual(
      WindowChromeRecipe.titlebarGlassHeight(
        frameHeight: 700, contentLayoutHeight: 724),
      0)
  }

  @MainActor
  func testTitlebarGlassHeightReadsRealFullSizeContentWindow() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false
    )
    defer { window.close() }

    WindowChromeRecipe.apply(to: window, title: "Chrome Truth Probe")

    let expected = WindowChromeRecipe.titlebarGlassHeight(
      frameHeight: window.frame.height,
      contentLayoutHeight: window.contentLayoutRect.height)
    XCTAssertEqual(WindowChromeRecipe.titlebarGlassHeight(for: window), expected)
    XCTAssertGreaterThanOrEqual(expected, 0)
  }
}
