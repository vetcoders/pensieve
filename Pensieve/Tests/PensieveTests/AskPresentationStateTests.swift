import AppKit
import XCTest

@testable import Pensieve

@MainActor
final class AskPresentationStateTests: XCTestCase {
  func testDockFloatHideKeepConversationDraftAttachmentsAndOneSubscriber() {
    let conversation = ConversationBox(id: UUID())
    let request = UUID()
    var carry = AskSurfaceCarry(
      conversation: conversation,
      draft: "keep the draft",
      attachments: ["img-a", "img-b"],
      provider: "grok",
      requestID: request,
      streamSubscribers: 1,
      presentation: .expandedDefault)
    let identity = ObjectIdentifier(conversation)
    let content = CGSize(width: 900, height: 700)
    XCTAssertEqual(carry.apply(.float, content: content), .presented)
    XCTAssertEqual(carry.apply(.dock, content: content), .presented)
    XCTAssertEqual(carry.apply(.hide, content: content), .concealed)
    XCTAssertEqual(carry.apply(.expand, content: content), .presented)
    XCTAssertEqual(carry.apply(.collapse, content: content), .presented)
    XCTAssertEqual(ObjectIdentifier(carry.conversation), identity)
    XCTAssertEqual(carry.draft, "keep the draft")
    XCTAssertEqual(carry.attachments, ["img-a", "img-b"])
    XCTAssertEqual(carry.provider, "grok")
    XCTAssertEqual(carry.requestID, request)
    XCTAssertEqual(carry.streamSubscribers, 1)
    XCTAssertNil(AskWindowPolicy.restorationClassName)
    XCTAssertNil(AskWindowPolicy.nativeWindowClassName)
    XCTAssertFalse(AskWindowPolicy.subscribesToStream)
  }

  func testHideDoesNotCancelAndStopDoesNotHide() {
    var state = AskPresentationState.expandedDefault
    let content = CGSize(width: 900, height: 700)
    state.resizeDock(to: 460, in: content)
    let dock = state.preferredDockHeight
    XCTAssertEqual(state.apply(.hide, content: content), .concealed)
    XCTAssertEqual(state.mode, .hidden)
    XCTAssertEqual(state.apply(.stop, content: content), .cancelTurn)
    XCTAssertEqual(state.mode, .hidden, "Stop must not reveal or replace the surface")
    XCTAssertEqual(state.preferredDockHeight, dock, accuracy: 0.01)
    XCTAssertNotEqual(AskSurfaceSymbol.hide, AskSurfaceSymbol.stop)
    XCTAssertEqual(AskSurfaceSymbol.hide, "xmark")
    XCTAssertEqual(AskSurfaceSymbol.stop, "stop.fill")
    XCTAssertEqual(
      Set([
        AskSurfaceSymbol.expand, AskSurfaceSymbol.collapse, AskSurfaceSymbol.float,
        AskSurfaceSymbol.dock, AskSurfaceSymbol.hide, AskSurfaceSymbol.stop,
        AskSurfaceSymbol.grip,
      ]).count,
      7)
  }

