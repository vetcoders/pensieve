import CoreGraphics
import XCTest

@testable import Pensieve

final class AskSurfaceLayoutTests: XCTestCase {
  private let reference = CGSize(width: 900, height: 700)
  private let minimum = CGSize(width: 640, height: 480)

  func testExpandedReferenceGivesTranscriptAtLeast240() {
    let layout = AskSurfaceLayout.allocate(
      content: reference, presentation: .expandedDefault)
    XCTAssertGreaterThanOrEqual(layout.transcript.height, 240)
    XCTAssertLessThanOrEqual(layout.composer.height, 112)
    XCTAssertEqual(layout.status.height, 26, accuracy: 0.01)
    XCTAssertEqual(layout.status.maxY, reference.height, accuracy: 0.01)
    XCTAssertGreaterThan(layout.editor.height, 0)
    XCTAssertFalse(overlaps(layout.askRegion, layout.status))
    XCTAssertLessThanOrEqual(layout.grip.maxY, layout.chrome.minY + 0.01)
    XCTAssertLessThanOrEqual(layout.chrome.maxY, layout.transcript.minY + 0.01)
    XCTAssertLessThanOrEqual(layout.transcript.maxY, layout.composer.minY + 0.01)
    XCTAssertLessThanOrEqual(layout.composer.maxY, layout.status.minY + 0.01)
    XCTAssertEqual(
      layout.editor.height + layout.askRegion.height + layout.status.height,
      reference.height,
      accuracy: 0.01)
    assertReachable(layout, in: reference)
  }

  func testMinimumContentKeepsEditorAndStatus() {
    let layout = AskSurfaceLayout.allocate(
      content: minimum, presentation: .expandedDefault)
    XCTAssertGreaterThanOrEqual(layout.editor.height, 160)
    XCTAssertEqual(layout.status.height, 26, accuracy: 0.01)
    XCTAssertEqual(layout.status.maxY, minimum.height, accuracy: 0.01)
    XCTAssertLessThanOrEqual(layout.composer.height, 112)
    XCTAssertFalse(overlaps(layout.askRegion, layout.status))
    XCTAssertEqual(
      layout.editor.height + layout.askRegion.height + layout.status.height,
      minimum.height,
      accuracy: 0.01)
    let outside = layout.editor.union(layout.askRegion).union(layout.status)
    XCTAssertLessThanOrEqual(outside.maxX, minimum.width + 0.01)
    XCTAssertLessThanOrEqual(outside.maxY, minimum.height + 0.01)
    assertReachable(layout, in: minimum)
  }

  func testDockResizeCannotCoverEditorOrStatus() {
    var state = AskPresentationState.expandedDefault
    state.resizeDock(to: 10_000, in: minimum)
    let layout = AskSurfaceLayout.allocate(content: minimum, presentation: state)
    XCTAssertGreaterThanOrEqual(layout.editor.height, 160)
    XCTAssertEqual(layout.status.height, 26, accuracy: 0.01)
    XCTAssertFalse(overlaps(layout.editor, layout.askRegion))
    XCTAssertFalse(overlaps(layout.askRegion, layout.status))
    XCTAssertLessThanOrEqual(layout.composer.height, 112)
    assertReachable(layout, in: minimum)

    let grown = AskSurfaceLayout.allocate(content: reference, presentation: state)
    XCTAssertGreaterThan(grown.transcript.height, 120)
    XCTAssertGreaterThanOrEqual(grown.editor.height, 160)
  }

  func testCollapseRemembersExpandedHeight() {
    var state = AskPresentationState.expandedDefault
    state.resizeDock(to: 500, in: reference)
    let expanded = AskSurfaceLayout.allocate(content: reference, presentation: state)
    XCTAssertGreaterThanOrEqual(expanded.transcript.height, 240)
    let remembered = state.preferredDockHeight
    XCTAssertEqual(state.apply(.collapse, content: reference), .presented)
    let collapsed = AskSurfaceLayout.allocate(content: reference, presentation: state)
    XCTAssertEqual(collapsed.transcript.height, 0, accuracy: 0.01)
    XCTAssertGreaterThanOrEqual(collapsed.editor.height, 160)
    XCTAssertEqual(layoutStatusVisible(collapsed, in: reference), true)
    XCTAssertEqual(state.preferredDockHeight, remembered, accuracy: 0.01)
    XCTAssertEqual(state.apply(.expand, content: reference), .presented)
    let restored = AskSurfaceLayout.allocate(content: reference, presentation: state)
    XCTAssertEqual(restored.transcript.height, expanded.transcript.height, accuracy: 0.01)
    assertReachable(collapsed, in: reference)
    assertReachable(restored, in: reference)
  }

