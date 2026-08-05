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

  // MARK: - The pocket's precondition (scene launcher vs AppKit factory)

  /// The measured discriminator: a full-size-content window with a TRANSPARENT
  /// titlebar is the shape WebKit refuses to adopt the pocket for. That is the
  /// scene-owned launcher's shape, and only its preview column was affected —
  /// AppKit's editor scroll view insets itself either way.
  func testATransparentTitlebarIsWhatSuppressesTheWebContentPocket() {
    XCTAssertTrue(
      WindowChromeRecipe.suppressesAutomaticWebContentInsets(
        styleMask: WindowChromeRecipe.documentStyleMask,
        titlebarAppearsTransparent: true),
      "the scene launcher's shape must be recognised as pocket-suppressing")
    XCTAssertFalse(
      WindowChromeRecipe.suppressesAutomaticWebContentInsets(
        styleMask: WindowChromeRecipe.documentStyleMask,
        titlebarAppearsTransparent: false),
      "the AppKit factory's shape adopts the pocket and must not be touched")
    // Without full-size content there is no band under the chrome to inset in
    // the first place, so transparency alone is not the defect.
    XCTAssertFalse(
      WindowChromeRecipe.suppressesAutomaticWebContentInsets(
        styleMask: [.titled, .closable, .resizable],
        titlebarAppearsTransparent: true))
  }

  /// The correction itself: scene-shaped window gets corrected exactly once,
  /// factory-shaped window is left ALONE (a window that already adopts the
  /// pocket must receive zero compensation), and a clobber back to the
  /// suppressing shape heals — which is what a tab-bar reshuffle or a toolbar
  /// re-bridge can do.
  @MainActor
  func testOnlyThePocketSuppressingWindowIsCorrectedAndItConverges() {
    func makeWindow() -> NSWindow {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: WindowChromeRecipe.documentStyleMask,
        backing: .buffered,
        defer: false)
      WindowChromeRecipe.apply(to: window, title: "Pocket Precondition Probe")
      return window
    }

    let scene = makeWindow()
    let factory = makeWindow()
    defer {
      scene.close()
      factory.close()
    }
    // SwiftUI's scene window arrives like this; the AppKit factory keeps
    // NSWindow's default opaque titlebar.
    scene.titlebarAppearsTransparent = true

    XCTAssertTrue(
      WindowChromeRecipe.assertOpaqueTitlebarForWebContentInsets(
        on: scene, osOwnsWebContentInsets: true),
      "the scene-shaped window was left in the shape WebKit zeroes the pocket for")
    XCTAssertFalse(scene.titlebarAppearsTransparent)
    XCTAssertFalse(
      WindowChromeRecipe.assertOpaqueTitlebarForWebContentInsets(
        on: scene, osOwnsWebContentInsets: true),
      "an already-correct window was rewritten — on a per-update trigger that is the loop")

    XCTAssertFalse(
      WindowChromeRecipe.assertOpaqueTitlebarForWebContentInsets(
        on: factory, osOwnsWebContentInsets: true),
      "a healthy factory window must receive NO correction")
    XCTAssertFalse(factory.titlebarAppearsTransparent)

    // Level-triggered: an external reset back to the suppressing shape is
    // corrected again, so the launcher heals instead of staying broken for the
    // rest of the session.
    scene.titlebarAppearsTransparent = true
    XCTAssertTrue(
      WindowChromeRecipe.assertOpaqueTitlebarForWebContentInsets(
        on: scene, osOwnsWebContentInsets: true))
    XCTAssertFalse(scene.titlebarAppearsTransparent)
  }

  /// Before macOS 26 there is no pocket at all — the CSS fallback owns the
  /// offset there — so the correction must not touch a window on that path.
  @MainActor
  func testThePreMacOS26FallbackPathIsLeftAlone() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false)
    WindowChromeRecipe.apply(to: window, title: "Pre-26 Fallback Probe")
    defer { window.close() }
    window.titlebarAppearsTransparent = true

    XCTAssertFalse(
      WindowChromeRecipe.assertOpaqueTitlebarForWebContentInsets(
        on: window, osOwnsWebContentInsets: false))
    XCTAssertTrue(window.titlebarAppearsTransparent)
  }

  /// End to end through the shipping invariant pass, on the OS where the pocket
  /// exists: the launcher's window shape is repaired by the same call every
  /// window already makes, so nothing new has to be wired into the scene.
  @MainActor
  func testTheSceneLauncherShapeIsRepairedThroughAssertWindowChrome() throws {
    guard #available(macOS 26.0, *) else {
      throw XCTSkip("the obscured-content-insets pocket exists from macOS 26")
    }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false)
    defer { window.close() }
    WindowChromeRecipe.apply(to: window, title: "Launcher Shape Probe")
    window.titlebarAppearsTransparent = true

    WindowChromeRecipe.assertWindowChrome(on: window, for: .ink)

    XCTAssertFalse(
      window.titlebarAppearsTransparent,
      "the chrome pass left the launcher in the shape that zeroes the preview's top inset")
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
      ColorSpec.nsColor(fromHex: "#6e6e6e"))
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

  // MARK: - Native tab bar

  /// `VibrantDark` and `DarkAqua` are the same SIDE. Comparing raw names would
  /// call an already-correct vibrant tab bar a disagreement and rewrite it on
  /// every pass — flattening its glass and never converging.
  func testAppearancePolarityFoldsTheVibrantVariantsOntoTwoAnswers() {
    XCTAssertEqual(
      WindowChromeRecipe.appearancePolarity(NSAppearance(named: .vibrantDark)), .darkAqua)
    XCTAssertEqual(WindowChromeRecipe.appearancePolarity(NSAppearance(named: .darkAqua)), .darkAqua)
    XCTAssertEqual(
      WindowChromeRecipe.appearancePolarity(NSAppearance(named: .vibrantLight)), .aqua)
    XCTAssertEqual(WindowChromeRecipe.appearancePolarity(NSAppearance(named: .aqua)), .aqua)
    XCTAssertNil(WindowChromeRecipe.appearancePolarity(nil))
  }

  /// A correction keeps the material it found. A glass node that had chosen
  /// `VibrantLight` is put back to `VibrantDark`; a flat one to `DarkAqua`.
  func testACorrectionKeepsTheVibrancyItFound() {
    XCTAssertEqual(
      WindowChromeRecipe.matchingAppearance(
        for: .darkAqua, preservingVibrancyOf: NSAppearance(named: .vibrantLight))?.name,
      .vibrantDark,
      "flattening a glass node to DarkAqua would drop the material the tab bar is made of")
    XCTAssertEqual(
      WindowChromeRecipe.matchingAppearance(
        for: .aqua, preservingVibrancyOf: NSAppearance(named: .vibrantDark))?.name,
      .vibrantLight)
    XCTAssertEqual(
      WindowChromeRecipe.matchingAppearance(
        for: .darkAqua, preservingVibrancyOf: NSAppearance(named: .aqua))?.name,
      .darkAqua)
  }

  /// The side the tab bar must agree with comes from the SKIN when the skin
  /// names one, and from the window only for the adaptive skins.
  ///
  /// Skin-first is load-bearing, not tidiness: a skin switch is one of the
  /// moments the tab bar is rebuilt, and `window.effectiveAppearance` can still
  /// be reporting the outgoing half while that happens — so a window-first read
  /// would pin the new tab bar to the skin being left.
  @MainActor
  func testTabBarPolarityPrefersTheSkinAndFallsBackToTheWindow() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false)
    defer { window.contentView = nil }

    window.appearance = NSAppearance(named: .darkAqua)
    XCTAssertEqual(
      WindowChromeRecipe.tabBarPolarity(on: window, for: .parchment), .aqua,
      "a light skin's tab bar must be light even while the window still reads dark")

    XCTAssertEqual(
      WindowChromeRecipe.tabBarPolarity(on: window, for: .default), .darkAqua,
      "an adaptive skin names no appearance, so the window is the only answer left")
    window.appearance = NSAppearance(named: .aqua)
    XCTAssertEqual(WindowChromeRecipe.tabBarPolarity(on: window, for: .default), .aqua)
  }

  /// THE REGRESSION PIN for the tab bar.
  ///
  /// What it models is the state an operator photographed: a native tab pill
  /// over the white preview column rendering light on a dark window. The
  /// TRIGGER is not reproducible below the window server — a glass view resolves
  /// against composited luminance, and a headless probe with a white content
  /// column produced no flip at all (the same limit `bdbb816` recorded for the
  /// toolbar platters). So the flip is INJECTED, exactly as measured on the
  /// probe: the tab bar's glass nodes carrying an explicitly-set `VibrantLight`
  /// while the window is `darkAqua`.
  ///
  /// Injecting the state is honest here because the state is what was measured
  /// on the real app, and because the defect is TRANSIENT: the tab bar is
  /// rebuilt out from under any one-shot pin (every window in the group carries
  /// its own accessory, and selecting a tab hands the newly visible one a glass
  /// node with no appearance of its own). What has to be true is that production
  /// puts a wrong-sided tab bar back, on demand, as often as AppKit hands it
  /// one — and that is exactly what this asserts.
  @MainActor
  func testAFlippedTabBarIsPutBackOnTheWindowsSide() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false)
    defer { window.contentView = nil }
    window.appearance = NSAppearance(named: .darkAqua)

    // The measured shape: a track-level glass node and one per tab pill, each
    // having self-selected the wrong side.
    let track = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 28))
    let leading = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    let trailing = NSView(frame: NSRect(x: 300, y: 0, width: 300, height: 24))
    track.addSubview(leading)
    track.addSubview(trailing)
    for view in [track, leading, trailing] {
      view.appearance = NSAppearance(named: .vibrantLight)
    }

    XCTAssertTrue(
      WindowChromeRecipe.assertTabBarAppearance(
        on: window, for: .ink, tabBarViews: [track, leading, trailing]))
    for view in [track, leading, trailing] {
      XCTAssertEqual(
        view.appearance?.name, .vibrantDark,
        "a tab pill that self-selected light over the preview column stays light — nothing "
          + "re-asserts the window's side on the tab bar")
    }

    // Converged: an already-correct tab bar is not touched again, so this is
    // safe on a window update cycle.
    XCTAssertFalse(
      WindowChromeRecipe.assertTabBarAppearance(
        on: window, for: .ink, tabBarViews: [track, leading, trailing]),
      "a second pass rewrote an already-correct tab bar — that is the write loop, on a "
        + "notification the window itself posts")

    // And a node already on the right side keeps its exact material.
    let vibrant = NSView(frame: .zero)
    vibrant.appearance = NSAppearance(named: .vibrantDark)
    XCTAssertFalse(
      WindowChromeRecipe.assertTabBarAppearance(on: window, for: .ink, tabBarViews: [vibrant]))
    XCTAssertEqual(vibrant.appearance?.name, .vibrantDark)
  }

  /// A window with no visible tab bar has nothing to correct, and must say so
  /// rather than report a correction on every pass — `assertWindowChrome` folds
  /// this answer into its own converged/not result.
  @MainActor
  func testTabBarAssertionIsSilentWithoutATabBar() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false)
    defer { window.contentView = nil }

    XCTAssertTrue(WindowChromeRecipe.tabBarSelfSelectingViews(in: window).isEmpty)
    XCTAssertFalse(WindowChromeRecipe.assertTabBarAppearance(on: window, for: .parchment))
  }

  /// THE END-TO-END PIN: a REAL native tab group, the real AppKit view tree, and
  /// the production entry point with no seam.
  ///
  /// The pin above drives the polarity rules against a known view shape; this
  /// one proves the other half — that the walk actually FINDS AppKit's tab bar
  /// (`titlebarAccessoryViewControllers` → `NSTabBar` → the glass nodes that set
  /// their own appearance), that the `isTabBarVisible` gate lets it through, and
  /// that `assertWindowChrome` runs it. Nothing here names a private class: the
  /// flip is injected onto whatever nodes the walk itself returns, so the pin
  /// cannot pass by agreeing with a hard-coded view hierarchy.
  @MainActor
  func testARealTabGroupsFlippedGlassIsRepairedThroughAssertWindowChrome() throws {
    func makeWindow(_ title: String) -> NSWindow {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: WindowChromeRecipe.documentStyleMask,
        backing: .buffered,
        defer: false)
      WindowChromeRecipe.apply(to: window, title: title)
      window.contentView = NSView(frame: .zero)
      return window
    }

    let leading = makeWindow("dont_forget_about")
    let trailing = makeWindow("Recovered Untitled.md")
    defer {
      for window in [leading, trailing] {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
      }
    }
    for window in [leading, trailing] { window.appearance = NSAppearance(named: .darkAqua) }
    // Parked far offscreen at zero alpha: still laid out, never on a screen an
    // operator is looking at.
    leading.setFrameOrigin(NSPoint(x: -9000, y: -9000))
    leading.alphaValue = 0
    leading.makeKeyAndOrderFront(nil)
    leading.addTabbedWindow(trailing, ordered: .above)
    leading.layoutIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))

    let found = WindowChromeRecipe.tabBarSelfSelectingViews(in: leading)
    guard leading.tabGroup?.isTabBarVisible == true, !found.isEmpty else {
      throw XCTSkip("headless host did not build a native tab bar")
    }

    // Inject the measured symptom onto the real nodes.
    for view in found { view.appearance = NSAppearance(named: .vibrantLight) }
    XCTAssertEqual(
      WindowChromeRecipe.appearancePolarity(found.first?.appearance), .aqua,
      "premise: the tab bar is now on the wrong side, like the pill over the preview column")

    XCTAssertTrue(
      WindowChromeRecipe.assertWindowChrome(on: leading, for: .ink),
      "the window chrome pass did not reach the native tab bar at all")
    for view in WindowChromeRecipe.tabBarSelfSelectingViews(in: leading) {
      XCTAssertEqual(
        WindowChromeRecipe.appearancePolarity(view.appearance), .darkAqua,
        "a self-selected light tab bar survived the chrome pass on a dark window")
    }

    // Converged: the same pass over an already-correct tab bar writes nothing,
    // which is what makes it safe on every window update cycle.
    XCTAssertFalse(
      WindowChromeRecipe.assertTabBarAppearance(on: leading, for: .ink),
      "an already-correct tab bar was rewritten — on a didUpdate trigger that is the loop")
  }

  // MARK: - Sidebar chrome inset (bug A)

  /// A window with nothing below its toolbar owes the sidebar nothing, so the
  /// untabbed window keeps its exact current layout.
  @MainActor
  func testBelowToolbarChromeHeightIsZeroWithoutABottomAccessory() {
    let window = NSWindow(
      contentRect: WindowChromeRecipe.defaultContentRect,
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false)
    defer { window.close() }
    WindowChromeRecipe.apply(to: window, title: "Chrome Probe")

    XCTAssertEqual(WindowChromeRecipe.belowToolbarChromeHeight(in: window), 0)
    XCTAssertEqual(WindowChromeRecipe.belowToolbarChromeHeight(in: nil), 0)
  }

  /// `titlebarAccessoryViewControllers` RAISES on a window without `.titled` —
  /// an `NSAssertionHandler` abort, not an optional. A diagnostic probe hit
  /// exactly that on the app's plain helper window while this bug was being
  /// measured, so the guard is pinned rather than left to reviewers' memory.
  @MainActor
  func testBelowToolbarChromeHeightSurvivesAWindowThatCannotHaveAccessories() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }

    XCTAssertFalse(window.styleMask.contains(.titled), "premise: no titlebar to carry accessories")
    XCTAssertEqual(WindowChromeRecipe.belowToolbarChromeHeight(in: window), 0)
  }

  /// Only the accessories laid out BELOW the toolbar are the sidebar's problem:
  /// a `.right` accessory shares the toolbar's own band and is already spent.
  @MainActor
  func testBelowToolbarChromeHeightCountsOnlyTheBottomAccessories() {
    let window = NSWindow(
      contentRect: WindowChromeRecipe.defaultContentRect,
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false)
    defer { window.close() }
    WindowChromeRecipe.apply(to: window, title: "Chrome Probe")

    func accessory(_ attribute: NSLayoutConstraint.Attribute, height: CGFloat)
      -> NSTitlebarAccessoryViewController
    {
      let controller = NSTitlebarAccessoryViewController()
      controller.layoutAttribute = attribute
      controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 1300, height: height))
      return controller
    }

    window.addTitlebarAccessoryViewController(accessory(.right, height: 28))
    XCTAssertEqual(
      WindowChromeRecipe.belowToolbarChromeHeight(in: window), 0,
      "a toolbar-band accessory was billed to the sidebar")

    window.addTitlebarAccessoryViewController(accessory(.bottom, height: 36))
    XCTAssertEqual(
      WindowChromeRecipe.belowToolbarChromeHeight(in: window), 36,
      "the strip below the toolbar is the height the sidebar has to skip")
  }

  /// THE PIN THAT TRACKS THE VISUAL DEFECT: a REAL native tab group, and the
  /// arithmetic that makes the workspace title row disappear.
  ///
  /// Bug A is that the split view lays the sidebar column out against the
  /// TOOLBAR height while AppKit reserves toolbar + tab bar, so the title row
  /// (`pensieve.sidebar.title`, 62..80 in a 1300×760 window) ends up under the
  /// full-width bar background that spans the whole 88pt band. No accessibility
  /// frame moves when that happens — the AX dump from the live capture reports
  /// the title row at its healthy position while the pixels are gone — so the
  /// invariant is geometric and taken from AppKit:
  ///
  ///     band(tabbed) - band(untabbed) == belowToolbarChromeHeight
  ///
  /// Both sides come from the same two real windows, so the pin cannot pass by
  /// agreeing with a hard-coded 36.
  @MainActor
  func testARealTabGroupsBandGrowsByExactlyTheSidebarChromeInset() throws {
    func makeWindow(_ title: String) -> NSWindow {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: WindowChromeRecipe.documentStyleMask,
        backing: .buffered,
        defer: false)
      WindowChromeRecipe.apply(to: window, title: title)
      window.contentView = NSView(frame: .zero)
      return window
    }

    let leading = makeWindow("dont_forget_about")
    let trailing = makeWindow("Recovered Untitled.md")
    defer {
      for window in [leading, trailing] {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
      }
    }
    // Parked far offscreen at zero alpha: still laid out, never on a screen an
    // operator is looking at.
    leading.setFrameOrigin(NSPoint(x: -9000, y: -9000))
    leading.alphaValue = 0
    leading.makeKeyAndOrderFront(nil)
    leading.layoutIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))

    let untabbedBand = WindowChromeRecipe.titlebarGlassHeight(for: leading)
    XCTAssertEqual(
      WindowChromeRecipe.belowToolbarChromeHeight(in: leading), 0,
      "premise: a lone window has nothing below its toolbar")

    leading.addTabbedWindow(trailing, ordered: .above)
    leading.layoutIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))

    guard leading.tabGroup?.isTabBarVisible == true else {
      throw XCTSkip("headless host did not build a native tab bar")
    }

    let inset = WindowChromeRecipe.belowToolbarChromeHeight(in: leading)
    XCTAssertGreaterThan(
      inset, 0, "the visible tab bar is not being counted as chrome below the toolbar")
    XCTAssertEqual(
      WindowChromeRecipe.titlebarGlassHeight(for: leading) - untabbedBand, inset, accuracy: 1,
      "the band the tab bar adds is exactly what the sidebar column has to skip")
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
