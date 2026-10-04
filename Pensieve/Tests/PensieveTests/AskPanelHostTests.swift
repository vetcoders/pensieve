import AppKit
import SwiftUI
import XCTest

@testable import Pensieve

@MainActor
final class AskPanelHostTests: XCTestCase {
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

    class HitTestControl: NSView {
      override var isFlipped: Bool { true }
      override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
      }
    }
    let control = HitTestControl(frame: CGRect(x: 400, y: 400, width: 100, height: 40))
    anchor.addSubview(control)

    // Docked mode
    let dockRect = CGRect(x: 0, y: 374, width: 900, height: 300)
    anchor.dockRect = dockRect
    anchor.isDocked = true

    // Click in editor (y < 374) -> passes through (nil)
    XCTAssertNil(anchor.hitTest(NSPoint(x: 450, y: 100)))

    // Click in status bar (y > 674) -> passes through (nil)
    XCTAssertNil(anchor.hitTest(NSPoint(x: 450, y: 685)))

    // Click in dock on control -> hits control
    XCTAssertEqual(anchor.hitTest(NSPoint(x: 450, y: 420)), control)

    // Click in dock outside control -> hits anchor
    XCTAssertEqual(anchor.hitTest(NSPoint(x: 100, y: 450)), anchor)

    // Non-docked (floating or hidden) -> passes everything through
    anchor.isDocked = false
    XCTAssertNil(anchor.hitTest(NSPoint(x: 450, y: 420)))
    XCTAssertNil(anchor.hitTest(NSPoint(x: 450, y: 100)))
    XCTAssertNil(anchor.hitTest(NSPoint(x: 450, y: 685)))
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