  func testWindowShrinkClampsWithoutForgettingTheDock() {
    var state = AskPresentationState.expandedDefault
    let before = AskSurfaceLayout.allocate(content: reference, presentation: state)
    XCTAssertGreaterThanOrEqual(before.transcript.height, 240)
    let remembered = state.preferredDockHeight
    state.clampOrigin(to: minimum)
    let squeezed = AskSurfaceLayout.allocate(content: minimum, presentation: state)
    XCTAssertGreaterThanOrEqual(squeezed.editor.height, 160)
    XCTAssertEqual(squeezed.status.height, 26, accuracy: 0.01)
    XCTAssertLessThan(squeezed.transcript.height, before.transcript.height)
    XCTAssertEqual(state.preferredDockHeight, remembered, accuracy: 0.01)
    let restored = AskSurfaceLayout.allocate(content: reference, presentation: state)
    XCTAssertEqual(restored.transcript.height, before.transcript.height, accuracy: 0.01)
    assertReachable(squeezed, in: minimum)
  }

  func testFloatDragAndResizeStayReachableWhenTheWindowShrinks() {
    var state = AskPresentationState.expandedDefault
    XCTAssertEqual(state.apply(.float, content: reference), .presented)
    let open = AskSurfaceLayout.allocate(content: reference, presentation: state)
    XCTAssertGreaterThanOrEqual(open.transcript.height, 240)
    XCTAssertEqual(open.editor.height, reference.height - 26, accuracy: 0.01)
    XCTAssertFalse(overlaps(open.askRegion, open.status))

    state.dragFloat(
      from: state.floatOrigin, by: CGSize(width: 5_000, height: 5_000), in: reference)
    state.resizeFloat(
      from: state.preferredFloatSize, by: CGSize(width: 5_000, height: 5_000), in: reference)
    let wide = AskSurfaceLayout.allocate(content: reference, presentation: state)
    assertReachable(wide, in: reference)
    XCTAssertEqual(wide.editor.height, reference.height - 26, accuracy: 0.01)

    let narrow = AskSurfaceLayout.allocate(content: minimum, presentation: state)
    XCTAssertEqual(narrow.editor.height, minimum.height - 26, accuracy: 0.01)
    XCTAssertEqual(narrow.status.height, 26, accuracy: 0.01)
    XCTAssertFalse(overlaps(narrow.askRegion, narrow.status))
    assertReachable(narrow, in: minimum)

    let hiddenEditor = editorAfterHide(state, content: minimum)
    XCTAssertEqual(hiddenEditor, minimum.height - 26, accuracy: 0.01)
  }

  private func editorAfterHide(_ state: AskPresentationState, content: CGSize) -> CGFloat {
    var copy = state
    XCTAssertEqual(copy.apply(.hide, content: content), .concealed)
    let layout = AskSurfaceLayout.allocate(content: content, presentation: copy)
    XCTAssertEqual(layout.askRegion.height, 0, accuracy: 0.01)
    XCTAssertEqual(copy.preferredDockHeight, state.preferredDockHeight, accuracy: 0.01)
    return layout.editor.height
  }

  private func layoutStatusVisible(_ layout: AskSurfaceAllocation, in content: CGSize) -> Bool {
    layout.status.height >= 26 - 0.01 && abs(layout.status.maxY - content.height) < 0.01
      && !overlaps(layout.askRegion, layout.status)
  }

  private func assertReachable(_ layout: AskSurfaceAllocation, in content: CGSize) {
    let safe = AskSurfaceLayout.safeRect(content)
    XCTAssertFalse(layout.controls.isEmpty)
    for control in layout.controls {
      XCTAssertTrue(
        safe.insetBy(dx: -0.5, dy: -0.5).contains(control.frame),
        "\(control.role) escaped the owner")
      XCTAssertGreaterThanOrEqual(control.frame.width, 8, "\(control.role) width")
      XCTAssertGreaterThanOrEqual(control.frame.height, 8, "\(control.role) height")
      XCTAssertFalse(overlaps(control.frame, layout.status))
    }
  }

  private func overlaps(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    let hit = lhs.intersection(rhs)
    return hit.width > 0.5 && hit.height > 0.5
  }
}
