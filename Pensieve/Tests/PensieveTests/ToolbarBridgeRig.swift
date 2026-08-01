import AppKit
import SwiftUI
import XCTest

@testable import Pensieve

/// A real window hosting the REAL `EditorToolbelt`, so a test reads the AppKit
/// controls the operator actually clicks instead of the SwiftUI declaration.
///
/// Shared by the three toolbar suites — bridging, overflow and width budget —
/// because they must all be looking at the SAME toolbar: a rig that differed in
/// window size, hosting options or content would let one suite pass on a
/// toolbar the others never see.
@MainActor
final class ToolbarBridgeRig {
  let appState: AppState
  let controller: AppController
  let themeManager: ThemeManager
  let window: NSWindow

  /// A rig window that keeps the width it asks for.
  ///
  /// AppKit constrains an ordered-in window to the screen it lands on, and it
  /// constrains the WIDTH too: measured on this rig, a requested 1600pt comes
  /// back as 1512pt on a 1512pt display. That silent shrink is what makes an
  /// unguarded rig machine-dependent — below the toolbar's clipping threshold a
  /// family goes into the "»" overflow, and a clipped control is detached from
  /// the window (`control.window == nil`), so a synthesized click lands nowhere
  /// while every structural assertion still passes. That is precisely the shape
  /// of the CI failure ("clicking the mode picker changed nothing") on a runner
  /// whose virtual display is far smaller than an operator's: the toolbar was
  /// never given the width the rig declared. The window is still parked
  /// offscreen at zero alpha, so a frame no screen can hold costs the operator
  /// nothing.
  final class UnconstrainedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
      frameRect
    }
  }

  init(defaults: UserDefaults, width: CGFloat = 1600) {
    appState = AppState(defaults: defaults)
    appState.documentSession = .untitled()
    appState.documentSession.text = "hello brave new world"
    appState.mode = .split
    controller = AppController(appState: appState)
    themeManager = ThemeManager(defaults: defaults)

    window = UnconstrainedWindow(
      contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
      styleMask: WindowChromeRecipe.documentStyleMask,
      backing: .buffered,
      defer: false)
    window.isReleasedWhenClosed = false
    window.toolbarStyle = WindowChromeRecipe.toolbarStyle
    let hosting = NSHostingView(
      rootView: AnyView(
        ToolbarBridgeHost(
          appState: appState, controller: controller, themeManager: themeManager)))
    // The same bridge the factory tab path uses to carry `.toolbar` content
    // from a SwiftUI root into an AppKit window.
    hosting.sceneBridgingOptions = [.toolbars, .title]
    window.contentView = hosting
    // The bridge only builds the toolbar for a window that is ordered in, but
    // a test must never flash chrome across an operator's screen: the window
    // is parked far offscreen and fully transparent, which still lays out and
    // still tracks synthesized mouse events.
    window.setFrameOrigin(NSPoint(x: -9000, y: -9000))
    window.alphaValue = 0
    window.makeKeyAndOrderFront(nil)
    window.layoutIfNeeded()
    settle(0.6)
  }

  /// Hand the process back the state the rig found: an NSHostingView left on a
  /// closed window keeps the SwiftUI graph (and its window reference) alive,
  /// and a live graph can still draw into a later test's assertions.
  func tearDown() {
    window.orderOut(nil)
    window.contentView = nil
    window.close()
  }

  func settle(_ seconds: TimeInterval = 0.3) {
    window.layoutIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
  }

  func resize(to width: CGFloat) {
    window.setContentSize(NSSize(width: width, height: 800))
    settle()
  }

  var toolbar: NSToolbar? { window.toolbar }

  /// The same toolbelt value the host builds, so a test asks the production
  /// declaration what the overflow menu should contain rather than restating it.
  var toolbelt: EditorToolbelt {
    EditorToolbelt(
      appState: appState,
      controller: controller,
      themeManager: themeManager,
      onDispatchToAgent: {},
      isDispatchDisabled: false,
      dispatchHelp: "Dispatch to Agent")
  }

  var itemGroups: [NSToolbarItemGroup] {
    (window.toolbar?.items ?? []).compactMap { $0 as? NSToolbarItemGroup }
  }

  /// The families macOS is currently showing. `visibleItems` drops what the
  /// window was too narrow to lay out — the public read of "it went into the »
  /// menu".
  var visibleItemCount: Int { window.toolbar?.visibleItems?.count ?? 0 }

  /// Sum of the widths the toolbar's item viewers actually occupy in the
  /// titlebar. The bridged `NSToolbarItem`s carry no view of their own, so the
  /// only honest read of "how much room does this toolbar need" is the laid-out
  /// titlebar geometry.
  var laidOutItemWidth: CGFloat {
    itemViewers.reduce(0) { $0 + $1.frame.width }
  }

  var itemViewers: [NSView] {
    guard let titlebar = window.standardWindowButton(.closeButton)?.superview else { return [] }
    var found: [NSView] = []
    func walk(_ view: NSView) {
      if String(describing: type(of: view)) == "NSToolbarItemViewer" { found.append(view) }
      for subview in view.subviews { walk(subview) }
    }
    walk(titlebar)
    return found
  }

  /// Does every authored family currently describe the toolbar it is attached
  /// to — right identity, right contents?
  func overflowMatches(_ families: [ToolbarOverflowFamily]) -> Bool {
    let groups = itemGroups
    guard groups.count == families.count else { return false }
    for (group, family) in zip(groups, families) where !family.commands.isEmpty {
      let form = group.menuFormRepresentation
      guard form?.identifier == ToolbarOverflowRecipe.formIdentifier(for: family.identifier),
        form?.submenu?.items.map(\.title) == family.commands.map(\.title)
      else { return false }
    }
    return true
  }

  /// Brings the overflow menus up to date the way the app does, but on the
  /// test's schedule instead of SwiftUI's.
  ///
  /// The app has two triggers and a headless run drives neither reliably: the
  /// sink runs on a SwiftUI body re-evaluation, and the clobber repair runs on
  /// `NSWindow.didUpdateNotification`. Measured on this rig: once a group's form
  /// is taken away, WAITING NEVER RESTORES IT — a test run posts no window
  /// update cycle of its own, so `settle()` can spin for half a second and still
  /// read a toolbar in SwiftUI's incomplete state. That is the whole reason a
  /// test that re-reads the menu after a state change was machine-dependent.
  ///
  /// So this posts the real window update AND runs the same pass the sink runs,
  /// then reports whether the menus actually converged. A scenario test using it
  /// is asserting on menu CONTENT and ACTIONS, not on a scheduler:
  /// `testEveryControlGroupFamilyGetsAnAuthoredOverflowEntry` never calls it and
  /// keeps the sink itself honest, and
  /// `testAClobberedFormIsRepairedOnAWindowUpdate` keeps the repair trigger
  /// honest.
  ///
  /// It RETRIES, because one pass is provably not enough: the state change also
  /// schedules a SwiftUI rebuild, and nothing orders that rebuild before the
  /// pass. Land it after — inside the very settle the check verifies from — and
  /// a single shot authors the menus, watches SwiftUI take them straight back,
  /// and reports a toolbar that "never converged" at a width where nothing was
  /// even clipped. That is the CI failure, reproduced on demand by
  /// `testOverflowSyncSurvivesARebuildThatLandsAfterThePass`.
  ///
  /// So each attempt re-runs the pass and re-verifies AFTER settling, and the
  /// loop ends when the toolbar has gone quiet and the menus agree with it. The
  /// bound is a failure, never a pass: an overflow menu that never converges
  /// fails the test rather than timing out into a green.
  @discardableResult
  func syncOverflowMenus(attempts: Int = 40) -> Bool {
    for _ in 0..<attempts {
      window.update()
      ToolbarOverflowRecipe.assertOverflowMenus(on: window, families: toolbelt.overflowFamilies)
      settle(0.02)
      if overflowMatches(toolbelt.overflowFamilies) { return true }
    }
    return false
  }

  /// Waits for the APP's OWN machinery to settle — the sink's deferred pass and
  /// the window-update repair — without the test authoring anything itself.
  ///
  /// The difference from `syncOverflowMenus` matters: this one never calls the
  /// pass, so a pin whose claim is "production wires the overflow menus up on
  /// its own" keeps that claim intact while dropping the assumption that
  /// production has already finished by the time the rig's initializer returns.
  /// It has not, necessarily — SwiftUI can re-derive a group's menu form after
  /// the sink ran, and it re-derives exactly the family whose CONTENT it
  /// rewrites, which is why the view family (its appearance control is labelled
  /// with the live skin name) was the only one a CI runner ever caught derived.
  @discardableResult
  func awaitOverflowConvergence(attempts: Int = 40) -> Bool {
    for _ in 0..<attempts {
      if overflowMatches(toolbelt.overflowFamilies) { return true }
      window.update()
      settle(0.02)
    }
    return overflowMatches(toolbelt.overflowFamilies)
  }

  /// Everything a failing overflow assertion needs to name its own cause on a
  /// machine nobody can attach a debugger to: the geometry the rig actually got
  /// (not the one it asked for), whether the window is really on screen, how
  /// much of the toolbar macOS is showing, and who owns each group's menu form.
  var overflowDiagnostics: String {
    let forms = itemGroups.map {
      $0.menuFormRepresentation?.identifier?.rawValue ?? "<swiftui-derived>"
    }
    return
      "window frame=\(window.frame) visible=\(window.isVisible) "
      + "toolbarItems=\(toolbar?.items.count ?? -1) visibleItems=\(visibleItemCount) "
      + "families=\(toolbelt.overflowFamilies.count) forms=\(forms)"
  }

  /// The mode picker is the only `.selectOne` control in this toolbar.
  func modePickerControl() -> NSSegmentedControl? {
    WindowChromeRecipe.toolbarSegmentedControls(in: window)
      .first { $0.trackingMode == .selectOne }
  }

  func formatControl() -> NSSegmentedControl? {
    WindowChromeRecipe.toolbarSegmentedControls(in: window)
      .first { control in
        (0..<control.segmentCount).contains {
          control.toolTip(forSegment: $0) == MarkdownFormat.bold.label
        }
      }
  }

  func textView() -> NSTextView? {
    guard let content = window.contentView else { return nil }
    return Self.firstTextView(in: content)
  }

  private static func firstTextView(in view: NSView) -> NSTextView? {
    if let text = view as? NSTextView { return text }
    for subview in view.subviews {
      if let found = firstTextView(in: subview) { return found }
    }
    return nil
  }

  /// AppKit's real clipped-items ("»") button, present only while something is
  /// actually clipped.
  func clippedItemsIndicator() -> NSButton? {
    guard let titlebar = window.standardWindowButton(.closeButton)?.superview else { return nil }
    func walk(_ view: NSView) -> NSButton? {
      if String(describing: type(of: view)) == "NSToolbarClippedItemsIndicator",
        let button = view as? NSButton
      {
        return button
      }
      for subview in view.subviews {
        if let found = walk(subview) { return found }
      }
      return nil
    }
    return walk(titlebar)
  }

  /// A REAL click. SwiftUI's segmented-control coordinator traps when its
  /// action selector is invoked programmatically (measured: `EXC_BREAKPOINT`
  /// inside `primaryActionTriggered`), so the press is synthesized: the
  /// mouse-up is queued BEFORE the mouse-down is delivered, giving AppKit's
  /// segment tracking loop the terminator it waits for without a live pointer.
  /// Per-segment rects are not public API, so the target is the segment's
  /// share of the control width; every assertion reads back what AppKit
  /// actually selected instead of trusting that estimate.
  func click(_ control: NSSegmentedControl, segment: Int) {
    // `toolbarSegmentedControls` reads `toolbar.items`, which still hands back
    // a control the toolbar has CLIPPED into the "»" overflow — and a clipped
    // control is not in the window's view tree, so a synthesized click has
    // nothing to land on. Say that out loud instead of letting it read as
    // "the action is not wired".
    guard control.window === window else {
      XCTFail(
        "the toolbar clipped this control into the overflow menu: the rig window is "
          + "\(window.frame.width)pt wide, too narrow to host every family")
      return
    }
    let share = control.bounds.width / CGFloat(max(1, control.segmentCount))
    let center = NSPoint(
      x: control.bounds.minX + (CGFloat(segment) + 0.5) * share,
      y: control.bounds.midY)
    let location = control.convert(center, to: nil)
    func event(_ type: NSEvent.EventType, pressure: Float) -> NSEvent? {
      NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: pressure)
    }
    guard
      let down = event(.leftMouseDown, pressure: 1),
      let up = event(.leftMouseUp, pressure: 0)
    else { return }
    NSApp.postEvent(up, atStart: true)
    window.sendEvent(down)
  }
}

