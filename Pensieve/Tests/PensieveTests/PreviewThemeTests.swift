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

  func testPaperSkinIsSerifAndNarrow() {
    let css = PreviewWebView.skinCSS(for: .paper)
    XCTAssertTrue(css.contains("vc-skin:paper"))
    XCTAssertTrue(css.contains("serif"))
    XCTAssertTrue(css.contains("max-width: 720px"))
  }

  func testCodeSkinIsMonospace() {
    let css = PreviewWebView.skinCSS(for: .code)
    XCTAssertTrue(css.contains("vc-skin:code"))
    XCTAssertTrue(css.contains("monospace"))
  }

  func testRawSkinStripsChrome() {
    let css = PreviewWebView.skinCSS(for: .raw)
    XCTAssertTrue(css.contains("vc-skin:raw"))
    XCTAssertTrue(css.contains("max-width: none"))
  }

  func testNotionSkinUsesNotionTokens() {
    let css = PreviewWebView.skinCSS(for: .notion)
    XCTAssertTrue(css.contains("vc-skin:notion"))
    // Notion ink + red inline-code accent are the signature tokens.
    XCTAssertTrue(css.contains("#37352f"))
    XCTAssertTrue(css.contains("--vc-preview-notion-code"))
  }

  func testVistaSkinBandsTables() {
    let css = PreviewWebView.skinCSS(for: .vista)
    XCTAssertTrue(css.contains("vc-skin:vista"))
    XCTAssertTrue(css.contains("Helvetica"))
    // Banded rows are the VISTA table signature.
    XCTAssertTrue(css.contains("tbody tr:nth-child(even)"))
  }

  func testMLASkinIsSerifAndDoubleSpaced() {
    let css = PreviewWebView.skinCSS(for: .mla)
    XCTAssertTrue(css.contains("vc-skin:mla"))
    XCTAssertTrue(css.contains("serif"))
    XCTAssertTrue(css.contains("line-height: 2.0"))
  }

  func testJamstaticSkinIsPoppinsWithLilacAccent() {
    let css = PreviewWebView.skinCSS(for: .jamstatic)
    XCTAssertTrue(css.contains("vc-skin:jamstatic"))
    XCTAssertTrue(css.contains("Poppins"))
    XCTAssertTrue(css.contains("#b1a3cc"))
  }

  func testVercelSkinIsBlueLinkOnNearBlackInk() {
    let css = PreviewWebView.skinCSS(for: .vercel)
    XCTAssertTrue(css.contains("vc-skin:vercel"))
    XCTAssertTrue(css.contains("#171717"))
    XCTAssertTrue(css.contains("Geist"))
    XCTAssertTrue(css.contains("font-weight: 700"))
  }

  func testThemeableSkinIsInterOnSlate() {
    let css = PreviewWebView.skinCSS(for: .themeable)
    XCTAssertTrue(css.contains("vc-skin:themeable"))
    XCTAssertTrue(css.contains("Inter"))
    XCTAssertTrue(css.contains("#1e293b"))
  }

  func testGlassSkinIsBackdropBlurred() {
    let css = PreviewWebView.skinCSS(for: .glass)
    XCTAssertTrue(css.contains("vc-skin:glass"))
    XCTAssertTrue(css.contains("backdrop-filter: blur"))
    XCTAssertTrue(css.contains("linear-gradient"))
  }

  func testEverySkinIsExhaustivelyCovered() {
    // Guards against an enum case being added without a skinCSS branch + marker.
    for skin in ThemeManager.PreviewTheme.allCases {
      let css = PreviewWebView.skinCSS(for: skin)
      XCTAssertTrue(
        css.contains("vc-skin:\(skin.rawValue)"),
        "skin \(skin.rawValue) is missing its overlay marker")
    }
  }

  // MARK: - appearanceCSS threads the skin through

  func testAppearanceCSSAppendsSkinOverlay() {
    let base = PreviewWebView.appearanceCSS(fontSize: 14, skin: .default)
    let paper = PreviewWebView.appearanceCSS(fontSize: 14, skin: .paper)

    // Both carry the shared base tokens...
    XCTAssertTrue(base.contains("--vc-preview-text"))
    XCTAssertTrue(paper.contains("--vc-preview-text"))
    // ...but only the paper skin appends its overlay marker.
    XCTAssertFalse(base.contains("vc-skin:paper"))
    XCTAssertTrue(paper.contains("vc-skin:paper"))
  }

  func testAppearanceCSSDefaultsToDefaultSkin() {
    // The skin parameter is defaulted so legacy call sites keep compiling and
    // render the established surface.
    let css = PreviewWebView.appearanceCSS(fontSize: 14)
    XCTAssertTrue(css.contains("vc-skin:default"))
  }

  func testAppearanceCSSDefinesRelativeHeadingScaleIndependentOfFlavor() {
    for skin in [ThemeManager.PreviewTheme.default, .vercel, .paper] {
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
    let css = PreviewWebView.appearanceCSS(fontSize: 14, skin: .paper)

    XCTAssertTrue(css.contains("--vc-preview-titlebar-glass-height: 0px"))
    XCTAssertTrue(css.contains("body::before"))
    XCTAssertTrue(css.contains("top: var(--vc-preview-titlebar-glass-height)"))
    XCTAssertTrue(css.contains("background: var(--vc-preview-page-background)"))
    XCTAssertTrue(css.contains("--vc-preview-page-background: var(--vc-preview-paper-bg)"))
    XCTAssertFalse(css.contains("background: var(--vc-preview-paper-bg) !important"))
  }

  func testAppearanceCSSPinsPreviewTopContentInsetToWindowChromeRecipe() {
    let css = PreviewWebView.appearanceCSS(fontSize: 14, skin: .default)

    // The top inset rides on the measured glass height: the viewport is
    // full-bleed (obscured content insets zeroed), so the CSS var is the only
    // owner of the chrome offset — a bare pixel inset would park the first
    // line under the toolbelt.
    XCTAssertTrue(
      css.contains(
        "padding: calc(var(--vc-preview-titlebar-glass-height) + \(Int(WindowChromeRecipe.previewContentTopInset))px) clamp(12px, 3vw, 28px) clamp(12px, 3vw, 28px) !important"
      ))
    XCTAssertTrue(css.contains(".markdown-body > :first-child"))
    XCTAssertTrue(css.contains("margin-top: 0 !important"))
  }

  func testTitlebarGlassHeightComesFromWindowContentLayoutDelta() {
    XCTAssertEqual(
      PreviewTitlebarGlassController.titlebarGlassHeight(
        frameHeight: 800, contentLayoutHeight: 736),
      64)
    XCTAssertEqual(
      PreviewTitlebarGlassController.titlebarGlassHeight(
        frameHeight: 800, contentLayoutHeight: 800),
      0)
    XCTAssertEqual(
      PreviewTitlebarGlassController.titlebarGlassHeight(
        frameHeight: 799.5, contentLayoutHeight: 735.25),
      65)
    XCTAssertEqual(
      PreviewTitlebarGlassController.titlebarGlassHeight(
        frameHeight: 700, contentLayoutHeight: 724),
      0)
  }

  func testTitlebarGlassHeightScriptTargetsDocumentRootCSSVariable() {
    let script = PreviewTitlebarGlassController.titlebarGlassHeightScript(height: 47.2)

    XCTAssertTrue(script.contains("document.documentElement.style.setProperty"))
    XCTAssertTrue(script.contains("'--vc-preview-titlebar-glass-height'"))
    XCTAssertTrue(script.contains("'48px'"))
  }

  @MainActor
  func testPreviewTitlebarGlassControllerAppliesAttachAndNavigationUpdates() {
    let controller = PreviewTitlebarGlassController()

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

  func testAppearanceCSSPaintsGlassBandVeilOwnedByMeasuredVariables() {
    let css = PreviewWebView.appearanceCSS(fontSize: 14, skin: .default)

    XCTAssertTrue(css.contains("--vc-preview-titlebar-glass-backing: transparent"))
    XCTAssertTrue(css.contains("body::after"))
    XCTAssertTrue(css.contains("height: var(--vc-preview-titlebar-glass-height)"))
    XCTAssertTrue(
      css.contains("background: var(--vc-preview-titlebar-glass-backing, transparent)"))
    // The veil's mask must never carry a fully-opaque stop (`black`): the
    // editor's scroll-edge effect transmits ghosts across the whole band, so
    // an opaque segment reads as a solid plate under the toolbar buttons with
    // the dissolve compressed into a stripe below them (cut 7-12b).
    XCTAssertTrue(
      css.contains(
        "mask-image: linear-gradient(to bottom, rgba(0, 0, 0, 0.92) 0%, "
          + "rgba(0, 0, 0, 0.86) 45%, rgba(0, 0, 0, 0.62) 80%, rgba(0, 0, 0, 0.42) 100%)"))
    XCTAssertFalse(css.contains("mask-image: linear-gradient(to bottom, black"))
    // Core Animation refuses nested backdrop capture under the native titlebar
    // glass (measured in cut 7-12): a backdrop-filter here passes @supports,
    // renders fine in a plain window, and silently drops the whole veil —
    // mask included — in the real chrome. The veil must stay filter-free.
    XCTAssertFalse(css.contains("backdrop-filter:"))
  }

  func testTitlebarGlassBackingScriptTargetsDocumentRootCSSVariable() {
    let script = PreviewTitlebarGlassController.titlebarGlassBackingScript(
      cssColor: "rgb(30, 30, 30)")

    XCTAssertTrue(script.contains("document.documentElement.style.setProperty"))
    XCTAssertTrue(script.contains("'--vc-preview-titlebar-glass-backing'"))
    XCTAssertTrue(script.contains("'rgb(30, 30, 30)'"))
  }

  @MainActor
  func testPreviewTitlebarGlassControllerPlumbsBackingColourWithHeight() {
    let controller = PreviewTitlebarGlassController()

    var scripts: [String] = []
    controller.scriptEvaluator = { scripts.append($0) }
    controller.titlebarGlassHeightProvider = { _ in 41 }
    controller.titlebarGlassBackingProvider = { _ in "rgb(1, 2, 3)" }
    controller.attach(to: nil)

    XCTAssertTrue(scripts.last?.contains("'--vc-preview-titlebar-glass-height'") == true)
    XCTAssertTrue(scripts.last?.contains("'--vc-preview-titlebar-glass-backing'") == true)
    XCTAssertTrue(scripts.last?.contains("'rgb(1, 2, 3)'") == true)

    // A dark/light flip changes only the backing colour — same glass height.
    // The guard must not swallow that update.
    let beforeFlip = scripts.count
    controller.titlebarGlassBackingProvider = { _ in "rgb(4, 5, 6)" }
    controller.appearanceDidChange()
    let deadline = Date().addingTimeInterval(2.0)
    while scripts.count == beforeFlip && Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    XCTAssertGreaterThan(scripts.count, beforeFlip)
    XCTAssertTrue(scripts.last?.contains("'rgb(4, 5, 6)'") == true)
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
    let skins: [ThemeManager.PreviewTheme] = [
      .paper,
      .code,
      .notion,
      .vista,
      .mla,
      .jamstatic,
      .vercel,
      .themeable,
      .glass,
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

    let withCode = PreviewRenderRequest(
      markdown: "x", fontSize: 14, theme: .gfm, skin: .code, documentURL: nil)
    XCTAssertEqual(withCode.skin, .code)
    // Skin participates in equality so a skin change is a distinct request.
    XCTAssertNotEqual(withDefault, withCode)
  }

  // MARK: - ThemeManager persists the skin

  func testThemeManagerPersistsSkinSelection() {
    let suiteName = "pensieve.preview.skin.tests"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)

    let manager = ThemeManager(defaults: defaults)
    XCTAssertEqual(manager.skin, .default)
    manager.skin = .paper

    let reloaded = ThemeManager(defaults: defaults)
    XCTAssertEqual(reloaded.skin, .paper)

    defaults.removePersistentDomain(forName: suiteName)
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
