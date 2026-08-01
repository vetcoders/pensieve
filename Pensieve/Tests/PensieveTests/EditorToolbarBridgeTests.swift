import AppKit
import SwiftUI
import XCTest

@testable import Pensieve

/// The toolbelt's SwiftUI declaration is only half the truth: what the operator
/// clicks is the AppKit control the bridge builds out of it, and that bridge
/// silently degrades whole controls when a family is declared wrong (a `Picker`
/// nested in a `ControlGroup` becomes ONE DISABLED segment; a `Button` sharing a
/// `ControlGroup` with a `Toggle` becomes a sticky chip). None of that is
/// visible from the SwiftUI side, so these tests host the REAL `EditorToolbelt`
/// in a window, read the bridged `NSToolbar`, and drive it with synthesized
/// mouse events — the only way a regression here fails a test instead of an
/// operator.
final class EditorToolbarBridgeTests: XCTestCase {
  // MARK: - Mode picker

  @MainActor
  func testModePickerBridgesToALiveSegmentPerEditorMode() throws {
    let rig = try makeRig()
    defer { rig.tearDown() }

    let picker = try XCTUnwrap(
      rig.modePickerControl(),
      "the mode picker must bridge to a segmented control with one segment per mode")
    XCTAssertEqual(picker.segmentCount, EditorMode.allCases.count)
    for segment in 0..<picker.segmentCount {
      XCTAssertTrue(
        picker.isEnabled(forSegment: segment),
        "mode segment \(segment) came back disabled — the picker is nested in a ControlGroup again")
    }
  }

  @MainActor
  func testClickingAModeSegmentSwitchesTheEditorMode() throws {
    let rig = try makeRig()
    defer { rig.tearDown() }

    let picker = try XCTUnwrap(rig.modePickerControl())
    let before = rig.appState.mode
    // Aim at the last segment; the assertion reads back which segment AppKit
    // actually landed on, so it never depends on exact segment geometry.
    rig.click(picker, segment: picker.segmentCount - 1)
    rig.settle()

    let landed = picker.selectedSegment
    XCTAssertGreaterThanOrEqual(landed, 0, "the click did not select any segment")
    XCTAssertNotEqual(rig.appState.mode, before, "clicking the mode picker changed nothing")
    XCTAssertEqual(
      rig.appState.mode, EditorMode.allCases[landed],
      "the selected segment and the editor mode disagree")
  }

  // MARK: - Format actions

  @MainActor
  func testFormatButtonsStayMomentaryInsteadOfStickyChips() throws {
    let rig = try makeRig()
    defer { rig.tearDown() }

    let formats = try XCTUnwrap(rig.formatControl(), "the format row must reach the toolbar")
    XCTAssertEqual(
      formats.trackingMode, .momentary,
      "format actions must not share a ControlGroup with a Toggle — \(formats.trackingMode) "
        + "tracking makes every button a sticky on/off chip")
    XCTAssertEqual(formats.segmentCount, MarkdownFormat.allCases.count)
  }

  @MainActor
  func testToolbarBoldEditsTheDocument() throws {
    let rig = try makeRig()
    defer { rig.tearDown() }

    let textView = try XCTUnwrap(rig.textView())
    rig.window.makeFirstResponder(textView)
    textView.setSelectedRange(NSRange(location: 6, length: 5))

    let formats = try XCTUnwrap(rig.formatControl())
    let bold = try XCTUnwrap(
      (0..<formats.segmentCount).first {
        formats.toolTip(forSegment: $0) == MarkdownFormat.bold.label
      })
    rig.click(formats, segment: bold)
    rig.settle()

    XCTAssertEqual(
      textView.string, "hello **brave** new world",
      "the main toolbar's Bold must wrap the selection, like the floating bar does")
  }

  // MARK: - Skin chips

  @MainActor
  func testToggleFamiliesStayPaintableChipGroups() throws {
    let rig = try makeRig()
    defer { rig.tearDown() }

    let chipGroups = WindowChromeRecipe.toolbarSegmentedControls(in: rig.window)
      .filter(WindowChromeRecipe.isToggleChipGroup)
    XCTAssertFalse(
      chipGroups.isEmpty,
      "splitting the families must not cost the toggles their segmented chips — "
        + "assertToolbarChipTint has nothing left to paint from the skin")
    for group in chipGroups {
      for segment in 0..<group.segmentCount {
        XCTAssertNotEqual(
          group.toolTip(forSegment: segment), MarkdownFormat.bold.label,
          "a momentary format action landed in a paintable chip group")
      }
    }
  }

  // MARK: - Overflow menu

  @MainActor
  func testClippedFamiliesStillOfferOverflowMenuEntries() throws {
    let rig = try makeRig()
    defer { rig.tearDown() }

    let groups = (rig.window.toolbar?.items ?? []).compactMap { $0 as? NSToolbarItemGroup }
    let entries = groups.flatMap { group in
      group.subitems.compactMap { $0.menuFormRepresentation?.title }.filter { !$0.isEmpty }
    }
    // A family whose whole content sits in a ControlGroup contributes nothing
    // here, which is why the "»" menu used to open on an empty list.
    XCTAssertFalse(
      entries.isEmpty,
      "the clipped-items menu has no named entry to show — every family is ControlGroup-wrapped")
    XCTAssertTrue(
      entries.contains("Mode"),
      "the mode picker must survive a narrow window through the overflow menu, got \(entries)")
  }

  // MARK: - Rig

  @MainActor
  private func makeRig() throws -> Rig {
    let rig = Rig(defaults: makeEphemeralDefaults(prefix: "EditorToolbarBridgeTests"))
    guard rig.window.toolbar != nil else {
      rig.tearDown()
      throw XCTSkip("headless window did not bridge a SwiftUI toolbar")
    }
    return rig
  }

  @MainActor
  private final class Rig {
    let appState: AppState
    let controller: AppController
    let themeManager: ThemeManager
    let window: NSWindow

    init(defaults: UserDefaults) {
      appState = AppState(defaults: defaults)
      appState.documentSession = .untitled()
      appState.documentSession.text = "hello brave new world"
      appState.mode = .split
      controller = AppController(appState: appState)
      themeManager = ThemeManager(defaults: defaults)

      window = UnconstrainedWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1600, height: 800),
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
}

/// A rig window that keeps the width it asks for.
///
/// AppKit constrains an ordered-in window to the screen it lands on, and it
/// constrains the WIDTH too: measured on this rig, a requested 1600pt comes back
/// as 1512pt on a 1512pt display. That silent shrink is what makes this rig
/// machine-dependent — below roughly 1200pt this toolbar clips the Mode family
/// into the "»" overflow, and a clipped control is detached from the window
/// (`control.window == nil`), so the synthesized click lands nowhere while every
/// structural assertion still passes. That is precisely the shape of the CI
/// failure ("clicking the mode picker changed nothing") on a runner whose
/// virtual display is far smaller than an operator's: the toolbar was never
/// given the width the rig declared. The window is still parked offscreen at
/// zero alpha, so a frame no screen can hold costs the operator nothing.
private final class UnconstrainedWindow: NSWindow {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}

/// The editor half of the rig: the same representable `EditorView` builds, so a
/// toolbar action has a real text surface to land in.
private struct ToolbarBridgeHost: View {
  var appState: AppState
  @ObservedObject var controller: AppController
  @ObservedObject var themeManager: ThemeManager

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
    .toolbar {
      EditorToolbelt(
        appState: appState,
        controller: controller,
        themeManager: themeManager,
        onDispatchToAgent: {},
        isDispatchDisabled: false,
        dispatchHelp: "Dispatch to Agent")
    }
  }
}
