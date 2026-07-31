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

  /// Fill for the on-state chips of the toolbar's toggle groups (Rich Markdown,
  /// auto reload, scroll sync, dictation, autocomplete). The skin's
  /// `chromeAccent`, the same token table `titlebarGlassBackingColor` reads.
  static func toolbarChipBezelColor(for theme: PensieveTheme) -> NSColor {
    theme.tokens.chromeAccent.nsColor
  }

  /// The glyph AppKit draws over a custom `selectedSegmentBezelColor`.
  ///
  /// Not a colour this app sets — AppKit picks the contrasting content tint
  /// itself — but a measured fact the palette has to be chosen against, so it is
  /// written down where the legibility pin can read it. Measured on the running
  /// toolbar (staged probe app, both a warm sienna and a deep teal bezel): the
  /// selected segment's template image is drawn white.
  static let toolbarChipGlyphColor: NSColor = .white

  /// Every `NSSegmentedControl` the window's toolbar currently hosts.
  ///
  /// A SwiftUI `ControlGroup` in a toolbar is not a row of buttons: the bridge
  /// folds the whole group into ONE `NSSegmentedControl` (`SwiftUISegmentedControl`),
  /// one segment per child. The walk is scoped to `toolbar.items` — and their
  /// subitems, which is where the hosting views actually hang — rather than the
  /// titlebar view tree, so a per-pass assertion stays a handful of nodes.
  static func toolbarSegmentedControls(in window: NSWindow) -> [NSSegmentedControl] {
    var found: [NSSegmentedControl] = []

    func collect(from view: NSView) {
      if let segmented = view as? NSSegmentedControl { found.append(segmented) }
      for subview in view.subviews { collect(from: subview) }
    }

    for item in window.toolbar?.items ?? [] {
      if let view = item.view { collect(from: view) }
      if let group = item as? NSToolbarItemGroup {
        for subitem in group.subitems {
          if let view = subitem.view { collect(from: view) }
        }
      }
    }
    return found
  }

  /// A control whose segments toggle independently — a `ControlGroup` holding
  /// at least one `Toggle`. This is the discriminator that keeps the paint on
  /// the chips the request is about and off everything else in the toolbar: the
  /// segmented mode picker tracks `.selectOne`, a group of plain buttons tracks
  /// `.momentary`, and only a group containing toggles tracks `.selectAny`.
  static func isToggleChipGroup(_ control: NSSegmentedControl) -> Bool {
    control.trackingMode == .selectAny
  }

  /// Repaints the on-state chips of the toolbar's toggle groups from the skin,
  /// setting only what currently disagrees. Returns `true` when something had
  /// to be corrected.
  ///
  /// Why this lives on the AppKit side at all: the toggles are declared in
  /// SwiftUI (`EditorToolbelt`), but a toolbar `ControlGroup` is bridged into a
  /// native segmented control whose selected segment AppKit fills from
  /// `controlAccentColor`. That painter is downstream of every SwiftUI modifier
  /// on the toggle — measured on a staged probe app: a `.tint` on the toggle and
  /// a custom `ToggleStyle` are both dropped, and the chip stays system blue over
  /// a parchment or porcelain titlebar. `selectedSegmentBezelColor` is the one
  /// lever AppKit exposes for it.
  ///
  /// Why it is re-asserted on every pass rather than pinned once: SwiftUI resets
  /// the bezel colour whenever it rebuilds the toolbar — which a skin switch
  /// always does, since the appearance menu's label carries the skin name — so a
  /// one-shot pin would survive exactly until the switch that needs it.
  ///
  /// Why a plain compare-and-set is safe here, when the window appearance next
  /// door needs edge-triggering: this property DOES round-trip. Measured over 45
  /// consecutive passes on the probe — the first pass corrects, every pass after
  /// it reads back the value we wrote and corrects nothing — and the write does
  /// not re-drive the SwiftUI graph (the view body was evaluated once across all
  /// 45). So the never-converging loop `assertedAppearances` exists to prevent
  /// has no analogue on this path.
  @discardableResult
  static func assertToolbarChipTint(on window: NSWindow, for theme: PensieveTheme) -> Bool {
    let wanted = toolbarChipBezelColor(for: theme)
    var corrected = false

    for control in toolbarSegmentedControls(in: window) where isToggleChipGroup(control) {
      guard !colorsMatch(control.selectedSegmentBezelColor, wanted) else { continue }
      control.selectedSegmentBezelColor = wanted
      corrected = true
    }

    return corrected
  }

  /// The window appearance a skin demands: its fixed light/dark, or `nil` for
  /// the adaptive skins, which follow the system setting.
  static func windowAppearance(for theme: PensieveTheme) -> NSAppearance? {
    theme.appearanceName.map { NSAppearance(named: $0) } ?? nil
  }

  /// The appearance we last WROTE to a window, keyed weakly by that window so an
  /// entry disappears with the window it describes.
  ///
  /// This bookkeeping exists because `NSWindow.appearance` is not a property this
  /// app can read its own writes back from. Measured on the running app (release
  /// build, instrumented `assertWindowChrome`, 1.27 MB restored draft, parchment):
  /// the assignment lands — reading `window.appearance` immediately afterwards
  /// returns the value we set — and by the time the NEXT update pass runs, the
  /// same window (one identity, 125 consecutive passes) reports `appearance ==
  /// nil` and `effectiveAppearance == darkAqua` again. The document windows are
  /// SwiftUI's `AppKitWindow`: the scene owns their appearance and puts its own
  /// answer back after anyone else writes.
  ///
  /// A compare-and-set against that read-back therefore never converges. Every
  /// pass sees the same mismatch and writes again, each write re-drives the
  /// SwiftUI graph into another full `updateNSView`, and that pass writes again —
  /// an unbounded update loop whose every cycle pays the document-sized editor
  /// hot path. That is the reported hang: main thread pinned at 99% CPU with the
  /// window stuck at 0×0, only for a big document (each cycle costs ~140 ms at
  /// 1.27 MB) crossed with a skin that demands a FIXED appearance (the adaptive
  /// skins want `nil`, which is what the window reports anyway, so they never
  /// write and never spin). Measured against the same rig: never writing the
  /// appearance settles at 0% CPU, writing it exactly once settles at 0% CPU,
  /// writing it per pass burns 99%.
  ///
  /// So the appearance is asserted on OUR intent — the value we last wrote for
  /// this window — instead of on a read-back that is not ours to trust. The
  /// healing property `c454889` and `da7954a` exist for is kept by the backing
  /// colour, which DOES round-trip faithfully and which the same external resets
  /// take out: see `assertWindowChrome`.
  nonisolated(unsafe) private static let assertedAppearances =
    NSMapTable<NSWindow, AssertedAppearance>.weakToStrongObjects()

  /// Boxed `NSAppearance.Name?` — `NSMapTable` stores objects, and "this window
  /// was asserted, and what it wanted was the adaptive `nil`" has to be
  /// representable as distinct from "this window was never asserted".
  private final class AssertedAppearance {
    let name: NSAppearance.Name?
    init(_ name: NSAppearance.Name?) { self.name = name }
  }

  /// Re-asserts the window's chrome (appearance + titlebar backing) for a skin,
  /// setting ONLY what currently disagrees. Returns `true` when something
  /// actually had to be corrected.
  ///
  /// This is an INVARIANT re-asserted on every update pass, not a one-shot pin,
  /// and that distinction is still the whole point. A single pin guarded on
  /// "skin changed" loses permanently to any external reset: AppKit re-bridges
  /// the hosting view's toolbar into the window when toolbar CONTENT changes
  /// (the theme picker's label carries the skin name, so every switch
  /// re-bridges), and a tab-group reshuffle re-parents windows — either can hand
  /// the window back a default chrome after we pinned it, with no further skin
  /// change coming to trigger a re-pin.
  ///
  /// What the two halves compare against differs, because only one of them can
  /// be read back honestly:
  ///
  ///   * `backgroundColor` round-trips (measured: a steady pass reports it equal
  ///     to the wanted backing), so it stays a plain compare-and-set — the real
  ///     level-triggered invariant, idempotent in a steady state.
  ///   * `appearance` does NOT round-trip on a SwiftUI-owned window (see
  ///     `assertedAppearances`), so re-deriving "does it disagree?" from the
  ///     window would spin forever. It is edge-triggered on the value we last
  ///     wrote for this window instead: a skin change, a first assert, and a
  ///     window we have never asserted all still write.
  ///
  /// The appearance is ALSO rewritten whenever the backing had to be corrected.
  /// That is what keeps the healing property: an external reset does not take
  /// the appearance alone — it hands the window back a default chrome, backing
  /// included — so the property we CAN read back is the detector for the one we
  /// cannot. It is the same clobber shape the regression tests model (they reset
  /// appearance and backing together, because that is what a re-bridge and a
  /// re-parent do), and the same one the original report described: the titlebar
  /// strip, which is the backing colour, stayed on the previous skin.
  @discardableResult
  static func assertWindowChrome(on window: NSWindow, for theme: PensieveTheme) -> Bool {
    var corrected = false

    let wantedBacking = titlebarGlassBackingColor(for: theme)
    let backingDisagrees = !colorsMatch(window.backgroundColor, wantedBacking)

    let wantedAppearance = windowAppearance(for: theme)
    let asserted = assertedAppearances.object(forKey: window)
    if asserted == nil || asserted?.name != wantedAppearance?.name || backingDisagrees {
      window.appearance = wantedAppearance
      assertedAppearances.setObject(AssertedAppearance(wantedAppearance?.name), forKey: window)
      corrected = true
    }

    if backingDisagrees {
      window.backgroundColor = wantedBacking
      corrected = true
    }

    // The toolbar's on-state chips are chrome too, and they are lost to the same
    // external resets this method exists to heal (a toolbar re-bridge hands the
    // segmented control back its default accent fill).
    if assertToolbarChipTint(on: window, for: theme) {
      corrected = true
    }

    return corrected
  }

  /// sRGB component comparison. `NSColor ==` is unreliable across colour spaces
  /// and for the catalog/dynamic colours the adaptive skins use, so a plain
  /// equality check would report a permanent mismatch and re-set the backing on
  /// every pass.
  ///
  /// Internal, not private: the preview sink re-asserts its own view-level chrome
  /// (the WebView's under-page backing) on every pass and needs the SAME
  /// comparison, for the same reason — two different comparisons would be two
  /// different definitions of "already correct".
  ///
  /// The tolerance is one 8-bit channel step, not half of one, because
  /// `WKWebView` round-trips `underPageBackgroundColor` through an 8-bit
  /// surface. Measured: setting sRGB `(0.101, 0.1037, 0.1099)` reads back as
  /// `(0.101961, 0.101961, 0.109804)` — a worst case of `0.5/255 ≈ 0.00196`,
  /// which OVERSHOOTS a `1/512 ≈ 0.00195` tolerance. Today's fixed skins are
  /// built from hex, so their components are already 8-bit exact and round-trip
  /// unchanged; any token that was not would make the preview's compare fail
  /// forever and re-set the backing on every single pass — the same never-
  /// converging invariant that made the window appearance spin, on the same hot
  /// path. One channel step is still far finer than any real colour difference,
  /// so an external clobber (a system window background, WebKit's default warm
  /// gray) is nowhere near being mistaken for "already correct".
  static func colorsMatch(_ lhs: NSColor?, _ rhs: NSColor) -> Bool {
    guard let lhs else { return false }
    if lhs == rhs { return true }
    guard
      let left = lhs.usingColorSpace(.sRGB),
      let right = rhs.usingColorSpace(.sRGB)
    else { return false }
    let tolerance = 1.0 / 255.0
    return abs(left.redComponent - right.redComponent) < tolerance
      && abs(left.greenComponent - right.greenComponent) < tolerance
      && abs(left.blueComponent - right.blueComponent) < tolerance
      && abs(left.alphaComponent - right.alphaComponent) < tolerance
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
