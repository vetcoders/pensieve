import Foundation
import XCTest

@testable import Pensieve

@MainActor
final class AutocompleteControllerTests: XCTestCase {
  func testTypingPauseYieldsSuggestion() async {
    let engine = MockVistaAutocompleteEngine { prefix, maxTokens in
      XCTAssertEqual(prefix, "hello")
      XCTAssertEqual(maxTokens, 32)
      return " world"
    }
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 20_000_000)

    controller.textDidChange(prefix: "hello")
    XCTAssertNil(controller.suggestion)

    try? await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(controller.suggestion, " world")
    XCTAssertNil(controller.lastError)
  }

  func testNewKeystrokeSuppressesPriorCompletion() async {
    let engine = MockVistaAutocompleteEngine { prefix, _ in
      if prefix == "alpha" {
        await nonCancellableSleep(nanoseconds: 150_000_000)
        return " stale"
      }
      await nonCancellableSleep(nanoseconds: 10_000_000)
      return " fresh"
    }
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 10_000_000)

    controller.textDidChange(prefix: "alpha")
    try? await Task.sleep(nanoseconds: 30_000_000)
    controller.textDidChange(prefix: "alpha b")

    try? await Task.sleep(nanoseconds: 260_000_000)

    XCTAssertEqual(controller.suggestion, " fresh")
    XCTAssertNotEqual(controller.suggestion, " stale")
  }
}

private func nonCancellableSleep(nanoseconds: UInt64) async {
  await withCheckedContinuation { continuation in
    DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
      continuation.resume()
    }
  }
}
