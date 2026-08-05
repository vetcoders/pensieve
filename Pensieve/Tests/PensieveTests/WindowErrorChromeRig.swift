import AppKit
import SwiftUI
import XCTest

@testable import Pensieve

/// A real window hosting the REAL `ContentView`, so a test reads the chrome the
/// operator actually sees instead of the value a resolver returned.
///
/// This exists because of the D.2 lesson: a suite of green pins over a pure
/// decision function once passed while the live surface was broken, because
/// nothing in it asserted that the app ever mounted the thing the function
/// decided on. `WindowErrorSurface.resolve` has the same shape, so the pins
/// that matter most here go through `ContentView` itself — its detail pane, its
/// gating, its real editor — and read the AppKit layout that window actually
/// produces.
@MainActor
final class WindowErrorChromeRig {
  let appState: AppState
  let controller: AppController
  let themeManager: ThemeManager
  let window: NSWindow
  let hosting: NSHostingView<AnyView>

  /// Keeps the frame the rig asks for, exactly as the toolbar rig does: AppKit
  /// otherwise shrinks an ordered-in window to the screen it lands on, and a
  /// window narrower than the layout expects hides chrome for reasons that have
  /// nothing to do with the code under test.
  final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
      frameRect
    }
  }

  init(defaults: UserDefaults) {
    appState = AppState(defaults: defaults)
    // `.source` rather than `.split`: the preview half renders Markdown through
    // the whole pipeline on every layout pass, and this rig is about the error
    // line, not the renderer.
    appState.mode = .source
    controller = AppController(appState: appState)
    themeManager = ThemeManager(defaults: defaults)

    window = UnconstrainedWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false

    hosting = NSHostingView(
      rootView: AnyView(
        ContentView(
          // Configured + autocomplete off, so the onboarding sheet this window
          // can present never becomes eligible and never covers the chrome.
          providerOnboardingCoordinator: ProviderOnboardingCoordinator(
            autocompleteEnabled: false, providerConfigured: true)
        )
        // The same chrome contract every production window root carries.
        .pensieveSkinAppearance(themeManager)
        .environment(appState)
        .environmentObject(controller)
        .environmentObject(controller.transcriptionService)
        .environmentObject(themeManager)))
    window.contentView = hosting

    // Parked far offscreen and fully transparent: it lays out and it publishes
    // accessibility, and it never flashes across an operator's screen.
    window.setFrameOrigin(NSPoint(x: -9000, y: -9000))
    window.alphaValue = 0
    window.makeKeyAndOrderFront(nil)
    window.layoutIfNeeded()
    settle(0.4)
  }

  func tearDown() {
    window.orderOut(nil)
    window.contentView = nil
    window.close()
  }

  func settle(_ seconds: TimeInterval = 0.2) {
    window.layoutIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  // MARK: - Reading the live chrome

  /// The height the editor pane actually occupies in this window.
  ///
  /// This is how a pin here reads "is the banner on screen": the banner is a
  /// sibling of the editor inside the detail pane's `VStack`, so mounting it
  /// takes real room away from the editor and unmounting it gives that room
  /// back. Measured on this rig the difference is a stable 26pt, but no pin
  /// hardcodes that — each one calibrates against the same window's own
  /// banner-free height, so a change to the banner's padding or font moves the
  /// number without touching a test.
  ///
  /// The obvious read — accessibility identifiers — was tried first and does
  /// not work here: measured on this rig, `NSHostingView` publishes an `AXGroup`
  /// with ZERO children in a headless test process (no assistive client ever
  /// attaches, so SwiftUI never builds the tree). Every identifier the banner
  /// declares is real and reaches VoiceOver in the shipped app; none of it is
  /// visible to a `swift test` run, so a pin built on it would have skipped
  /// itself into a permanent green.
  func editorPaneHeight() -> CGFloat? {
    textView()?.enclosingScrollView?.frame.height
  }

  /// The editor's real `NSTextView`, the thing that holds first responder while
  /// the operator is typing.
  func textView() -> NSTextView? {
    guard let content = window.contentView else { return nil }
    func walk(_ view: NSView) -> NSTextView? {
      if let text = view as? NSTextView { return text }
      for subview in view.subviews {
        if let found = walk(subview) { return found }
      }
      return nil
    }
    return walk(content)
  }
}

extension XCTestCase {
  /// A rig with a document open and an editor laid out, ready to be measured.
  ///
  /// Skips rather than fails when the headless host laid out no editor at all:
  /// with no editor there is no pane to measure and no first responder to
  /// protect, and a failure there would be about the environment rather than
  /// the chrome. The skip is deliberately narrow — it triggers only when the
  /// window hosts NO text view, never when the editor is there and the banner
  /// fails to change it.
  @MainActor
  func makeWindowErrorChromeRig(prefix: String) throws -> WindowErrorChromeRig {
    let rig = WindowErrorChromeRig(defaults: makeEphemeralDefaults(prefix: prefix))
    rig.appState.documentSession = .untitled()
    rig.appState.documentSession.text = "the operator is in the middle of a sentence"
    rig.settle(0.3)
    guard rig.editorPaneHeight() != nil else {
      rig.tearDown()
      throw XCTSkip("headless window laid out no editor")
    }
    return rig
  }
}
