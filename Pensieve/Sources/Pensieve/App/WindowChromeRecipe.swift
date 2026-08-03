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

  // MARK: - Native tab bar

  /// Light or dark, with the vibrant variants folded onto the two answers that
  /// matter. `VibrantDark` and `DarkAqua` are the same SIDE — comparing raw
  /// names would call them a disagreement and rewrite a tab bar that was already
  /// right, taking its vibrancy with it.
  static func appearancePolarity(_ appearance: NSAppearance?) -> NSAppearance.Name? {
    appearance?.bestMatch(from: [.aqua, .darkAqua])
  }

  /// The side the whole window is on, as the tab bar has to agree with it.
  ///
  /// Taken from the SKIN first and from the window only for the adaptive skins,
  /// which name no appearance of their own. Skin-first is not a stylistic choice:
  /// a skin switch is one of the moments the tab bar is rebuilt, and during it
  /// `window.effectiveAppearance` can still be reporting the outgoing half — so
  /// reading the window there would pin the tab bar to the skin being left.
  static func tabBarPolarity(on window: NSWindow, for theme: PensieveTheme) -> NSAppearance.Name? {
    appearancePolarity(windowAppearance(for: theme))
      ?? appearancePolarity(window.effectiveAppearance)
  }

  /// The same side as `polarity`, keeping whatever vibrancy the view had chosen
  /// for itself. A glass node that picked `VibrantLight` is put back to
  /// `VibrantDark`, not to a flat `DarkAqua` that would drop the material.
  static func matchingAppearance(
    for polarity: NSAppearance.Name, preservingVibrancyOf current: NSAppearance?
  ) -> NSAppearance? {
    let vibrant = current?.name == .vibrantLight || current?.name == .vibrantDark
    switch polarity {
    case .darkAqua: return NSAppearance(named: vibrant ? .vibrantDark : .darkAqua)
    default: return NSAppearance(named: vibrant ? .vibrantLight : .aqua)
    }
  }

  /// Every view inside the window's NATIVE TAB BAR that carries an appearance of
  /// its OWN — the self-selectors, and the only nodes worth inspecting.
  ///
  /// The tab bar is not part of the toolbar. It is a separate
  /// `NSTitlebarAccessoryViewController` AppKit builds and owns, so
  /// `toolbarColorScheme` — the declaration `bdbb816` added to stop the toolbar
  /// platters reading the paper — provably does not reach it. Measured on a
  /// two-tab probe (window `darkAqua`, split dark|white content):
  ///
  ///   accessory[0] NSTitlebarAccessoryViewController (layout .bottom)
  ///     NSTabBar                              set=—            eff=VibrantDark
  ///       NSTabBarTrackView                   set=—            eff=VibrantDark
  ///         NSLessExpensiveSubduedGlassEffectView  set=VibrantDark  ← SET
  ///           …
  ///             NSTabButton                   set=—            eff=VibrantDark
  ///               NSGlassEffectView           set=—            eff=VibrantDark
  ///
  /// and declaring an appearance on the ACCESSORY VIEW does not reach the node
  /// that set its own: with the accessory declared `aqua`, `NSTabBar` and
  /// `NSTabBarTrackView` moved to `Aqua` while the glass view stayed on its own
  /// `VibrantDark`. An ancestor declaration is therefore not a fix here, which is
  /// the difference from the toolbar — there AppKit offered a supported lever,
  /// and for the tab bar it offers none.
  static func tabBarSelfSelectingViews(in window: NSWindow) -> [NSView] {
    guard window.tabGroup?.isTabBarVisible == true else { return [] }

    var found: [NSView] = []
    func collect(from view: NSView) {
      if view.appearance != nil { found.append(view) }
      for subview in view.subviews { collect(from: subview) }
    }
    for controller in window.titlebarAccessoryViewControllers {
      guard hostsTabBar(controller.view) else { continue }
      collect(from: controller.view)
    }
    return found
  }

  private static func hostsTabBar(_ view: NSView) -> Bool {
    if String(describing: type(of: view)) == "NSTabBar" { return true }
    return view.subviews.contains(where: hostsTabBar)
  }

  /// Puts any tab-bar glass that has self-selected the WRONG SIDE back on the
  /// window's. Returns `true` when something had to be corrected.
  ///
  /// The reported symptom is a native tab pill positioned over the preview
  /// column rendering light/cream on a dark window while its neighbour over the
  /// editor column stays dark — the same defect `bdbb816` measured on the
  /// toolbar platters, on a surface that fix could not reach. It is TRANSIENT
  /// (both pills measured dark at 14:50, the right one light at 14:51:49),
  /// because the tab bar is rebuilt out from under any one-shot pin: measured on
  /// the probe, EVERY window in the group carries its own accessory, and
  /// selecting the other tab moves the populated tab bar to that window and
  /// hands it back a glass node with NO appearance of its own — free to
  /// self-select from whatever is composited beneath it.
  ///
  /// Only nodes that disagree in POLARITY are written, so a tab bar that is
  /// already on the right side is not touched at all and keeps its exact
  /// material. Measured on the probe: flipping the three glass nodes to
  /// `VibrantLight` costs ONE repair pass of three writes, and the next 19
  /// passes correct nothing — the write round-trips, so a compare-and-set
  /// converges here. That is what makes this safe to re-assert from a window
  /// update cycle, unlike `NSWindow.appearance` on a scene-owned window, which
  /// does not round-trip and whose per-pass rewrite is the 99% CPU start-up hang
  /// `assertedAppearances` exists to prevent. These are AppKit's own titlebar
  /// accessory views; no SwiftUI scene owns them and none writes an answer back.
  ///
  /// `tabBarViews` exists so the polarity rules can be driven against a known
  /// view shape. It defaults to the real walk, and the end-to-end pin
  /// (`testARealTabGroupsFlippedGlassIsRepairedThroughAssertWindowChrome`) goes
  /// through `assertWindowChrome` with the default, so the discovery half is
  /// never left unproven by the seam.
  @discardableResult
  static func assertTabBarAppearance(
    on window: NSWindow, for theme: PensieveTheme, tabBarViews: [NSView]? = nil
  ) -> Bool {
    guard let polarity = tabBarPolarity(on: window, for: theme) else { return false }
    var corrected = false

    for view in tabBarViews ?? tabBarSelfSelectingViews(in: window) {
      guard appearancePolarity(view.appearance) != polarity else { continue }
      guard
        let wanted = matchingAppearance(for: polarity, preservingVibrancyOf: view.appearance)
      else { continue }
      view.appearance = wanted
      corrected = true
    }

    return corrected
  }

  /// The window appearance a skin demands: its fixed light/dark, or `nil` for
  /// the adaptive skins, which follow the system setting.
  static func windowAppearance(for theme: PensieveTheme) -> NSAppearance? {
    theme.appearanceName.map { NSAppearance(named: $0) } ?? nil
  }

  /// The appearance the READING SURFACE wants — the preview WebView and the
  /// exported sheet. Identical to `windowAppearance` for every skin except a
  /// PAIRED one, whose window follows the system while its paper stays white on
  /// both sides. Derived from the theme rather than re-deciding here, so the two
  /// answers cannot drift.
  static func readingSurfaceAppearance(for theme: PensieveTheme) -> NSAppearance? {
    theme.readingSurfaceAppearanceName.map { NSAppearance(named: $0) } ?? nil
  }

  /// The appearance to render an EXPORT under. A paired skin exports its light
  /// half from a dark machine too: the page is paper, and paper is white.
  static func exportAppearance(for theme: PensieveTheme) -> NSAppearance? {
    theme.exportAppearanceName.map { NSAppearance(named: $0) } ?? nil
  }

  /// The same demand expressed at the SwiftUI level, which is the ONLY level a
  /// scene-owned window respects — see `pensieveSkinAppearance`. Derived from
  /// `windowAppearance` rather than from the token table a second time, so the
  /// AppKit and SwiftUI answers cannot drift apart.
  static func preferredColorScheme(for theme: PensieveTheme) -> ColorScheme? {
    switch theme.appearanceName {
    case .some(.darkAqua): return .dark
    case .some: return .light
    case .none: return nil
    }
  }

  /// Everything a skin DECLARES to SwiftUI about a window's chrome: the scheme
  /// for the window, and the scheme for its toolbar. Two fields, ONE decision —
  /// see `SkinChrome`.
  static func skinChrome(for theme: PensieveTheme) -> SkinChrome {
    let scheme = preferredColorScheme(for: theme)
    return SkinChrome(window: scheme, toolbar: scheme)
  }

  /// The window scheme and the TOOLBAR scheme, together, because leaving the
  /// second one unstated is not a neutral default — it is a hand-off.
  ///
  /// On macOS 26 a toolbar is glass, and each `NSToolbarPlatterView` picks its
  /// OWN appearance from the luminance of the content composited beneath it
  /// unless the toolbar states a scheme. A window can therefore be `.darkAqua`
  /// from top to bottom and still hand individual pills a light appearance —
  /// which is exactly what this app does to itself, because a PAIRED skin pins
  /// its reading surface white in BOTH halves (`readingSurfaceAppearanceName`).
  /// The white sheet sits under the trailing half of the toolbar, so AppKit
  /// dresses the pills over it for a light background.
  ///
  /// Measured on an isolated probe (own bundle id, own support dir, typewriter,
  /// system dark, one document open in split mode, window 1300 wide with the
  /// editor/preview divider at x=764):
  ///
  ///   * WITHOUT a declared toolbar scheme — window `darkAqua`, `NSTitlebarView`
  ///     and `NSToolbarView` `VibrantDark`, and then every platter from x=913
  ///     rightwards (plus the clipped-items `»` indicator at x=1252) carrying an
  ///     EXPLICITLY SET `VibrantLight`. Every platter whose centre falls over the
  ///     preview column, and no other. That is the reported symptom: dark
  ///     titlebar, dark leading families, white trailing pills.
  ///   * WITH it — the same window, the same document, every platter
  ///     `DarkAqua`, none carrying an appearance of its own.
  ///
  /// The launcher window has no preview and reproduced nothing, which is why the
  /// bug looked like it came and went with the document rather than with a
  /// commit: it is not a regression from the live-flip fix, and the same mix is
  /// visible in probe captures taken on the code before it.
  ///
  /// Stating the scheme is the supported way out and is idempotent — unlike
  /// writing appearances onto the platters ourselves, which would re-enter the
  /// never-converging write loop `assertedAppearances` exists to prevent.
  struct SkinChrome: Equatable {
    /// `nil` means "follow the system", which is what the adaptive skins want.
    let window: ColorScheme?
    /// Always the SAME answer as `window`. A skin that declares its window dark
    /// and leaves its toolbar to guess is the defect above, spelled out.
    let toolbar: ColorScheme?
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

    // The native tab bar is chrome too, and it is the one surface the SwiftUI
    // scheme declaration cannot reach at all — see `assertTabBarAppearance`.
    if assertTabBarAppearance(on: window, for: theme) {
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

extension View {
  /// Declares the skin's fixed light/dark for the window hosting this root.
  ///
  /// This is the half of the chrome that `assertWindowChrome` provably CANNOT
  /// deliver, and it is why a light skin used to render a split window: parchment
  /// pane, dark sidebar and traffic lights. The editor and preview paint every
  /// pixel they own from the token table, so they look right whatever the window
  /// appearance says; the sidebar is a system material and the titlebar widgets
  /// are AppKit's, so they follow `effectiveAppearance` — and on a SwiftUI
  /// scene-owned window that stays the SYSTEM appearance no matter what AppKit
  /// writes.
  ///
  /// Measured on a probe app (two windows, same SwiftUI root, dark system, the
  /// shipping edge-triggered assert running on every update pass):
  ///
  ///   * `NSWindow` + `NSHostingView` (the factory tab path) keeps the written
  ///     appearance — `appearance=aqua`, 15/15 passes.
  ///   * the `WindowGroup` scene's own window (the launcher — which is the window
  ///     restoration loads the recovered document into, so it is the FIRST thing
  ///     an operator sees on a cold start) reports `appearance=nil`,
  ///     `effective=darkAqua` on every one of those same passes. The scene owns
  ///     that property and puts its own answer back.
  ///
  /// Re-asserting harder is not the fix — that is exactly the never-converging
  /// write loop `assertedAppearances` exists to prevent (the 99% CPU start-up
  /// hang). Declaring the value where SwiftUI already owns it is: with this
  /// modifier the same probe reports `appearance=aqua` on BOTH windows, follows a
  /// live skin switch in one pass, and returns to the system appearance for the
  /// adaptive skins (`nil`) — with no write loop, because a declared value is
  /// idempotent by construction.
  ///
  /// `assertWindowChrome` stays: it owns the titlebar backing colour, the chip
  /// tint, and the recomposite kick a live skin switch needs on the layer-backed
  /// editor pane. The two agree by construction — both read
  /// `PensieveTheme.appearanceName`.
  ///
  /// The manager is OBSERVED by the modifier itself rather than by the root that
  /// applies it. A skin switch has to rebuild whatever declares the appearance,
  /// and the roots that host document windows hold their `ThemeManager` to hand
  /// it down through `.environmentObject` — reading `.skin` off a plain stored
  /// property there would repaint the panes on a switch and leave the sidebar and
  /// titlebar on the previous skin. Owning the observation here means applying
  /// the modifier is the whole contract; the caller cannot get it half right.
  ///
  /// It declares the TOOLBAR's scheme alongside the window's, from the one
  /// `SkinChrome` value, because on macOS 26 a toolbar left unstated resolves
  /// its glass per pill against whatever is composited under it — see
  /// `SkinChrome` for the measurement.
  func pensieveSkinAppearance(_ themeManager: ThemeManager) -> some View {
    modifier(SkinAppearanceModifier(themeManager: themeManager))
  }
}

private struct SkinAppearanceModifier: ViewModifier {
  @ObservedObject var themeManager: ThemeManager

  func body(content: Content) -> some View {
    let chrome = WindowChromeRecipe.skinChrome(for: themeManager.skin)
    return
      content
      .preferredColorScheme(chrome.window)
      .toolbarColorScheme(chrome.toolbar, for: .windowToolbar)
      // The AppKit half of the same contract. Declared here rather than left to
      // the editor because the editor is not a thing every window has — see
      // `WindowChromeSink`.
      .background(WindowChromeSink(theme: themeManager.skin))
  }
}

/// Runs the window-chrome pass for the window hosting this root.
///
/// A hidden zero-size view rather than a lifecycle hook, for the same reasons
/// `ToolbarOverflowSink` is one: the pass needs a WINDOW, and it has to run
/// again after every toolbar re-bridge.
///
/// Why it exists at all — two measured gaps, one mechanism:
///
///   * `assertWindowChrome` had exactly two production callers: the editor's
///     representable and the preview's WebView. A window that hosts NEITHER
///     never received the pass at all, so its toggle chips kept AppKit's
///     `controlAccentColor` fill. That is not a hypothetical window — it is the
///     launcher / empty-workspace window, which is what an operator meets on a
///     cold start and what "New Window" gives her.
///   * On a window that DOES host an editor the pass runs, and still loses.
///     Measured on `ToolbarBridgeRig` (typewriter, wanted `#6e6e6e`): after a
///     skin switch the chip bezel reads `nil` at +50 ms, +350 ms and +1.35 s.
///     The re-bridge the switch itself causes — the appearance picker's label
///     carries the skin name, so switching skins always rebuilds the toolbar —
///     lands AFTER the editor's pass and takes the bezel with it, and WAITING
///     NEVER RESTORES IT: only the next unrelated SwiftUI pass repaints. So the
///     chips were right up until the operator picked a skin, which is the first
///     moment they are supposed to be visible at all.
///
/// The adaptive skins hid both halves for as long as they were the default:
/// their `chromeAccent` IS `controlAccentColor`, so an unpainted chip and a
/// correctly painted one are the same pixels. The report reads "it breaks after
/// switching to Typewriter" for exactly that reason.
///
/// Hence three triggers, and none of them a repaint storm:
///
///   * the SwiftUI pass, which covers a skin change (the modifier observes the
///     manager) and every rebuild of the root;
///   * one runloop turn later, which is where both the first toolbar build and
///     the skin switch's re-bridge land;
///   * every window update cycle — the same `NSWindow.didUpdateNotification`
///     repair `ToolbarOverflowController` runs, for the same measured reason.
///
/// The update-cycle trigger deliberately re-asserts the CHIP TINT and the TAB
/// BAR ONLY, not the whole chrome. Both round-trip faithfully — measured, 45
/// consecutive passes for `selectedSegmentBezelColor` and 19 for the tab bar's
/// glass, correcting once and staying silent after — so a per-update
/// compare-and-set converges, and neither write re-drives the SwiftUI graph.
/// Both are also the two surfaces AppKit rebuilds BETWEEN SwiftUI passes (a
/// toolbar re-bridge, a tab selection), which is exactly what a pass-driven
/// trigger cannot catch.
///
/// The window appearance is the opposite case and stays off this trigger: it
/// does not round-trip on a scene-owned window, and driving that off a
/// notification the window itself posts is how a write loop becomes the 99% CPU
/// start-up hang `assertedAppearances` exists to prevent. The appearance and the
/// titlebar backing therefore stay on the bounded SwiftUI passes, exactly where
/// the editor already drives them.
struct WindowChromeSink: NSViewRepresentable {
  let theme: PensieveTheme

  /// Holds the window observation across SwiftUI passes. A representable is a
  /// value type, so the live theme is copied in on every `configure` and read
  /// back out by a notification that fires between passes.
  @MainActor
  final class Coordinator {
    var theme: PensieveTheme = .default
    private weak var window: NSWindow?
    private var observer: NSObjectProtocol?

    func observe(_ window: NSWindow?) {
      guard self.window !== window else { return }
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
      self.window = window
      guard let window else { return }
      observer = NotificationCenter.default.addObserver(
        forName: NSWindow.didUpdateNotification, object: window, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, let window = self.window else { return }
          WindowChromeRecipe.assertToolbarChipTint(on: window, for: self.theme)
          WindowChromeRecipe.assertTabBarAppearance(on: window, for: self.theme)
        }
      }
    }

    func assertChrome() {
      guard let window else { return }
      WindowChromeRecipe.assertWindowChrome(on: window, for: theme)
    }

    deinit {
      if let observer { NotificationCenter.default.removeObserver(observer) }
    }
  }

  /// A plain `NSView` plus a dispatch is a timing heuristic: a window that
  /// arrives later than that turn, with no further SwiftUI update behind it,
  /// would never be asserted. `viewDidMoveToWindow()` is AppKit's guaranteed
  /// signal that the window slot changed — the same belt `DocumentWindowAccessor`
  /// wears.
  final class SinkView: NSView {
    var onWindowChanged: (() -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      onWindowChanged?()
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = SinkView(frame: .zero)
    view.isHidden = true
    configure(view, coordinator: context.coordinator)
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    guard let view = nsView as? SinkView else { return }
    configure(view, coordinator: context.coordinator)
  }

  private func configure(_ view: SinkView, coordinator: Coordinator) {
    // Reinstalled on every pass so the callback closes over THIS pass's theme.
    coordinator.theme = theme
    view.onWindowChanged = { [weak view] in
      guard let view else { return }
      coordinator.observe(view.window)
      coordinator.assertChrome()
    }
    coordinator.observe(view.window)
    coordinator.assertChrome()
    // The first update lands before the bridge has built the toolbar items, and
    // a skin switch's re-bridge lands after this body ran; one turn later both
    // are settled.
    DispatchQueue.main.async { [weak view] in
      guard let view else { return }
      coordinator.observe(view.window)
      coordinator.assertChrome()
    }
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
