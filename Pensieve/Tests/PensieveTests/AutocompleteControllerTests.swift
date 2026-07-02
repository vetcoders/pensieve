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

  func testCompletionPathNeverTouchesSttModelInit() async {
    // complete() is an HTTP call to the LLM endpoint; initModel() loads the
    // whisper STT model. The completion path must not couple to STT: with the
    // model "not loaded", a suggestion must still arrive and init must never run.
    let engine = MockVistaAutocompleteEngine(
      completionHandler: { _, _ in " suggestion" },
      modelLoaded: false,
      initModelHandler: {
        XCTFail("completion path must not init the STT model")
      })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 1)

    controller.textDidChange(prefix: "hello")
    for _ in 0..<200 where controller.suggestion == nil {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(controller.suggestion, " suggestion")
    XCTAssertNil(controller.lastError)
  }

  func testEngineFactoryIsInvokedLazilyAndOnce() async {
    let factoryCalls = AttemptCounter()
    let controller = AutocompleteController(
      engineFactory: {
        factoryCalls.increment()
        return MockVistaAutocompleteEngine(completionHandler: { _, _ in " world" })
      },
      debounceNanoseconds: 10_000_000)

    XCTAssertEqual(factoryCalls.value, 0, "the factory must not run at construction time")

    controller.textDidChange(prefix: "hello")
    try? await Task.sleep(nanoseconds: 80_000_000)
    XCTAssertEqual(controller.suggestion, " world")

    controller.textDidChange(prefix: "hello w")
    try? await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(factoryCalls.value, 1, "the resolved engine must be cached across requests")
  }

  func testProductionDefaultSurfaceHasEngineSource() {
    // Guards the EditorView wiring: the default MarkdownEditorSurface (the
    // production path through EditorRepresentable.makeNSView) must own a
    // controller with a real engine source. The factory is lazy, so this
    // never constructs a VistaEngine.
    let surface = MarkdownEditorSurface(text: "hello", fontSize: 14)
    XCTAssertTrue(surface.autocompleteController.hasEngineSource)
  }

  func testTypedUnavailableLatchesAcrossKeystrokes() async {
    let attempts = AttemptCounter()
    let unavailable = VistaError.ModelError(
      msg: "completion LLM unavailable: set LLM_ENDPOINT, LLM_ASSISTIVE_ENDPOINT, "
        + "or LLM_FORMATTING_ENDPOINT")
    let engine = MockVistaAutocompleteEngine(completionHandler: { _, _ in
      attempts.increment()
      throw unavailable
    })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 10_000_000)

    controller.textDidChange(prefix: "hello")
    try? await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(attempts.value, 1)
    XCTAssertTrue(controller.lastError?.hasPrefix("completion LLM unavailable") == true)

    controller.textDidChange(prefix: "hello a")
    try? await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(
      attempts.value, 1, "typed unavailable must not be retried per keystroke")
    XCTAssertTrue(controller.lastError?.hasPrefix("completion LLM unavailable") == true)
    XCTAssertNil(controller.suggestion)
  }

  func testTransientCompletionErrorDoesNotLatch() async {
    let attempts = AttemptCounter()
    let engine = MockVistaAutocompleteEngine(completionHandler: { _, _ in
      attempts.increment()
      throw VistaError.ModelError(msg: "completion request failed: connection reset")
    })
    let controller = AutocompleteController(engine: engine, debounceNanoseconds: 10_000_000)

    controller.textDidChange(prefix: "hello")
    try? await Task.sleep(nanoseconds: 80_000_000)
    XCTAssertEqual(controller.lastError, "completion request failed: connection reset")

    controller.textDidChange(prefix: "hello a")
    try? await Task.sleep(nanoseconds: 80_000_000)

    XCTAssertEqual(
      attempts.value, 2,
      "a transient failure must not kill autocomplete; the debounce is the storm guard")
  }

  func testCancelResetsUnavailableLatch() async {
    let attempts = AttemptCounter()
    let engine = MockVistaAutocompleteEngine(completionHandler: { _, _ in
      attempts.increment()
      throw VistaError.ModelError(msg: "completion LLM unavailable: set LLM_ENDPOINT")
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
