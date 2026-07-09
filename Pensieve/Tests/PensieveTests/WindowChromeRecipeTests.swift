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

  // MARK: - Veil mask profile (single source of truth)

  func testVeilMaskProfilePinsMeasuredTransmissionCurve() {
    // The 7-12b row-probe values. Editing the profile is a conscious
    // re-measurement, not a drive-by CSS tweak — this pin makes that explicit.
    let stops = WindowChromeRecipe.titlebarGlassVeilMaskStops
    XCTAssertEqual(stops.map(\.alpha), [0.92, 0.86, 0.62, 0.42])
    XCTAssertEqual(stops.map(\.percent), [0, 45, 80, 100])
  }

  func testVeilMaskProfileNeverCarriesAnOpaqueStopAndOnlyDissolvesDownward() {
    let stops = WindowChromeRecipe.titlebarGlassVeilMaskStops
    XCTAssertFalse(stops.isEmpty)
    for stop in stops {
      XCTAssertLessThan(
        stop.alpha, 1.0,
        "an opaque stop reads as a solid plate under the toolbar (cut 7-12b)")
      XCTAssertGreaterThan(stop.alpha, 0.0)
    }
    // The editor's scroll-edge dissolve only ever increases transmission
    // toward the chrome seam; the veil must never re-thicken mid-band.
    XCTAssertEqual(stops.map(\.alpha), stops.map(\.alpha).sorted(by: >))
    XCTAssertEqual(stops.map(\.percent), stops.map(\.percent).sorted())
    XCTAssertEqual(stops.first?.percent, 0)
    XCTAssertEqual(stops.last?.percent, 100)
  }

  func testVeilMaskCSSGradientRendersTheProfileVerbatim() {
    XCTAssertEqual(
      WindowChromeRecipe.titlebarGlassVeilMaskCSSGradient,
      "linear-gradient(to bottom, rgba(0, 0, 0, 0.92) 0%, rgba(0, 0, 0, 0.86) 45%, "
        + "rgba(0, 0, 0, 0.62) 80%, rgba(0, 0, 0, 0.42) 100%)")
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

  @MainActor
  func testPreviewWebViewKeepsFullBleedViewportUnderChrome() throws {
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
    WindowChromeRecipe.apply(to: window, title: "Viewport Probe")

    let view = PreviewWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    window.contentView = view
    view.layoutSubtreeIfNeeded()

    let webView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
    // macOS 26 otherwise auto-adopts the safe area as obscured insets — and
    // RE-applies them when the view lands in a window — which hard-clips
    // scrolled preview content at the chrome edge while the editor pane
    // glides under the glass, and doubles the CSS glass-height offset. The
    // window attach above is the part that regressed silently with an
    // init-only reset.
    XCTAssertEqual(webView.obscuredContentInsets.top, 0)
    XCTAssertEqual(webView.obscuredContentInsets.left, 0)
    XCTAssertEqual(webView.obscuredContentInsets.bottom, 0)
    XCTAssertEqual(webView.obscuredContentInsets.right, 0)
  }

  /// The regression path polarize L2 measured on the operator's window:
  /// WebKit re-adopts the safe area as obscured insets on chrome geometry
  /// changes that give the container NO layout pass (SwiftUI attaches the
  /// toolbar after the preview joins the window, shrinking
  /// `contentLayoutRect` silently). Enforcement must therefore ride the
  /// glass controller's geometry channel, not just layout()/window moves —
  /// otherwise the pocket doubles the page-start offset and hard-clips
  /// scrolled content with WebKit's own fade instead of the veil's.
  @MainActor
  func testPreviewWebViewReZeroesViewportOnChromeGeometryEventsWithoutLayout() throws {
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
    WindowChromeRecipe.apply(to: window, title: "Viewport Re-Adoption Probe")

    let view = PreviewWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    window.contentView = view
    view.layoutSubtreeIfNeeded()

    let webView = try XCTUnwrap(view.subviews.compactMap { $0 as? WKWebView }.first)
    // Simulate WebKit's silent re-adoption after attach — no container layout.
    webView.obscuredContentInsets = NSEdgeInsets(top: 52, left: 0, bottom: 0, right: 0)
    XCTAssertEqual(webView.obscuredContentInsets.top, 52)

    // A chrome geometry event with no layout pass: the controller's window
    // notification path (didResize) schedules apply() after ~30ms.
    NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
    let deadline = Date().addingTimeInterval(2)
    while webView.obscuredContentInsets.top != 0, Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    XCTAssertEqual(webView.obscuredContentInsets.top, 0)
  }

  /// The enforcer must run on EVERY apply — including unforced ones whose
  /// script guard short-circuits (unchanged height/backing): the pocket can
  /// re-adopt while the measured glass height stays identical.
  @MainActor
  func testGlassControllerRunsViewportEnforcerOnEveryGeometryApply() {
    let controller = PreviewTitlebarGlassController()
    var enforcements = 0
    controller.viewportEnforcer = { enforcements += 1 }
    controller.scriptEvaluator = { _ in }

    controller.attach(to: nil)
    XCTAssertEqual(enforcements, 1)
    controller.navigationDidFinish()
    XCTAssertEqual(enforcements, 2)
    // Unchanged values: script application is skipped, enforcement is not.
    controller.apply()
    XCTAssertEqual(enforcements, 3)
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

  // The preview veil (cut 7-12) paints web-side pixels that must equal the
  // native glass backing on the editor side of the split — one colour truth,
  // resolved per appearance, emitted as a concrete sRGB value (a CSS keyword
  // guess is exactly how the 7-9 tinted-stripe class comes back).
  @MainActor
  func testTitlebarGlassBackingCSSColorResolvesPerAppearance() throws {
    func cssColor(_ appearanceName: NSAppearance.Name) throws -> String {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
        styleMask: WindowChromeRecipe.documentStyleMask,
        backing: .buffered,
        defer: false
      )
      window.isReleasedWhenClosed = false
      defer { window.close() }
      window.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
      return WindowChromeRecipe.titlebarGlassBackingCSSColor(for: window)
    }

    let dark = try cssColor(.darkAqua)
    let light = try cssColor(.aqua)

    for value in [dark, light] {
      XCTAssertTrue(
        value.range(of: #"^rgb\(\d{1,3}, \d{1,3}, \d{1,3}\)$"#, options: .regularExpression)
          != nil,
        "backing colour must resolve to a concrete rgb() value, got: \(value)")
    }
    XCTAssertNotEqual(dark, light, "backing colour must follow the effective appearance")
  }
}
