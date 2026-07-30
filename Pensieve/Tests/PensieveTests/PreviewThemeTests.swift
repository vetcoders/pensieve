import AppKit
import XCTest

@testable import Pensieve

final class PreviewThemeTests: XCTestCase {
  // MARK: - skinCSS overlay composition

  func testDefaultSkinEmitsNoOverlayRules() {
    let css = PreviewWebView.skinCSS(for: .default)
    // Default is a comment marker only — the established GitHub surface stays
    // byte-for-byte unchanged.
    XCTAssertTrue(css.contains("vc-skin:default"))
    XCTAssertFalse(css.contains(".markdown-body"))
  }

  func testRawSkinStripsChrome() {
    let css = PreviewWebView.skinCSS(for: .raw)
    XCTAssertTrue(css.contains("vc-skin:raw"))
    XCTAssertTrue(css.contains("max-width: none"))
  }

  func testParchmentSkinIsWarmSerifAndNarrow() {
    let css = PreviewWebView.skinCSS(for: .parchment)
    XCTAssertTrue(css.contains("vc-skin:parchment"))
    XCTAssertTrue(css.contains("serif"))
    XCTAssertTrue(css.contains("Newsreader"))
    XCTAssertTrue(css.contains("max-width: 680px"))
    XCTAssertTrue(css.contains("--vc-preview-parchment-bg: #f7f2e4"))
  }

  func testGraphiteSkinIsCoolReportInstrument() {
    let css = PreviewWebView.skinCSS(for: .graphite)
    XCTAssertTrue(css.contains("vc-skin:graphite"))
    XCTAssertTrue(css.contains("Instrument Sans"))
    XCTAssertTrue(css.contains("#d2d2d2"))
    XCTAssertTrue(css.contains("JetBrains Mono"))
  }

  func testInkSkinIsSignatureDarkWithFadingHeadingRule() {
    let css = PreviewWebView.skinCSS(for: .ink)
    XCTAssertTrue(css.contains("vc-skin:ink"))
    XCTAssertTrue(css.contains("Literata"))
    XCTAssertTrue(css.contains("#c6ccd6"))
    // Signature: the fading silver rule under h2 is an ::after gradient, not a
    // full border.
    XCTAssertTrue(css.contains("h2::after"))
    XCTAssertTrue(css.contains("linear-gradient"))
    XCTAssertTrue(css.contains("--vc-preview-link: #8a7fc8"))
  }

  func testPorcelainSkinIsClinicalNeutral() {
    let css = PreviewWebView.skinCSS(for: .porcelain)
    XCTAssertTrue(css.contains("vc-skin:porcelain"))
    XCTAssertTrue(css.contains("IBM Plex Sans"))
    XCTAssertTrue(css.contains("#14181c"))
    // Patient-card table opens with a thick rule.
    XCTAssertTrue(css.contains("border-top: 2px solid var(--vc-preview-text) !important"))
  }

  func testTypewriterSkinIsOneMonoFamilyCentred() {
    let css = PreviewWebView.skinCSS(for: .typewriter)
    XCTAssertTrue(css.contains("vc-skin:typewriter"))
    XCTAssertTrue(css.contains("Spline Sans Mono"))
    XCTAssertTrue(css.contains("monospace"))
    XCTAssertTrue(css.contains("text-align: center"))
  }

  func testFixedPaletteSkinsCarryNoPrefersColorSchemeBlock() {
    // Single-mode themes set every token unconditionally; the appearance is
    // pinned on the WebView instead of branching on the system setting.
    for skin in [PensieveTheme.parchment, .graphite, .ink, .porcelain, .typewriter] {
      XCTAssertFalse(
        PreviewWebView.skinCSS(for: skin).contains("prefers-color-scheme"),
        "skin \(skin.rawValue) must not branch on prefers-color-scheme")
    }
  }

  func testEverySkinIsExhaustivelyCovered() {
    // Guards against an enum case being added without a skinCSS branch + marker.
    for skin in PensieveTheme.allCases {
      let css = PreviewWebView.skinCSS(for: skin)
      XCTAssertTrue(
        css.contains("vc-skin:\(skin.rawValue)"),
        "skin \(skin.rawValue) is missing its overlay marker")
    }
  }

