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
