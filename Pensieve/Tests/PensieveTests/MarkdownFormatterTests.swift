import AppKit
import SwiftUI
import XCTest

@testable import Pensieve

final class MarkdownFormatterTests: XCTestCase {
  func testLegacyMarkdownFormatterOutputs() {
    XCTAssertEqual(MarkdownFormatter.format("text", as: .bold), "**text**")
    XCTAssertEqual(MarkdownFormatter.format("text", as: .italic), "*text*")
    XCTAssertEqual(MarkdownFormatter.format("text", as: .strike), "~~text~~")
    XCTAssertEqual(MarkdownFormatter.format("text", as: .code), "```\ntext\n```")
    XCTAssertEqual(MarkdownFormatter.format("text", as: .link), "[text](url)")
    XCTAssertEqual(MarkdownFormatter.format("one\ntwo", as: .quote), "> one\n> two\n")
    XCTAssertEqual(MarkdownFormatter.format("one\ntwo", as: .bulletedList), "- one\n- two\n")
    XCTAssertEqual(MarkdownFormatter.format("one\ntwo", as: .numberedList), "1. one\n1. two\n")
  }

  @MainActor
  func testControllerMarkdownFormatCommandAppliesToEditorSelectionAndMarksDirty() {
    var boundText = "alpha beta"
    var isDirty = false
    var didRouteDocumentChange = false
    let appState = AppState()
    let ref = DocumentRef(id: URL(fileURLWithPath: "/tmp/pensieve-format.md"))
    appState.documentSession = DocumentSession(document: ref, text: boundText)
    let controller = AppController(appState: appState)
    let surface = MarkdownEditorSurface(text: boundText, fontSize: 14)
    surface.onTextChanged = { newText in
      boundText = newText
      isDirty = true
      didRouteDocumentChange = true
    }
    surface.textView.setSelectedRange(NSRange(location: 6, length: 4))

    controller.applyMarkdownFormat(.bold)
    let command = appState.pendingMarkdownFormatCommand
    let representable = EditorRepresentable(
      text: Binding(get: { boundText }, set: { boundText = $0 }),
      fontSize: 14,
      syntaxHighlightingEnabled: true,
      formattingCommand: command,
      isDirty: Binding(get: { isDirty }, set: { isDirty = $0 }),
      onDocumentChanged: {
        didRouteDocumentChange = true
      }
    )
    let coordinator = representable.makeCoordinator()

    coordinator.apply(command, to: surface)

    XCTAssertEqual(surface.textStorage.string, "alpha **beta**")
    XCTAssertEqual(boundText, "alpha **beta**")
    XCTAssertTrue(isDirty)
    XCTAssertTrue(didRouteDocumentChange)
  }

  @MainActor
  func testEmptySelectionFormattingIsLegacyNoOp() {
    var didRouteDocumentChange = false
    let surface = MarkdownEditorSurface(text: "plain", fontSize: 14)
    surface.onTextChanged = { _ in
      didRouteDocumentChange = true
    }
    surface.textView.setSelectedRange(NSRange(location: 0, length: 0))

    let didApply = surface.applyMarkdownFormat(.italic)

    XCTAssertFalse(didApply)
    XCTAssertEqual(surface.textStorage.string, "plain")
    XCTAssertFalse(didRouteDocumentChange)
  }
}
