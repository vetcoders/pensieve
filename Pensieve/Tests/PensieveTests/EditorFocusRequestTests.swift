import AppKit
import XCTest

@testable import Pensieve

final class EditorFocusRequestTests: XCTestCase {
  @MainActor
  func testOrdinaryEditorUpdatePreservesAnotherFirstResponderAndSynchronizesTheBuffer() {
    let (surface, window, sentinel) = makeHostedSurface(text: "old buffer")
    XCTAssertTrue(window.makeFirstResponder(sentinel))

    surface.update(
      text: "opened file buffer",
      fontSize: 14,
      syntaxHighlightingEnabled: true,
      tableTidyOnPaste: true,
      asciiSafeTables: false,
      aiAutocompleteEnabled: false,
      findQuery: "",
      findBarVisible: false)

    XCTAssertTrue(window.firstResponder === sentinel)
    XCTAssertEqual(surface.textStorage.string, "opened file buffer")
  }

  @MainActor
  func testOnlyABrandNewUntitledSessionArmsAnEditorFocusRequest() throws {
    let appState = AppState()
    let file = DocumentRef(id: URL(fileURLWithPath: "/tmp/focus-pin.md"))

    appState.documentSession = DocumentSession(document: file, text: "file", isDirty: false)
    XCTAssertNil(appState.editorFocusRequest)

    appState.documentSession.restoreUntitled(
      title: "Recovered.md",
      text: "recovered",
      recoveryID: UUID())
    XCTAssertNil(appState.editorFocusRequest)

    appState.documentSession.createUntitled()
    let firstRequest = try XCTUnwrap(appState.editorFocusRequest)
    XCTAssertEqual(firstRequest.sessionIdentity, appState.documentSession.identity)

    appState.activeDocumentText = "typed after focus"
    XCTAssertTrue(appState.editorFocusRequest === firstRequest)

    appState.documentSession.createUntitled(title: "Untitled 2.md")
    XCTAssertFalse(appState.editorFocusRequest === firstRequest)
    XCTAssertEqual(appState.editorFocusRequest?.sessionIdentity, appState.documentSession.identity)
  }

  @MainActor
  func testMatchingNewSessionRequestFocusesTheEditorExactlyOnceWithoutChangingTheBuffer() throws {
    let appState = AppState()
    appState.documentSession.createUntitled()
    let request = try XCTUnwrap(appState.editorFocusRequest)
    let (surface, window, sentinel) = makeHostedSurface(text: "draft survives")
    XCTAssertTrue(window.makeFirstResponder(sentinel))

    surface.applyEditorFocusRequest(
      request,
      currentSessionIdentity: appState.documentSession.identity)

    XCTAssertTrue(window.firstResponder === surface.textView)
    XCTAssertEqual(surface.textStorage.string, "draft survives")
    XCTAssertTrue(request.isConsumed)

    XCTAssertTrue(window.makeFirstResponder(sentinel))
    surface.applyEditorFocusRequest(
      request,
      currentSessionIdentity: appState.documentSession.identity)

    XCTAssertTrue(window.firstResponder === sentinel)
    XCTAssertEqual(surface.textStorage.string, "draft survives")
  }

  @MainActor
  func testRequestForAReplacedSessionDoesNotTakeFocusFromTheCurrentControl() throws {
    let appState = AppState()
    appState.documentSession.createUntitled()
    let staleRequest = try XCTUnwrap(appState.editorFocusRequest)
    let file = DocumentRef(id: URL(fileURLWithPath: "/tmp/current-file.md"))
    appState.documentSession = DocumentSession(document: file, text: "file", isDirty: false)
    let (surface, window, sentinel) = makeHostedSurface(text: "current file buffer")
    XCTAssertTrue(window.makeFirstResponder(sentinel))

    surface.applyEditorFocusRequest(
      staleRequest,
      currentSessionIdentity: appState.documentSession.identity)

    XCTAssertTrue(window.firstResponder === sentinel)
    XCTAssertEqual(surface.textStorage.string, "current file buffer")
    XCTAssertTrue(staleRequest.isConsumed)
  }

