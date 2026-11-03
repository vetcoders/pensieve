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
        AskSurfaceSymbol.grip, AskSurfaceSymbol.alwaysOnTopActive,
        AskSurfaceSymbol.alwaysOnTopInactive,
      ]).count,
      9)
  }

  func testDockResizePreservesEditorAndFloatUsesNativePanelAllocation() {
    let content = CGSize(width: 900, height: 700)
    var floating = AskPresentationState.expandedDefault
    XCTAssertEqual(floating.apply(.float, content: content), .presented)
    let dock = floating.preferredDockHeight
    XCTAssertTrue(floating.isAlwaysOnTop)
    XCTAssertEqual(AskPointerRoute.grip(mode: .floating), nil)
    XCTAssertEqual(AskPointerRoute.grip(mode: .docked), .dockResize)
    XCTAssertNil(AskPointerRoute.corner(mode: .floating))
    XCTAssertNil(AskPointerRoute.corner(mode: .docked))
    XCTAssertNil(AskPointerRoute.corner(mode: .hidden))

    // Floating panel allocation allocates within the panel's own window size
    let panelSize = CGSize(width: 640, height: 520)
    let floatLayout = AskSurfaceLayout.allocate(content: panelSize, presentation: floating)
    XCTAssertEqual(floatLayout.askRegion.size, panelSize)
    XCTAssertTrue(floatLayout.controls.contains { $0.role == .alwaysOnTop })

    // Dock resize resizes dock and preserves editor floor
    var docked = AskPresentationState.expandedDefault
    AskPointerRoute.apply(
      .dockResize,
      to: &docked,
      content: content,
      dockStart: docked.preferredDockHeight,
      translation: CGSize(width: 0, height: -40))
    XCTAssertEqual(docked.mode, .docked)
    XCTAssertGreaterThan(docked.preferredDockHeight, AskSurfaceLayout.preferredExpandedDockHeight)
    let dockLayout = AskSurfaceLayout.allocate(content: content, presentation: docked)
    XCTAssertFalse(dockLayout.controls.contains { $0.role == .alwaysOnTop })
    XCTAssertGreaterThanOrEqual(dockLayout.editor.height, 160)
    XCTAssertEqual(docked.preferredDockHeight, dock + 40, accuracy: 0.01)
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
