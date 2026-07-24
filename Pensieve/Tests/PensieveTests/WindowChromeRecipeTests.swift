import AppKit
import WebKit
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

  /// The scene-owned launcher presents the cold frame on launch while the
  /// AppKit factory presents every later document tab. Both read the same
  /// toolbar-fitting width, so a cold window never exposes fewer toolbar
  /// controls than a factory one just because SwiftUI built it.
  func testToolbarFittingWidthIsWiderThanThePinnedDefaultContentWidth() {
    XCTAssertEqual(WindowChromeRecipe.toolbarFittingContentWidth, 1300)
    XCTAssertGreaterThan(
      WindowChromeRecipe.toolbarFittingContentWidth,
      WindowChromeRecipe.defaultContentSize.width)
    XCTAssertEqual(
      WindowChromeRecipe.factoryInitialFrame(
        in: NSRect(x: 0, y: 0, width: 3000, height: 2000)
      ).width,
      WindowChromeRecipe.toolbarFittingContentWidth)
  }

  func testFactoryInitialFramePrefersToolbarWidthWithinVisibleScreen() {
    let roomyVisibleFrame = NSRect(x: 0, y: 67, width: 1512, height: 881)
    let roomyFrame = WindowChromeRecipe.factoryInitialFrame(in: roomyVisibleFrame)
    XCTAssertEqual(roomyFrame, NSRect(x: 106, y: 127.5, width: 1300, height: 760))

    let constrainedVisibleFrame = NSRect(x: 40, y: 80, width: 1000, height: 700)
    let constrainedFrame = WindowChromeRecipe.factoryInitialFrame(in: constrainedVisibleFrame)
    XCTAssertEqual(constrainedFrame, constrainedVisibleFrame)
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

  func testTitlebarGlassBackingColorMatchesEditorSurface() {
    XCTAssertEqual(WindowChromeRecipe.titlebarGlassBackingColor, .textBackgroundColor)
  }

  @MainActor
  func testPreviewWebViewFeedsChromeTheRecipeBackingColor() {
    let view = PreviewWebView(frame: .zero)
    let webView = view.subviews.compactMap { $0 as? WKWebView }.first
    XCTAssertNotNil(webView)
    // WKWebView resolves the dynamic catalog colour to concrete sRGB on set;
    // compare resolved components, not colour identity.
    let applied = webView?.underPageBackgroundColor.usingColorSpace(.sRGB)
    let expected = WindowChromeRecipe.titlebarGlassBackingColor.usingColorSpace(.sRGB)
    XCTAssertNotNil(applied)
    XCTAssertNotNil(expected)
    if let applied, let expected {
      XCTAssertEqual(applied.redComponent, expected.redComponent, accuracy: 0.001)
      XCTAssertEqual(applied.greenComponent, expected.greenComponent, accuracy: 0.001)
      XCTAssertEqual(applied.blueComponent, expected.blueComponent, accuracy: 0.001)
      XCTAssertEqual(applied.alphaComponent, expected.alphaComponent, accuracy: 0.001)
    }
  }

  /// The pocket IS the chrome truth on macOS 26 (polarize L3): WebKit's
  /// auto-adopted obscured insets park the page start at the glass line and
  /// render the editor's scroll-edge ghosts through the band. Nothing in the
  /// preview stack may fight the adoption — zeroing it painted scrolled text
  /// crisp through the window title (measured: 192/255 in-band vs the
  /// pocket's native 2–12/255 dissolve).
  @MainActor
  func testPreviewWebViewLetsWebKitKeepTheAdoptedChromePocket() throws {
    guard #available(macOS 26.0, *) else {
      throw XCTSkip("obscured content insets exist from macOS 26")
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false
    )
    defer { window.close() }
    WindowChromeRecipe.apply(to: window, title: "Pocket Adoption Probe")

    let view = PreviewWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    window.contentView = view
    view.layoutSubtreeIfNeeded()

    let webView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
    // Simulate WebKit's adoption after attach; a headless test window never
    // triggers the real one deterministically, so plant the adopted value.
    webView.obscuredContentInsets = NSEdgeInsets(top: 52, left: 0, bottom: 0, right: 0)

    // Chrome geometry events (the L2 enforcement channel) and layout passes
    // (the 7-10 channel) must both leave the adopted pocket alone now.
    NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
    let deadline = Date().addingTimeInterval(0.3)
    while Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    XCTAssertEqual(webView.obscuredContentInsets.top, 52)
  }

  /// On macOS 26 the glass controller must stay silent: the CSS offset
  /// variable keeps its 0px default because the OS pocket owns the offset.
  /// The controller only plumbs the measured height before macOS 26.
  @MainActor
  func testGlassControllerStaysSilentWhereTheOSPocketOwnsTheOffset() {
    let controller = PreviewTitlebarGlassController()
    var scripts: [String] = []
    controller.scriptEvaluator = { scripts.append($0) }
    controller.titlebarGlassHeightProvider = { _ in 52 }

    controller.engagementOverride = false  // the macOS 26 runtime posture
    controller.attach(to: nil)
    controller.navigationDidFinish()
    XCTAssertTrue(scripts.isEmpty)

    controller.engagementOverride = true  // the pre-26 fallback posture
    controller.attach(to: nil)
    XCTAssertFalse(scripts.isEmpty)
  }

  @MainActor
  func testGutterDrawingRectStopsAtChromeBoundary() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false
    )
    defer { window.close() }
    WindowChromeRecipe.apply(to: window, title: "Gutter Chrome Probe")

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let textView = NSTextView(frame: scrollView.bounds)
    scrollView.documentView = textView
    window.contentView = scrollView

    let layoutManager = NSTextLayoutManager()
    let gutter = LineNumberGutter(scrollView: scrollView, textLayoutManager: layoutManager)
    scrollView.verticalRulerView = gutter
    scrollView.hasVerticalRuler = true
    scrollView.rulersVisible = true
    scrollView.tile()

    // The ruler spans the full-size content view, i.e. it runs under the
    // titlebar; its allowed drawing region must not.
    XCTAssertFalse(gutter.bounds.isEmpty)
    let allowed = gutter.chromeClippedDrawingRect()
    XCTAssertFalse(allowed.isEmpty)
    let allowedInWindow = gutter.convert(allowed, to: nil)
    XCTAssertLessThanOrEqual(
      allowedInWindow.maxY, window.contentLayoutRect.maxY + 0.5,
      "gutter drawing must stop at the chrome boundary instead of crossing the title")

    let glassHeight = WindowChromeRecipe.titlebarGlassHeight(for: window)
    if glassHeight > 0 {
      let boundsInWindow = gutter.convert(gutter.bounds, to: nil)
      XCTAssertGreaterThan(
        boundsInWindow.maxY, window.contentLayoutRect.maxY,
        "probe premise: the ruler itself extends under the chrome")
      XCTAssertLessThan(allowedInWindow.height, boundsInWindow.height)
    }
  }

}
