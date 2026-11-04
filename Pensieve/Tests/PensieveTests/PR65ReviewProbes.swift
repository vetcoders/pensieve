import AppKit
import XCTest

@testable import Pensieve

@MainActor
final class PR65ReviewProbes: XCTestCase {
  func testNativeChildReceivesParentCoordinates() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled],
      backing: .buffered, defer: true)
    let parent = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
    window.contentView = parent
    let anchor = AskDockAnchorView(frame: NSRect(x: 35, y: 45, width: 900, height: 700))
    parent.addSubview(anchor)
    anchor.isDocked = true
    anchor.dockRect = CGRect(x: 0, y: 374, width: 900, height: 300)
    let control = NSView(frame: NSRect(x: 400, y: 400, width: 100, height: 40))
    anchor.addSubview(control)
    let localPoint = NSPoint(x: 450, y: 420)
    // Each hitTest takes a point in that view's parent coordinates. The
    // flipped anchor and its native child therefore need different points.
    let parentPoint = parent.convert(localPoint, from: anchor)
    XCTAssertTrue(
      control.hitTest(localPoint) === control, "AppKit control baseline uses parent coordinates")
    XCTAssertTrue(
      anchor.hitTest(parentPoint) === control,
      "Dock must return the real control, not swallow the click")
    XCTAssertNil(anchor.hitTest(parent.convert(NSPoint(x: 450, y: 100), from: anchor)))
  }

  func testDockSlotKeepsTheHeightTheOwnerAllocated() {
    let state = AskPresentationState.expandedDefault
    let ownerSize = CGSize(width: 900, height: 700)
    let allocated = AskSurfaceLayout.displayedDockHeight(presentation: state, content: ownerSize)
    let insideHost = AskSurfaceLayout.allocate(
      content: CGSize(width: 900, height: allocated), presentation: state)
    print(
      "REVIEW dock allocated=\(allocated) rendered=\(insideHost.askRegion.height) transcript=\(insideHost.transcript.height)"
    )
    XCTAssertEqual(
      insideHost.askRegion.height, allocated,
      "Do not subtract editor/status a second time inside the dock host")
  }

  func testCollapsedDockKeepsTheComposer() {
    var state = AskPresentationState.expandedDefault
    state.isExpanded = false
    let height = AskSurfaceLayout.displayedDockHeight(
      presentation: state, content: CGSize(width: 900, height: 700))
    let insideHost = AskSurfaceLayout.allocate(
      content: CGSize(width: 900, height: height), presentation: state)
    print(
      "REVIEW collapsed dock allocated=\(height) rendered=\(insideHost.askRegion.height) composer=\(insideHost.composer.height)"
    )
    XCTAssertGreaterThan(insideHost.composer.height, 0, "Collapse must retain the input")
  }

  func testCollapsedNativePanelHidesTranscript() {
    var state = AskPresentationState.expandedDefault
    state.mode = .floating
    state.isExpanded = false
    let insidePanel = AskSurfaceLayout.allocate(
      content: CGSize(width: 640, height: 520), presentation: state)
    XCTAssertEqual(insidePanel.transcript.height, 0, "Floating collapse must hide the transcript")
  }

  func testRequestedNativePanelSizeReachesTheWindow() {
    let panel = NonActivatingTaflaPanel(
      contentRect: NSRect(x: 100, y: 100, width: 640, height: 520),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered, defer: true)
    let controller = AskPanelController(
      panelFactory: { panel }, presentPanel: { _ in }, dismissPanel: { _ in },
      panelIsVisible: { _ in false })
    var state = AskPresentationState.expandedDefault
    state.mode = .floating
    state.preferredFloatSize = CGSize(width: 1400, height: 900)
    controller.syncPresentation(state, contentSize: CGSize(width: 640, height: 480))
    XCTAssertEqual(
      panel.contentView?.bounds.size, state.preferredFloatSize,
      "Assert real panel geometry, not a copied state value")
  }

  func testOwnerCloseCannotBeUndoneByAnotherPresentationSync() {
    let panel = NonActivatingTaflaPanel(
      contentRect: NSRect(x: 100, y: 100, width: 640, height: 520),
      styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered, defer: true)
    var presented = false
    let controller = AskPanelController(
      panelFactory: { panel }, presentPanel: { _ in presented = true },
      dismissPanel: { _ in presented = false }, panelIsVisible: { _ in presented })
    let owner = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled],
      backing: .buffered, defer: true)
    controller.attachOwnerWindow(owner)
    var state = AskPresentationState.expandedDefault
    state.mode = .floating
    controller.syncPresentation(state, contentSize: CGSize(width: 900, height: 700))
    NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: owner)
    XCTAssertFalse(presented)
    controller.syncPresentation(
      controller.presentation, contentSize: CGSize(width: 900, height: 700))
    XCTAssertFalse(
      presented, "Owner close is terminal; a retained host must not re-present an orphan panel")
  }

  func testPendingStreamTailIsFlushedAfterPublicationInterval() async throws {
    var now: TimeInterval = 0
    let model = AskConversationModel(clock: { now })
    var turn = AskTurn(role: .assistant, text: "a", isStreaming: true)
    model.observe(turns: [turn])
    await model.awaitParseWorker()
    XCTAssertEqual(model.document(for: turn.id.uuidString)?.source, "a")
    now = 0.01
    turn.text = "ab"
    model.observe(turns: [turn])
    now = 1
    // The trailing flush is a real 110 ms timer, then a main-actor hop, then a
    // parse. Wait for its effect rather than for a fixed time, so a loaded
    // runner cannot read the document before the flush has run.
    let deadline = ContinuousClock.now + .seconds(5)
    while model.document(for: turn.id.uuidString)?.source != "ab",
      ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(20))
      await model.awaitParseWorker()
    }
    XCTAssertEqual(
      model.document(for: turn.id.uuidString)?.source, "ab",
      "A paused stream must flush its pending tail without another delta")
  }
}