extension XCTestCase {
  /// Skips rather than fails when the headless host does not bridge a toolbar
  /// at all: with no `NSToolbar` there is nothing for these suites to read, and
  /// a failure there would be about the environment, not the toolbelt.
  @MainActor
  func makeToolbarRig(prefix: String, width: CGFloat = 1600) throws -> ToolbarBridgeRig {
    let rig = ToolbarBridgeRig(defaults: makeEphemeralDefaults(prefix: prefix), width: width)
    guard rig.window.toolbar != nil else {
      rig.tearDown()
      throw XCTSkip("headless window did not bridge a SwiftUI toolbar")
    }
    return rig
  }
}

/// The editor half of the rig: the same representable `EditorView` builds, so a
/// toolbar action has a real text surface to land in — and the same overflow
/// sink `ContentView` installs, so the "»" menu under test is the one the app
/// ships, not one a test assembled.
private struct ToolbarBridgeHost: View {
  var appState: AppState
  @ObservedObject var controller: AppController
  @ObservedObject var themeManager: ThemeManager

  private var toolbelt: EditorToolbelt {
    EditorToolbelt(
      appState: appState,
      controller: controller,
      themeManager: themeManager,
      onDispatchToAgent: {},
      isDispatchDisabled: false,
      dispatchHelp: "Dispatch to Agent")
  }

  var body: some View {
    @Bindable var bindable = appState
    return EditorRepresentable(
      text: Binding(
        get: { appState.documentSession.text },
        set: { appState.documentSession.text = $0 }),
      editorMode: appState.mode,
      fontSize: appState.fontSize,
      skin: themeManager.skin,
      syntaxHighlightingEnabled: appState.richMarkdownEnabled,
      formattingCommand: appState.pendingMarkdownFormatCommand,
      rewriteCommand: nil,
      findQuery: $bindable.findQuery,
      findReplacement: $bindable.findReplaceQuery,
      findBarVisible: false,
      findCommand: nil,
      tableTidyOnPaste: false,
      asciiSafeTables: false,
      aiAutocompleteEnabled: false,
      isDirty: Binding(
        get: { appState.documentSession.isDirty },
        set: { appState.documentSession.isDirty = $0 }),
      onDocumentChanged: {},
      onCloseFindBar: {}
    )
    .toolbar { toolbelt }
    .background(ToolbarOverflowSink(families: toolbelt.overflowFamilies))
  }
}