  func testGripMovesTheFloatAndTheCornerDoesNotRewriteTheDock() {
    let content = CGSize(width: 900, height: 700)
    var floating = AskPresentationState.expandedDefault
    XCTAssertEqual(floating.apply(.float, content: content), .presented)
    let dock = floating.preferredDockHeight
    let origin = floating.floatOrigin
    let size = floating.preferredFloatSize
    XCTAssertEqual(AskPointerRoute.grip(mode: .floating), .floatDrag)
    XCTAssertEqual(AskPointerRoute.grip(mode: .docked), .dockResize)
    XCTAssertEqual(AskPointerRoute.corner(mode: .floating), .floatResize)
    XCTAssertNil(AskPointerRoute.corner(mode: .docked))
    XCTAssertNil(AskPointerRoute.corner(mode: .hidden))

    AskPointerRoute.apply(
      .floatDrag,
      to: &floating,
      content: content,
      dockStart: dock,
      originStart: origin,
      sizeStart: size,
      translation: CGSize(width: 36, height: -24))
    XCTAssertEqual(floating.mode, .floating)
    XCTAssertEqual(floating.preferredDockHeight, dock, accuracy: 0.01)
    XCTAssertEqual(floating.preferredFloatSize, size)
    XCTAssertNotEqual(floating.floatOrigin, origin)
    let moved = AskSurfaceLayout.allocate(content: content, presentation: floating)
    XCTAssertEqual(moved.editor.height, content.height - 26, accuracy: 0.01)
    XCTAssertFalse(moved.controls.filter { $0.role == .resize }.isEmpty)

    let grownFrom = floating.preferredFloatSize
    AskPointerRoute.apply(
      .floatResize,
      to: &floating,
      content: content,
      dockStart: dock,
      originStart: floating.floatOrigin,
      sizeStart: grownFrom,
      translation: CGSize(width: 48, height: 40))
    XCTAssertEqual(floating.mode, .floating)
    XCTAssertEqual(floating.preferredDockHeight, dock, accuracy: 0.01)
    XCTAssertGreaterThan(floating.preferredFloatSize.width, grownFrom.width)
    XCTAssertGreaterThan(floating.preferredFloatSize.height, grownFrom.height)
    let resized = AskSurfaceLayout.allocate(content: content, presentation: floating)
    let overlap = resized.askRegion.intersection(resized.status)
    XCTAssertEqual(resized.editor.height, content.height - 26, accuracy: 0.01)
    XCTAssertFalse(overlap.width > 0.5 && overlap.height > 0.5)

    var docked = AskPresentationState.expandedDefault
    let floatOrigin = docked.floatOrigin
    AskPointerRoute.apply(
      .dockResize,
      to: &docked,
      content: content,
      dockStart: docked.preferredDockHeight,
      originStart: floatOrigin,
      sizeStart: docked.preferredFloatSize,
      translation: CGSize(width: 0, height: -40))
    XCTAssertEqual(docked.mode, .docked)
    XCTAssertEqual(docked.floatOrigin, floatOrigin)
    XCTAssertGreaterThan(docked.preferredDockHeight, AskSurfaceLayout.preferredExpandedDockHeight)
    let dockLayout = AskSurfaceLayout.allocate(content: content, presentation: docked)
    XCTAssertFalse(dockLayout.controls.contains { $0.role == .resize })
    XCTAssertGreaterThanOrEqual(dockLayout.editor.height, 160)
  }

  func testGlassIsAvailabilityGatedAndTransparencyStaysSolid() {
    XCTAssertEqual(
      AskChromeMaterial.resolve(majorVersion: 26, reduceTransparency: false, role: .floatingShell),
      .liquidGlass)
    XCTAssertEqual(
      AskChromeMaterial.resolve(majorVersion: 26, reduceTransparency: false, role: .chromeGroup),
      .liquidGlass)
    XCTAssertEqual(
      AskChromeMaterial.resolve(majorVersion: 15, reduceTransparency: false, role: .floatingShell),
      .systemMaterial)
    XCTAssertEqual(
      AskChromeMaterial.resolve(majorVersion: 15, reduceTransparency: false, role: .chromeGroup),
      .systemMaterial)
    XCTAssertEqual(
      AskChromeMaterial.resolve(majorVersion: 26, reduceTransparency: false, role: .dockShell),
      .liquidGlass)
    XCTAssertEqual(
      AskChromeMaterial.resolve(majorVersion: 15, reduceTransparency: false, role: .dockShell),
      .systemMaterial)
    XCTAssertEqual(
      AskChromeMaterial.resolve(majorVersion: 26, reduceTransparency: true, role: .dockShell),
      .solidTheme)
    XCTAssertEqual(
      AskChromeMaterial.resolve(majorVersion: 26, reduceTransparency: false, role: .transcript),
      .plain)
    XCTAssertEqual(
      AskChromeMaterial.resolve(majorVersion: 26, reduceTransparency: true, role: .floatingShell),
      .solidTheme)
    XCTAssertEqual(
      AskChromeMaterial.resolve(majorVersion: 15, reduceTransparency: true, role: .chromeGroup),
      .solidTheme)
  }

  func testLightDarkAndReduceTransparencyStayLegible() {
    let themes: [PensieveTheme] = [.porcelain, .graphite, .ink, .parchment, .typewriter]
    for theme in themes {
      for dark in [false, true] {
        let tokens = theme.tokens(underDarkSystem: dark)
        let palette = AskSurfacePalette.resolve(tokens: tokens, material: .solidTheme)
        XCTAssertTrue(
          ThemeContrast.isLegible(palette.text, on: palette.background),
          "\(theme.rawValue) dark=\(dark) ink is not legible on the source token")
        XCTAssertEqual(palette.headingFamily, tokens.previewHeadingFamily)
        XCTAssertEqual(palette.headingSize, 12, accuracy: 0.01)
        XCTAssertEqual(palette.material, .solidTheme)
      }
    }
  }
}

private final class ConversationBox: Equatable {
  let id: UUID
  init(id: UUID) { self.id = id }
  static func == (lhs: ConversationBox, rhs: ConversationBox) -> Bool { lhs.id == rhs.id }
}