  // MARK: - semantic status tokens live in the base block

  func testBaseBlockDefinesSemanticStatusTokensInBothModes() {
    let css = PreviewWebView.appearanceCSS(fontSize: 14, skin: .default)

    // Light defaults in the base :root...
    XCTAssertTrue(css.contains("--vc-preview-danger: #cf222e"))
    XCTAssertTrue(css.contains("--vc-preview-warning: #9a6700"))
    XCTAssertTrue(css.contains("--vc-preview-positive: #1a7f37"))
    // ...and dark overrides in the base @media block, so `default`/`raw` keep
    // the tokens without any skin overlay.
    XCTAssertTrue(css.contains("--vc-preview-danger: #ff7b72"))
    XCTAssertTrue(css.contains("--vc-preview-warning: #d29922"))
    XCTAssertTrue(css.contains("--vc-preview-positive: #3fb950"))
  }

  // MARK: - appearanceCSS threads the skin through

  func testAppearanceCSSAppendsSkinOverlay() {
    let base = PreviewWebView.appearanceCSS(fontSize: 14, skin: .default)
    let parchment = PreviewWebView.appearanceCSS(fontSize: 14, skin: .parchment)

    // Both carry the shared base tokens...
    XCTAssertTrue(base.contains("--vc-preview-text"))
    XCTAssertTrue(parchment.contains("--vc-preview-text"))
    // ...but only the parchment skin appends its overlay marker.
    XCTAssertFalse(base.contains("vc-skin:parchment"))
    XCTAssertTrue(parchment.contains("vc-skin:parchment"))
  }

  func testAppearanceCSSDefaultsToDefaultSkin() {
    // The skin parameter is defaulted so legacy call sites keep compiling and
    // render the established surface.
    let css = PreviewWebView.appearanceCSS(fontSize: 14)
    XCTAssertTrue(css.contains("vc-skin:default"))
  }

  func testAppearanceCSSRendersCodeWithoutFramesAndWithASubtleShadow() {
    let css = PreviewWebView.appearanceCSS(fontSize: 14)

    let inlineCodeRule = cssRule(
      selector: ".markdown-body tt", containing: "font-family:", in: css)
    XCTAssertTrue(
      inlineCodeRule?.contains("border: 0 !important;") == true,
      inlineCodeRule ?? "missing")
    XCTAssertTrue(
      inlineCodeRule?.contains("font-family: ui-monospace") == true,
      inlineCodeRule ?? "missing")
    XCTAssertFalse(inlineCodeRule?.contains("1px solid") == true, inlineCodeRule ?? "missing")

    let blockCodeRule = cssRule(
      selector: ".markdown-body pre", containing: "box-shadow:", in: css)
    XCTAssertTrue(
      blockCodeRule?.contains("border: 0 !important;") == true,
      blockCodeRule ?? "missing")
    XCTAssertTrue(
      blockCodeRule?.contains("box-shadow: var(--vc-preview-code-shadow);") == true,
      blockCodeRule ?? "missing")
    XCTAssertTrue(
      blockCodeRule?.contains("font-family: ui-monospace") == true,
      blockCodeRule ?? "missing")
    XCTAssertFalse(blockCodeRule?.contains("1px solid") == true, blockCodeRule ?? "missing")
    XCTAssertTrue(css.contains("--vc-preview-code-shadow:"))

    let raw = PreviewWebView.skinCSS(for: .raw)
    XCTAssertTrue(raw.contains("box-shadow: none !important"))
  }

  func testAppearanceCSSDefinesRelativeHeadingScaleIndependentOfFlavor() {
    for skin in [PensieveTheme.default, .ink, .parchment] {
      let css = PreviewWebView.appearanceCSS(fontSize: 16, skin: skin)

      XCTAssertTrue(css.contains("line-height: 1.25"), "skin \(skin.rawValue)")
      XCTAssertTrue(css.contains("margin-top: 1.4em"), "skin \(skin.rawValue)")
      XCTAssertTrue(css.contains("font-weight: 700"), "skin \(skin.rawValue)")

      for (selector, size) in headingScaleExpectations {
        let rule = cssRule(selector: selector, containing: "font-size:", in: css)
        XCTAssertTrue(rule?.contains("font-size: \(size);") == true, "skin \(skin.rawValue)")
      }
    }
  }

