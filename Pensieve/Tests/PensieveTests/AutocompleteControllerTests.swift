import AppKit
import Foundation
import XCTest

@testable import Pensieve

@MainActor
final class AutocompleteControllerTests: XCTestCase {
  func testTypingPauseYieldsSuggestion() async {
    let engine = MockVistaAutocompleteEngine(completionHandler: { prefix, maxTokens in
      XCTAssertEqual(prefix, "hello")
      XCTAssertEqual(maxTokens, 32)
      return " world"
    })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 20_000_000)

    controller.textDidChange(prefix: "hello")
    XCTAssertNil(controller.suggestion)

    try? await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(controller.suggestion, " world")
    XCTAssertNil(controller.lastError)
  }

  func testNewKeystrokeSuppressesPriorCompletion() async {
    let engine = MockVistaAutocompleteEngine(completionHandler: { prefix, _ in
      if prefix == "alpha" {
        await nonCancellableSleep(nanoseconds: 150_000_000)
        return " stale"
      }
      await nonCancellableSleep(nanoseconds: 10_000_000)
      return " fresh"
    })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 10_000_000)

    controller.textDidChange(prefix: "alpha")
    try? await Task.sleep(nanoseconds: 30_000_000)
    controller.textDidChange(prefix: "alpha b")

    try? await Task.sleep(nanoseconds: 260_000_000)

    XCTAssertEqual(controller.suggestion, " fresh")
    XCTAssertNotEqual(controller.suggestion, " stale")
  }

  func testAcceptAutocompleteInsertsSuggestionOnce() {
    let surface = makeSurface(text: "hello")
    surface.textView.setSelectedRange(NSRange(location: 5, length: 0))
    surface.textView.setAutocompleteGhost(" world", at: 5)

    XCTAssertTrue(surface.acceptAutocompleteSuggestion())

    XCTAssertEqual(surface.textStorage.string, "hello world")
    XCTAssertNil(surface.textView.autocompleteGhostText)
  }

  func testDismissAutocompleteDoesNotMutateTextStorage() {
    let surface = makeSurface(text: "hello")
    surface.textView.setSelectedRange(NSRange(location: 5, length: 0))
    surface.textView.setAutocompleteGhost(" world", at: 5)

    XCTAssertTrue(surface.dismissAutocompleteSuggestion())

    XCTAssertEqual(surface.textStorage.string, "hello")
    XCTAssertNil(surface.textView.autocompleteGhostText)
  }

  func testInvalidateAutocompleteClearsGhostOnly() {
    let surface = makeSurface(text: "hello")
    surface.textView.setAutocompleteGhost(" world", at: 5)

    surface.invalidateAutocomplete()

    XCTAssertEqual(surface.textStorage.string, "hello")
    XCTAssertFalse(surface.textView.hasAutocompleteGhost)
  }

  func testStaleAutocompleteAnchorDoesNotInsertAfterCaretMove() {
    let surface = makeSurface(text: "hello")
    surface.textView.setSelectedRange(NSRange(location: 5, length: 0))
    surface.textView.setAutocompleteGhost(" world", at: 5)
    surface.textView.setSelectedRange(NSRange(location: 0, length: 0))

    XCTAssertFalse(surface.acceptAutocompleteSuggestion())

    XCTAssertEqual(surface.textStorage.string, "hello")
    XCTAssertFalse(surface.textView.hasAutocompleteGhost)
  }
}

private func nonCancellableSleep(nanoseconds: UInt64) async {
  await withCheckedContinuation { continuation in
    DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
      continuation.resume()
    }
  }
}

@MainActor
private func makeSurface(text: String) -> MarkdownEditorSurface {
  MarkdownEditorSurface(
    text: text,
    fontSize: 14,
    syntaxHighlightingEnabled: true,
    tableTidyOnPaste: true,
    asciiSafeTables: false,
    aiAutocompleteEnabled: true,
    autocompleteController: AutocompleteController(
      engine: MockVistaAutocompleteEngine(),
      debounceNanoseconds: 1
    )
  )
}
