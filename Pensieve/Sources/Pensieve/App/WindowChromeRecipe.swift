import AppKit
import SwiftUI

enum WindowChromeRecipe {
  static let documentTabbingIdentifier = "Pensieve.DocumentWindow"
  static let defaultContentSize = NSSize(width: 1180, height: 760)
  static let minimumContentSize = NSSize(width: 720, height: 480)
  static let toolbarStyle: NSWindow.ToolbarStyle = .unified
  static let documentContentTopInset: CGFloat = 10
  static var previewContentTopInset: CGFloat { max(0, documentContentTopInset - 2) }
  static let documentStyleMask: NSWindow.StyleMask = [
    .titled,
    .closable,
    .miniaturizable,
    .resizable,
    .fullSizeContentView,
  ]

  static var defaultContentRect: NSRect {
    NSRect(
      x: 0,
      y: 0,
      width: defaultContentSize.width,
      height: defaultContentSize.height
    )
  }

  static func apply(to window: NSWindow, title: String) {
    window.isReleasedWhenClosed = false
    window.toolbarStyle = toolbarStyle
    window.tabbingMode = .preferred
    window.tabbingIdentifier = documentTabbingIdentifier
    window.title = title
    window.contentMinSize = minimumContentSize
  }

  /// Backing colour WebKit composites into the titlebar glass above the
  /// preview page (`WKWebView.underPageBackgroundColor`). Must be the same
  /// surface the editor pane feeds the chrome — `textBackgroundColor` — or
  /// the glass strip reads a different tint on each side of the split
  /// divider: WebKit's default under-page colour is a light warm gray that
  /// glows through dark chrome as a lighter, sepia-tinted patch.
  static var titlebarGlassBackingColor: NSColor { .textBackgroundColor }

  /// The same backing truth as a CSS colour, resolved through the window's
  /// effective appearance. The preview's veil band (cut 7-12) must paint the
  /// exact pixels the native glass composites on the editor side of the
  /// split, or the band reads as a tinted stripe — the 7-9 failure class.
  static func titlebarGlassBackingCSSColor(for window: NSWindow?) -> String {
    let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
    var cssColor = "transparent"
    appearance.performAsCurrentDrawingAppearance {
      guard let srgb = titlebarGlassBackingColor.usingColorSpace(.sRGB) else { return }
      let red = Int(round(srgb.redComponent * 255))
      let green = Int(round(srgb.greenComponent * 255))
      let blue = Int(round(srgb.blueComponent * 255))
      cssColor = "rgb(\(red), \(green), \(blue))"
    }
    return cssColor
  }

  /// Measured transmission profile of the editor's native scroll-edge effect
  /// (cut 7-12b row probe: ~9% ghost transmission at the window edge, ~15%
  /// mid-band, ~38% at 80%, ~55% just above the chrome seam). The preview's
  /// veil band must mask to `alpha = 1 − transmission` at each row, and no
  /// stop may be fully opaque — an opaque segment reads as a solid plate under
  /// the toolbar buttons with the dissolve compressed into a stripe below.
  /// This is the ONLY home of the profile: the veil CSS and its regression
  /// pins both consume `titlebarGlassVeilMaskCSSGradient`.
  static let titlebarGlassVeilMaskStops: [(alpha: Double, percent: Int)] = [
    (alpha: 0.92, percent: 0),
    (alpha: 0.86, percent: 45),
    (alpha: 0.62, percent: 80),
    (alpha: 0.42, percent: 100),
  ]

  static var titlebarGlassVeilMaskCSSGradient: String {
    let stops =
      titlebarGlassVeilMaskStops
      .map { "rgba(0, 0, 0, \(String(format: "%.2f", $0.alpha))) \($0.percent)%" }
      .joined(separator: ", ")
    return "linear-gradient(to bottom, \(stops))"
  }

  static func titlebarGlassHeight(frameHeight: CGFloat, contentLayoutHeight: CGFloat) -> CGFloat {
    ceil(max(0, frameHeight - contentLayoutHeight))
  }

  static func titlebarGlassHeight(for window: NSWindow?) -> CGFloat {
    guard let window else { return 0 }
    return titlebarGlassHeight(
      frameHeight: window.frame.height,
      contentLayoutHeight: window.contentLayoutRect.height)
  }

  static func contentLayoutRect(in view: NSView) -> NSRect? {
    guard let window = view.window else { return nil }
    return view.convert(window.contentLayoutRect, from: nil)
  }

  static func chromeClippedVisibleRect(for view: NSView, fallback visible: NSRect) -> NSRect {
    guard let content = contentLayoutRect(in: view) else { return visible }
    let clipped = visible.intersection(content)
    return clipped.isEmpty ? visible : clipped
  }
}

extension Scene {
  func pensieveDocumentWindowChrome() -> some Scene {
    self
      .windowStyle(.titleBar)
      .windowToolbarStyle(.unified(showsTitle: true))
      .defaultSize(
        width: WindowChromeRecipe.defaultContentSize.width,
        height: WindowChromeRecipe.defaultContentSize.height
      )
      .windowResizability(.contentMinSize)
  }
}
