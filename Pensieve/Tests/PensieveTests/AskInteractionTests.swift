import AppKit
import XCTest

@testable import Pensieve

@MainActor
final class AskInteractionTests: XCTestCase {
  func testReturnSubmitsAndShiftReturnInsertsNewline() throws {
    let view = AskDraftTextView()
    view.isRichText = false
    var sends = 0
    view.onSubmit = { sends += 1 }
    view.string = "question"
    view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
    view.keyDown(with: try key(.shift))
    XCTAssertEqual(sends, 0)
    XCTAssertEqual(view.string, "question\n")
    view.keyDown(with: try key([]))
    XCTAssertEqual(sends, 1)
    XCTAssertEqual(view.string, "question\n")
    view.isEditable = false
    view.keyDown(with: try key([]))
    XCTAssertEqual(sends, 1, "streaming must block keyboard submission too")
  }

  func testAskConversationAndRepeatedVisibilityChangesLeaveRoomForStatusBar() throws {
    let defaults = makeEphemeralDefaults(prefix: "ask-footer")
    defaults.set(true, forKey: "pensieve.ask.visible")
    let rig = WindowErrorChromeRig(defaults: defaults)
    defer { rig.tearDown() }
    rig.appState.documentSession = .untitled()
    rig.appState.documentSession.text = "# An open document"
    rig.settle(0.3)
    let thread = rig.askThreads.thread(for: rig.appState.documentSession.askThreadID)
    thread.draft = "Explain the document"
    thread.appendDictation("Explain the document")
    rig.settle(0.3)
    let expandedHeight = try XCTUnwrap(rig.editorPaneHeight())
    assertStatusSpace(rig)
    for _ in 0..<3 {
      defaults.set(false, forKey: "pensieve.ask.visible")
      rig.settle(0.3)
      let hiddenHeight = try XCTUnwrap(rig.editorPaneHeight())
      XCTAssertGreaterThan(hiddenHeight, expandedHeight)
      assertStatusSpace(rig)
      defaults.set(true, forKey: "pensieve.ask.visible")
      rig.settle(0.3)
      XCTAssertEqual(try XCTUnwrap(rig.editorPaneHeight()), expandedHeight, accuracy: 1)
      assertStatusSpace(rig)
    }
  }

  func testConversationLeavesStatusBarInsideTheMinimumWindow() throws {
    let defaults = makeEphemeralDefaults(prefix: "ask-small-footer")
    defaults.set(true, forKey: "pensieve.ask.visible")
    let rig = WindowErrorChromeRig(defaults: defaults)
    defer { rig.tearDown() }
    rig.window.setContentSize(WindowChromeRecipe.minimumContentSize)
    rig.appState.documentSession = .untitled()
    rig.appState.documentSession.text = "# Document"
    rig.settle(0.3)
    let thread = rig.askThreads.thread(for: rig.appState.documentSession.askThreadID)
    thread.draft = "Explain"
    thread.appendDictation("Explain")
    rig.settle(0.3)
    rig.window.setContentSize(WindowChromeRecipe.minimumContentSize)
    rig.settle(0.3)
    let editor = try XCTUnwrap(rig.textView()?.enclosingScrollView)
    let rect = editor.convert(editor.bounds, to: rig.hosting)
    // The new flexible dock policy at a minimum-sized window: the dock is
    // clamped (never the old fixed 280) so the editor floor and the 26pt
    // status bar both survive. At 480pt content: dock ≤ 294, editor ≥ 160.
    let spaceBelow =
      rig.hosting.isFlipped
      ? rig.hosting.bounds.maxY - rect.maxY : rect.minY - rig.hosting.bounds.minY
    XCTAssertGreaterThanOrEqual(spaceBelow, 26, "the status bar keeps its space")
    XCTAssertLessThanOrEqual(
      spaceBelow, 320, "the clamped dock plus status bar never exceed the flexible policy")
    XCTAssertGreaterThanOrEqual(
      rect.height, 159, "the editor keeps its floor at the minimum content size")
    XCTAssertLessThanOrEqual(rig.hosting.bounds.height, 480)
    XCTAssertGreaterThanOrEqual(rect.minY, rig.hosting.bounds.minY)
    XCTAssertLessThanOrEqual(rect.maxY, rig.hosting.bounds.maxY)
  }

  func testAskTogglePreservesSidebarAndCanScrollToDocumentEnd() throws {
    let defaults = makeEphemeralDefaults(prefix: "ask-workspace-scroll")
    defaults.set(true, forKey: "pensieve.ask.visible")
    defaults.set("workspace", forKey: "pensieve.sidebar.tab")
    let rig = WindowErrorChromeRig(defaults: defaults)
    defer { rig.tearDown() }
    rig.appState.documentSession = .untitled()
    rig.appState.documentSession.text = (1...300).map { "Line \($0)\n" }.joined() + "END_SENTINEL"
    let node = WorkspaceNode(id: "fixture", name: "Note.md", kind: .document)
    rig.appState.workspaceTree = [node]
    rig.settle(0.3)
    for mode in [EditorMode.source, .split] {
      rig.appState.mode = mode
      rig.settle(0.3)
      for visible in [false, true, false] {
        defaults.set(visible, forKey: "pensieve.ask.visible")
        rig.settle(0.3)
        XCTAssertEqual(rig.appState.workspaceTree, [node])
        let search = try XCTUnwrap(findSearch(in: rig.hosting))
        XCTAssertFalse(search.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(rig.hosting.bounds.contains(search.convert(search.bounds, to: rig.hosting)))
        let editor = try XCTUnwrap(rig.textView())
        if let layout = editor.textLayoutManager {
          layout.ensureLayout(for: layout.documentRange)
        }
        editor.scrollToEndOfDocument(nil)
        rig.settle(0.2)
        XCTAssertEqual(editor.string.suffix(12), "END_SENTINEL")
        XCTAssertGreaterThanOrEqual(editor.visibleRect.maxY, editor.bounds.maxY - 2)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        XCTAssertTrue(rig.hosting.bounds.contains(scroll.convert(scroll.bounds, to: rig.hosting)))
        assertStatusSpace(rig)
      }
    }
  }

  private func findSearch(in view: NSView) -> NSSearchField? {
    if let search = view as? NSSearchField { return search }
    return view.subviews.lazy.compactMap { self.findSearch(in: $0) }.first
  }

  private func assertStatusSpace(
    _ rig: WindowErrorChromeRig, file: StaticString = #filePath, line: UInt = #line
  ) {
    guard let scroll = rig.textView()?.enclosingScrollView else {
      XCTFail("missing editor", file: file, line: line)
      return
    }
    let rect = scroll.convert(scroll.bounds, to: rig.hosting)
    let spaceBelow =
      rig.hosting.isFlipped
      ? rig.hosting.bounds.maxY - rect.maxY : rect.minY - rig.hosting.bounds.minY
    XCTAssertGreaterThanOrEqual(spaceBelow, 26, file: file, line: line)
  }

  private func key(_ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
    try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
        isARepeat: false, keyCode: 36))
  }
}
