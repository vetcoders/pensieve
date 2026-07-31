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
  @MainActor
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

  @MainActor
  func testFactoryInitialFramePrefersToolbarWidthWithinVisibleScreen() {
    let roomyVisibleFrame = NSRect(x: 0, y: 67, width: 1512, height: 881)
    let roomyFrame = WindowChromeRecipe.factoryInitialFrame(in: roomyVisibleFrame)
    XCTAssertEqual(roomyFrame, NSRect(x: 106, y: 127.5, width: 1300, height: 760))

    let constrainedVisibleFrame = NSRect(x: 40, y: 80, width: 1000, height: 700)
    let constrainedFrame = WindowChromeRecipe.factoryInitialFrame(in: constrainedVisibleFrame)
    XCTAssertEqual(constrainedFrame, constrainedVisibleFrame)
  }

  /// P2-03: the factory feeds `factoryInitialFrame` straight into
  /// `NSWindow(contentRect:)`, so the returned rect must leave room for the
  /// titlebar — the FINAL frame (content grown by chrome) must never spill
  /// above a low screen's work area. Exercised with a mask that actually adds
  /// a titlebar (the document mask's `.fullSizeContentView` overlays it, so
  /// the frame equals the content rect and would not surface the regression).
  @MainActor
  func testFactoryContentRectKeepsFinalFrameWithinVisibleAreaWithTitlebarChrome() {
    let titlebarMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
    let lowVisibleFrame = NSRect(x: 0, y: 25, width: 1440, height: 500)

    let content = WindowChromeRecipe.factoryInitialContentRect(
      in: lowVisibleFrame, styleMask: titlebarMask)
    let finalFrame = NSWindow.frameRect(forContentRect: content, styleMask: titlebarMask)

    XCTAssertGreaterThanOrEqual(finalFrame.minX, lowVisibleFrame.minX - 0.5)
    XCTAssertGreaterThanOrEqual(finalFrame.minY, lowVisibleFrame.minY - 0.5)
    XCTAssertLessThanOrEqual(finalFrame.maxX, lowVisibleFrame.maxX + 0.5)
    XCTAssertLessThanOrEqual(finalFrame.maxY, lowVisibleFrame.maxY + 0.5)

    // Premise guard: this mask really adds titlebar chrome, so the content rect
    // had to shrink below the raw visible height to keep the frame in bounds.
    XCTAssertGreaterThan(finalFrame.height, content.height)
    XCTAssertLessThan(content.height, lowVisibleFrame.height)
  }

  /// The same invariant on the REAL document mask: even where
  /// `.fullSizeContentView` makes the frame equal the content rect, a low
  /// screen must not produce a frame that reaches past the work area.
  @MainActor
  func testFactoryFrameFitsVisibleAreaOnALowScreenWithTheDocumentMask() {
    let lowVisibleFrame = NSRect(x: 0, y: 25, width: 1440, height: 520)
    let content = WindowChromeRecipe.factoryInitialFrame(in: lowVisibleFrame)
    let finalFrame = NSWindow.frameRect(
      forContentRect: content, styleMask: WindowChromeRecipe.documentStyleMask)

    XCTAssertGreaterThanOrEqual(finalFrame.minX, lowVisibleFrame.minX - 0.5)
    XCTAssertGreaterThanOrEqual(finalFrame.minY, lowVisibleFrame.minY - 0.5)
    XCTAssertLessThanOrEqual(finalFrame.maxX, lowVisibleFrame.maxX + 0.5)
    XCTAssertLessThanOrEqual(finalFrame.maxY, lowVisibleFrame.maxY + 0.5)
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

  func testTitlebarGlassBackingColorIsTheThemeSourceToken() {
    // The adaptive `default` theme keeps the established editor surface...
    XCTAssertEqual(
      WindowChromeRecipe.titlebarGlassBackingColor(for: .default), .textBackgroundColor)
    // ...and a fixed-palette theme feeds its own source colour so the titlebar
    // strip never lights up on a dark surface.
    let inkBacking = WindowChromeRecipe.titlebarGlassBackingColor(for: .ink)
      .usingColorSpace(.sRGB)
    let inkSource = PensieveTheme.ink.tokens.source.nsColor.usingColorSpace(.sRGB)
    XCTAssertNotNil(inkBacking)
    XCTAssertNotNil(inkSource)
    if let inkBacking, let inkSource {
      XCTAssertEqual(inkBacking.redComponent, inkSource.redComponent, accuracy: 0.001)
      XCTAssertEqual(inkBacking.greenComponent, inkSource.greenComponent, accuracy: 0.001)
      XCTAssertEqual(inkBacking.blueComponent, inkSource.blueComponent, accuracy: 0.001)
    }
  }

  @MainActor
  func testPreviewWebViewFeedsChromeTheRecipeBackingColor() {
    let view = PreviewWebView(frame: .zero)
    let webView = view.subviews.compactMap { $0 as? WKWebView }.first
    XCTAssertNotNil(webView)
    // WKWebView resolves the dynamic catalog colour to concrete sRGB on set;
    // compare resolved components, not colour identity. A freshly built view
    // (no document loaded) backs the chrome with the `default` theme surface.
    let applied = webView?.underPageBackgroundColor.usingColorSpace(.sRGB)
    let expected = WindowChromeRecipe.titlebarGlassBackingColor(for: .default)
      .usingColorSpace(.sRGB)
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

  @MainActor
  func testGutterAdoptsThickenedRuleAndCurrentLineToken() {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
    let textView = NSTextView(frame: scrollView.bounds)
    scrollView.documentView = textView
    let layoutManager = NSTextLayoutManager()
    let gutter = LineNumberGutter(scrollView: scrollView, textLayoutManager: layoutManager)

    // Chrome-polish cut: the ruler widened 40 -> 46.
    XCTAssertEqual(gutter.ruleThickness, 46)

    // The active-line number + right-edge marker paint from the theme's
    // srcCurrentLine token; the fill stays the source token.
    gutter.applyTokens(PensieveTheme.ink.tokens)
    XCTAssertEqual(gutter.gutterCurrentLine, PensieveTheme.ink.tokens.srcCurrentLine.nsColor)
    XCTAssertEqual(gutter.gutterBackground, PensieveTheme.ink.tokens.source.nsColor)

    // The active line the gutter picks out is a settable 1-based line.
    gutter.currentLineNumber = 4
    XCTAssertEqual(gutter.currentLineNumber, 4)
  }

  // MARK: - Toolbar chip tint

  /// The chip fill is the skin's `chromeAccent`, byte-for-byte — the same token
  /// table the titlebar backing reads, so the chips and the strip they sit on
  /// can never come from two different skins.
  func testToolbarChipBezelColorIsTheSkinsChromeAccent() {
    for skin in PensieveTheme.allCases {
      XCTAssertEqual(
        WindowChromeRecipe.toolbarChipBezelColor(for: skin),
        skin.tokens.chromeAccent.nsColor,
        skin.rawValue)
    }
    XCTAssertEqual(
      WindowChromeRecipe.toolbarChipBezelColor(for: .typewriter),
      ColorSpec.nsColor(fromHex: "#a8342a"))
    // Adaptive skins still follow the accent picked in System Settings.
    XCTAssertEqual(
      WindowChromeRecipe.toolbarChipBezelColor(for: .default), NSColor.controlAccentColor)
  }

  /// The discriminator that keeps the paint on the toggle chips and off the rest
  /// of the toolbar. A SwiftUI `ControlGroup` becomes one segmented control, and
  /// its tracking mode is what says which kind of group it was: independent
  /// toggles (`.selectAny`), the single-selection mode picker (`.selectOne`), or
  /// a row of plain buttons (`.momentary`).
  @MainActor
  func testOnlyMultiSelectToggleGroupsCountAsChipGroups() {
    func control(_ tracking: NSSegmentedControl.SwitchTracking) -> NSSegmentedControl {
      let control = NSSegmentedControl()
      control.segmentCount = 3
      control.trackingMode = tracking
      return control
    }

    XCTAssertTrue(WindowChromeRecipe.isToggleChipGroup(control(.selectAny)))
    XCTAssertFalse(
      WindowChromeRecipe.isToggleChipGroup(control(.selectOne)),
      "the segmented mode picker must keep its own selection colour")
    XCTAssertFalse(
      WindowChromeRecipe.isToggleChipGroup(control(.momentary)),
      "a group of plain buttons has no on-state chip to paint")
  }

  /// A window with no toolbar has nothing to correct — the assertion must stay
  /// silent rather than report a correction on every pass, because
  /// `assertWindowChrome` folds this result into its own converged/not answer.
  @MainActor
  func testToolbarChipAssertionIsSilentWithoutAToolbar() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false)
    defer { window.contentView = nil }

    XCTAssertTrue(WindowChromeRecipe.toolbarSegmentedControls(in: window).isEmpty)
    XCTAssertFalse(WindowChromeRecipe.assertToolbarChipTint(on: window, for: .parchment))
  }

  /// The real shape, minus SwiftUI: a toolbar carrying one toggle group and one
  /// single-selection picker. The chip group takes the skin's fill, the picker
  /// is left alone, and a second pass corrects nothing — the compare-and-set
  /// converges instead of re-writing on every update pass.
  @MainActor
  func testToolbarChipAssertionPaintsToggleGroupsOnlyAndConverges() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false)
    defer { window.contentView = nil }

    let chips = NSSegmentedControl()
    chips.segmentCount = 2
    chips.trackingMode = .selectAny

    let picker = NSSegmentedControl()
    picker.segmentCount = 3
    picker.trackingMode = .selectOne

    let toolbar = NSToolbar(identifier: "pensieve.test.chiptint")
    let delegate = StubToolbarDelegate(views: [chips, picker])
    toolbar.delegate = delegate
    window.toolbar = toolbar

    XCTAssertEqual(
      WindowChromeRecipe.toolbarSegmentedControls(in: window).count, 2,
      "premise: the walk reaches both view-backed toolbar items")

    XCTAssertTrue(WindowChromeRecipe.assertToolbarChipTint(on: window, for: .parchment))
    XCTAssertEqual(
      chips.selectedSegmentBezelColor,
      WindowChromeRecipe.toolbarChipBezelColor(for: .parchment))
    XCTAssertNil(picker.selectedSegmentBezelColor, "the mode picker must not be repainted")

    // Converged: nothing left to correct on the next pass.
    XCTAssertFalse(WindowChromeRecipe.assertToolbarChipTint(on: window, for: .parchment))

    // A skin switch moves the chip; an external reset (what a toolbar re-bridge
    // does) is healed by the next pass.
    XCTAssertTrue(WindowChromeRecipe.assertToolbarChipTint(on: window, for: .porcelain))
    XCTAssertEqual(
      chips.selectedSegmentBezelColor,
      WindowChromeRecipe.toolbarChipBezelColor(for: .porcelain))

    chips.selectedSegmentBezelColor = nil
    XCTAssertTrue(WindowChromeRecipe.assertToolbarChipTint(on: window, for: .porcelain))
    XCTAssertEqual(
      chips.selectedSegmentBezelColor,
      WindowChromeRecipe.toolbarChipBezelColor(for: .porcelain))
  }
}

/// Minimal toolbar delegate handing back two view-backed items — the AppKit
/// shape a SwiftUI `ControlGroup` is bridged into.
@MainActor
private final class StubToolbarDelegate: NSObject, NSToolbarDelegate {
  static let chipsIdentifier = NSToolbarItem.Identifier("pensieve.test.chips")
  static let pickerIdentifier = NSToolbarItem.Identifier("pensieve.test.picker")

  private let views: [NSView]

  init(views: [NSView]) {
    self.views = views
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [Self.chipsIdentifier, Self.pickerIdentifier]
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    item.view = itemIdentifier == Self.chipsIdentifier ? views[0] : views[1]
    return item
  }
}