  func testAppearanceCSSKeepsHeadingScaleRelativeAcrossFontSizes() {
    let small = PreviewWebView.appearanceCSS(fontSize: 16)
    let large = PreviewWebView.appearanceCSS(fontSize: 24)

    XCTAssertTrue(small.contains("--vc-font-size: 16px"))
    XCTAssertTrue(large.contains("--vc-font-size: 24px"))

    for css in [small, large] {
      for (selector, size) in headingScaleExpectations {
        guard let rule = cssRule(selector: selector, containing: "font-size:", in: css) else {
          XCTFail("missing heading rule for \(selector)")
          continue
        }
        XCTAssertTrue(rule.contains("font-size: \(size);"), rule)
        XCTAssertFalse(rule.contains("px"), rule)
      }
    }
  }

  func testAppearanceCSSDefaultsTitlebarOverlapToOpaqueUntilNativeMeasurement() {
    let css = PreviewWebView.appearanceCSS(fontSize: 14, skin: .parchment)

    XCTAssertTrue(css.contains("--vc-preview-titlebar-glass-height: 0px"))
    XCTAssertTrue(css.contains("body::before"))
    XCTAssertTrue(css.contains("top: var(--vc-preview-titlebar-glass-height)"))
    XCTAssertTrue(css.contains("background: var(--vc-preview-page-background)"))
    XCTAssertTrue(css.contains("--vc-preview-page-background: var(--vc-preview-parchment-bg)"))
    XCTAssertFalse(css.contains("background: var(--vc-preview-parchment-bg) !important"))
  }

  func testAppearanceCSSPinsPreviewTopContentInsetToWindowChromeRecipe() {
    let css = PreviewWebView.appearanceCSS(fontSize: 14, skin: .default)

    // On macOS 26 the glass-height var stays at its 0px default (the OS
    // pocket owns the chrome offset), so the padding reduces to the Recipe's
    // preview inset; before macOS 26 the glass controller plumbs the measured
    // height into the var as the fallback offset. Same CSS, one owner per OS.
    XCTAssertTrue(
      css.contains(
        "padding: calc(var(--vc-preview-titlebar-glass-height) + \(Int(WindowChromeRecipe.previewContentTopInset))px) clamp(12px, 3vw, 28px) clamp(12px, 3vw, 28px) !important"
      ))
    XCTAssertTrue(css.contains(".markdown-body > :first-child"))
    XCTAssertTrue(css.contains("margin-top: 0 !important"))
  }

  // The glass-height arithmetic is owned by WindowChromeRecipe and pinned in
  // WindowChromeRecipeTests.testTitlebarGlassHeightComesFromWindowContentLayoutDelta;
  // the controller consumes it (polarize L4 removed the forwarding twins here).

  func testTitlebarGlassHeightScriptTargetsDocumentRootCSSVariable() {
    let script = PreviewTitlebarGlassController.titlebarGlassHeightScript(height: 47.2)

    XCTAssertTrue(script.contains("document.documentElement.style.setProperty"))
    XCTAssertTrue(script.contains("'--vc-preview-titlebar-glass-height'"))
    XCTAssertTrue(script.contains("'48px'"))
  }

  @MainActor
  func testPreviewTitlebarGlassControllerAppliesAttachAndNavigationUpdates() {
    let controller = PreviewTitlebarGlassController()
    controller.engagementOverride = true

    var scripts: [String] = []
    controller.scriptEvaluator = { scripts.append($0) }
    controller.titlebarGlassHeightProvider = { _ in 41 }
    controller.attach(to: nil)

    XCTAssertFalse(scripts.isEmpty)
    XCTAssertTrue(scripts.last?.contains("'--vc-preview-titlebar-glass-height'") == true)
    XCTAssertTrue(scripts.last?.contains("'41px'") == true)

    let afterAttachCount = scripts.count
    controller.titlebarGlassHeightProvider = { _ in 0 }
    controller.navigationDidFinish()

    XCTAssertGreaterThan(scripts.count, afterAttachCount)
    XCTAssertTrue(scripts.last?.contains("'--vc-preview-titlebar-glass-height'") == true)
    XCTAssertTrue(scripts.last?.contains("'0px'") == true)
  }

