import AppKit
import Combine
import SwiftUI
import XCTest

@testable import Pensieve

@MainActor
final class AskPanelHostTests: XCTestCase {
  func testDockRetiresTheFloatingContainerSoItCannotResizeDockedContent() throws {
    let fixture = makeFixture()
    defer { fixture.close() }
    let anchor = AskDockAnchorView()
    fixture.controller.dockAnchorView = anchor
    let content = NSView()
    fixture.controller.hostingView = content
    var state = AskPresentationState.expandedDefault
    state.mode = .floating
    fixture.controller.syncPresentation(state, contentSize: CGSize(width: 900, height: 700))
    state.mode = .docked
    fixture.controller.syncPresentation(state, contentSize: CGSize(width: 900, height: 700))
    XCTAssertNil(fixture.panel.contentView, "the hidden panel must not retain a dock sizing writer")
    XCTAssertTrue(content.superview === anchor)
    let dockFrame = content.frame
    fixture.panel.contentView?.setFrameSize(CGSize(width: 360, height: 260))
    XCTAssertEqual(content.frame, dockFrame)
  }

  func testFloatingChromeHasOneCloseControlWithoutDetachedTrafficLights() {
    let fixture = makeFixture()
    defer { fixture.close() }
    var state = AskPresentationState.expandedDefault
    state.mode = .floating
    fixture.controller.syncPresentation(state, contentSize: CGSize(width: 900, height: 700))
    for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
      XCTAssertTrue(fixture.panel.standardWindowButton(button)?.isHidden ?? true)
    }
  }

  func testUnchangedNativeSynchronizationPublishesNoSwiftUIUpdates() {
    let fixture = makeFixture()
    defer { fixture.close() }
    var updates = 0
    let observation = fixture.controller.$presentation.dropFirst().sink { _ in updates += 1 }
    let state = fixture.controller.presentation
    for _ in 0..<100 {
      fixture.controller.syncPresentation(state, contentSize: CGSize(width: 900, height: 700))
    }
    XCTAssertEqual(
      updates, 0, "layout updates must not feed an invalidation loop on the main thread")
    withExtendedLifetime(observation) {}
  }

  func testMultipleDocumentRootsShareOneHostAndExclusiveDockFloatState() throws {
    let fixture = makeFixture()
    defer { fixture.close() }
    let defaults = makeEphemeralDefaults(prefix: "one-application-ask")
    let context = CommandSurfaceContext()
    let first = WindowErrorChromeRig(
      defaults: defaults, askSession: fixture.controller, commandSurface: context)
    defer { first.tearDown() }
    first.appState.documentSession = .untitled()
    first.appState.documentSession.text = "First document"
    first.settle()
    let thread = fixture.controller.threads.thread(for: fixture.controller.documentThreadID)
    thread.draft = "Keep this draft when switching documents"
    thread.appendDictation("One conversation")
    let second = WindowErrorChromeRig(
      defaults: defaults, askSession: fixture.controller, commandSurface: context)
    defer { second.tearDown() }
    second.appState.documentSession = .untitled()
    second.appState.documentSession.text = "Second document"
    second.settle()
    let host = try XCTUnwrap(fixture.controller.hostingView)
    fixture.controller.presentation.mode = .floating
    second.settle()
    XCTAssertTrue(fixture.isPresented)
    XCTAssertTrue(host.superview === fixture.panel.contentView)
    for _ in 0..<3 {
      context.adopt(appState: first.appState, controller: first.controller)
      first.settle()
      XCTAssertTrue(fixture.controller.ownerWindow === first.window)
      context.adopt(appState: second.appState, controller: second.controller)
      second.settle()
      XCTAssertTrue(fixture.controller.ownerWindow === second.window)
      XCTAssertTrue(fixture.controller.hostingView === host)
    }
    fixture.controller.presentation.mode = .docked
    second.settle()
    XCTAssertFalse(fixture.isPresented)
    let anchor = try XCTUnwrap(fixture.controller.dockAnchorView)
    XCTAssertTrue(anchor.isDocked)
    XCTAssertTrue(host.superview === anchor)
    XCTAssertNil(fixture.panel.contentView)
    XCTAssertEqual(thread.draft, "Keep this draft when switching documents")
    XCTAssertEqual(thread.turns.count, 1)
    fixture.controller.setVisible(false)
    second.settle()
    XCTAssertFalse(fixture.isPresented)
    XCTAssertNil(host.superview)
    fixture.controller.setVisible(true)
    second.settle()
    XCTAssertEqual(fixture.controller.presentation.mode, .docked)
    XCTAssertTrue(fixture.controller.hostingView === host)
  }

  func testFloatingPanelUsesTheLiveThemeAndRetainsItsIdentity() {
    let fixture = makeFixture()
    defer { fixture.close() }
    fixture.controller.presentation.mode = .floating
    let panel = fixture.panel
    for theme: PensieveTheme in [.graphite, .parchment, .ink, .porcelain, .default] {
      fixture.controller.updateTheme(theme)
      XCTAssertEqual(panel.appearance?.name, WindowChromeRecipe.windowAppearance(for: theme)?.name)
      XCTAssertTrue(fixture.controller.panel === panel)
    }
  }

  func testPersistentHostingIdentityAcrossDockFloatAndHide() {
    let fixture = makeFixture()
    defer { fixture.close() }

    let controller = fixture.controller
    let anchor = AskDockAnchorView()
    controller.dockAnchorView = anchor

    let testView = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    controller.hostingView = testView
    let originalIdentity = ObjectIdentifier(testView)

    // 1. Docked
    var presentation = AskPresentationState.expandedDefault
    presentation.mode = .docked
    controller.syncPresentation(presentation, contentSize: CGSize(width: 900, height: 700))

    XCTAssertTrue(anchor.isDocked)
    XCTAssertTrue(testView.isDescendant(of: anchor))
    XCTAssertFalse(fixture.isPresented)
    XCTAssertEqual(ObjectIdentifier(testView), originalIdentity)

    // 2. Floating
    presentation.mode = .floating
    controller.syncPresentation(presentation, contentSize: CGSize(width: 900, height: 700))

    XCTAssertFalse(anchor.isDocked)
    XCTAssertTrue(fixture.isPresented)
    let panelContentView = fixture.panel.contentView
    XCTAssertTrue(testView.isDescendant(of: panelContentView!))
    XCTAssertEqual(ObjectIdentifier(testView), originalIdentity)

    // 3. Hidden
    presentation.mode = .hidden
    controller.syncPresentation(presentation, contentSize: CGSize(width: 900, height: 700))

    XCTAssertFalse(anchor.isDocked)
    XCTAssertFalse(fixture.isPresented)
    XCTAssertNil(testView.superview)
    XCTAssertEqual(ObjectIdentifier(testView), originalIdentity)

    // 4. Back to Docked
    presentation.mode = .docked
    controller.syncPresentation(presentation, contentSize: CGSize(width: 900, height: 700))

    XCTAssertTrue(anchor.isDocked)
    XCTAssertTrue(testView.isDescendant(of: anchor))
    XCTAssertEqual(ObjectIdentifier(testView), originalIdentity)
  }

  func testNativePanelRecipeAndAlwaysOnTop() {
    let fixture = makeFixture()
    defer { fixture.close() }

    let panel = fixture.panel
    let controller = fixture.controller

    var presentation = AskPresentationState.expandedDefault
    presentation.mode = .floating
    presentation.isAlwaysOnTop = true

    controller.syncPresentation(presentation, contentSize: CGSize(width: 900, height: 700))

    XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
    XCTAssertTrue(panel.canBecomeKey)
    XCTAssertFalse(panel.canBecomeMain)
    XCTAssertEqual(panel.level, .floating)
    XCTAssertTrue(panel.isFloatingPanel)
    XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
    XCTAssertFalse(panel.hidesOnDeactivate)
    XCTAssertFalse(panel.isReleasedWhenClosed)
    XCTAssertTrue(panel.styleMask.contains(.resizable))
    XCTAssertEqual(
      panel.collectionBehavior.intersection([
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .ignoresCycle,
      ]),
      [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    )
    XCTAssertEqual(panel.sharingType, .readOnly)

    // Toggle AoT to normal level
    controller.setAlwaysOnTop(false)
    XCTAssertFalse(controller.presentation.isAlwaysOnTop)
    XCTAssertEqual(panel.level, .normal)

    // Toggle AoT back to floating level
    controller.setAlwaysOnTop(true)
    XCTAssertTrue(controller.presentation.isAlwaysOnTop)
    XCTAssertEqual(panel.level, .floating)
  }

  func testOwnerSpecificCloseConcealsPanel() {
    let fixture = makeFixture()
    defer { fixture.close() }

    let ownerWindow = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 800, height: 600),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true
    )
    fixture.controller.attachOwnerWindow(ownerWindow)

    var presentation = AskPresentationState.expandedDefault
    presentation.mode = .floating
    fixture.controller.syncPresentation(presentation, contentSize: CGSize(width: 800, height: 600))
    XCTAssertTrue(fixture.isPresented)

    // Simulate owner window closing
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: ownerWindow)
    XCTAssertFalse(fixture.isPresented)
  }

  func testPanelTitleBarCloseConcealsAskWithoutCancelling() {
    let fixture = makeFixture()
    defer { fixture.close() }

    var presentation = AskPresentationState.expandedDefault
    presentation.mode = .floating
    fixture.controller.syncPresentation(presentation, contentSize: CGSize(width: 900, height: 700))
    XCTAssertTrue(fixture.isPresented)

    // Simulate window close notification for the panel
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: fixture.panel)

    XCTAssertEqual(fixture.controller.presentation.mode, .hidden)
    XCTAssertFalse(fixture.isPresented)
  }

  func testDockAnchorHitTestingPassesClicksThroughToEditorAndStatus() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
    let anchor = AskDockAnchorView()
    anchor.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
    window.contentView = anchor

    let control = NSButton(frame: CGRect(x: 400, y: 400, width: 100, height: 40))
    anchor.addSubview(control)

    func hit(_ point: NSPoint) -> NSView? {
      anchor.hitTest(anchor.convert(point, to: anchor.superview))
    }

    // Docked mode
    let dockRect = CGRect(x: 0, y: 374, width: 900, height: 300)
    anchor.dockRect = dockRect
    anchor.isDocked = true

    // Click in editor (y < 374) -> passes through (nil)
    XCTAssertNil(hit(NSPoint(x: 450, y: 100)))

    // Click in status bar (y > 674) -> passes through (nil)
    XCTAssertNil(hit(NSPoint(x: 450, y: 685)))

    // Click in dock on control -> hits control
    XCTAssertEqual(hit(NSPoint(x: 450, y: 420)), control)

    // Click in dock outside control -> hits anchor
    XCTAssertEqual(hit(NSPoint(x: 100, y: 450)), anchor)

    // Non-docked (floating or hidden) -> passes everything through
    anchor.isDocked = false
    XCTAssertNil(hit(NSPoint(x: 450, y: 420)))
    XCTAssertNil(hit(NSPoint(x: 450, y: 100)))
    XCTAssertNil(hit(NSPoint(x: 450, y: 685)))
  }

  func testDockedComposerAndCollapseReceiveNativeHitsAfterReopening() {
    let parent = NSView(frame: CGRect(x: 0, y: 0, width: 1100, height: 900))
    let anchor = AskDockAnchorView(frame: CGRect(x: 80, y: 100, width: 900, height: 700))
    parent.addSubview(anchor)
    let dockRect = CGRect(x: 0, y: 374, width: 900, height: 300)
    anchor.dockRect = dockRect

    let host = NSView(frame: dockRect)
    anchor.addSubview(host)
    let collapse = NSButton(frame: CGRect(x: 790, y: 248, width: 25, height: 25))
    let draft = AskDraftTextView(frame: CGRect(x: 20, y: 16, width: 760, height: 80))
    draft.isEditable = true
    host.addSubview(collapse)
    host.addSubview(draft)

    // AppKit receives hit-test points in the receiver's superview coordinates.
    // Use the real controls' contract, with a translated anchor and host.
    let draftPoint = parent.convert(CGPoint(x: 200, y: 40), from: draft)
    let collapsePoint = parent.convert(CGPoint(x: 12, y: 12), from: collapse)
    let editorPoint = parent.convert(CGPoint(x: 200, y: 100), from: anchor)
    let statusPoint = parent.convert(CGPoint(x: 200, y: 685), from: anchor)

    for _ in 0..<3 {
      anchor.isDocked = true
      XCTAssertTrue(anchor.hitTest(draftPoint) === draft)
      XCTAssertTrue(anchor.hitTest(collapsePoint) === collapse)
      XCTAssertNil(anchor.hitTest(editorPoint))
      XCTAssertNil(anchor.hitTest(statusPoint))
      anchor.isDocked = false
      XCTAssertNil(anchor.hitTest(draftPoint))
      XCTAssertNil(anchor.hitTest(collapsePoint))
    }
  }

  func testNativePanelAllocationIsIndependentOfOwnerWindow() {
    let fixture = makeFixture()
    defer { fixture.close() }

    let largeSize = CGSize(width: 1400, height: 900)
    var presentation = AskPresentationState.expandedDefault
    presentation.mode = .floating
    presentation.preferredFloatSize = largeSize

    fixture.controller.syncPresentation(presentation, contentSize: CGSize(width: 640, height: 480))
    XCTAssertTrue(fixture.isPresented)
    XCTAssertEqual(fixture.controller.presentation.preferredFloatSize, largeSize)
  }

  func testOwnerWindowCloseTearsDownControllerAndClearsReferences() {
    let fixture = makeFixture()
    defer { fixture.close() }

    let owner = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
      styleMask: [.titled],
      backing: .buffered,
      defer: true
    )
    let anchor = AskDockAnchorView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
    let hosting = NSView(frame: NSRect(x: 0, y: 374, width: 900, height: 300))
    anchor.addSubview(hosting)
    fixture.controller.dockAnchorView = anchor
    fixture.controller.hostingView = hosting
    fixture.controller.attachOwnerWindow(owner)

    fixture.controller.onPresentationChange = { _ in }

    fixture.controller.syncPresentation(
      .expandedDefault, contentSize: CGSize(width: 900, height: 700))

    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: owner)

    XCTAssertNil(fixture.controller.ownerWindow)
    XCTAssertNil(fixture.controller.dockAnchorView)
    XCTAssertNil(fixture.controller.hostingView)
    XCTAssertNil(fixture.controller.onPresentationChange)
  }

  private func makeFixture() -> Fixture {
    let panel = NonActivatingTaflaPanel(
      contentRect: NSRect(x: 100, y: 100, width: 640, height: 520),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    var panelPresented = false
    let controller = AskPanelController(
      panelFactory: { panel },
      presentPanel: { _ in panelPresented = true },
      dismissPanel: { _ in panelPresented = false },
      panelIsVisible: { _ in panelPresented }
    )
    return Fixture(panel: panel, controller: controller, getPresented: { panelPresented })
  }

  private struct Fixture {
    let panel: NSPanel
    let controller: AskPanelController
    let getPresented: () -> Bool

    var isPresented: Bool { getPresented() }

    @MainActor
    func close() {
      panel.close()
    }
  }
}
