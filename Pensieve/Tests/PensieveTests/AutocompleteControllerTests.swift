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

  func testNewKeystrokeCancelsPriorTaskBeforeEngineCompletes() async {
    let staleTaskObservedCancellation = expectation(
      description: "stale completion task observed cancellation")
    let engine = MockVistaAutocompleteEngine(completionHandler: { prefix, _ in
      if prefix == "alpha" {
        await nonCancellableSleep(nanoseconds: 80_000_000)
        XCTAssertTrue(Task.isCancelled)
        staleTaskObservedCancellation.fulfill()
        return " stale"
      }
      return " fresh"
    })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 1)

    controller.textDidChange(prefix: "alpha")
    try? await Task.sleep(nanoseconds: 20_000_000)
    controller.textDidChange(prefix: "alpha b")

    await fulfillment(of: [staleTaskObservedCancellation], timeout: 1.0)
    try? await Task.sleep(nanoseconds: 80_000_000)

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

  func testEditInvalidatesAutocompleteAndPreventsStaleInsert() {
    let surface = makeSurface(text: "hello")
    surface.textView.setSelectedRange(NSRange(location: 5, length: 0))
    surface.textView.setAutocompleteGhost(" world", at: 5)

    XCTAssertTrue(surface.textView.insertTextAtSelection("!"))
    XCTAssertFalse(surface.acceptAutocompleteSuggestion())

    XCTAssertEqual(surface.textStorage.string, "hello!")
    XCTAssertFalse(surface.textView.hasAutocompleteGhost)
  }

  func testDefaultControllerWithoutEngineSurfacesUnavailableError() {
    let controller = AutocompleteController(debounceNanoseconds: 1)

    controller.textDidChange(prefix: "hello")

    XCTAssertNil(controller.suggestion)
    XCTAssertEqual(controller.lastError, AutocompleteController.engineUnavailableMessage)
  }

  func testRequestArrivingDuringModelInitCompletesAfterInit() async {
    let attempts = AttemptCounter()
    let initEntered = expectation(description: "model init entered")
    let releaseInit = DispatchSemaphore(value: 0)
    let engine = MockVistaAutocompleteEngine(
      completionHandler: { prefix, _ in
        XCTAssertEqual(prefix, "hello a", "only the newest request may complete")
        return " suggestion"
      },
      modelLoaded: false,
      initModelHandler: {
        attempts.increment()
        initEntered.fulfill()
        releaseInit.wait()
      })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 1)

    controller.textDidChange(prefix: "hello")
    await fulfillment(of: [initEntered], timeout: 2)

    // A newer keystroke lands while the first request is still loading the
    // model; it must join the shared init instead of bailing.
    controller.textDidChange(prefix: "hello a")
    try? await Task.sleep(nanoseconds: 40_000_000)
    releaseInit.signal()

    for _ in 0..<200 where controller.suggestion == nil {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(
      controller.suggestion, " suggestion",
      "the request that arrived during init must complete once init lands")
    XCTAssertNil(controller.lastError)
    XCTAssertEqual(attempts.value, 1, "init stays single-flight")
  }

  func testInitModelFailureLatchesAcrossKeystrokes() async {
    let attempts = AttemptCounter()
    let engine = MockVistaAutocompleteEngine(
      modelLoaded: false,
      initModelHandler: {
        attempts.increment()
        throw InitModelTestFailure()
      })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 10_000_000)

    controller.textDidChange(prefix: "hello")
    try? await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(controller.lastError, InitModelTestFailure().errorDescription)
    XCTAssertEqual(attempts.value, 1)

    controller.textDidChange(prefix: "hello a")
    try? await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(attempts.value, 1, "failed init must not be retried per keystroke")
    XCTAssertEqual(controller.lastError, InitModelTestFailure().errorDescription)
  }

  func testInitModelFailureLatchEngagesEvenWhenRequestSuperseded() async {
    let attempts = AttemptCounter()
    let engine = MockVistaAutocompleteEngine(
      modelLoaded: false,
      initModelHandler: {
        attempts.increment()
        usleep(100_000)  // keep init in flight while a newer keystroke supersedes it
        throw InitModelTestFailure()
      })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 10_000_000)

    controller.textDidChange(prefix: "hello")
    try? await Task.sleep(nanoseconds: 40_000_000)
    controller.textDidChange(prefix: "hello a")
    try? await Task.sleep(nanoseconds: 250_000_000)

    controller.textDidChange(prefix: "hello ab")
    try? await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(
      attempts.value, 1,
      "latch is engine-global; a superseded request must still arm it")
  }

  func testCancelResetsInitFailureLatch() async {
    let attempts = AttemptCounter()
    let engine = MockVistaAutocompleteEngine(
      modelLoaded: false,
      initModelHandler: {
        attempts.increment()
        throw InitModelTestFailure()
      })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 10_000_000)

    controller.textDidChange(prefix: "hello")
    try? await Task.sleep(nanoseconds: 80_000_000)
    XCTAssertEqual(attempts.value, 1)

    controller.cancel()
    controller.textDidChange(prefix: "hello again")
    try? await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(attempts.value, 2, "cancel() must re-open the deliberate retry path")
  }

  func testAIAutocompleteSettingDefaultsOffAndPersists() {
    let suiteName = "AutocompleteControllerTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let model = DocumentWindowModel(defaults: defaults)
    XCTAssertFalse(model.aiAutocompleteEnabled)

    model.aiAutocompleteEnabled = true
    let reloaded = DocumentWindowModel(defaults: defaults)
    XCTAssertTrue(reloaded.aiAutocompleteEnabled)
  }
}

private struct InitModelTestFailure: Error, LocalizedError {
  var errorDescription: String? { "init model boom" }
}

private final class AttemptCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
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