  @MainActor
  func testPreviewTitlebarGlassControllerFollowsContentLayoutChanges() throws {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false
    )
    defer { window.close() }
    WindowChromeRecipe.apply(to: window, title: "Glass KVO Probe")

    let controller = PreviewTitlebarGlassController()
    controller.engagementOverride = true
    var scripts: [String] = []
    controller.scriptEvaluator = { scripts.append($0) }
    controller.attach(to: window)
    let scriptsAfterAttach = scripts.count
    let heightBefore = WindowChromeRecipe.titlebarGlassHeight(for: window)

    // SwiftUI attaches the toolbar AFTER the preview joins the window. That
    // shrinks contentLayoutRect without firing any resize notification and
    // without resizing the full-bleed web view (no layout pass either), so
    // the controller must re-measure on its own or it keeps the glass height
    // it saw mid-construction.
    window.toolbar = NSToolbar(identifier: "pensieve.tests.glassKVOProbe")
    let heightAfter = WindowChromeRecipe.titlebarGlassHeight(for: window)
    guard heightAfter != heightBefore else {
      throw XCTSkip("headless window did not change contentLayoutRect on toolbar attach")
    }

    // The controller coalesces updates (~0.03 s); pump the run loop until the
    // re-measured script lands.
    let deadline = Date().addingTimeInterval(2.0)
    while scripts.count == scriptsAfterAttach && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    XCTAssertGreaterThan(scripts.count, scriptsAfterAttach)
    XCTAssertTrue(
      scripts.last?.contains("'\(Int(heightAfter))px'") == true,
      "controller should re-apply the freshly measured glass height, got: \(scripts.last ?? "none")"
    )
  }

  func testAppearanceCSSCarriesNoPageSideChromeBand() {
    let css = PreviewWebView.appearanceCSS(fontSize: 14, skin: .default)

    // The scrolled dissolve under the glass is owned by the OS pocket
    // (obscuredContentInsets auto-adoption, polarize L3) on both panes. Two
    // page-side imitations died against measured platform walls and must not
    // come back: a backdrop-filter is silently dropped by Core Animation
    // under the native titlebar glass (cut 7-12 — @supports lies, the limit
    // is positional), and a masked backing veil sits ON TOP of the pocket's
    // own ghosts and can only mute them — it transmitted 0/255 on the
    // operator window (polarize L2).
    XCTAssertFalse(css.contains("body::after"))
    XCTAssertFalse(css.contains("mask-image"))
    XCTAssertFalse(css.contains("backdrop-filter:"))
    XCTAssertFalse(css.contains("--vc-preview-titlebar-glass-backing"))
  }

  func testPreviewTitlebarGlassControllerTracksChromeChangeNotifications() {
    XCTAssertTrue(
      PreviewTitlebarGlassController.windowChromeNotifications.contains(
        NSWindow.didResizeNotification))
    XCTAssertTrue(
      PreviewTitlebarGlassController.windowChromeNotifications.contains(
        NSWindow.didEnterFullScreenNotification))
    XCTAssertTrue(
      PreviewTitlebarGlassController.windowChromeNotifications.contains(
        NSWindow.didExitFullScreenNotification))
  }

  func testOpaqueSkinsRouteBackgroundThroughPageBackdropToken() {
    let skins: [PensieveTheme] = [
      .parchment,
      .graphite,
      .ink,
      .porcelain,
      .typewriter,
    ]

    for skin in skins {
      XCTAssertTrue(
        PreviewWebView.skinCSS(for: skin).contains("--vc-preview-page-background"),
        "skin \(skin.rawValue) should keep its pane background below the glass strip")
    }

    XCTAssertFalse(PreviewWebView.skinCSS(for: .default).contains("--vc-preview-page-background"))
    XCTAssertFalse(PreviewWebView.skinCSS(for: .raw).contains("--vc-preview-page-background"))
  }

  // MARK: - request carries the skin axis

  func testRenderRequestCarriesSkinAndDefaultsToDefault() {
    let withDefault = PreviewRenderRequest(
      markdown: "x", fontSize: 14, theme: .gfm, documentURL: nil)
    XCTAssertEqual(withDefault.skin, .default)

    let withInk = PreviewRenderRequest(
      markdown: "x", fontSize: 14, theme: .gfm, skin: .ink, documentURL: nil)
    XCTAssertEqual(withInk.skin, .ink)
    // Skin participates in equality so a skin change is a distinct request.
    XCTAssertNotEqual(withDefault, withInk)
  }

  // MARK: - PensieveTheme migration + fresh-install default

  func testFreshInstallDefaultsToGraphite() {
    XCTAssertEqual(PensieveTheme.resolve(persistedRawValue: nil), .graphite)
  }

  func testKnownRawValuesResolveToThemselves() {
    for theme in PensieveTheme.allCases {
      XCTAssertEqual(PensieveTheme.resolve(persistedRawValue: theme.rawValue), theme)
    }
  }

  func testLegacyRawValuesMigrateToConsolidationTargets() {
    let expected: [String: PensieveTheme] = [
      "paper": .parchment,
      "mla": .parchment,
      "code": .graphite,
      "vista": .porcelain,
      "notion": .porcelain,
      "vercel": .porcelain,
      "themeable": .porcelain,
      "jamstatic": .porcelain,
      "glass": .ink,
      "pergament": .parchment,
      "klinika": .porcelain,
      "maszynopis": .typewriter,
    ]
    for (raw, target) in expected {
      XCTAssertEqual(
        PensieveTheme.resolve(persistedRawValue: raw), target,
        "legacy skin \(raw) should migrate to \(target.rawValue)")
    }
  }

  func testUnknownRawValueFallsBackToDefault() {
    XCTAssertEqual(PensieveTheme.resolve(persistedRawValue: "nonexistent-skin"), .default)
    XCTAssertEqual(PensieveTheme.resolve(persistedRawValue: ""), .default)
  }

  // MARK: - ThemeManager persists + migrates the skin

  func testThemeManagerFreshInstallDefaultsToGraphite() {
    let defaults = makeEphemeralDefaults(prefix: "pensieve.preview.skin.fresh")
    XCTAssertEqual(ThemeManager(defaults: defaults).skin, .graphite)
  }

  func testThemeManagerPersistsSkinSelection() {
    let defaults = makeEphemeralDefaults(prefix: "pensieve.preview.skin.tests")

    let manager = ThemeManager(defaults: defaults)
    manager.skin = .parchment

    let reloaded = ThemeManager(defaults: defaults)
    XCTAssertEqual(reloaded.skin, .parchment)
  }

  func testThemeManagerMigratesLegacyPersistedSkin() {
    let defaults = makeEphemeralDefaults(prefix: "pensieve.preview.skin.legacy")
    defaults.set("glass", forKey: "pensieve.preview.skin")

    XCTAssertEqual(ThemeManager(defaults: defaults).skin, .ink)
  }
}

private let headingScaleExpectations = [
  (".markdown-body h1", "2em"),
  (".markdown-body h2", "1.5em"),
  (".markdown-body h3", "1.25em"),
  (".markdown-body h4", "1em"),
  (".markdown-body h5", "0.875em"),
  (".markdown-body h6", "0.85em"),
]

private func cssRule(selector: String, containing declaration: String, in css: String) -> String? {
  var searchRange = css.startIndex..<css.endIndex
  while let selectorRange = css.range(of: "\(selector) {", range: searchRange) {
    guard let closeBrace = css[selectorRange.upperBound...].firstIndex(of: "}") else {
      return nil
    }
    let rule = String(css[selectorRange.lowerBound...closeBrace])
    if rule.contains(declaration) {
      return rule
    }
    searchRange = closeBrace..<css.endIndex
  }
  return nil
}