  /// The ATTEMPT spends the request, not its success. When the responder chain
  /// refuses the change — here the current control declines to resign — the
  /// request must still be spent, or it sits armed and yanks focus into the
  /// editor on some later, unrelated re-render.
  @MainActor
  func testRefusedFocusChangeStillSpendsTheRequestInsteadOfStealingFocusLater() throws {
    let appState = AppState()
    appState.documentSession.createUntitled()
    let request = try XCTUnwrap(appState.editorFocusRequest)
    let surface = MarkdownEditorSurface(text: "draft survives", fontSize: 14)
    let sentinel = StubbornFocusSentinel(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    let window = NSWindow(
      contentRect: container.bounds,
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true)
    window.contentView = container
    container.addSubview(surface.scrollView)
    container.addSubview(sentinel)
    XCTAssertTrue(window.makeFirstResponder(sentinel))

    surface.applyEditorFocusRequest(
      request,
      currentSessionIdentity: appState.documentSession.identity)

    XCTAssertTrue(
      window.firstResponder === sentinel, "precondition: the focus change was refused")
    XCTAssertTrue(request.isConsumed, "a refused apply must still spend the one-shot request")

    // A later pass over the same session — the control now willing to resign —
    // must NOT be able to replay the spent request.
    sentinel.refusesToResign = false
    surface.applyEditorFocusRequest(
      request,
      currentSessionIdentity: appState.documentSession.identity)

    XCTAssertTrue(
      window.firstResponder === sentinel,
      "a spent request must never take focus on a later update")
    XCTAssertEqual(surface.textStorage.string, "draft survives")
  }

  @MainActor
  func testControllerNewRequestTraversesTheLiveEditorViewAndTakesFirstResponder() throws {
    let rig = WindowErrorChromeRig(
      defaults: makeEphemeralDefaults(prefix: "editor-focus-live-bridge"))
    defer { rig.tearDown() }
    let sentinel = FocusSentinel(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    // Keep the test responder beside SwiftUI's owned hierarchy.
    let container = NSView(frame: rig.hosting.frame)
    rig.window.contentView = container
    rig.hosting.autoresizingMask = [.width, .height]
    container.addSubview(rig.hosting)
    container.addSubview(sentinel)
    XCTAssertTrue(rig.window.makeFirstResponder(sentinel))

    XCTAssertTrue(rig.controller.createUntitledDocument())
    rig.settle(0.3)

    let editor = try XCTUnwrap(rig.textView(), "the new session mounted no source editor")
    XCTAssertTrue(rig.window.firstResponder === editor)
    XCTAssertEqual(editor.string, "")
    XCTAssertEqual(rig.appState.activeDocumentText, "")
  }

  @MainActor
  private func makeHostedSurface(text: String) -> (MarkdownEditorSurface, NSWindow, FocusSentinel) {
    let surface = MarkdownEditorSurface(text: text, fontSize: 14)
    let sentinel = FocusSentinel(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    let window = NSWindow(
      contentRect: container.bounds,
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true)

    window.contentView = container
    container.addSubview(surface.scrollView)
    container.addSubview(sentinel)
    return (surface, window, sentinel)
  }
}

private final class FocusSentinel: NSView {
  override var acceptsFirstResponder: Bool { true }
}

/// A control that declines to hand over first responder — the ordinary AppKit
/// reason `makeFirstResponder` returns false (a field mid-validation, a sheet's
/// own responder). Flip `refusesToResign` to let it go.
private final class StubbornFocusSentinel: NSView {
  var refusesToResign = true
  override var acceptsFirstResponder: Bool { true }
  override func resignFirstResponder() -> Bool { !refusesToResign }
}
