import AppKit
import XCTest

@testable import Pensieve

/// Toolbar width is a correctness property, not taste.
///
/// macOS hides whole toolbar families behind the "»" clipped-items menu the
/// moment the titlebar runs out of room, and it hides them from the TRAILING
/// end first — mode, preview runtime, assistants. That is what the operator met
/// at a 1450pt window: a mode picker carrying four titled segments and a 300pt
/// width floor took 300pt of a 1096pt toolbar, and the three trailing families
/// went behind the chevron at a perfectly ordinary working width.
///
/// So the toolbar gets a budget, and the budget is checked two ways: the width
/// the items actually occupy, and the window width at which macOS starts
/// clipping. The second is the property the operator feels; the first is the one
/// that tells the next author WHY their new control did not fit.
final class EditorToolbarWidthBudgetTests: XCTestCase {
  /// The most the toolbar's items may occupy, in points.
  ///
  /// Derived from the operator's working window rather than picked as a ceiling
  /// that today's toolbar happens to clear. Measured on this rig at full width:
  ///
  ///   * 92pt — the titlebar's leading inset, where the traffic lights sit
  ///     (`NSToolbarTitleView` starts at x = 92).
  ///   * 300pt — what `NSToolbarTitleStackView` asks for. The real window needs
  ///     it: it carries a document name AND the 5.2 breadcrumb subtitle, where
  ///     this rig carries "Untitled" and nothing.
  ///   * ~48pt — the sidebar toggle `NavigationSplitView` puts in the leading
  ///     area of the shipping window and this rig has no column to toggle.
  ///
  /// 1450 − 92 − 300 − 48 ≈ 1010, rounded down to a round 1000. Today's toolbar
  /// measures 944pt, so a new control has ~56pt of slack — about one and a half
  /// icon segments. That tightness is deliberate: past this line a new control
  /// has to be paid for by removing or shrinking another one, not by pushing a
  /// family behind the chevron.
  static let itemWidthBudget: CGFloat = 1000

  /// The widest window that is still allowed to clip.
  ///
  /// The operator's window is 1450pt. This rig sits below the shipping window's
  /// real demand — no sidebar toggle, a one-word title, no breadcrumb — so the
  /// rig's own threshold has to clear 1450 by a margin rather than merely reach
  /// it. 200pt is that margin: an engineering allowance for the two chrome
  /// elements above, not a measurement.
  static let clippingThresholdCeiling: CGFloat = 1250

  @MainActor
  func testToolbarItemsFitTheWidthBudget() throws {
    let rig = try makeToolbarRig(prefix: "EditorToolbarWidthBudgetTests")
    defer { rig.tearDown() }

    XCTAssertEqual(
      rig.itemViewers.count, rig.toolbar?.items.count,
      "the rig has to measure a toolbar that is fully laid out — some family is already clipped")

    let width = rig.laidOutItemWidth
    XCTAssertGreaterThan(width, 0, "no toolbar geometry to measure")
    XCTAssertLessThanOrEqual(
      width, Self.itemWidthBudget,
      "the toolbar now needs \(Int(width))pt of titlebar, over the \(Int(Self.itemWidthBudget))pt "
        + "budget — at the operator's 1450pt window macOS will start dropping trailing families "
        + "into the » menu. Shrink or drop a control instead of raising this number.")
  }

  @MainActor
  func testNoFamilyIsClippedAtTheOperatorsWorkingWidth() throws {
    let rig = try makeToolbarRig(prefix: "EditorToolbarWidthBudgetTests")
    defer { rig.tearDown() }
    let declared = try XCTUnwrap(rig.toolbar?.items.count)

    for width in [1450, 1350, Int(Self.clippingThresholdCeiling)] as [Int] {
      rig.resize(to: CGFloat(width))
      XCTAssertEqual(
        rig.visibleItemCount, declared,
        "at a \(width)pt window macOS is showing \(rig.visibleItemCount) of \(declared) toolbar "
          + "families — the rest are behind the » chevron")
    }
  }

  /// The measured number, so a change to the toolbar reports WHERE the threshold
  /// moved instead of only that it moved.
  @MainActor
  func testClippingThresholdIsReportedAndUnderTheCeiling() throws {
    let rig = try makeToolbarRig(prefix: "EditorToolbarWidthBudgetTests")
    defer { rig.tearDown() }
    let declared = try XCTUnwrap(rig.toolbar?.items.count)

    func fits(_ width: CGFloat) -> Bool {
      rig.resize(to: width)
      return rig.visibleItemCount == declared
    }

    // Binary search on a monotone predicate: wider always fits at least as well.
    var tooNarrow: CGFloat = 600
    var wideEnough: CGFloat = 1600
    guard fits(wideEnough) else {
      return XCTFail("the toolbar does not fit even a 1600pt window")
    }
    while wideEnough - tooNarrow > 25 {
      let middle = ((tooNarrow + wideEnough) / 2).rounded()
      if fits(middle) { wideEnough = middle } else { tooNarrow = middle }
    }

    XCTAssertLessThanOrEqual(
      wideEnough, Self.clippingThresholdCeiling,
      "macOS starts clipping toolbar families at \(Int(wideEnough))pt, over the "
        + "\(Int(Self.clippingThresholdCeiling))pt ceiling this rig has to clear for the "
        + "operator's 1450pt window to stay whole")
  }
}
