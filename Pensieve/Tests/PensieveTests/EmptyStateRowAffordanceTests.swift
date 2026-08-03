import XCTest

@testable import Pensieve

/// The empty state's action rows have to LOOK clickable.
///
/// Before this cut the ⌘N row and every Recent entry were `.buttonStyle(.plain)`
/// buttons with no hover wash and no cursor change — and the detail-pane host
/// imposes its own `foregroundStyle` hierarchy, which swallows the dimming a
/// plain button shows while pressed. The rows were therefore indistinguishable
/// from the caption text beside them in all three interaction states.
final class EmptyStateRowAffordanceTests: XCTestCase {
  func testRestingRowPaintsNothing() {
    XCTAssertEqual(
      EmptyStateRowButtonStyle.fillOpacity(isHovering: false, isPressed: false),
      0,
      "a row nobody is pointing at must stay as quiet as the caption text around it")
  }

  func testHoverIsVisibleAndPressIsStronger() {
    let hover = EmptyStateRowButtonStyle.fillOpacity(isHovering: true, isPressed: false)
    let pressed = EmptyStateRowButtonStyle.fillOpacity(isHovering: true, isPressed: true)

    XCTAssertGreaterThan(hover, 0, "hover is the affordance; an invisible one is no affordance")
    XCTAssertGreaterThan(
      pressed, hover, "the press has to read as a distinct state, not as more hover")
    XCTAssertLessThan(
      pressed, 0.5,
      "this is affordance, not decoration — the wash must never take over the row")
  }

  /// A press that arrives without a hover (VoiceOver, a keyboard activation, a
  /// tap while the pointer sat still) still has to show the pressed state.
  func testPressedWithoutHoverStillPaints() {
    XCTAssertEqual(
      EmptyStateRowButtonStyle.fillOpacity(isHovering: false, isPressed: true),
      EmptyStateRowButtonStyle.fillOpacity(isHovering: true, isPressed: true),
      "pressed is pressed regardless of where the pointer is")
  }

  /// The wash is tinted from the same accessor the sidebar's row selection takes,
  /// so a hover in the empty state and a hover in the file tree cannot drift onto
  /// two different accents.
  @MainActor
  func testWashTakesTheSameChromeAccentAsSidebarRows() {
    for theme in PensieveTheme.allCases {
      XCTAssertEqual(
        SidebarView.chromeAccentColor(for: theme.tokens),
        theme.tokens.legibleAccent,
        "\(theme) empty-state rows must wash with the sidebar's chrome accent")
    }
  }
}
