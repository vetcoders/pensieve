import AppKit
import SwiftUI

enum WindowChromeRecipe {
  static let documentTabbingIdentifier = "Pensieve.DocumentWindow"
  static let defaultContentSize = NSSize(width: 1180, height: 760)
  static let minimumContentSize = NSSize(width: 720, height: 480)
  /// Initial content width both window paths present at. `defaultContentSize`
  /// is the narrower geometry the recipe pins for resize/minimum purposes; the
  /// unified toolbar needs more room than that or its trailing groups (preview
  /// runtime + assistants) collapse into the overflow chevron and disappear
  /// from the accessibility tree. Factory windows and the scene-owned launcher
  /// must agree here, otherwise the cold frame a user (or `make ui-smoke`)
  /// meets depends on which path happened to build it.
  static let toolbarFittingContentWidth: CGFloat = 1300
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

  /// Content rect the factory hands `NSWindow(contentRect:)`, sized and
  /// centred so the FINAL window frame — the content rect grown by whatever
  /// titlebar/border `styleMask` contributes — still fits inside
  /// `visibleFrame`. The clamp is applied to the frame, not the bare content:
  /// capping only the content height lets the titlebar spill above the work
  /// area on a low screen. `documentStyleMask` uses `.fullSizeContentView`,
  /// where the titlebar overlays the content and the frame equals the content
  /// rect (chrome delta 0), so today this returns the same geometry as a plain
  /// content clamp; routing through `NSWindow.frameRect(forContentRect:)`
  /// keeps it correct-by-construction if the mask ever drops
  /// `.fullSizeContentView`. The `styleMask` parameter exists so the chrome
  /// accounting is unit-testable with a mask that actually adds a titlebar.
  @MainActor
  static func factoryInitialContentRect(
    in visibleFrame: NSRect,
    styleMask: NSWindow.StyleMask
  ) -> NSRect {
    let desiredContent = NSRect(
      x: 0,
      y: 0,
      width: toolbarFittingContentWidth,
      height: defaultContentSize.height
    )
    let desiredFrame = NSWindow.frameRect(forContentRect: desiredContent, styleMask: styleMask)
    let frameSize = NSSize(
      width: min(desiredFrame.width, visibleFrame.width),
      height: min(desiredFrame.height, visibleFrame.height)
    )
    let finalFrame = NSRect(
      x: visibleFrame.midX - frameSize.width / 2,
      y: visibleFrame.midY - frameSize.height / 2,
      width: frameSize.width,
      height: frameSize.height
    )
    return NSWindow.contentRect(forFrameRect: finalFrame, styleMask: styleMask)
  }

  @MainActor
  static func factoryInitialFrame(in visibleFrame: NSRect) -> NSRect {
    factoryInitialContentRect(in: visibleFrame, styleMask: documentStyleMask)
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
  /// surface the editor pane reports for the active theme — `tokens.source` —
  /// or the glass strip reads a different tint on each side of the split
  /// divider: WebKit's default under-page colour is a light warm gray that
  /// glows through dark chrome as a lighter, sepia-tinted patch, and a fixed
  /// `textBackgroundColor` would light-up a dark theme's titlebar.
  ///
  /// This colour and the pre-macOS-26 fallback offset below are the ONLY
  /// chrome truths the preview consumes. The scrolled dissolve itself has one
  /// owner on both panes — the OS: AppKit's automatic content insets for the
  /// editor's scroll view, WebKit's auto-adopted `obscuredContentInsets`
  /// pocket for the preview (measured, polarize L3: the pocket renders the
  /// same scroll-edge ghosts as the editor band, 2–12/255 vs 3–11/255).
  static func titlebarGlassBackingColor(for theme: PensieveTheme) -> NSColor {
    theme.tokens.source.nsColor
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
        width: WindowChromeRecipe.toolbarFittingContentWidth,
        height: WindowChromeRecipe.defaultContentSize.height
      )
      .windowResizability(.contentMinSize)
  }
}
